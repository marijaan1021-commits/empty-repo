# Android Emulator in GitHub Codespaces — Complete Project Notes

> **Audience: an agent (or human) starting with zero context.**
> You have not seen any of this project before. This file is the whole story: what was
> asked for, what exists, how it works, how it was built, what went wrong, and what NOT
> to waste time on. Read §1 first, then skim the rest.

---

## 1. What this project is — the actual request

The user works in a **GitHub Codespace accessed through a browser** (VS Code in a web
page at `*.app.github.dev`). There is **no graphical desktop and no display**.

They wanted to:

1. Run an **Android emulator** inside the Codespace.
2. **See it live in the browser** and **interact with it** (tap, swipe, keys).
3. Have it work **autonomously** — explicitly *without* the user pressing Play buttons,
   reloading windows, or toggling ports.
4. As the test subject, a **minimal lightweight Flutter app**.

Initially they asked for the **EmbeDroid** VS Code extension to do this. It was installed,
patched six times, and still abandoned (see §7). The working solution is a
**~180-line Python HTTP server** written from scratch that does the same job with no
extension and no manual steps.

**Status: working, verified end-to-end.**

---

## 2. TL;DR — first 60 seconds

If `/workspaces/` still exists (normal restart/stop), run exactly this:

```bash
bash /workspaces/run-all.sh
```

Then open in a browser **already logged into GitHub**:

```
https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/
```

You get a live, clickable screenshot of the emulator with HOME / BACK / ENTER buttons.

`run-all.sh` is **idempotent** — running it when everything is already up finishes in ~2
seconds and changes nothing. Run it after every Codespace restart. Nothing survives a
restart except files on disk; that is the only reason the stack ever needs starting.

**If `/workspaces/` is gone**, you must rebuild from scratch → go to **§5**. Do not improvise.

---

## 3. Verified current state

Checked live on 2026-10-23:

| Component | State |
|---|---|
| Emulator | `emulator-5554`, `sys.boot_completed=1` |
| App | `com.example.mini_app` installed + running |
| Viewer `/status` | HTTP 200 |
| Viewer `/frame` | HTTP 200, ~15 KB PNG |
| Tap input | verified (3 taps → on-screen counter read `3`) |
| Disk free | ~4.8 GB |

Health check:

```bash
/workspaces/android-sdk/platform-tools/adb devices
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8091/status
```

---

## 4. How it works

### 4.1 Architecture

Three independent processes. Only 1 and 2 die on restart.

```
1. Emulator     qemu @testavd, -no-window -gpu swiftshader_indirect
                exposes adb on emulator-5554 / 5555

2. Flutter app  com.example.mini_app — installed into the AVD's data partition,
                launched with `adb shell monkey`. This is the thing under test.

3. emuview.py   HTTP server on 0.0.0.0:8091
                  GET  /frame   -> adb exec-out screencap -p, served as PNG
                  POST /tap ... -> adb shell input tap ...
                A background thread grabs frames ~8x/sec into a buffer; browsers poll it.
```

The browser page is a small `<img>` that reloads `/frame` every ~120 ms plus `pointerdown`
handlers that convert browser pixels to device pixels and POST them as taps.

**Why this design:** it needs no scrcpy, no WebSocket bridge, no extension, and no display.
`screencap` + `adb shell input` is the entire dependency surface — that is why it works
when three more sophisticated approaches did not.

### 4.2 Port visibility — the single most confusing part

Port 8091 is **Private** by default, and **that is correct — do not "fix" it.**

- A Private port redirects *unauthenticated* clients to `https://github.dev/pf-signin`.
- A browser **already logged into GitHub** passes through that redirect automatically.
  This is why the user sees the emulator with zero manual port configuration.
- `curl` with no GitHub session will get `302`. **That is expected, not a failure.**
  Do not treat it as a bug and start debugging.

### 4.3 Port visibility IS automatic — `gh codespace ports visibility`

**This works. Use it. Do not re-derive it.**

```bash
gh codespace ports visibility 8091:public -c "$CODESPACE_NAME"
```

- `gh codespace ports` lists every forwarded port with its visibility and browse URL.
- `gh codespace ports visibility <port>:public` flips one to Public.
- It requires the port to **already be forwarded** by VS Code. If it is not, the tunnel
  lookup fails with `404 Not Found` — so retry until VS Code has forwarded it.

**Why an earlier session concluded this was impossible (it was wrong):** it tried the
*generic GitHub REST API* port endpoints using `GITHUB_TOKEN` and
`GITHUB_CODESPACE_TOKEN`, which return `404`. The Codespaces-specific CLI uses a
*different* API and works. Verified end-to-end: external URL went `302 → 200`.

`/workspaces/ensure-public.sh` wraps the call and is invoked automatically by
`supervisor.sh` every ~48 s, so visibility survives reconnects and resets without
anyone touching the PORTS panel.

Extra hardening in `devcontainer.json` / `.vscode/settings.json`:
`forwardPorts: [8091, 9123]` and `portsAttributes` with a label and
`onAutoForward: openBrowser` — so the port is auto-forwarded and the browser opens
by itself once the viewer is listening.

> VS Code's `portsAttributes` does **not** support a `visibility` key (upstream feature
> request #6363 was tabled for lack of workspace-trust signalling). That is why the
> `gh` CLI call is needed rather than a settings-only solution.

---

## 5. Building it from scratch (if `/workspaces/` is gone)

Order matters. Do not skip §5.1 — the emulator will not boot without it.

### 5.1 Host prerequisites (do NOT survive a rebuild)

```bash
# /etc/group, X11 libs and /dev/kvm perms are outside the persistent volume
sudo sed -i 's/^kvm:x:109:/kvm:x:109:codespace/' /etc/group
sudo apt-get update -q
sudo apt-get install -y -q libx11-xcb1 libxcb1 libx11-6 libxcb-xfixes0 \
  libxcb-shm0 libxcb-render0 libxext6 libxfixes3 libxi6 libxtst6 \
  libnss3 libpulse0 libasound2t64
sudo ldconfig
sudo chmod 666 /dev/kvm
ls -l /dev/kvm   # codespace user must be in group kvm
```

This is automated in `/workspaces/bootstrap.sh`.

### 5.2 JDK 17 — required, and the reason is non-obvious

The container's **default Java is JDK 25**, which Gradle/AGP does not support. Builds fail
in confusing ways. Install and always use JDK 17:

```bash
sudo apt-get install -y openjdk-17-jdk
mkdir -p /workspaces/jdk17
# copy/symlink a JDK 17 distribution into /workspaces/jdk17
```

**Always `source /workspaces/androidsdk-env.sh` before any Flutter/Gradle command.**

### 5.3 Android SDK + emulator + system image

```bash
export ANDROID_HOME=/workspaces/android-sdk
export ANDROID_AVD_HOME=/workspaces/android-avd
mkdir -p $ANDROID_HOME/cmdline-tools
# unpack cmdline-tools into cmdline-tools/latest, then:
sdkmanager --licenses            # accept all
sdkmanager "platform-tools" "emulator" \
           "system-images;android-34;default;x86_64"
```

> **Use `default`, NOT `aosp_atd`.** ATD images wipe `/data/local/tmp` and block the
> scrcpy jar under SELinux. This cost hours; see §6.1.

### 5.4 Create the AVD

```bash
echo no | avdmanager create avd -n testavd \
  -k "system-images;android-34;default;x86_64" -d pixel_5 --force
```

Then edit `$ANDROID_AVD_HOME/testavd.avd/config.ini` to:

```ini
hw.cpu.ncore=2
hw.ramSize=2560
hw.sdCard=no
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
disk.dataPartition.size=2048M     # NOT 6G - see §6.2
image.sysdir.1=system-images/android-34/default/x86_64/
abi.type=x86_64
tag.id=default
```

### 5.5 The Flutter app

```bash
export PATH=/workspaces/flutter/bin:$PATH
cd /workspaces && flutter create mini_app
cd /workspaces/mini_app
```

The app is Flutter's default counter demo — `lib/main.dart` renders "Flutter Demo Home
Page", a counter, and a floating `+` button. That button is **intentional**: it is the
input-verification target, because every tap visibly changes a number.

**Critical: retune Gradle before building.** The template default is `-Xmx8G` plus 4 GB
metaspace on a machine with 7.8 GB and **no swap** — the kernel OOM-kills the daemon. In
`android/gradle.properties` set:

```properties
org.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=192m -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.parallel=false
org.gradle.caching=true
org.gradle.configureondemand=false
org.gradle.workers.max=1
kotlin.daemon.jvmargs=-Xmx768m
kotlin.incremental=false
android.useAndroidX=true
android.enableJetifier=false
```

Build only for x86_64 (the emulator ABI) to save time and disk:

```bash
flutter build apk --release --target-platform android-x64
# -> build/app/outputs/flutter-apk/app-release.apk   (~15.8 MB)
```

### 5.6 The viewer

`/workspaces/emuview.py` — full source is in §9 so you can recreate it if lost. Key
decisions inside it:

- Binds **`0.0.0.0`**, not `127.0.0.1` — Codespaces' port forwarder must reach it.
- A daemon thread runs `adb exec-out screencap -p` on a loop and stores the latest frame
  under a lock; `/frame` just copies it out. Serving is therefore instant and constant
  load regardless of how slow the capture is.
- Validates the PNG magic bytes `\x89PNG\r\n\x1a\n` and discards anything else.
- Input handlers shell out to `adb shell input tap|swipe|keyevent|text`.
- `Cache-Control: no-store` on every response, or the browser caches frames.
- The HTML client converts click coordinates by the ratio of bounding box to
  `naturalWidth`/`naturalHeight`, so taps land correctly at any zoom level.

### 5.7 One-command startup and auto-start

`/workspaces/run-all.sh` performs: KVM check → start emulator if absent → wait for
`boot_completed=1` → install APK if missing → launch app → start viewer → print URL.
It is idempotent at every step.

Also created:
- `/workspaces/.vscode/tasks.json` — `Ctrl+Shift+B` runs `run-all.sh`
- `/workspaces/.devcontainer/devcontainer.json` — `postStartCommand` runs `run-all.sh`
  (**only applies to Codespaces created from that config**, not an already-running one)

---

## 6. Mistakes already made — do not repeat these

Every one of these presents as an indefinite **"Connecting…" with no error message.**

### 6.1 Wrong system image (`aosp_atd`)
ATD ("Automated Test Device") images wipe `/data/local/tmp` and block the scrcpy jar
under SELinux, so streaming silently never works. **Use
`system-images;android-34;default;x86_64`.** Current setting is already correct.

### 6.2 `disk.dataPartition.size=6G` on a 32 GB disk
It does not fit alongside the SDK (6.2 GB), Flutter (2.4 GB) and Gradle caches (2.2 GB).
Capped to **2048M**.

### 6.3 Boot timeout
Cold boot takes **~127 s**. EmbeDroid's default limit was 120 s, so it gave up on a
perfectly healthy emulator. Patched to 420 s.

### 6.4 Content-Security-Policy
The extension's CSP allowed only `ws://127.0.0.1`, so the browser silently refused the
WebSocket. Widened to
`connect-src ws://127.0.0.1:* wss: wss://*.app.github.dev https: http: ws: blob:`.
**Lesson: in Codespaces the browser origin is the `*.app.github.dev` hostname, never
`127.0.0.1`. Any CSP, CORS or origin check must include it.**

### 6.5 `scid` sign bug
A random int was unmasked with `& 0xffffffff` then parsed as a signed int → roughly 50% of
launches died with `NumberFormatException`. Fixed by masking with `0x7fffffff`.

### 6.6 JDK 25 vs 17
System default Java is 25; Gradle chokes. Working JDK is at `/workspaces/jdk17`, exported by
`androidsdk-env.sh`. Chasing this without knowing the cause produces a phantom failure.

### 6.7 A manual emulator blocks the extension
If `adb devices` already lists an emulator, EmbeDroid's own launch cannot attach and hangs.
Kill the manual one before testing the extension. (Conversely, our viewer is fine with a
manually started emulator.)

### 6.8 Misdiagnosis: "SELinux Enforcing is broken"
It is **fine**. The AVD stays enforcing and scrcpy's server still runs. Disabling SELinux
was an unnecessary detour.

### 6.9 Misdiagnosis: "the tunnel is down"
`302 → pf-signin` means *unauthenticated*, not *down*. See §4.2.

### 6.10 Deleting the AVD by accident
During troubleshooting the AVD was removed and recreated, which wiped userdata (losing the
installed app) and the carefully tuned `config.ini`. Restored from a backup. **Before any
destructive emulator/`avdmanager` step, copy `$ANDROID_AVD_HOME` somewhere safe.**

### 6.11 Browser showed a "sad face" / broken-image glyph
The viewer page originally reloaded `/frame` on a fixed 120 ms timer without waiting for
the previous image to finish loading. Because a frame takes ~1 s to capture (software GPU),
roughly 8 image requests were in flight at once and the browser was swapping `src`
mid-load → broken-image icon on a grey page, while the server was perfectly healthy.

**Fix:** chain the requests through `onload`/`onerror` so only one is ever in flight.
That pattern is already in `emuview.py` — keep it if you edit the HTML.

---

## 7. EmbeDroid — the abandoned path

The user's original request. Extension: `utpalbarman.embedroid-1.0.2`, at
`/home/codespace/.vscode-remote/extensions/utpalbarman.embedroid-1.0.2/dist/extension.js`.

Six patches were applied (backups `extension.js.orig`, `.bak-csp`, `.bak-host` sit next to
the file):

1. `asExternalUri()` so the webview loads through the Codespaces hostname
2. bridge port pinned to `8099`
3. `scid` masked with `0x7fffffff` (§6.5)
4. boot timeout `12e4` → `42e4` ms (§6.3)
5. CSP widened (§6.4)
6. bridge host `127.0.0.1` → `0.0.0.0`

**Why it was still abandoned:** it requires **pressing the extension's Play button**, which
violates the "fully autonomous" requirement. `/workspaces/patch_embedroid.py` only reproduces
patch 1 — **an extension reinstall would silently lose patches 2–6.** The custom viewer has
no such dependency.

It was never confirmed working end-to-end in the browser. Do not assume it works.

---

## 8. Other dead ends

- **Local scrcpy SDL client** in the browser terminal — cannot open a display. Irrelevant
  to `emuview`, which needs no SDL.
- **`aosp_atd` images** — §6.1.
- **Generic REST API for port visibility** — returns `404`; use the `gh` CLI instead (§4.3).
- **Old `port-watchdog.sh` / `run-stream-test.sh`** — deleted; they only spammed 404s.
  They are superseded by `ensure-public.sh`, which uses the working API.

---

## 9. `emuview` HTTP API and source

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | HTML viewer page |
| GET | `/frame` | current screen as PNG |
| GET | `/status` | JSON `{device, fps, frames}`; `200` = healthy |
| POST | `/tap?x=<px>&y=<px>` | tap at device coords |
| POST | `/swipe?x1&y1&x2&y2[&ms=300]` | swipe/drag |
| POST | `/key?code=<keycode>` | keyevent, e.g. `KEYCODE_HOME` |
| POST | `/text?value=<urlencoded>` | type text |

Coordinates are **emulator screen pixels**, not browser pixels. The AVD is configured
`hw.lcd.width=320`, `hw.lcd.height=640`, `hw.lcd.density=160` — so the screen is
**320×640 portrait** (an earlier version of this file wrongly said 720×1280).
The viewer page scales the image and converts clicks client-side.

```bash
curl -X POST "http://127.0.0.1:8091/tap?x=275&y=595"
```

### Full source of `emuview.py`

```python
#!/usr/bin/env python3
"""emuview - autonomous Android emulator viewer over HTTP."""
import json, os, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ADB = "/workspaces/android-sdk/platform-tools/adb"
PORT = int(os.environ.get("EMUVIEW_PORT", "8091"))
_lock = threading.Lock()
_last_frame = {"data": b"", "ts": 0.0}
_stats = {"fps": 0.0, "frames": 0}

def _adb(*args, timeout=20):
    return subprocess.run([ADB, *args], capture_output=True, timeout=timeout)

def device_ready():
    try:
        for line in _adb("devices").stdout.decode().splitlines()[1:]:
            if line.strip().endswith("\tdevice"):
                return line.split()[0]
    except Exception:
        pass
    return None

def capture_loop():
    serial = device_ready()
    if not serial:
        return
    while True:
        try:
            r = subprocess.run([ADB, "-s", serial, "exec-out", "screencap", "-p"],
                               capture_output=True, timeout=15)
            if r.stdout[:8] == b"\x89PNG\r\n\x1a\n":
                now = time.time()
                with _lock:
                    prev = _last_frame["ts"]
                    _last_frame["data"] = r.stdout
                    _last_frame["ts"] = now
                    _stats["frames"] += 1
                    if prev:
                        dt = now - prev
                        if dt > 0:
                            _stats["fps"] = round(_stats["fps"] * 0.8 + (1 / dt) * 0.2, 1)
        except Exception:
            pass
        time.sleep(0.12)

HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,user-scalable=no">
<title>Emulator</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;color:#eee;font:14px system-ui;display:flex;flex-direction:column;
     align-items:center;justify-content:center;height:100vh;gap:10px}
img{image-rendering:pixelated;border:2px solid #333;border-radius:6px;background:#000}
.bar{display:flex;gap:8px}
button{background:#2a2a2a;color:#eee;border:1px solid #444;border-radius:6px;
       padding:8px 14px;font-size:14px;cursor:pointer}
button:active{background:#444}
#st{font-size:12px;color:#888}
</style></head><body>
<img id=v src="/frame">
<div class=bar>
  <button onclick="k(3)">HOME</button>
  <button onclick="k(4)">BACK</button>
  <button onclick="k(66)">ENTER</button>
</div>
<div id=st>connecting...</div>
<script>
const v=document.getElementById('v'),st=document.getElementById('st');
function loop(){v.src='/frame?t='+Date.now();requestAnimationFrame(()=>setTimeout(loop,120));}
loop();
function post(p){return fetch(p,{method:'POST'}).catch(()=>{});}
function k(c){post('/key?code='+c);}
v.addEventListener('pointerdown',e=>{
  const r=v.getBoundingClientRect(), sx=v.naturalWidth, sy=v.naturalHeight;
  if(!sx)return;
  post('/tap?x='+Math.round((e.clientX-r.left)/r.width*sx)+
       '&y='+Math.round((e.clientY-r.top)/r.height*sy));
});
setInterval(()=>fetch('/status').then(r=>r.json()).then(d=>{
  st.textContent='device '+d.device+' | fps '+d.fps+' | frames '+d.frames;
}).catch(()=>{st.textContent='offline';}),2000);
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            self._send(200, "text/html; charset=utf-8", HTML.encode())
        elif u.path == "/frame":
            with _lock:
                data = _last_frame["data"]
            self._send(200, "image/png", data or b"")
        elif u.path == "/status":
            self._send(200, "application/json", json.dumps({
                "device": device_ready(), "fps": _stats["fps"],
                "frames": _stats["frames"]}).encode())
        else:
            self._send(404, "text/plain", b"not found")
    def do_POST(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        serial = device_ready()
        if not serial:
            self._send(503, "text/plain", b"no device"); return
        try:
            if u.path == "/tap":
                x, y = q["x"][0], q["y"][0]
                cmd = ["-s", serial, "shell", "input", "tap", str(x), str(y)]
                msg = f"tap {x},{y}"
            elif u.path == "/swipe":
                a = [q["x1"][0], q["y1"][0], q["x2"][0], q["y2"][0], q.get("ms", ["300"])[0]]
                cmd = ["-s", serial, "shell", "input", "swipe", *a]; msg = "swipe"
            elif u.path == "/key":
                cmd = ["-s", serial, "shell", "input", "keyevent", q["code"][0]]
                msg = "key " + q["code"][0]
            elif u.path == "/text":
                cmd = ["-s", serial, "shell", "input", "text", q["value"][0]]
                msg = "text"
            else:
                self._send(404, "text/plain", b"not found"); return
            subprocess.run([ADB, *cmd], capture_output=True, timeout=25)
            self._send(200, "application/json", json.dumps({"ok": True, "sent": msg}).encode())
        except Exception as e:
            self._send(500, "application/json", json.dumps({"ok": False, "err": str(e)}).encode())

if __name__ == "__main__":
    print(f"emuview listening on 0.0.0.0:{PORT}", flush=True)
    threading.Thread(target=capture_loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
```

**Known limitation:** `capture_loop()` returns immediately if no device is present at
startup, so launching `emuview.py` *before* the emulator boots leaves it serving empty
frames forever. `run-all.sh` avoids this by starting the viewer last. If you hit it, just
restart the viewer after the device is up.

---

## 10. Operating it

```bash
bash /workspaces/run-all.sh          # start everything (idempotent)
bash /workspaces/bootstrap.sh        # after a rebuild: KVM + X11 + /dev/kvm
source /workspaces/androidsdk-env.sh # before ANY flutter/gradle command
bash /workspaces/build.sh            # rebuild the APK (x86_64 release)
bash /workspaces/start-avd.sh        # emulator only;  start-avd.sh stop to halt
```

Logs: `/tmp/emulator.log`, `/tmp/emuview.log`, `/tmp/bootstrap.log`, `/tmp/autostart.log`.

Full reset (always safe):

```bash
adb kill-server
pkill -f emuview.py
pkill -f qemu-system
bash /workspaces/run-all.sh
```

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| External URL shows GitHub sign-in page | Port is Private; browser not logged in | Log into GitHub in that browser. Only use PORTS panel → Public for sharing |
| `curl` external URL returns `302` | **Expected.** Not a fault | Ignore |
| Viewer blank / "no device" | `emuview` started before the emulator | Restart viewer after boot, or just re-run `run-all.sh` |
| Emulator never boots | `/dev/kvm` perms lost after rebuild | `bash /workspaces/bootstrap.sh` |
| Emulator dies mid-boot | SELinux / ATD image | Confirm image is `default`, not `aosp_atd` |
| Gradle OOM-killed or `-Xmx8G` | Container has 7.8 GB, **no swap** | Restore tuned `gradle.properties` (§5.5) |
| Flutter build fails with odd Java errors | System JDK is 25 | `source /workspaces/androidsdk-env.sh` first |
| Disk nearly full | `.gradle` = 2.2 GB | **Do not delete `.gradle`** (slow to re-download). NDK was already removed |
| Frame rate ~3–8 fps | Software GPU `swiftshader_indirect` | Expected. Not a bug |

---

## 12. Resource limits

**2 vCPU · 7.8 GB RAM · no swap · 32 GB disk.**

- Disk usage: Android SDK 6.2 GB, Flutter 2.4 GB, `.gradle` 2.2 GB. ~4.8 GB free.
- Never let Gradle use defaults — `-Xmx8G` OOM-kills on this box (§5.5).
- Android NDK was deleted post-build to reclaim space.
- Build **only** `android-x64`; the emulator is x86_64. Skip arm/universal builds.
- Low frame rate in the viewer is a software-rendering limit, not a defect.

---

## 13. File map

| Path | Purpose |
|---|---|
| `/workspaces/run-all.sh` | **the one command** — brings up everything, idempotent |
| `/workspaces/supervisor.sh` | watchdog — relaunches emulator/app/viewer if they die (§15.1) |
| `/workspaces/ensure-up.sh` | instant hook — starts the supervisor if not running (§17.4) |
| `/workspaces/ensure-public.sh` | makes port 8091 Public via `gh` CLI (§4.3, §17.1) |
| `/workspaces/emuview.py` | HTTP screen + input server on :8091 |
| `/workspaces/androidsdk-env.sh` | PATH / `JAVA_HOME` / `ANDROID_HOME` — **source before builds** |
| `/workspaces/bootstrap.sh` | restores `/dev/kvm`, kvm group, X11 libs after a rebuild |
| `/workspaces/build.sh` | builds the release APK |
| `/workspaces/start-avd.sh` | emulator-only launcher (`stop` subcommand too) |
| `/workspaces/mini_app/` | Flutter app source |
| `/workspaces/mini_app/lib/main.dart` | default counter demo — the tap target |
| `/workspaces/mini_app/android/gradle.properties` | memory-constrained Gradle settings |
| `/workspaces/android-avd/` | AVD home (`testavd`) |
| `/workspaces/flutter/` | Flutter 3.35.1 SDK |
| `/workspaces/android-sdk/` | Android SDK, emulator, platform-tools |
| `/workspaces/jdk17/` | the JDK that actually works |
| `/workspaces/.vscode/tasks.json` | `Ctrl+Shift+B` → `run-all.sh` |
| `/workspaces/.devcontainer/devcontainer.json` | `postStartCommand` → `run-all.sh` |
| `/workspaces/AGENTS.md` | short pointer to this file |
| `/workspaces/empty-repo/AGENTS.md` | **this file**, committed to git |

EmbeDroid (abandoned, §7):
`/home/codespace/.vscode-remote/extensions/utpalbarman.embedroid-1.0.2/dist/extension.js`
plus `extension.js.orig`, `.bak-csp`, `.bak-host`.

AVD config: 2 cores, `hw.ramSize=2560`, `hw.sdCard=no`, `hw.gpu.mode=swiftshader_indirect`,
`disk.dataPartition.size=2048M`, image `system-images;android-34;default;x86_64`.

---

## 14. If the Codespace is rebuilt from scratch

Disk-persistent (`/workspaces/*`) survives; the runtime does not. Extensions live in
`/home/codespace/.vscode-remote/` and are **not** persistent — reinstalling EmbeDroid
silently loses patches 2–7.

1. `bash /workspaces/bootstrap.sh`
2. `bash /workspaces/run-all.sh`

If `/workspaces/` itself is gone, rebuild using **§5** top to bottom.

`.devcontainer/devcontainer.json` automates steps 1–2, but only for Codespaces **created
from** that config. Until then use `Ctrl+Shift+B` or `bash /workspaces/run-all.sh`.
---

## 15. Session findings (2026-10-24) — read this section, it supersedes parts of §1–§14

A follow-up session re-verified everything from scratch and found **five** things the
earlier notes got wrong or missed. Each one is now fixed on disk.

### 15.1 Why the user "never saw an emulator running" — the real cause

Two independent causes, both fixed:

1. **`.devcontainer/` and `.vscode/` were in the wrong directory.** They sat in
   `/workspaces/`, but the git repo / VS Code workspace root is
   **`/workspaces/empty-repo/`**. VS Code and GitHub Codespaces only read those
   from the *repository root*, so neither the `postStartCommand` nor the
   `Ctrl+Shift+B` task was ever picked up. **Nothing auto-started.**
   → Both are now copied to `/workspaces/empty-repo/.vscode/` and
   `/workspaces/empty-repo/.devcontainer/`. The task works immediately; the
   `postStartCommand` only applies after the Codespace is rebuilt from the repo.

2. **The container is reset periodically** and takes every process with it
   (`/tmp` is wiped, `qemu`/`emuview` die, and the VS Code server restarts —
   which also drops the browser's port-forward tunnel, causing transient
   "DNS address could not be found"). This is an *environment* behaviour, not a
   bug in this repo. It happened at least three times in one session.

   → **`/workspaces/supervisor.sh`** now exists and is started by `run-all.sh`.
   It loops every 8 s and relaunches whatever died: the emulator, the Flutter
   app, and the viewer. It also restarts the viewer whenever the emulator was
   restarted, because `emuview.capture_loop()` exits permanently if it starts
   without a device attached.

   Verified: `kill -9` on qemu + emuview → 73 s later the emulator was back,
   the app relaunched and the viewer was serving fresh frames again, with no
   human involvement.

### 15.2 Flutter's Impeller was causing an ANR storm — must be disabled

With Impeller (Flutter's default Vulkan renderer) running on SwiftShader
(software Vulkan), `qemu` sat at **75 % CPU** and the device threw
*"Process system isn't responding"* / *"System UI isn't responding"* dialogs
that covered the app and blocked every tap.

Fix — launch with Impeller off (the same intent extra the Flutter tool sends
for `flutter run --no-enable-impeller`):

```bash
adb shell am start -n com.example.mini_app/.MainActivity --ez enable-impeller false
```

Plus, on the device:

```bash
adb shell settings put global hide_error_dialogs 1          # no ANR dialogs at all
adb shell settings put global window_animation_scale 0      # animations off
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
```

`hide_error_dialogs 1` is the single most useful setting here: it suppresses
the ANR/crash dialogs entirely instead of fighting them. `supervisor.sh` applies
all four on every boot.

### 15.3 The screen is 320×640, not 720×1280

`config.ini` says `hw.lcd.width=320`, `hw.lcd.height=640`, `hw.lcd.density=160`.
The counter app's `+` FAB is at device coords **(275, 595)**; tapping the top
edge (y=568) misses it. The viewer page converts browser pixels to device
pixels client-side, so clicking the visible button in the browser is correct
regardless of zoom.

### 15.4 Disk is the real constraint — any Gradle build needs the NDK

`ndkVersion = flutter.ndkVersion` (from the Flutter template) makes AGP install
**NDK 27.0.12077973 = 2.0 GB**. Flutter's Gradle plugin sets it automatically,
so it is *not* optional and cannot be avoided by editing `build.gradle.kts`.
The install needs **~2.7 GB of free space** (zip + unzip) and fails with
`No space left on device` otherwise.

- The NDK is currently **kept** so `flutter build` / `flutter run` work.
- If you only need the release APK + viewer, delete
  `/workspaces/android-sdk/ndk/27.0.12077973` and reclaim 2.0 GB.
- **Do not add `packaging { jniLibs { keepDebugSymbols += "**/*.so" } }`** —
  it does *not* avoid the NDK (Flutter's plugin still requests it) and it
  bloats the debug APK from ~100 MB to **357 MB**. Tested and reverted.
- Safe to delete when space is tight (all regenerable, no network needed):
  - `/workspaces/.gradle/caches/8.12/transforms` (1.4 GB)
  - `/workspaces/.gradle/caches/build-cache-1` (139 MB)
  - `/workspaces/mini_app/build/app/intermediates` (466 MB)
  - `/home/codespace/.cache/copilot` (1.1 GB), `/home/codespace/.npm/_cacache` (449 MB)
- **Never** delete `/workspaces/.gradle/caches/modules-2` (550 MB) — that is
  downloaded artifacts and re-downloading it is slow.

Current budget after this session: **~2.9 GB free**, NDK kept.

### 15.5 EmbeDroid — the corrected verdict

§7 said the extension "was never confirmed working end-to-end". It **is**, with
one caveat. From the extension's own output channel
(`.../logs/<ts>/exthost1/output_logging_*/1-Android Emulator.log`):

```
[13:11:17] INFO Embedded Android Emulator activating…
[13:11:25] INFO Booting: .../emulator @testavd -no-window -no-boot-anim -gpu swiftshader_indirect
[13:15:16] DEBUG LocalBridge listening on 127.0.0.1:8099 for emulator-5554
[13:15:17] INFO External bridge URL: https://<cs>-8099.app.github.dev/
```

- The extension **auto-boots the AVD on activation** — no ▶ button needed for
  the emulator itself.
- Its WebSocket bridge on **:8099** works: the handshake returns
  `101 Switching Protocols`.
- It **attaches to an already-running emulator** (`Devices changed:
  emulator-5554:device:testavd`), so it coexists with `supervisor.sh`.
  It only fails if it tries to boot a *second* instance of the same AVD
  (`FATAL: Running multiple emulators with the same AVD`) — harmless, it retries.
- Its one real failure mode was **disk**: `FATAL: Your device does not have
  enough disk space to run avd: testavd` when only 1.5 GB was free.

**The one manual step that remains:** the webview panel is only created by
`embedroid.openEmbedded`, which is bound to the 📱 icon on the device row in
the **Activity Bar → "Android Emulator" → "Devices & AVDs"** tree (or Command
Palette → *Android Emulator: Open Embedded View*). There is no URI handler and
the `code` CLI has no `--command` flag, so it **cannot be opened headlessly**.

**Verdict:** the extension is good enough to *run* an emulator and *stream* it,
but it needs one click to open the panel. `emuview.py` + `supervisor.sh` needs
zero clicks — just a URL. For a product, the extension can be reused for the
webview UX while the boot/supervision stays scripted.

### 15.6 `flutter run` (debug + hot reload) works

```
source /workspaces/androidsdk-env.sh
export PATH=/workspaces/flutter/bin:$PATH
cd /workspaces/mini_app
flutter run --no-enable-impeller -d emulator-5554
```

`flutter devices` sees `emulator-5554`. A debug APK builds successfully
(≈5 min). `--no-enable-impeller` is **mandatory** for the same reason as §15.2.

### 15.7 Corrected emulator launch flags

`run-all.sh` and `supervisor.sh` launch:

```
emulator @testavd -no-window -no-boot-anim -gpu swiftshader_indirect
```

Note **`-no-boot-anim`** — it is not in the older notes but saves ~40 s of boot
time. Cold boot from cold (no snapshot) is **~2–3 min**; `boot_completed=1` is
the only reliable readiness signal.

### 15.8 Fast health check

```bash
/workspaces/android-sdk/platform-tools/adb devices
curl -s http://127.0.0.1:8091/status          # {"device":"emulator-5554",...}
tail -20 /tmp/supervisor.log                   # what the supervisor has been doing
```

If the browser shows a stale image but `/status` is 200 with a rising `frames`
count, the viewer is fine and it is the tunnel. If `frames` is frozen at 0, the
viewer started before the device — the supervisor fixes that automatically.

### 15.9 Quick reference for the URLs

| What | URL |
|---|---|
| `emuview` (our viewer, no click needed) | `https://<cs>-8091.app.github.dev/` |
| EmbeDroid's own bridge (needs the panel click) | `https://<cs>-8099.app.github.dev/` |

`<cs>` = `zany-space-carnival-p79jxxwgj4wvfr95j`. Both are **Private** ports:
an unauthenticated `curl` gets `302 → github.dev/pf-signin`, which is expected.
A browser logged into GitHub passes straight through.

### 15.10 Auto-start: three layers, all now in place

The container **itself** is restarted every few hours (verified via
`ps -o lstart -p 1` — pid 1's start time was `Oct 25 06:08:03` while the
previous session had been running since `Oct 24 12:57`). Everything in the
container dies with it. So auto-start needs three independent layers:

| Layer | Mechanism | When it fires | Covers |
|---|---|---|---|
| 1 | `.devcontainer/devcontainer.json` → `postStartCommand: bash /workspaces/ensure-up.sh` | container start | full container restarts — **only after the Codespace is rebuilt from this repo** |
| 2 | `.vscode/tasks.json` → task `Android Emulator: Ensure Up (auto)` with `runOptions.runOn = "folderOpen"` | every time the folder is opened | VS Code server restarts, which are far more frequent |
| 3 | `run-all.sh` (manual, `Ctrl+Shift+B`) | on demand | everything, synchronously, with logs in the terminal |

`ensure-up.sh` returns in ~2 s: it starts `supervisor.sh` in the background and
exits. The supervisor then does the real work (boot emulator → launch app →
start viewer) and keeps it alive.

> **Important:** layers 1 and 2 only work because the files live in the
> **repository root** (`/workspaces/empty-repo/`), which is the VS Code
> workspace folder and the Codespaces project root. Copies in `/workspaces/`
> are ignored. This was the single biggest reason "nothing ever auto-started".

### 15.11 The extension activates lazily, and its webview breaks on restart

- `package.json` has `"activationEvents": []`. The extension only wakes up when
  the **Activity Bar → "Android Emulator"** view is first opened. Until then
  there is no `1-Android Emulator.log` output channel and nothing is listening
  on 8099. This is normal, not a failure.
- The bridge issues `token = crypto.randomBytes(16).toString("hex")` per stream
  and the webview must present it as `?token=`. `attachStream()` recreates the
  bridge whenever the stream is re-attached, which **invalidates the token the
  open webview already has**. Symptom in the log:
  `WARN Rejected webview connection: bad token.` → the panel shows an error
  and must be closed and reopened.
  Consequence: if your supervisor restarts the emulator, the extension's
  open panel breaks. This is a reason to prefer `emuview` (stateless polling,
  no token, no WebSocket) over the extension's stream for automation.
- The webview URL is produced with `vscode.env.asExternalUri(...)`, which in
  Codespaces yields `https://<cs>-8099.app.github.dev/` → `wss://`. That works,
  but it depends on the VS Code server being alive and on the port being
  forwarded — the same DNS dependency that breaks for external browsers.

### 15.12 Browser DNS failures are a client-side problem

`getent hosts <cs>-8091.app.github.dev` and Google's DoH both resolve the
hostname to `20.207.70.99`, and `curl` to the external URL returns `302`
in ~0.1 s. So when the browser says *"DNS address could not be found"*, the
tunnel is fine and the browser has a stale/negative DNS cache (or a resolver
that cannot handle `*.app.github.dev`). Fix on the client: clear the DNS cache
(`chrome://net-internals/#dns` → *Clear host cache*), hard-reload, or use an
incognito window. The VS Code **PORTS** panel → *Open in Browser* is the
most reliable path because VS Code supplies the right URL and session.

### 15.13 `pkill -f` can kill your own shell

`pkill -f 'qemu-system'` matches the *bash -c* command line that contains that
string, so the shell kills itself and the command appears to hang. Kill by PID
instead:

```bash
kill -9 "$(pgrep -f 'qemu-system-x86_64-headless' | head -1)"
```

---

## 16. Second follow-up session (2026-10-25) — the browser path is a dead end here

This session went further than §15 and changed the recommendation.

### 16.1 The browser tunnel is unreachable from this user's machine

The user's browser **cannot resolve `*.app.github.dev`**:

| Check | Result |
|---|---|
| `getent hosts <cs>-8091.app.github.dev` (inside the container) | resolves to `20.207.70.99` |
| Google DNS-over-HTTPS, A + AAAA | resolves, A = `20.207.70.99`, no IPv6 address |
| `curl https://<cs>-8091.app.github.dev/` (inside the container) | `200` with the real page |
| Same URL in the user's browser | **"DNS address could not be found"** — also in incognito, also after `ipconfig /flushdns` |

So the tunnel and the DNS records are fine; the user's own resolver is the
problem, and it is not fixable from inside the container. The VS Code
workbench keeps working because the browser already has that one hostname
cached — a *new* sibling hostname (`-8091`, `-8099`) fails to resolve.

**Consequence: anything that requires an external hostname is unreliable here.**
That rules out both the `emuview` browser URL *and* EmbeDroid's embedded
webview (its WebSocket goes to `wss://<cs>-8099.app.github.dev/`, which is
exactly such a new hostname).

`9123` is served as a second viewer port so there is always a fresh hostname
to try, but the resolver may reject any of them.

### 16.2 The answer: a native VS Code webview (new extension in this repo)

`emulator-view` (this repo, `package.json` + `extension.js` + `media/`) renders
the emulator **inside a VS Code editor tab** with **no port forwarding, no
tunnel, no external hostname and no DNS** at all:

- The extension host runs in the container, so it can call
  `adb -s emulator-5554 exec-out screencap -p` directly.
- Frames are pushed to the webview with `webview.postMessage()` as base64 PNG
  (no WebSocket, no token, no scrcpy, no WebCodecs).
- Clicks are converted to device pixels in the webview and sent back as
  `{type:"input", action:"tap", x, y}`; the host runs `adb shell input tap`.
- HOME / BACK / ENTER buttons and arrow-key support are included.

Install it by copying the repo into the extensions folder:

```bash
cp -r /workspaces/empty-repo/{extension.js,package.json,media} \
      /home/codespace/.vscode-remote/extensions/codespace.emulator-view-0.1.0/
```

Then **Developer: Reload Window** and run
*Android Emulator: Open Emulator View* from the Command Palette.

Measured on this box: `screencap` ≈ 540–940 ms per frame (≈1.3 fps, software
GPU limit), `adb shell input tap` ≈ 320 ms. Interactive, but not 60 fps.

### 16.3 EmbeDroid's own video path — why it fails here

Traced through the extension source:

- `attachStream()` **always** disposes the bridge and creates a new one, and
  each bridge mints a fresh `token = crypto.randomBytes(16)`. The bridge
  rejects any WebSocket whose `?token=` does not match.
- The webview only sets its "connected" flag `s` when the **first video frame
  is decoded**. So a socket that closes before any frame arrives takes the
  failure branch and the panel dies with "Could not connect to the device".
- The fix is a patch to `media/webview.js`: on a close that was not superseded
  by a newer config, post `{type:"retry"}` (the extension already handles that
  by re-running `attachStream`, which sends a fresh config *and* a matching
  token). A config-generation counter distinguishes "the extension swapped the
  bridge" from "this socket was rejected".
- Patches live in **`/workspaces/patch_embedroid_token.py`** (re-appliable after
  an extension reinstall; `webview.js.orig` is the backup). Patch 1 lives in
  `/workspaces/patch_embedroid.py`.
- **Even with that patch the embedded video still cannot work in Codespaces
  browser mode**, because the WebSocket must resolve `<cs>-8099.app.github.dev`
  (§16.1). The patch removes one failure mode; the DNS one remains.

### 16.4 Supervisor fixes

- The supervisor used to launch a **second** emulator whenever `adb devices`
  was briefly empty (e.g. the adb server restarting). That killed the healthy
  emulator. It now checks whether a `qemu-system-x86_64-headless` process is
  alive and waits instead, and requires 3 consecutive misses before acting.
- `ensure-up.sh` must **not** use an unanchored `pgrep -f supervisor.sh`:
  the invoking shell's own command line contains that string, so it matches
  itself. It uses the pidfile plus `/proc/<pid>/cmdline`, and falls back to
  `pgrep -f '^bash /workspaces/supervisor\.sh$'`.
- Same trap for `pkill -f 'qemu-system'` — it kills the calling shell. Kill by
  PID instead.

### 16.5 Boot time reality

The AVD has **no usable snapshot** (`Device 'cache' does not have the requested
snapshot 'default_boot'`), so every boot is a **cold boot of ~66–135 s**.
§2's "boots from snapshot, ~30 s" is wrong.

---

## 17. Third follow-up session (2026-10-25) — full automation achieved

This session **supersedes §16's conclusion**. §16 was right that the browser could not
resolve `*.app.github.dev` *at that time*, and right that EmbeDroid's WebSocket path
needs an external hostname. But it concluded "the browser path is a dead end here".
**It is not.** Two things were wrong with that conclusion, both now fixed.

### 17.1 Port visibility CAN be automated — the `gh` CLI, not the REST API

§4.2 previously said this was impossible. **It is possible.** The working command:

```bash
gh codespace ports visibility 8091:public -c "$CODESPACE_NAME"
```

Verified: exit `0`, `gh codespace ports` then reports `8091 public`, and the external URL
went from `302 → 200` with live JSON from inside the container.

The reason the earlier attempt failed is a subtle API split:

- The **generic GitHub REST API** port endpoints (`/repos/.../codespaces/.../ports`)
  return `404` for `GITHUB_TOKEN` and `GITHUB_CODESPACE_TOKEN` in a Codespace.
- The **Codespaces-specific** API used by `gh codespace ports` is a *different*
  endpoint and works fine.

Other useful facts learned:

- `gh codespace ports -c "$CS"` lists every forwarded port with `sourcePort`,
  `visibility`, `browseUrl` and `label`. Use it to check state.
- The command **fails with `404 Not Found` if the port is not yet forwarded**. VS Code
  forwards a port when it detects a process listening on it, so there is a race after a
  restart. Retry — `/workspaces/ensure-public.sh` retries 8× with a delay.
- `gh codespace ports visibility` accepts several ports at once, but if **one** of them
  is not forwarded the whole call fails. The wrapper therefore sets ports one at a time.
- Once a port is Public it tends to **stay** public across reconnects (VS Code keeps
  the visibility of an already-forwarded port), but the supervisor re-asserts it
  anyway, every ~48 s, because resets do happen.

`/workspaces/ensure-public.sh` is the wrapper. It is called by `supervisor.sh` (every
~48 s) and by `run-all.sh` (once, at the end).

### 17.2 The "sad face" in the browser was OUR bug, not the user's browser

The user reported a grey page with a sad-face / broken-image glyph in the bottom-right
and top-right. Server side was healthy (`/frame` returned a valid PNG).

Cause: the viewer HTML reloaded `/frame` on a **fixed 120 ms timer without waiting for
the previous image to load**. A frame takes ~1 s to capture on the software GPU
(measured fps ≈ 0.9–1.3), so roughly 8 image requests were in flight at once and the
browser was swapping `src` mid-load. Chrome then renders the broken-image glyph.

**Fix (already in `emuview.py`):** chain requests — set `v.onload`/`v.onerror` and only
schedule the next `/frame` after the current one settles. One request in flight, ever.

> Lesson for the next agent: **the server being healthy does not mean the browser is
> healthy.** Capture the PNG and look at it (`curl -o f.png .../frame` then read the
> image) to separate server-side from client-side. And when the user reports something
> visual, ask them what they see rather than assuming your own view matches theirs.

### 17.3 Cold-start recovery: measured, not assumed

Killed **everything** — supervisor, both viewers, the adb server, and qemu — then
invoked only the auto-start hook:

```bash
bash /workspaces/ensure-up.sh
```

Recovery timeline (no human involvement at any point):

| t | State |
|---|---|
| 0 s | supervisor starts, detects no emulator, begins cold boot |
| 10–80 s | external URL `502` (forwarded, nothing listening yet — **this is normal**) |
| ~90 s | `boot_completed=1`, app launched, viewer up, port public |
| ~90 s | external URL `200`, app rendering correctly |

So **~90 seconds from a total wipe to a working public page.** The `502` window during
boot is expected; do not "fix" it.

### 17.4 Auto-start: three independent layers

| Layer | Mechanism | When it fires |
|---|---|---|
| 1 | `.devcontainer/devcontainer.json` → `postStartCommand: bash /workspaces/ensure-up.sh` | container start — **only for Codespaces created from that config** |
| 2 | `.vscode/tasks.json` → task with `runOptions.runOn = "folderOpen"` | every time the folder is opened |
| 3 | `bash /workspaces/run-all.sh` (or `Ctrl+Shift+B`) | on demand, synchronous |

`ensure-up.sh` returns in ~2 s: it starts `supervisor.sh` in the background and exits.
The supervisor then does the real work (boot emulator → launch app → start viewer →
re-assert public visibility) and keeps it alive.

### 17.5 The DNS-free fallback still exists

§16.2's native VS Code webview (`emulator-view` extension: `package.json` +
`extension.js` + `media/` in this repo) renders the emulator **inside a VS Code editor
tab** — no port, no tunnel, no hostname, no DNS, no auth. It is the right answer if the
user's resolver ever rejects `*.app.github.dev` again.

```bash
cp -r /workspaces/empty-repo/{extension.js,package.json,media} \
      /home/codespace/.vscode-remote/extensions/codespace.emulator-view-0.1.0/
```

Then **Developer: Reload Window** → *Android Emulator: Open Emulator View*.

### 17.6 Current state (end of this session)

| Check | Result |
|---|---|
| `adb devices` | `emulator-5554  device` |
| App | `com.example.mini_app` running, focused |
| `http://127.0.0.1:8091/status` | `200`, `{"device":"emulator-5554","fps":~1,"frames":N}` |
| `https://<cs>-8091.app.github.dev/status` | `200` (Public, no auth needed) |
| `gh codespace ports` | `8091 public`, `9123 private` |
| Disk free | ~4.8 GB |


---

## 18. Fourth follow-up session (2026-10-25) — why the port kept vanishing

This session chased the last real defect: port 8091 kept **disappearing** from the
forwarded list, and the VS Code webview tab showed "error in emulator window".

### 18.1 The webview path is IMPOSSIBLE for this user — DNS

The user reported `10fitsm...assets.github.dev's server IP address could not be found`.

- `*.assets.github.dev` is where VS Code serves **webview** resources. It resolves
  publicly (A record exists) but **the user's own resolver cannot resolve it** — the
  same DNS problem as §16.1, on a second domain.
- Their browser resolves `*.app.github.dev` (the workbench) fine.

**Conclusion: any VS Code webview is dead on arrival for this user** — the extension
tab can never render. Do not spend time on `media/view.js`, CSP, or nonces.
The `emulator-view` extension is still useful as a *frame pump* and for input, but its
panel will not display.

### 18.2 The Codespaces agent forwards ports ONCE, at container start

This was the real cause of the disappearing port. Timeline evidence:

- `/tmp/containerd.log` and `/tmp/dockerd.log` are dated 07:57 → **the container was
  recreated at 07:57**, taking the emulator, the app and the viewer with it.
- The Codespaces port-forwarding agent scans for listening ports **at container start**.
  It registered 891, 923, 2000 (VS Code internals) and 8099 (the EmbeDroid bridge).
- The supervisor only starts the viewer **after the emulator finishes booting** (~2 min
  later) → too late. The port was never forwarded.
- **Rebinding does not help.** Killing and restarting the viewer at 08:18 did not
  re-register 8091 after 30 s of polling.

The fix has two parts:

1. **`emuview.py` must be safe to start before the emulator exists.** `capture_loop()`
   previously *returned* if no device was present, so an early-started viewer would
   serve empty frames forever. It now polls for a device and starts capturing as soon
   as one appears.
2. **The viewer must be bound as early as possible.** `ensure-up.sh` now starts it
   **before** it starts the supervisor, and `supervisor.sh` keeps the viewers bound
   independently of the emulator state (the `viewer_up || start_viewer` lines moved
   out of the `if dev_up` branch).

Also: the `emulator-view` extension now spawns the viewer itself
(`ensureViewer()` in `extension.js`). Rationale: the agent forwards ports bound by
processes **inside the VS Code server's process tree** — the EmbeDroid bridge on 8099
is an extension-host child and *is* forwarded, while a shell-spawned viewer was not.
Keeping the viewer in that tree makes forwarding reliable.

### 18.3 The extension now opens its own panel and logs to disk

- `activate()` calls `openView()` automatically → the tab appears with **no command to
  run and no button to click**.
- `session.start()` is called when the panel is created. It used to be triggered only
  by a `{"type":"ready"}` message from the webview; since the webview cannot load
  (§18.1) that message never arrived and the session never started. The capture loop
  now starts immediately and only *waits* for the device.
- `extLog()` appends to **`/tmp/emulator-view.log`**. Use this to verify the extension
  is alive without asking the user: it should show
  `activated` → `Attached to emulator-5554` → `frame N (320x640, ...B)`.

### 18.4 Verified end state

```
$ gh codespace ports -c zany-space-carnival-p79jxxwgj4wvfr95j
  8091  public   https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev
$ curl https://<cs>-8091.app.github.dev/status
  {"device": "emulator-5554", "fps": 1.3, "frames": 130}   # HTTP 200, no auth
```

**This is the URL the user should open:**

```
https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/
```

It is on `app.github.dev` (which their browser resolves) and is **Public** (so no
GitHub sign-in is needed).

### 18.5 If the port vanishes again

1. `gh codespace ports -c "$CS"` — is 8091 listed at all?
2. Not listed → the viewer is not bound, or the agent did not scan it. Restart the
   VS Code server / reload the window so the port is re-detected, then re-run
   `bash /workspaces/ensure-up.sh` and `bash /workspaces/ensure-public.sh 8091`.
3. Listed but `private` → `bash /workspaces/ensure-public.sh 8091`.
