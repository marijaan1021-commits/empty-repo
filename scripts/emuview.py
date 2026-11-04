#!/usr/bin/env python3
"""
emuview - autonomous Android emulator viewer over HTTP.

Serves live screen frames to any browser plus tap/swipe/key input, so the
emulator is usable without the EmbeDroid extension or any VS Code UI.

Endpoints:
  GET  /                HTML viewer (auto-refreshing frame stream)
  GET  /frame           PNG screenshot of the current screen
  GET  /status          JSON: device state, fps
  POST /tap?x=&y=       tap at device coordinates
  POST /swipe?x1=&y1=&x2=&y2=&ms=
  POST /key?code=       send a keyevent (e.g. BACK=4, HOME=3, ENTER=66)
  POST /text?value=     type text

Run:  python3 emuview.py            (listens on 0.0.0.0:8091)
"""
import json
import os
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ADB = "/workspaces/android-sdk/platform-tools/adb"
PORT = int(os.environ.get("EMUVIEW_PORT", "8091"))
GRPC_GRAB = "/workspaces/grpc-grab.js"

# The canonical runtime location is /workspaces (symlinks to this repo's
# scripts/). If those symlinks are missing, fall back to the directory this
# file actually lives in, so the fast gRPC capture path never dies silently.
_here = os.path.dirname(os.path.abspath(__file__))
if not os.path.exists(GRPC_GRAB):
    GRPC_GRAB = os.path.join(_here, "grpc-grab.js")
if not os.path.exists(ADB):
    _sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if _sdk:
        ADB = os.path.join(_sdk, "platform-tools", "adb")

_lock = threading.Lock()
_last_frame = {"data": b"", "ts": 0.0}
_stats = {"fps": 0.0, "frames": 0, "source": "none"}


def _adb(*args, timeout=20):
    return subprocess.run([ADB, *args], capture_output=True, timeout=timeout)


# `adb devices` can block for a long time while the emulator is booting or
# wedged, and /status must never block on it - a hanging request makes the
# supervisor think the viewer is dead and restart it in a loop. So the device
# serial is polled in the background and cached.
_device_serial = {"value": None, "ts": 0.0}


def _poll_device():
    try:
        r = subprocess.run([ADB, "devices"], capture_output=True, timeout=8)
        serial = None
        for line in r.stdout.decode().splitlines()[1:]:
            if line.strip().endswith("\tdevice"):
                serial = line.split()[0]
                break
        _device_serial["value"] = serial
    except Exception:
        pass
    _device_serial["ts"] = time.time()


def device_ready():
    if time.time() - _device_serial["ts"] > 3:
        _poll_device()
    return _device_serial["value"]


def device_cached():
    """The device serial without ever blocking on adb.

    /status is polled by the browser every 2 s and by the supervisor every
    8 s. If it waits for "adb devices" it can take longer than the caller's
    timeout, and a slow adb server then looks like a dead viewer - which makes
    the supervisor restart it in a loop. The background poller keeps the
    cache fresh; /status just reads it.
    """
    return _device_serial["value"]


_booted = {"value": False, "ts": 0.0}


def device_booted(serial):
    """True once the guest finished booting.

    Capturing frames while the system is still starting up is expensive: each
    `screencap` costs ~0.9 s of CPU in the guest under the software GPU, and
    polling it continuously during boot starves the boot itself (observed: a
    boot that should take ~90 s stretched past 10 minutes). So nothing is
    captured until boot_completed is 1.
    """
    if time.time() - _booted["ts"] > 5:
        _booted["ts"] = time.time()
        try:
            r = subprocess.run([ADB, "-s", serial, "shell", "getprop", "sys.boot_completed"],
                               capture_output=True, timeout=15)
            _booted["value"] = r.stdout.decode().strip() == "1"
        except Exception:
            _booted["value"] = False
    return _booted["value"]


def _store_frame(data, source):
    now = time.time()
    with _lock:
        prev = _last_frame["ts"]
        _last_frame["data"] = data
        _last_frame["ts"] = now
        _stats["frames"] += 1
        _stats["source"] = source
        if prev:
            dt = now - prev
            if dt > 0:
                _stats["fps"] = round(_stats["fps"] * 0.8 + (1 / dt) * 0.2, 1)


def _grpc_frames():
    """Yield PNG frames from the emulator's own gRPC service.

    This is the fast path: the emulator hands out its framebuffer host-side in
    ~25 ms, and the guest does no work at all. "adb exec-out screencap" costs
    ~700-900 ms per frame and runs a PNG encoder inside the guest, which keeps
    one of the two vCPUs busy and starves the Flutter renderer - the app then
    stops drawing and the screen goes black.

    The helper keeps one HTTP/2 connection open and writes
    [4-byte length][PNG] frames to stdout. It reconnects by itself if the
    emulator restarts (the bearer token rotates on every emulator start).
    """
    proc = subprocess.Popen(
        ["node", GRPC_GRAB],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    try:
        while True:
            head = proc.stdout.read(4)
            if not head or len(head) < 4:
                return
            size = struct.unpack(">I", head)[0]
            if size <= 0 or size > 64 * 1024 * 1024:
                return
            buf = b""
            while len(buf) < size:
                chunk = proc.stdout.read(size - len(buf))
                if not chunk:
                    return
                buf += chunk
            if buf[:8] == b"\x89PNG\r\n\x1a\n":
                yield buf
    finally:
        try:
            proc.kill()
        except Exception:
            pass


def capture_loop():
    """Background loop: grab a frame, hand it to whoever asks for one.

    IMPORTANT: this must WAIT for a device rather than exiting when none is
    present. The Codespaces port-forwarding agent only scans for listening
    ports ONCE, at container start. If the viewer is not bound by then, the
    port is never forwarded and no external URL will ever work. So the viewer
    is started as early as possible and simply idles until a device appears.
    """
    serial = None
    grpc = None
    adb_fails = 0
    while True:
        # gRPC path: it does not need the guest to be up, only the emulator
        # process, so it is tried first and it is also the fast path.
        if grpc is None:
            try:
                grpc = _grpc_frames()
                next(grpc)
            except StopIteration:
                grpc = None
            except Exception:
                grpc = None
        if grpc is not None:
            try:
                frame = next(grpc)
                if frame:
                    _store_frame(frame, "grpc")
                    adb_fails = 0
                    continue
            except StopIteration:
                grpc = None
            except Exception:
                grpc = None

        if serial is None:
            serial = device_ready()
            if not serial:
                time.sleep(1.0)
                continue
        try:
            if not device_booted(serial):
                # Booting: do not capture. Wait, and let the guest finish.
                time.sleep(2.0)
                continue
            r = subprocess.run([ADB, "-s", serial, "exec-out", "screencap", "-p"],
                               capture_output=True, timeout=15)
            if r.stdout[:8] == b"\x89PNG\r\n\x1a\n":
                _store_frame(r.stdout, "adb")
                adb_fails = 0
            else:
                serial = None
        except Exception:
            serial = None
        adb_fails += 1
        # Only fall back to the slow path if gRPC is unavailable for good.
        if adb_fails > 20:
            adb_fails = 0
        time.sleep(0.25)


HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,user-scalable=no">
<title>Android Emulator</title><style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{background:#111;color:#eee;font:14px system-ui;display:flex;flex-direction:column;
     align-items:center;justify-content:center;height:100vh;gap:10px;padding:10px}
#wrap{flex:1;min-height:0;display:flex;align-items:center;justify-content:center;width:100%}
img{image-rendering:pixelated;border:2px solid #333;border-radius:6px;background:#000;
    max-width:100%;max-height:100%;width:auto;height:auto;object-fit:contain}
.bar{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}
button{background:#2a2a2a;color:#eee;border:1px solid #444;border-radius:6px;
       padding:10px 18px;font-size:15px;cursor:pointer;min-width:72px}
button:active{background:#444}
#st{font-size:12px;color:#888;text-align:center;line-height:1.6}
#st b{color:#eee;font-weight:600}
.warn{color:#ffb347}
.err{color:#ff6b6b}
a{color:#7aa7ff}
</style></head><body>
<div id=wrap><img id=v src="/frame" alt="emulator screen"></div>
<div class=bar>
  <button onclick="k(3)">HOME</button>
  <button onclick="k(4)">BACK</button>
  <button onclick="k(66)">ENTER</button>
</div>
<div id=st>connecting...</div>
<script>
const v=document.getElementById('v'),st=document.getElementById('st');
let loading=false,errors=0,frames=0,lastChange=Date.now(),black=0;

// A canvas downsample tells us whether the picture is actually all black.
// A sleeping emulator returns a solid-black frame from every capture path
// while everything else looks healthy, so say so instead of showing black.
function checkBlack(){
  try{
    const c=document.createElement('canvas');c.width=16;c.height=32;
    const g=c.getContext('2d');
    g.drawImage(v,0,0,16,32);
    const d=g.getImageData(0,0,16,32).data;
    let lit=0;
    for(let i=0;i<d.length;i+=4){ if(d[i]>28||d[i+1]>28||d[i+2]>28) lit++; }
    black = lit<=1;
  }catch(e){ black=false; }
}

function loop(){
  if(loading)return;
  loading=true;
  const t=Date.now();
  v.onload=()=>{
    loading=false;errors=0;frames++;lastChange=Date.now();
    checkBlack();
    setTimeout(loop,60);
  };
  v.onerror=()=>{
    loading=false;errors++;
    setTimeout(loop,1000);
  };
  v.src='/frame?t='+t;
}
loop();
function post(p){return fetch(p,{method:'POST'}).catch(()=>{});}
function k(c){post('/key?code='+c);}
// Tap on press, so a click is never swallowed.
v.addEventListener('pointerdown',e=>{
  const r=v.getBoundingClientRect(), sx=v.naturalWidth, sy=v.naturalHeight;
  if(!sx||!sy)return;
  e.preventDefault();
  post('/tap?x='+Math.round((e.clientX-r.left)/r.width*sx)+
       '&y='+Math.round((e.clientY-r.top)/r.height*sy));
});
v.addEventListener('contextmenu',e=>e.preventDefault());

setInterval(()=>{
  fetch('/status',{cache:'no-store'}).then(r=>r.json()).then(d=>{
    const age=Math.round((Date.now()-lastChange)/1000);
    let s='<b>'+(d.device||'no device')+'</b> | '+d.fps+' fps | '+d.frames+' frames | src '+(d.source||'?');
    if(errors>2) s+=' | <span class=err>'+errors+' frame errors</span>';
    if(black) s+=' | <span class=warn>SCREEN IS BLACK (emulator display is asleep)</span>';
    else if(age>10) s+=' | <span class=warn>no new picture for '+age+'s</span>';
    if(d.device===null) s+=' | <span class=err>no device attached</span>';
    s+=' | <a href="/status" target="_blank">status</a>';
    st.innerHTML=s;
  }).catch(()=>{st.innerHTML='<span class=err">offline - cannot reach the viewer</span>';});
},1500);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/":
            self._send(200, "text/html; charset=utf-8", HTML.encode())
        elif u.path == "/frame":
            with _lock:
                data = _last_frame["data"]
            self._send(200, "image/png", data or b"")
        elif u.path == "/status":
            body = json.dumps({
                "device": device_cached(),
                "fps": _stats["fps"],
                "frames": _stats["frames"],
                "source": _stats["source"],
            }).encode()
            self._send(200, "application/json", body)
        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        serial = device_ready()
        if not serial:
            self._send(503, "text/plain", b"no device")
            return
        try:
            if u.path == "/tap":
                x, y = q["x"][0], q["y"][0]
                cmd = ["-s", serial, "shell", "input", "tap", str(x), str(y)]
                msg = f"tap {x},{y}"
            elif u.path == "/swipe":
                a = [q["x1"][0], q["y1"][0], q["x2"][0], q["y2"][0], q.get("ms", ["300"])[0]]
                cmd = ["-s", serial, "shell", "input", "swipe", *a]
                msg = "swipe"
            elif u.path == "/key":
                cmd = ["-s", serial, "shell", "input", "keyevent", q["code"][0]]
                msg = "key " + q["code"][0]
            elif u.path == "/text":
                cmd = ["-s", serial, "shell", "input", "text", q["value"][0]]
                msg = "text"
            else:
                self._send(404, "text/plain", b"not found")
                return
            subprocess.run([ADB, *cmd], capture_output=True, timeout=25)
            self._send(200, "application/json", json.dumps({"ok": True, "sent": msg}).encode())
        except Exception as e:
            self._send(500, "application/json", json.dumps({"ok": False, "err": str(e)}).encode())


def _device_poll_loop():
    """Keep the device serial fresh in the background.

    /status must never wait for adb (see device_cached), so somebody has to
    poll. A dedicated thread does it every 2 s.
    """
    while True:
        _poll_device()
        time.sleep(2.0)


if __name__ == "__main__":
    print(f"emuview listening on 0.0.0.0:{PORT}", flush=True)
    threading.Thread(target=capture_loop, daemon=True).start()
    threading.Thread(target=_device_poll_loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()