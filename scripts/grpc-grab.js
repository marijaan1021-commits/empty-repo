// Streams the emulator's framebuffer over stdout using the emulator's own
// gRPC service (getScreenshot).
//
// Why not "adb exec-out screencap -p"?
//   * ~700-900 ms per frame on this box (software GPU), and it runs a PNG
//     encoder inside the guest - that alone keeps one of the two vCPUs busy
//     and starves the Flutter renderer, which makes the app stop drawing
//     (the screen then goes black).
//   * The gRPC path reads the framebuffer host-side: ~25 ms per frame and
//     zero guest CPU.
//
// Protocol on stdout: repeated [4-byte big-endian length][PNG bytes].
// On error it reconnects instead of exiting, so the consumer can just read.
//
//   FRAME_INTERVAL_MS=100  (default 120)
//   GRPC_TOKEN_FILE=...    (default ~/.android/avd/running/pid_*.ini)

const http2 = require("http2");
const fs = require("fs");
const os = require("os");
const path = require("path");

const HOST = "127.0.0.1";
const PORT = 8554;
const SERVICE = "android.emulation.control.EmulatorController";
const INTERVAL = parseInt(process.env.FRAME_INTERVAL_MS || "80", 10);
const RUNNING_DIR = path.join(os.homedir(), ".android", "avd", "running");

let token = null;
let client = null;
let stopped = false;

function readToken() {
  let files = [];
  try {
    files = fs.readdirSync(RUNNING_DIR).filter((f) => f.startsWith("pid_"));
  } catch (_) {
    return null;
  }
  for (const f of files) {
    try {
      const m = fs
        .readFileSync(path.join(RUNNING_DIR, f), "utf8")
        .match(/grpc\.token=(\S+)/);
      if (m) return m[1];
    } catch (_) {}
  }
  return null;
}

// Image { ImageFormat format = 1; uint32 width = 2; uint32 height = 3;
//         bytes image = 4; ... }
// The PNG is field 4.
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

function connect() {
  if (client && !client.closed) return client;
  token = readToken();
  if (!token) return null;
  try {
    client = http2.connect(`http://${HOST}:${PORT}`);
  } catch (_) {
    client = null;
    return null;
  }
  client.on("error", () => {
    client = null;
  });
  client.on("close", () => {
    client = null;
  });
  return client;
}

function grab() {
  return new Promise((resolve) => {
    const c = connect();
    if (!c) return resolve(null);
    let body = Buffer.alloc(0);
    let trailers = {};
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      try { c.close(); } catch (_) {}
      resolve(v);
    };
    const req = c.request({
      ":method": "POST",
      ":path": `/${SERVICE}/getScreenshot`,
      "content-type": "application/grpc+proto",
      te: "trailers",
      authorization: "Bearer " + token,
    });
    const timer = setTimeout(() => {
      try { req.close(http2.constants.NGHTTP2_CANCEL); } catch (_) {}
      finish(null);
    }, 5000);
    req.on("response", () => {});
    req.on("trailers", (t) => {
      trailers = t;
    });
    req.on("data", (d) => {
      body = Buffer.concat([body, d]);
    });
    req.on("error", () => {
      clearTimeout(timer);
      finish(null);
    });
    req.on("end", () => {
      clearTimeout(timer);
      // The gRPC status arrives in the HTTP/2 trailers, not the headers.
      if (String(trailers["grpc-status"]) !== "0") return finish(null);
      if (body.length < 5) return finish(null);
      const len = body.readUInt32BE(1);
      const png = extractPng(body.slice(5, 5 + len));
      if (!png || png.length < 8) return finish(null);
      finish(png);
    });
    // Empty ImageFormat request: 5 bytes, all zero.
    req.end(Buffer.from([0, 0, 0, 0, 0]));
  });
}

function write(png) {
  const head = Buffer.alloc(4);
  head.writeUInt32BE(png.length, 0);
  process.stdout.write(Buffer.concat([head, png]));
}

async function loop() {
  while (!stopped) {
    const png = await grab();
    if (png) write(png);
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

process.on("SIGTERM", () => {
  stopped = true;
  process.exit(0);
});
process.on("SIGPIPE", () => process.exit(0));

loop();
