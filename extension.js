const vscode = require("vscode");
const { spawn, execFile } = require("child_process");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const ADB = resolveAdb();
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const LOGFILE = "/tmp/emulator-view.log";
function extLog(msg) {
  const line = "[emulator-view] " + msg;
  console.log(line);
  try {
    fs.appendFileSync(LOGFILE, "[" + new Date().toISOString() + "] " + msg + "\n");
  } catch (_) {}
}

function resolveAdb() {
  const candidates = [
    process.env.ADB_PATH,
    process.env.ANDROID_HOME && path.join(process.env.ANDROID_HOME, "platform-tools", "adb"),
    process.env.ANDROID_SDK_ROOT && path.join(process.env.ANDROID_SDK_ROOT, "platform-tools", "adb"),
    "/workspaces/android-sdk/platform-tools/adb",
    path.join(os.homedir(), "Android", "Sdk", "platform-tools", "adb"),
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      fs.accessSync(c, fs.constants.X_OK);
      return c;
    } catch (_) {}
  }
  return "adb";
}

// execFile()'s timeout only sends SIGTERM. If the child ignores it (a booting
// emulator can wedge the adb client) the callback never fires and the promise
// never resolves - which silently freezes the whole frame loop. spawn() plus
// an explicit SIGKILL cannot get stuck that way.
function adb(args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(ADB, args);
    const out = [];
    const err = [];
    let done = false;
    const finish = (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ err: e || null, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") });
    };
    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch (_) {}
      finish(new Error("timeout"));
    }, opts.timeout || 20000);
    child.stdout.on("data", (d) => out.push(d));
    child.stderr.on("data", (d) => err.push(d));
    child.on("error", (e) => finish(e));
    child.on("close", (code) => finish(code === 0 ? null : new Error("exit " + code)));
  });
}

async function deviceSerial() {
  const { stdout } = await adb(["devices"]);
  for (const line of stdout.split("\n").slice(1)) {
    const parts = line.trim().split(/\s+/);
    if (parts.length >= 2 && parts[1] === "device") return parts[0];
  }
  return null;
}

class EmulatorSession {
  constructor(panel) {
    this.panel = panel;
    this.serial = null;
    this.running = false;
    this.lastFrame = null;
    this.frames = 0;
    this.width = 0;
    this.height = 0;
    this.status = "starting";
    this.grpc = new EmulatorGrpc();
    this.captureMode = "adb";
    this.misses = 0;
    this.pendingFrame = null;
    this.frameInFlight = false;
    this.frameSentAt = 0;
    this.hotUntil = 0;
  }

  log(msg) {
    extLog(msg);
    this.panel.webview.postMessage({ type: "log", message: msg });
  }

  async start() {
    // Start immediately: do NOT depend on the webview posting a "ready"
    // message. If the webview script is slow, blocked by CSP, or fails to
    // load, the session must still run and push frames when it recovers.
    if (this.running) return;
    this.running = true;
    this.loop();
  }

  async loop() {
    while (this.running) {
      if (!this.serial) {
        this.serial = await deviceSerial();
        if (!this.serial) {
          this.status = "no device";
          this.log("No Android device found - waiting for the emulator...");
          await delay(5000);
          continue;
        }
        this.status = "connected";
        this.log("Attached to " + this.serial);
        this.post({ type: "status", device: this.serial, state: this.status });
      }
      try {
        const frame = await this.capture();
        if (frame) {
          this.misses = 0;
          // Only push when the screen actually changed. The emulator hands out
          // the same framebuffer over and over, and re-posting identical PNGs
          // makes the browser decode 30 images a second for nothing.
          const changed = !this.lastFrame || !this.lastFrame.equals(frame);
          this.lastFrame = frame;
          this.frames++;
          if (changed) this.pendingFrame = frame;
          this.flushFrame();
          if (this.frames === 1 || this.frames % 100 === 0) {
            extLog("frame " + this.frames + " (" + this.width + "x" + this.height + ", " + frame.length + "B, via " + this.captureMode + ")");
          }
        } else {
          // Two empty captures in a row means the device is gone or wedged:
          // drop the serial so the loop re-detects it instead of hammering a
          // dead emulator forever.
          this.misses = (this.misses || 0) + 1;
          if (this.misses >= 2) {
            extLog("capture failed twice - re-detecting the device");
            this.serial = null;
            this.misses = 0;
          }
        }
      } catch (_) {}
      // Poll fast right after a gesture (the screen is about to change), and
      // slow down when nothing is happening. A constant 30 fps poll burns a
      // full host core in the emulator - and the host only has 2 vCPUs, which
      // the guest UI needs.
      const hot = Date.now() < (this.hotUntil || 0);
      await delay(hot ? 30 : this.captureMode === "grpc" ? 90 : 150);
    }
  }

  // Push the newest frame to the webview, but never more than one frame in
  // flight. Without this the extension queues frames faster than the browser
  // can decode them: the picture then updates in bursts and, worse, the input
  // messages (which travel in the same channel) queue up behind the frames -
  // so a click takes seconds to arrive or is lost entirely.
  flushFrame(now = Date.now()) {
    if (!this.pendingFrame) return;
    if (this.frameInFlight && now - (this.frameSentAt || 0) < 750) return;
    const frame = this.pendingFrame;
    this.pendingFrame = null;
    this.frameInFlight = true;
    this.frameSentAt = now;
    this.post({
      type: "frame",
      data: frame.toString("base64"),
      width: this.width,
      height: this.height,
      frames: this.frames,
    });
  }

  // The webview tells us when it has decoded the frame.
  onFrameAck() {
    this.frameInFlight = false;
    this.flushFrame();
  }

  // A freshly created webview knows nothing: it has no screen size, so every
  // tap would be dropped ("if (!naturalW || !naturalH) return"), and it shows
  // an empty box until the next screen change. Hand it the current frame
  // right away.
  primeWebview() {
    this.frameInFlight = false;
    if (this.lastFrame) this.pendingFrame = this.lastFrame;
    this.flushFrame();
  }

  post(msg) {
    this.panel.webview.postMessage(msg);
  }

  // Fast path: the emulator's own gRPC screenshot (~26 ms). Fallback: adb
  // screencap (~700 ms), which still works but is slow.
  async capture() {
    const png = await this.grpc.getScreenshot();
    if (png) {
      this.captureMode = "grpc";
      if (png.length >= 24) {
        this.width = png.readUInt32BE(16);
        this.height = png.readUInt32BE(20);
      }
      return png;
    }
    this.captureMode = "adb";
    return this.captureAdb();
  }

  captureAdb() {
    return new Promise((resolve) => {
      const p = spawn(ADB, ["-s", this.serial, "exec-out", "screencap", "-p"]);
      const chunks = [];
      let size = 0;
      let settled = false;
      const finish = (v) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(v);
      };
      // A screencap against a booting or wedged emulator NEVER returns. Without
      // this timeout one such call freezes the whole frame pump for good.
      const timer = setTimeout(() => {
        try { p.kill("SIGKILL"); } catch (_) {}
        finish(null);
      }, 20000);
      p.stdout.on("data", (d) => {
        chunks.push(d);
        size += d.length;
        if (size > 64 * 1024 * 1024) p.kill();
      });
      p.on("error", () => finish(null));
      p.on("close", () => {
        if (!chunks.length) return finish(null);
        const buf = Buffer.concat(chunks);
        if (buf.length < 8 || !buf.slice(0, 8).equals(PNG_MAGIC)) return finish(null);
        this.width = buf.readUInt32BE(16);
        this.height = buf.readUInt32BE(20);
        finish(buf);
      });
    });
  }

  // Input is serialised through a promise chain.
  //
  // "adb shell input tap" costs ~220-600 ms on this emulator (it starts a
  // JVM on the device every time). Firing five of them concurrently made the
  // adb channel drop all but one. Chaining them guarantees every gesture is
  // delivered, in order.
  input(msg) {
    msg._queuedAt = Date.now();
    this.inputChain = (this.inputChain || Promise.resolve())
      .then(() => this.runInput(msg))
      .catch((e) => extLog("input failed: " + (e && e.message)));
    return this.inputChain;
  }

  async runInput(msg) {
    if (!this.serial) return;
    const t0 = Date.now();
    // poll the screen fast for the next 2 s: it is about to change
    this.hotUntil = Date.now() + 2000;
    switch (msg.action) {
      case "tap": {
        // Input goes through "adb shell input", NOT through the emulator's own
        // gRPC input API.
        //
        // The gRPC input API (sendTouch, and streamInputEvent with a
        // touch_event) is a NO-OP on this emulator build (37.2.12.0, started
        // with -no-window): it answers grpc-status 0, the guest never sees the
        // event, and nothing happens on the screen. Verified 2026-10-27 by
        // comparing the counter in com.example.mini_app before and after -
        // 3 taps moved the counter by 0. See AGENTS.md section 24.
        //
        // "adb shell input tap" is measured at 70-200 ms and always lands
        // (9/9 taps registered). The emulator's software renderer needs
        // ~490 ms to show the result anyway, so the gRPC shortcut would only
        // save a fraction of the perceived latency - not worth a tap that
        // silently does nothing.
        const r = await this.adbInput(["shell", "input", "tap", String(msg.x), String(msg.y)]);
        if (r && r.err) extLog("tap FAILED: " + r.err + " " + (r.stderr || "").trim());
        break;
      }
      case "swipe": {
        const r = await this.adbInput(["shell", "input", "swipe",
          String(msg.x1), String(msg.y1), String(msg.x2), String(msg.y2), String(msg.ms || 300)]);
        if (r && r.err) extLog("swipe FAILED: " + r.err + " " + (r.stderr || "").trim());
        break;
      }
      case "key": {
        await this.adbInput(["shell", "input", "keyevent", String(msg.code)]);
        break;
      }
      case "text": {
        await this.adbInput(["shell", "input", "text", String(msg.value)]);
        break;
      }
      case "back": {
        await this.adbInput(["shell", "input", "keyevent", "4"]);
        break;
      }
      default:
        return;
    }
    extLog("input " + msg.action + " " + (msg.x !== undefined ? msg.x + "," + msg.y : "") +
      " (queue " + (t0 - (msg._queuedAt || t0)) + "ms, exec " + (Date.now() - t0) + "ms)");
  }

  // Input path. Uses the hardened adb() helper (spawn + SIGKILL):
  // execFile()'s timeout only sends SIGTERM, so a wedged adb client left the
  // promise unresolved and blocked every later tap in the queue.
  adbInput(args) {
    return adb(["-s", this.serial].concat(args), { timeout: 5000 });
  }

  dispose() {
    this.running = false;
  }
}

function delay(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Protobuf decoding, hand rolled (the extension has no dependencies).
//
//   Image { ImageFormat format = 1; uint32 width = 2; uint32 height = 3;
//           bytes image = 4; uint32 seq = 5; uint64 timestampUs = 6; }
//
// The PNG we want is field 4.
//
// NOTE: the emulator's gRPC INPUT api is deliberately not used - see
// runInput() and AGENTS.md section 24. It answers grpc-status 0 while the
// guest never receives the event, so a tap through it does nothing at all.
// Only the SCREENSHOT part of the gRPC service is used, and that one works.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Emulator gRPC client
//
// The Android emulator exposes a gRPC service on 127.0.0.1:8554 with a
// getScreenshot() call that grabs the framebuffer directly. That is ~30x
// faster than "adb exec-out screencap" (26 ms vs ~700 ms), because it skips
// the adb round trip and the guest-side PNG encoder.
//
// The service is protected: every call needs a bearer token, which the
// emulator writes into its discovery file <android avd home>/running/pid_*.ini
// as "grpc.token=...". The token changes every time the emulator restarts, so
// it is re-read whenever a call fails.
// ---------------------------------------------------------------------------
const GRPC_HOST = "127.0.0.1";
const GRPC_PORT = 8554;
const GRPC_SERVICE = "android.emulation.control.EmulatorController";

function emulatorGrpcToken() {
  const dir = path.join(os.homedir(), ".android", "avd", "running");
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => f.startsWith("pid_"));
  } catch (_) {
    return null;
  }
  for (const f of files) {
    try {
      const ini = fs.readFileSync(path.join(dir, f), "utf8");
      const m = ini.match(/grpc\.token=(\S+)/);
      if (m) return m[1];
    } catch (_) {}
  }
  return null;
}

// Image { ImageFormat format = 1; uint32 width = 2; uint32 height = 3;
//         bytes image = 4; uint32 seq = 5; uint64 timestampUs = 6; }
// The PNG we want is field 4.
function extractPng(buf) {
  let pos = 0;
  while (pos < buf.length) {
    const key = buf[pos++];
    const field = key >>> 3;
    const wire = key & 7;
    if (wire === 0) {
      while (pos < buf.length && (buf[pos++] & 0x80) !== 0) {}
    } else if (wire === 2) {
      let len = 0;
      let shift = 0;
      let b;
      do {
        b = buf[pos++];
        len |= (b & 0x7f) << shift;
        shift += 7;
      } while (b & 0x80);
      const slice = buf.slice(pos, pos + len);
      pos += len;
      if (field === 4) return slice;
    } else if (wire === 5) {
      pos += 4;
    } else if (wire === 1) {
      pos += 8;
    } else {
      break;
    }
  }
  return null;
}

class EmulatorGrpc {
  constructor() {
    this.client = null;
    this.token = null;
    this.broken = false;
    this.nextTry = 0;
  }

  connect() {
    if (this.client && !this.client.closed) return this.client;
    const http2 = require("http2");
    const token = emulatorGrpcToken();
    if (!token) {
      // the emulator has not written its discovery file yet - it is still
      // booting. Try again later.
      this.broken = true;
      this.nextTry = Date.now() + 3000;
      return null;
    }
    this.token = token;
    this.client = http2.connect(`http://${GRPC_HOST}:${GRPC_PORT}`);
    this.client.on("error", () => {
      this.broken = true;
      this.nextTry = Date.now() + 3000;
      this.client = null;
    });
    this.client.on("close", () => {
      this.client = null;
    });
    this.broken = false;
    this.nextTry = 0;
    return this.client;
  }

  markBroken() {
    this.broken = true;
    this.nextTry = Date.now() + 5000;
    if (this.client) {
      try { this.client.destroy(); } catch (_) {}
      this.client = null;
    }
  }

  // NOTE: there is deliberately no gRPC INPUT here (sendTouch /
  // streamInputEvent). It does not work on this emulator build
  // (37.2.12.0, started with -no-window): the RPC answers grpc-status 0, the
  // guest receives no input event at all, and nothing happens on the screen.
  // Measured 2026-10-27 by watching the counter in com.example.mini_app:
  //
  //   - sendTouch(TouchEvent)                        -> 0 of 3 taps registered
  //   - streamInputEvent(InputEvent) / android_event  -> 0 of 1 tap registered
  //   - streamInputEvent(InputEvent) / touch_event    -> 5 of 5 taps registered
  //   - "adb shell input tap"                        -> 9 of 9 taps registered
  //
  // The third line does work, but it is a newer API whose failure mode is
  // exactly the silent no-op that made this bug, so input goes through
  // "adb shell input" instead - see runInput().

  getScreenshot() {
    // A previous failure is not permanent: the emulator rotates the token on
    // every restart, and the gRPC port only appears once it has booted.
    if (this.broken && Date.now() < this.nextTry) {
      return Promise.resolve(null);
    }
    return new Promise((resolve) => {
      const client = this.connect();
      if (!client) return resolve(null);
      const req = client.request({
        ":method": "POST",
        ":path": `/${GRPC_SERVICE}/getScreenshot`,
        "content-type": "application/grpc+proto",
        "te": "trailers",
        authorization: "Bearer " + (this.token || ""),
      });
      const chunks = [];
      let done = false;
      const finish = (v) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { req.close(); } catch (_) {}
        resolve(v);
      };
      const timer = setTimeout(() => {
        this.markBroken();
        finish(null);
      }, 8000);
      req.on("error", () => {
        this.markBroken();
        finish(null);
      });
      // A gRPC status lives in the HTTP/2 TRAILERS, not in the response
      // headers. Node emits the headers in "response" and the trailers in
      // "trailers", so reading grpc-status from "response" always yields
      // undefined - which is how a failing call used to look like a success.
      req.on("response", (h) => {
        const st = h["grpc-status"];
        if (st && st !== "0") {
          this.markBroken();
          finish(null);
        }
      });
      req.on("trailers", (h) => {
        const st = h["grpc-status"];
        if (st && st !== "0") {
          this.markBroken();
          finish(null);
        }
      });
      req.on("data", (d) => chunks.push(d));
      req.on("end", () => {
        const body = Buffer.concat(chunks);
        if (body.length < 5) return finish(null);
        const len = body.readUInt32BE(1);
        if (body.length < 5 + len) return finish(null);
        const png = extractPng(body.slice(5, 5 + len));
        if (!png || png.length < 8 || !png.slice(0, 8).equals(PNG_MAGIC)) return finish(null);
        finish(png);
      });
      // empty ImageFormat request -> PNG at the device resolution
      req.end(Buffer.from([0, 0, 0, 0, 0]));
    });
  }
}

let current = null;
let viewerChild = null;

function makeTreeItem(label, description, contextValue, command) {
  return {
    label: label,
    description: description,
    contextValue: contextValue,
    iconPath: new vscode.ThemeIcon(contextValue === "message" ? "info" : "device-mobile"),
    command: command,
  };
}

function createDeviceTree(context) {
  // NOTE: TreeView.refresh() no longer exists in VS Code 1.143+. Refreshing is
  // done by firing the provider's onDidChangeTreeData event.
  const changeEmitter = new vscode.EventEmitter();
  context.subscriptions.push(changeEmitter);
  const provider = {
    onDidChangeTreeData: changeEmitter.event,
    async getChildren() {
      const serial = await deviceSerial();
      if (!serial) {
        return [makeTreeItem("No device", "start the emulator", "message")];
      }
      return [
        makeTreeItem(serial, "running", "device", {
          command: "emulatorView.open",
          title: "Open Emulator View",
          arguments: [],
        }),
      ];
    },
  };
  const tree = vscode.window.createTreeView("emulatorView.devices", { treeDataProvider: provider });
  const timer = setInterval(() => changeEmitter.fire(), 5000);
  context.subscriptions.push({ dispose: () => { clearInterval(timer); tree.dispose(); } });
  return tree;
}

function buildHtml(webview, extensionUri) {
  const nonce = makeNonce();
  // The webview's resources are normally loaded from
  //   vscode-remote+<...>.vscode-resource.vscode-cdn.net
  // which is a DIFFERENT public domain from the workbench host the browser
  // already has open. Some clients (and this user's browser in particular)
  // cannot resolve that domain, and then the webview renders as a blank panel.
  //
  // So the CSS and the script are INLINED into the HTML instead. The webview
  // document itself is always served from the workbench origin ('self'), so
  // after inlining the extension needs no hostname beyond the one the user
  // already has open - no DNS, no tunnel, no port forwarding.
  let css = "";
  let js = "";
  try {
    css = fs.readFileSync(path.join(extensionUri.fsPath, "media", "view.css"), "utf8");
    js = fs.readFileSync(path.join(extensionUri.fsPath, "media", "view.js"), "utf8");
    // A literal </script> inside the JS would terminate the inline tag.
    js = js.replace(/<\/script/gi, "<\\/script");
  } catch (e) {
    extLog("inline read failed, falling back to asWebviewUri: " + (e && e.message));
  }
  let styleTag = "";
  let scriptTag = "";
  if (css && js) {
    styleTag = `<style nonce="${nonce}">\n${css}\n</style>`;
    scriptTag = `<script nonce="${nonce}">\n${js}\n</script>`;
  } else {
    const script = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "view.js"));
    const style = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "view.css"));
    styleTag = `<link rel="stylesheet" href="${style}">`;
    scriptTag = `<script nonce="${nonce}" src="${script}"></script>`;
    extLog("webview script uri (fallback): " + String(script));
  }
  extLog("webview assets inlined: " + (css && js ? "yes" : "no"));
  extLog("webview cspSource: " + String(webview.cspSource));
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource} data: blob:; style-src ${webview.cspSource} 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src ${webview.cspSource};" />
${styleTag}
<title>Android Emulator</title></head>
<body>
  <div id="stage">
    <img id="screen" alt="Android emulator screen" draggable="false">
    <div id="placeholder">Waiting for the emulator…</div>
  </div>
  <div class="bar">
    <button data-key="3" title="KEYCODE_HOME">HOME</button>
    <button data-key="4" title="KEYCODE_BACK">BACK</button>
    <button data-key="66" title="KEYCODE_ENTER">ENTER</button>
    <span class="spacer"></span>
    <span id="status">connecting…</span>
  </div>
  ${scriptTag}
</body>
</html>`;
}

function makeNonce() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  for (let i = 0; i < 32; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

async function openView(context) {
  if (current) {
    current.panel.reveal(vscode.ViewColumn.Beside);
    return current;
  }
  const panel = vscode.window.createWebviewPanel(
    "emulatorView.panel",
    "Android Emulator",
    { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
    { enableScripts: true, retainContextWhenHidden: true }
  );
  panel.iconPath = vscode.Uri.joinPath(context.extensionUri, "media", "icon.svg");
  panel.webview.html = buildHtml(panel.webview, context.extensionUri);

  extLog("emulator panel created (webview " + (panel.webview.html ? "ready" : "empty") + ")");
  const session = new EmulatorSession(panel);
  current = { panel, session };

  // Start capturing right away - the webview does not have to ask for it.
  session.start();

  panel.webview.onDidReceiveMessage(async (msg) => {
    if (!msg || typeof msg !== "object") return;
    if (msg.type === "input") {
      await session.input(msg);
    } else if (msg.type === "ack") {
      session.onFrameAck();
    } else if (msg.type === "ready") {
      session.start();
      session.primeWebview();
    }
  });

  panel.onDidDispose(() => {
    extLog("emulator panel disposed - the view will be reopened automatically");
    session.dispose();
    current = null;
  });

  return current;
}

function ensureStackUp() {
  // The Codespace container is restarted periodically and takes every process
  // with it. The extension host lives inside the container and is re-created on
  // each VS Code start, so it is the most reliable place to re-launch the
  // emulator stack. ensure-up.sh starts the supervisor, which then keeps the
  // emulator, the app and the viewer alive.
  if (!fs.existsSync("/workspaces/ensure-up.sh")) return;
  try {
    const child = spawn("bash", ["/workspaces/ensure-up.sh"], {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
    extLog("ensure-up.sh launched");
  } catch (e) {
    extLog("could not launch ensure-up.sh: " + (e && e.message));
  }
}

function portOpen(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port }, () => { s.destroy(); resolve(true); });
    s.on("error", () => resolve(false));
    s.setTimeout(1500, () => { s.destroy(); resolve(false); });
  });
}

// Which process is listening on a TCP port? Used to find a viewer that was
// started from an unrelated shell (the supervisor) - such a process is
// invisible to the Codespaces port-forwarding agent, so the port never shows
// up as forwarded and the public browse URL stays a 404.
function listenerPid(port) {
  return new Promise((resolve) => {
    const p = spawn("ss", ["-ltnp", "sport = :" + port]);
    let out = "";
    const done = (v) => {
      clearTimeout(timer);
      resolve(v);
    };
    const timer = setTimeout(() => {
      try { p.kill("SIGKILL"); } catch (_) {}
      done(null);
    }, 5000);
    p.stdout.on("data", (d) => (out += d));
    p.on("error", () => done(null));
    p.on("close", () => {
      const m = out.match(/pid=(\d+)/);
      done(m ? Number(m[1]) : null);
    });
  });
}

// The Codespaces port-forwarding agent only forwards ports that are bound by
// a process inside the VS Code server's own process tree - a viewer spawned
// from an unrelated shell is never forwarded, no matter when it binds.
//
// So the extension owns the viewer: it is a child of the extension host, the
// same way the EmbeDroid bridge is, and the port therefore gets forwarded and
// a public browse URL exists.
async function ensureViewer() {
  const port = 8091;
  if (viewerChild && viewerChild.exitCode === null) {
    return; // our own child is alive
  }
  // Something else is holding the port. If it is a shell-spawned viewer the
  // port will never be forwarded, so take it over.
  const foreign = await listenerPid(port);
  if (foreign) {
    extLog("taking over :" + port + " from pid " + foreign + " (not in the VS Code process tree)");
    try { process.kill(foreign, "SIGKILL"); } catch (_) {}
    await new Promise((r) => setTimeout(r, 800));
  }
  if (!fs.existsSync("/workspaces/emuview.py")) {
    extLog("WARN: /workspaces/emuview.py not found");
    return;
  }
  extLog("starting viewer on :" + port);
  try {
    // NOT detached and NOT unref'd on purpose: the viewer stays a direct child
    // of the extension host, i.e. inside the VS Code server's process tree.
    // The Codespaces port-forwarding agent only forwards ports held by
    // processes in that tree - a viewer started through setsid/no setsid from
    // an unrelated shell is never forwarded, no matter when it binds.
    viewerChild = spawn("python3", ["/workspaces/emuview.py"], {
      stdio: "ignore",
      cwd: "/workspaces/empty-repo",
      env: Object.assign({}, process.env, { EMUVIEW_PORT: String(port) }),
    });
    viewerChild.on("exit", (code) => extLog("viewer exited with code " + code));
  } catch (e) {
    extLog("could not start viewer: " + (e && e.message));
    return;
  }
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await portOpen(port)) {
      extLog("viewer up on :" + port);
      await forwardPort(port);
      return;
    }
  }
  extLog("WARN: viewer did not come up on :" + port);
}

// vscode.env.asExternalUri() is the only supported way to ask the remote side
// to forward a port: the workbench resolves the URI through the tunnel and
// registers the port with the Codespaces port-forwarding service. Merely
// listening on a socket is NOT enough - the port stays invisible in
// `gh codespace ports` and the public browse URL 404s.
//
// The EmbeDroid extension forwards its bridge port this way, which is why
// :8099 shows up and a plain listener does not.
async function forwardPort(port) {
  try {
    const uri = await vscode.env.asExternalUri(vscode.Uri.parse("http://127.0.0.1:" + port));
    extLog("external URI for :" + port + " -> " + uri.toString());
    return uri;
  } catch (e) {
    extLog("asExternalUri failed for :" + port + ": " + (e && e.message));
    return null;
  }
}

// Heartbeat: the supervisor and the viewer can die (the Codespace container
// is restarted periodically). Both are re-created from here so the stack comes
// back on its own, without the user doing anything.
function startHeartbeat(context) {
  let tick = 0;
  const timer = setInterval(async () => {
    try {
      tick++;
      if (!fs.existsSync("/workspaces/supervisor.sh")) return;
      const pid = fs.readFileSync("/tmp/supervisor.pid", "utf8").trim();
      let alive = false;
      if (pid && /^\d+$/.test(pid)) {
        try {
          process.kill(Number(pid), 0);
          alive = true;
        } catch (_) {
          alive = false;
        }
      }
      if (!alive) {
        extLog("supervisor not running - restarting it");
        const child = spawn("bash", ["/workspaces/supervisor.sh"], {
          stdio: "ignore",
          detached: true,
        });
        child.unref();
      }
      if (!viewerChild || viewerChild.exitCode !== null) {
        await ensureViewer();
      } else if (tick % 4 === 0) {
        // the tunnel can drop when the Codespace reconnects
        await forwardPort(8091);
      }
      // If the tab was closed the session dies with it. Re-open it: the whole
      // point is that the emulator view is always there, with no manual step.
      if (!current) {
        try {
          await openView(context);
          extLog("emulator view reopened");
        } catch (e) {
          extLog("could not reopen the view: " + (e && e.message));
        }
      }
    } catch (e) {
      extLog("heartbeat error: " + (e && e.message));
    }
  }, 15000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

function activate(context) {
  console.log("emulator-view: activating");
  ensureStackUp();
  context.subscriptions.push(
    vscode.commands.registerCommand("emulatorView.open", () => openView(context)),
    vscode.commands.registerCommand("emulatorView.restart", async () => {
      await new Promise((resolve) => {
        execFile("bash", ["/workspaces/run-all.sh"], { timeout: 600000 }, () => resolve());
      });
      if (current) current.session.start();
      vscode.window.showInformationMessage("Emulator stack restarted.");
    })
  );
  try {
    createDeviceTree(context);
  } catch (e) {
    extLog("tree unavailable: " + (e && e.message));
  }
  extLog("activated - opening panel automatically");
  ensureViewer();
  startHeartbeat(context);
  // Open the panel on activation: no command to run, no button to click.
  openView(context).catch((e) => extLog("auto-open failed: " + (e && e.message)));
}

function deactivate() {
  if (current) {
    current.session.dispose();
    current = null;
  }
}

module.exports = { activate, deactivate };
