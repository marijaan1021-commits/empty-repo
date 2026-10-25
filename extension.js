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

function adb(args, opts = {}) {
  return new Promise((resolve) => {
    execFile(ADB, args, { timeout: opts.timeout || 20000, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ err, stdout: stdout || "", stderr: stderr || "" }));
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
          this.frames++;
          this.post({
            type: "frame",
            data: frame.toString("base64"),
            width: this.width,
            height: this.height,
            frames: this.frames,
          });
          if (this.frames === 1 || this.frames % 20 === 0) {
            extLog("frame " + this.frames + " (" + this.width + "x" + this.height + ", " + frame.length + "B)");
          }
        } else if (this.frames === 0 && !this.warnedEmpty) {
          this.warnedEmpty = true;
          extLog("screencap returned nothing - is the emulator up?");
        }
      } catch (_) {}
      await delay(80);
    }
  }

  post(msg) {
    this.panel.webview.postMessage(msg);
  }

  capture() {
    return new Promise((resolve) => {
      const p = spawn(ADB, ["-s", this.serial, "exec-out", "screencap", "-p"]);
      const chunks = [];
      let size = 0;
      p.stdout.on("data", (d) => {
        chunks.push(d);
        size += d.length;
        if (size > 64 * 1024 * 1024) p.kill();
      });
      p.on("error", () => resolve(null));
      p.on("close", () => {
        if (!chunks.length) return resolve(null);
        const buf = Buffer.concat(chunks);
        if (buf.length < 8 || !buf.slice(0, 8).equals(PNG_MAGIC)) return resolve(null);
        this.width = buf.readUInt32BE(16);
        this.height = buf.readUInt32BE(20);
        resolve(buf);
      });
    });
  }

  async input(msg) {
    if (!this.serial) return;
    let args;
    switch (msg.action) {
      case "tap":
        args = ["-s", this.serial, "shell", "input", "tap", String(msg.x), String(msg.y)];
        break;
      case "swipe":
        args = ["-s", this.serial, "shell", "input", "swipe",
          String(msg.x1), String(msg.y1), String(msg.x2), String(msg.y2), String(msg.ms || 300)];
        break;
      case "key":
        args = ["-s", this.serial, "shell", "input", "keyevent", String(msg.code)];
        break;
      case "text":
        args = ["-s", this.serial, "shell", "input", "text", String(msg.value)];
        break;
      case "back":
        args = ["-s", this.serial, "shell", "input", "keyevent", "4"];
        break;
      default:
        return;
    }
    execFile(ADB, args, { timeout: 20000 }, () => {});
  }

  dispose() {
    this.running = false;
  }
}

function delay(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

let current = null;

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
  const script = webview.asWebviewUri(
    vscode.Uri.joinPath(extensionUri, "media", "view.js"));
  const style = webview.asWebviewUri(
    vscode.Uri.joinPath(extensionUri, "media", "view.css"));
  const nonce = makeNonce();
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource} data: blob:; style-src ${webview.cspSource} 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src ${webview.cspSource};" />
<link rel="stylesheet" href="${style}">
<title>Android Emulator</title>
</head>
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
  <script nonce="${nonce}" src="${script}"></script>
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

  const session = new EmulatorSession(panel);
  current = { panel, session };

  // Start capturing right away - the webview does not have to ask for it.
  session.start();

  panel.webview.onDidReceiveMessage(async (msg) => {
    if (!msg || typeof msg !== "object") return;
    if (msg.type === "input") {
      await session.input(msg);
    } else if (msg.type === "ready") {
      session.start();
    }
  });

  panel.onDidDispose(() => {
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

// The Codespaces port-forwarding agent only forwards ports that are bound by
// a process inside the VS Code server's own process tree - a viewer spawned
// from an unrelated shell is never forwarded, no matter when it binds.
//
// So the extension owns the viewer: it is a child of the extension host, the
// same way the EmbeDroid bridge is, and the port therefore gets forwarded and
// a public browse URL exists.
async function ensureViewer() {
  const port = 8091;
  if (await portOpen(port)) {
    extLog("viewer already listening on :" + port);
    return;
  }
  if (!fs.existsSync("/workspaces/emuview.py")) {
    extLog("WARN: /workspaces/emuview.py not found");
    return;
  }
  extLog("starting viewer on :" + port);
  try {
    const child = spawn("python3", ["/workspaces/emuview.py"], {
      detached: true,
      stdio: "ignore",
      env: Object.assign({}, process.env, { EMUVIEW_PORT: String(port) }),
    });
    child.unref();
  } catch (e) {
    extLog("could not start viewer: " + (e && e.message));
    return;
  }
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await portOpen(port)) {
      extLog("viewer up on :" + port);
      return;
    }
  }
  extLog("WARN: viewer did not come up on :" + port);
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
