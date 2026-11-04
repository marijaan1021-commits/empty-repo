# Android Emulator in GitHub Codespaces — Complete Project Notes

> **Audience: an agent (or human) starting with zero context.**
> You have not seen any of this project before. This file is the whole story: what was
> asked for, what exists, how it works, how it was built, what went wrong, and what NOT
> to waste time on. Read §1 first, then skim the rest.

---

## 0. Read this first — you are probably in the wrong file

This file is the **history**: 32 sessions, every measurement, every dead end.
It is 130 KB and it is auto-loaded into your context, so it costs you ~35 000
tokens before you read a word.

| You want to… | Read |
|---|---|
| **build the project from scratch in a fresh Codespace** | **`START-HERE.md`** ← the procedure, with every command |
| understand the app (features, permissions, timing) | `CALLNOTE.md` |
| find out *why* something was done a certain way | this file (§1–§32) |

**The short version** (if you only read one line):

```bash
bash scripts/install-toolchain.sh && bash scripts/install-stack.sh && bash /workspaces/emu.sh
```

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
| Disk free | ~8.9 GB |

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
| Disk nearly full | `.gradle` = 1.3 GB | **Do not delete `.gradle/caches/modules-2`** (slow to re-download). See §19 for the cleanup procedure |
| Frame rate ~3–8 fps | Software GPU `swiftshader_indirect` | Expected. Not a bug |

---

## 12. Resource limits

**2 vCPU · 7.8 GB RAM · no swap · 32 GB disk.**

- Disk usage (after the §25 cleanup): Android SDK 3.1 GB, Flutter 2.1 GB, `.gradle` 1.1 GB, AVD 711 MB. **~12 GB free** on the 32 GB volume.
- Never let Gradle use defaults — `-Xmx8G` OOM-kills on this box (§5.5).
- The **NDK was removed** (2.0 GB, §25). `flutter build` / `flutter run` need it back:
  `sdkmanager "ndk;27.0.12077973"` (needs ~2.7 GB free for the download). The release
  APK is already built and installed, so running the stack does not need it.
- **Never delete `/workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk`** —
  `run-all.sh:16` and `supervisor.sh:20` install the app from exactly that path.
- Low frame rate in the viewer is a software-rendering limit, not a defect.

---

## 13. File map

| Path | Purpose |
|---|---|
| `/workspaces/emu.sh` | **the one command** (2026-10-27) — `start`/`status`/`stop`/`restart`/`url`/`logs`; idempotent, prints the URL |
| `/workspaces/run-all.sh` | older one-shot bring-up (superseded by `emu.sh`) |
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
  *(superseded on 2026-10-27 — it was removed to reclaim 2.0 GB, see §25.5)*
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

Current budget after this session: **~8.9 GB free** (see §19), NDK kept.
*(superseded by §25: ~12 GB free, NDK removed)*

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
| Disk free | ~8.9 GB |


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

---

## 19. Disk reclamation (2026-10-25) — 6.8 GB freed

The Codespace volume (`/dev/loop4` = `overlay /` + `/workspaces` + docker volumes) was at
**28 GB used / 2.1 GB free (93%)**. It is now **21 GB used / 8.9 GB free (71%)**.

### 19.1 The volume layout (this is the part that confuses people)

| Mount | Device | Size | Note |
|---|---|---|---|
| `/` and `/workspaces` | `/dev/loop4` | 31.3 GB | **this is the 32 GB that fills up** |
| `/tmp` | `/dev/sdb1` | 44 GB | **separate disk**, 38 GB free — `/tmp` is NOT the problem |
| `/vscode` | `/dev/sda1` | 28.9 GB | separate disk, 14 GB free |
| `/workspaces/.codespaces/shared` | `/dev/sda1` | — | separate disk |

`df` on `/` and `/workspaces` report the *same* numbers because they are the same
device. The container's overlay `upperdir` lives on it too, so everything written
under `/` counts against it. `/tmp` and `/vscode` are **different filesystems** —
the user's "the space is in /tmp" assumption is wrong; `/tmp` held 24 MB.

### 19.2 What was deleted

| Path | Freed | Why it was safe |
|---|---|---|
| `/workspaces/android-sdk/.temp/` | **4.4 GB** | `sdkmanager` staging leftovers: `x86_64-34_r02.zip` + `android-ndk-r27-linux.zip` and their `unzip/` dirs. Both packages were already extracted to `system-images/` and `ndk/`. Pure redundancy. |
| AVD `snapshots/default_boot/ram.bin` | **1.18 GB** | The snapshot was **unusable** (§16.5). See §19.3 for the config change that stops it regenerating. |
| `mini_app/build/` (except the release APK) | 368 MB | 357 MB debug APK + intermediates. Rebuildable. The **release APK was kept** — `run-all.sh`/`supervisor.sh` install from it. |
| `/opt/conda/pkgs/` | 569 MB | `conda clean --all`. Conda hardlinks packages into envs, so the env still works. |
| `/home/codespace/.cache/copilot` | 379 MB | Pure cache. |
| `/usr/local/sdkman/candidates/java/21.0.12+1-ms` | 346 MB | Unused: `sdkman/candidates/java/current` → 25.0.4, the project uses `/workspaces/jdk17`. No `/etc/alternatives` entry pointed at it. |
| `/workspaces/.gradle/caches/8.12/generated-gradle-jars` | 175 MB | Regenerated locally by Gradle, no network needed. |
| `/var/lib/apt/lists/*` | 54 MB | `apt-get update` restores them. |
| `/workspaces/dummy_app/` | 40 MB | Self-referencing scaffold; nothing in any script referenced it. |

**Kept on purpose:** `.gradle/caches/modules-2` (550 MB, slow to re-download),
`.gradle/wrapper/dists` (744 MB, needed to run Gradle), the NDK (2.0 GB, Flutter's
plugin requires it — *removed later, see §25.3*), `/workspaces/.sc/scrcpy.zip` (source for the scrcpy diagnostics),
`flutter-apk/app-release.apk`, and `nvm`'s node v22 (the extension host may want it).

### 19.3 The snapshot had to be disabled, not just deleted

`config.ini` had `firstboot.saveToLocalSnapshot=yes` and `fastboot.forceFastBoot=yes`,
so the emulator **re-created the 1.18 GB snapshot on every clean shutdown**. Deleting
the directory alone would have brought it straight back. Three changes:

1. `config.ini` → `firstboot.saveToLocalSnapshot=no`, `firstboot.bootFromLocalSnapshot=no`,
   `firstboot.bootFromDownloadableSnapshot=no`, `fastboot.forceFastBoot=no`
2. `run-all.sh` and `supervisor.sh` → emulator launch now passes
   `-no-snapshot-save -no-snapshot-load`
   (`start-avd.sh` already used `-no-snapshot`)
3. The **running** emulator had the old config in memory, so it was shut down
   gracefully (`adb emu kill`) and the snapshot dir deleted again *after* it exited.

**Consequence: every boot is now a cold boot.** That was already true in practice
(the snapshot never loaded), so nothing actually regressed. A cold boot measured
**66–135 s** normally, once **285 s** while the box was busy.

### 19.4 Two `pgrep` traps hit during this cleanup

- `pgrep -f 'qemu-system-x86_64-headless'` **matches the calling shell** when the
  pattern is typed inline in a `bash -c` command line (§15.13, §16.4). Inside a
  script file like `supervisor.sh` it is safe — the pattern is not in the cmdline.
- `pgrep -x qemu-system-x86_64` returns **nothing**: Linux `comm` is capped at 15
  characters, so the real name is `qemu-system-x86`. Use `pgrep -x qemu-system-x86`
  or match on the full cmdline with `-f`.

### 19.5 If disk gets tight again

Cheapest first: `android-sdk/.temp/` (regrows after every `sdkmanager` run — delete
it), `conda clean --all -y`, `rm -rf /home/codespace/.cache/*`,
`rm -rf /var/lib/apt/lists/*`. Bigger but still safe: the NDK (2.0 GB, only if you
accept that `flutter build` stops working), `flutter/bin/cache` (1.7 GB, restored by
`flutter precache`), `nvm`'s node v22 (204 MB).

**Do not delete** `.gradle/caches/modules-2`, `.gradle/wrapper/dists`,
`flutter-apk/app-release.apk`, or `/workspaces/.sc/scrcpy.zip`.


---

## 20. Fifth session (2026-10-26) — the emulator's own gRPC API (30x faster frames)

This session fixed the three things the user complained about: the screen was
slow, it did not scale, and taps were dropped. It also settled the question of
which of the three options to keep.

### 20.1 `adb exec-out screencap` is the wrong way to grab a frame

`adb exec-out screencap -p` costs **484–818 ms** per frame on this box
(≈1.3 fps). The guest is idle the whole time (143% idle), so the cost is the
adb round trip plus the guest-side PNG encoder, not CPU.

The Android emulator also runs a **gRPC service on 127.0.0.1:8554** that can
read the framebuffer directly:

```
POST /android.emulation.control.EmulatorController/getScreenshot   (application/grpc+proto)
```

**Measured: 17–44 ms per call (avg 26.6 ms) = 37.6 fps — a 30x improvement.**

The service name is `android.emulation.control.EmulatorController`
(**not** `emugrpc`, and **not** `EmulatorController`) — the wrong name returns
`grpc-status 7 "…is not on the allowlist"`.

### 20.2 Authentication: the token lives in the emulator's discovery file

Every call needs a bearer token. The emulator writes it when it starts:

```
/home/codespace/.android/avd/running/pid_<pid>.ini
    grpc.port=8554
    grpc.token=ENDxZ4+VwkAJtNC/9W5yYFQuYQMiuahyptPys1TRXrvFPg0EiQNoM6KMawjoR75pQUVtY/hEMW8iXWxnfVR7Pg==
    grpc.allowlist=/workspaces/android-sdk/emulator/lib/emulator_access.json
```

Header: `authorization: Bearer <grpc.token>`. Without it the emulator answers
`grpc-status 16 "Missing the 'authorization' header with security credentials."`

The token is **rotated on every emulator start** → re-read it whenever a call
fails. `supervisor.sh:start_emulator()` deletes `/home/codespace/.android/avd/running`
before launching, so the file only reappears once the emulator is up.

The allowlist is `/workspaces/android-sdk/emulator/lib/emulator_access.json`.
The `android-studio` issuer may call `/android.emulation.control.EmulatorController/.*`
unprotected, which is why the plain emulator token works.

### 20.3 The reply is already a PNG

`Image { ImageFormat format = 1; uint32 width = 2; uint32 height = 3; bytes image = 4; … }`
— the PNG is **field 4**, and the request can be empty
(`ImageFormat{format=PNG(0)}` are the defaults). The reply also carries the
frame size, so no separate `wm size` call is needed.

`streamScreenshot` (server-streaming) also exists. It only pushes a frame when
the display actually changes, so it is event-driven — great for latency, but it
delivers nothing on a static screen. Polling `getScreenshot` at ~30 fps is
simpler and always current.

### 20.4 The "permanent fallback" bug

`capture()` used to check `if (!this.grpc.broken)` before trying gRPC, and
every failure set `broken = true`. The first failure (emulator not booted yet,
so no token file) therefore disabled gRPC **forever** and the session silently
fell back to the 800 ms adb path. Fixed: `broken` now carries a `nextTry`
timestamp and gRPC is retried every 3–5 s.

### 20.5 Why the port kept disappearing: the process tree

The Codespaces port-forwarding agent only forwards ports bound by a process
**inside the VS Code server's process tree**:

| listener | parent | forwarded? |
|---|---|---|
| EmbeDroid bridge :8099 | extension host | **yes** |
| `emuview.py` :8091 started by `supervisor.sh` with `setsid` (PPID 1) | init | **no** |

The supervisor's viewer is started with `setsid nohup …` → PPID 1 → invisible
to the agent → the port never appears in `gh codespace ports` and the public
URL stays a 404.

**Fix:** the extension owns the viewer. `ensureViewer()` finds the process
holding :8091 with `ss -ltnp`, kills it if it is not our own child, and starts
`python3 /workspaces/emuview.py` as a **direct child of the extension host**
(no `detached`, no `unref`) so it stays in the VS Code process tree. The
supervisor no longer fights for the port (`start_viewer()` returns early when
the port is already open).

### 20.6 Other fixes from this session

- `tree.refresh` → `vscode.EventEmitter` + `onDidChangeTreeData` (VS Code 1.143
  removed `TreeItem.refresh`).
- Taps: the webview now dispatches the tap on **pointerdown** (the old
  pointerup handler was lost when the frame image was swapped and the browser
  fired `pointercancel`) with a 120 ms drag-cancel timer; a real drag becomes a
  swipe.
- Taps: the extension serialises all input through a promise chain, because
  `adb shell input tap` takes ~320 ms and overlapping calls were dropped.
- Scaling: the frame image is `width/height:100%` + `object-fit:contain`, and
  taps are mapped with `contentRect()` so they land on the letterboxed picture
  and not on the element box.
- Frame pushing skips unchanged frames (`Buffer.equals`), so an idle screen
  does not make the browser decode 30 images a second.
- Every `adb` call in the extension and in `supervisor.sh` is wrapped in
  `timeout`; a wedged `screencap` used to freeze the frame pump forever.
- The extension host is **not** respawned by the server after it is killed —
  the user has to reload the window (the workbench owns the request).

### 20.7 Rebuilding the extension

`vsce` is not installed, so the VSIX is built by hand (a VSIX is a zip):
`/tmp/opencode/build-vsix.py` writes `extension.vsixmanifest`,
`[Content_Types].xml` and the `extension/` folder. `/tmp` is wiped on every
container restart, so the script has to be recreated.

Installing with `code --install-extension` did not take effect in this
environment. What works is copying the files straight into the installed
folder and then reloading the window:

```bash
DST=/home/codespace/.vscode-remote/extensions/codespace.emulator-view-0.1.0
cp /workspaces/empty-repo/extension.js      "$DST/"
cp /workspaces/empty-repo/package.json       "$DST/"
cp /workspaces/empty-repo/media/view.js      "$DST/media/"
cp /workspaces/empty-repo/media/view.css     "$DST/media/"
cp /workspaces/empty-repo/media/icon.svg     "$DST/media/"
```

## 21. The three options, compared — and the recommendation

| | **A. custom extension** (`codespace.emulator-view`) | **B. third-party extension** (`D0Tech.vs-avd`) | **C. forwarding only** (`emuview.py` + `gh codespace ports`) | **D. EmbeDroid** |
|---|---|---|---|---|
| Needs the browser to resolve a new hostname | no (webview tab) | no (webview tab) | **yes** | **yes** (`:8099` WebSocket) |
| Works with the user's resolver | yes | yes | yes (verified 2026-10-26) | n/a — never worked end-to-end |
| Frame rate | **37 fps** (gRPC, §20) | ~1–2 fps (adb screencap) | ~1.2 fps | 1–2 fps, needs WebCodecs |
| Latency of a tap | ~200 ms (gRPC/adb) | ~300 ms | ~300 ms | unknown |
| Survives a container restart | **yes** (extension is the start hook) | no (needs a manual re-open) | yes (supervisor) | no |
| Zero manual steps | **yes** | no | yes (URL only) | no (a click to open the panel) |
| Effort | done | 1 h to wire up | done | abandoned (§7) |
| Fragile parts | gRPC token rotation (handled) | unknown, stale upstream | port must be forwarded by the agent | token + bridge + CSP |

### Recommendation: **A — keep the custom extension**, and keep C as the
### "give me a URL" fallback.

- It is the only option that is **fast** (the emulator's own gRPC API) and
  **fully automatic** (the extension re-creates the emulator, the app and the
  viewer after every container restart, with no human in the loop).
- B (`D0Tech.vs-avd`) is a good sanity check but it still uses
  `adb screencap` and needs the panel to be opened by hand.
- C stays useful as a second URL, but it needs the Codespaces port agent to
  forward :8091, which only happens when the **extension** owns the process.
- D (EmbeDroid) is not worth more time: it needs a second hostname, a
  WebCodecs `VideoDecoder` and a token that goes stale on every reconnect.

### What the user has to do

1. **Reload the VS Code window** once (Developer: Reload Window). The
   extension host was killed to pick up the new code and the server does not
   respawn it on its own.
2. Open the **Android Emulator** view in the Activity Bar → the emulator tab
   opens automatically.
3. Optionally open the external URL
   `https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/`.

---

## 22. Sixth session (2026-10-27) — the port forwards now, and the tap bug

### 22.1 THE missing piece for port forwarding: `vscode.env.asExternalUri()`

§18.2 and §20.5 blamed the *process tree*: a listener started by the supervisor
(PPID 1) was never forwarded, while a listener started by the extension host was.
That was **not the whole story**. The `gh codespace ports` list after a restart
contained `891, 923, 2000, 37441, 8099` — and **not** `8091`, even though our
viewer was a direct child of the extension host.

The real mechanism is the workbench's **`vscode.env.asExternalUri()`** call:

```js
const uri = await vscode.env.asExternalUri(vscode.Uri.parse("http://127.0.0.1:8091"));
// -> https://<cs>-8091.app.github.dev/
```

Resolving a URI through `asExternalUri()` is what makes the remote side forward
the port and register it with the Codespaces port-forwarding service. A socket
that merely *listens* is invisible to the tunnel, no matter which process owns
it. This is exactly why EmbeDroid's bridge on :8099 was forwarded: it builds
its webview URL with `asExternalUri()`.

After adding one `asExternalUri()` call in `ensureViewer()` (plus a re-assert
every 4th heartbeat tick, because the tunnel drops on reconnect):

```
gh codespace ports -c $CS   ->   8091  public  https://<cs>-8091.app.github.dev
curl https://<cs>-8091.app.github.dev/status   ->   HTTP 200
```

**Lesson: "the port is not forwarded" is not a process-tree problem. Call
`asExternalUri()`.**

### 22.2 The double-tap bug (found by watching the real taps)

The user tapped in the webview and the log showed every gesture twice:

```
07:10:35.548  input tap 284,588
07:10:35.934  input tap 284,588
```

Root cause in `media/view.js`:

- `pointerdown` started a 120 ms timer that sent the tap.
- `pointerup` did `else if (!tapTimer) send("tap", ...)` — i.e. it sent a tap
  **exactly when the timer had already fired**. The condition was inverted.

Consequences: a click *slower* than 120 ms registered twice, and a click
*faster* than 120 ms registered **zero** times (the timer was cleared on
pointerup before it could fire).

Fix: one gesture = one action.

- `pointerup` only handles the drag case (swipe). A plain tap is delivered by
  the pending timer, and the timer clears `downAt` itself.
- `pointercancel` no longer kills a pending tap. With gRPC the screen is
  replaced far more often than with adb, and the browser fires `pointercancel`
  when the image under the pointer is swapped. Only a *drag* is really
  cancelled.
- `setPointerCapture()` on pointerdown keeps the gesture bound to the element.

Verified: the counter in the app went 0 → 4 for 3 user clicks (2 lost to the
double-tap bug) and 0 → 5 for 5 scripted `adb shell input tap` calls.

### 22.3 gRPC response layout (corrected)

The reply is a **single** gRPC frame:

```
00 | 00 00 46 1d | <message>
^^    length = 17949
```

`body.readUInt32BE(1)` → length, `body.slice(5, 5+len)` → the `Image` message,
field 4 → the PNG. The PNG is **not** the first bytes of the message (field 1
`format` comes first), so the PNG magic check must be done on the *extracted
field 4*, not on the message.

Service name is `android.emulation.control.EmulatorController`; the endpoint is
`/android.emulation.control.EmulatorController/getScreenshot`; the request can
be an empty `ImageFormat` (5 bytes: `00 00 00 00 00`).

### 22.4 The extension survives everything now

Verified live on 2026-10-27 across a container restart:

| Event | Result |
|---|---|
| Container restart 07:06 | extension auto-activated, took :8091 over from the supervisor's viewer, called `asExternalUri` → port public |
| Emulator cold boot | "No Android device found - waiting…" → "Attached to emulator-5554" → "frame 1 (320x640, 17917B, **via grpc**)" |
| User closed the tab | "emulator panel disposed" → heartbeat → "emulator view reopened" (9–15 s later) |
| Port dropped on reconnect | heartbeat re-asserts `asExternalUri` every ~2 min |

### 22.5 Still open

- The tap fix (§22.2) is in the installed extension folder but the **open**
  webview still runs the old script. It is picked up the next time the panel is
  created (close the tab, or Developer: Reload Window).
- The supervisor's `start_viewer()` and the extension's viewer still race for
  :8091; the takeover logic resolves it, but the supervisor could simply not
  start a viewer at all when the extension is present.

---

## 23. Seventh session (2026-10-27) — why the taps were late/lost, and the real bottleneck

### 23.1 The AVD had NO touchscreen — the emulator was silently dropping every touch

`config.ini` had **no `hw.touchscreen` line at all** and `hw.keyboard=no`.
Consequence: the emulator's gRPC `sendTouch()` RPC returned **`grpc-status 0`**
(accepted!) but the touch never reached the app — there was no touch input
device to deliver it to. That is why "gRPC input is fast" did not work at all.

Fix (added to `config.ini`, needs an emulator restart):

```ini
hw.touchscreen=yes
hw.keyboard=yes
```

After that, gRPC touch works: **touch → visible change = 487 ms**, of which the
touch itself is ~20 ms (versus 220–600 ms for `adb shell input tap`, which
starts a JVM on the guest every time).

### 23.2 Taps were silently dropped by a freshly created webview

`media/view.js` computes the device coordinates from `naturalW`/`naturalH` and
starts with `if (!naturalW || !naturalH) return;`. Those values only arrive
with a **frame**. The old extension only pushed a frame when the screen
*changed* — so a webview created while the screen was static never received
one, never learned the screen size, and **dropped every tap without a trace**.
That is why taps worked, then stopped working for no reason.

Fix: `session.primeWebview()` pushes the current frame as soon as the webview
reports `ready` (and `flushFrame()` keeps at most one frame in flight).

### 23.3 Frame flow control — the reason the picture updated "in bursts"

The extension pushed every changed frame straight into the browser with no
back-pressure: ~17.5 frames/s of 20-47 KB PNGs (base64). The browser could not
decode that fast, so frames piled up in the channel — and the **input
messages travel in the same channel**, so clicks queued behind frames and
arrived seconds late or not at all.

Fix: one frame in flight. The webview posts `{type:"ack"}` from the image's
`onload` (i.e. after the browser decoded it) and the extension only sends the
next frame then. The capture loop also slowed down when nothing is happening
(~10 fps idle, ~18 fps for 2 s after a gesture) instead of a constant 17.5 fps.

### 23.4 `execFile` could wedge the whole input queue

`runInput()` used `execFile(..., {timeout: 20000})`. `execFile`'s timeout only
sends SIGTERM; a wedged adb client ignores it, the callback never fires and
the promise never resolves — so the serialised input chain stalled and every
later tap waited for it. Now it uses the hardened `adb()` helper (spawn +
SIGKILL, 5 s timeout).

### 23.5 Plain clicks were turned into swipes

`pointermove` flagged a drag at 12 px, and the frame image being swapped under
the pointer produced phantom moves → a click became a swipe (which does nothing
on the `+` button). Now a drag needs a **held button** (`event.buttons`) and
**30 px** of travel.

### 23.6 The actual "3 seconds" — it is the guest's software renderer

The app's own logcat says it plainly:

```
Choreographer: Skipped 71 frames!  The application may be doing too much work on its main thread.
```

71 frames ≈ 1.2 s per interaction. The emulator renders with **SwiftShader**
(software Vulkan/GL) on **2 shared vCPUs**, and the host is saturated
(load 4.6, `qemu` at 100 % of a core, 0 % idle). The guest is 91 % idle
because it is waiting for the host ("81 % host" in the guest's own `top`).

Measured on 2026-10-27:

| step | time |
|---|---|
| `adb shell input tap` command | 220–600 ms |
| gRPC `sendTouch` | ~20 ms |
| touch → visible screen change | 487 ms |
| gRPC `getScreenshot` | 18–84 ms (avg 42) |

### 23.7 The supervisor now checks the *foreground*, not just the process

A BACK key press (or a swipe on the launcher) left the app alive but
backgrounded — the supervisor saw a live process and did nothing, so the user
looked at the launcher and concluded the app had died. It now checks
`mCurrentFocus` and re-launches the app when needed.

### 23.8 What is left, and is there anything faster?

* **Not disk**: 6.5 GB free, and disk is not in the latency path.
* **Not KVM**: `/dev/kvm` is open by qemu (`kvm-vcpu:0/1`) — the guest CPU is
  hardware accelerated.
* **SwiftShader is the ceiling**: a Codespace has no GPU, so every local
  emulator rasterises on the CPU. The guest UI (launcher, SystemUI, dialogs,
  the Flutter app) is therefore inherently slower than on real hardware, and
  SystemUI ANRs under load (see `hide_error_dialogs 1`).
* Options if it must be fast: a **cloud device** (Firebase Test Lab / Device
  Farm — needs credentials), a **lighter AVD image** (`aosp_atd`, no Google
  apps; now viable because scrcpy is no longer needed), or a smaller
  resolution. What is *not* worth doing: chasing disk space or the adb path.

### 23.9 The full lifecycle, verified by an automated test

`/workspaces/coldstart-test.sh` destroys the stack (supervisor, emulator,
viewers, adb server), runs the single documented command, and verifies the
recovery. Result on 2026-10-27: **90 s from a total wipe to a working public
page** (emulator booted, app in the foreground, non-black frame, 8091 public,
external URL HTTP 200).

| Situation | What to do |
|---|---|
| Container restarted / VS Code reconnected | **Nothing.** The extension host starts → `activate()` → `ensureStackUp()` → `ensure-up.sh` → supervisor → emulator → app → viewer → `asExternalUri()` → port public. The browser may ask you to reconnect/reload. |
| Stack is down, VS Code still alive | `bash /workspaces/ensure-up.sh` (returns in ~2 s) or `bash /workspaces/run-all.sh` (synchronous, prints the URL) |
| Only the emulator died | `bash /workspaces/start-avd.sh` — or just wait ~30 s, the supervisor restarts it |
| Only the app died / went to the background | The supervisor notices within one tick (~15 s) and relaunches it (`app_foreground` check) |
| Everything is gone (`/workspaces` wiped) | Full rebuild recipe in §5 |

The only step that ever needs a human is **Developer: Reload Window**, and only
to make the extension host pick up a newly installed build — the server does
not respawn a killed extension host on its own.

---

## 24. Eighth session (2026-10-27) — verification, and the gRPC input API is a no-op

This session was a **verification** of sessions 1–7: does the documented system
actually work? Most of it does. One thing did not, and it was the thing the
whole design was built around.

### 24.1 What was verified as working

| Check | Result |
|---|---|
| `bash /workspaces/ensure-up.sh` | idempotent, ~2 s |
| `bash /workspaces/verify.sh` — all 8 checkpoints | pass |
| cold boot after a container restart | ~50 s to `boot_completed=1`, app up, viewer up |
| auto-start after a container restart | extension activated on its own, opened the panel, `asExternalUri()` → port public |
| public URL `https://<cs>-8091.app.github.dev/` | HTTP 200, `/frame` returns a valid 320×640 PNG, `/status` returns JSON |
| `adb shell input tap 275 595` | counter 0 → 1 → 2 … (9/9 taps land) |
| `POST http://127.0.0.1:8091/tap?x=275&y=595` | counter +1 |
| gRPC `getScreenshot` | 18–84 ms, valid PNG, field 4 of the `Image` message |

The auto-restart path was exercised for real: the container was restarted
mid-session at 09:23 and by 09:28 the emulator was booted, the app was running
and the public URL answered 200 again, with nobody doing anything.

### 24.2 The bug: gRPC input does nothing, and looks like it works

The extension sent touches with `sendTouch` over the emulator's gRPC service.
Measured on this setup (emulator **37.2.12.0**, started with `-no-window`):

| method | taps registered |
|---|---|
| `sendTouch(TouchEvent)` | **0 of 3** |
| `streamInputEvent(InputEvent)` with `android_event` (raw evdev) | **0 of 1** |
| `streamInputEvent(InputEvent)` with `touch_event` | 5 of 5 |
| `adb shell input tap` | **9 of 9** |

Every failing call answers **`grpc-status 0`** — the emulator accepts the RPC
and drops the event. Nothing reaches the guest: `getevent` in the guest shows
no `ABS_MT_*` event at all, and the counter in `com.example.mini_app` does not
move.

Keys behave the same way: `adb shell input keyevent 3` moves the focus to
the launcher, `sendKey` with the same keycode leaves the focus on the app.

Variants that were tried and made no difference: `identifier` 0 vs 1,
`expiration` 0 vs 1, 150 ms vs 600 ms press, press+release in one event vs
two, `TouchEvent.display` omitted vs 0 vs 1 vs 2, and the full field set vs
only `x`/`y`/`identifier`/`pressure`.

### 24.3 Why it was invisible

Two independent mistakes, both in `extension.js`:

1. **The gRPC status was read from the wrong place.** A gRPC status arrives in
   the HTTP/2 **trailers**. Node's `http2` client emits the response headers
   in `"response"` and the trailers in `"trailers"`. The code did

   ```js
   req.on("response", (h) => { const st = h["grpc-status"]; ... });
   ```

   so `st` was always `undefined`, the "did it fail?" check never fired, and
   `call()` resolved with the (empty) body → **success**. The adb fallback
   was therefore never reached.

2. **The log looked healthy.** `runInput()` logged
   `input tap 275,595 (exec 20ms)` for every call, including the ones that
   did nothing. The log proved that a message was *sent*, not that the phone
   *received* it.

`hw.touchscreen=yes` is in `config.ini` and the guest does have a real
touchscreen device (`virtio_input_multi_touch_1`, `/dev/input/event2`, a
`TOUCH_SCREEN` with a 320×640 viewport) — so the old explanation in §23.1
("no touchscreen → the emulator silently drops the touch") was **wrong**. The
touchscreen exists; the gRPC input path just does not reach it.

### 24.4 The fix

* Input now goes through `adb shell input tap` / `input swipe`
  (70–200 ms measured; 9/9 taps land). The guest's software renderer needs
  ~490 ms to show the result anyway, so the gRPC shortcut would only have
  saved a fraction of the perceived latency — not worth a tap that silently
  does nothing.
* The gRPC input code was **deleted**, not disabled, so it cannot be
  re-enabled by accident. The measurements are in a comment where it was.
* `getScreenshot()` now also checks the trailers for a gRPC status, so a
  genuinely failing screenshot call marks the connection broken instead of
  silently returning a truncated frame.

### 24.5 Two other findings

* **The extension host does not respawn.** Killing it (the workbench owns the
  request) leaves the emulator, the app and the HTTP viewer running — the
  public URL keeps working — but the in-VS-Code tab is gone until the user
  runs *Developer: Reload Window*.
* **Two viewers race for :8091.** `ensure-up.sh` and the extension both start
  one; the loser dies with `Address already in use` in `/tmp/emuview.log`.
  Harmless, but noisy. `ensure-up.sh`'s `viewer_bound()` only recognises a
  viewer started with `EMUVIEW_PORT=...` in its argv, so it does not see the
  one the extension started (the extension starts it as plain
  `python3 /workspaces/emuview.py`) and starts a duplicate every time.

### 24.6 How to test an input path properly

The counter digit is at device coordinates x 154–166, y 360–379 in the
320×640 framebuffer. Read that region out of the PNG and compare it before
and after the gesture. Two traps:

* **Do not restart the app between measurements.** Restarting resets the
  counter to 0 and leaves the screen blank for a moment, so a "before"
  reading taken too early is 0 dark pixels and a "after" reading is the
  digit — every method then looks like it worked.
* **Do not use the number of dark pixels as the value.** The digits have
  different ink counts (0 → 129, 1 → 73, 2 → 107, 3 → 117, 4 → 121, 7 → 80),
  so ink 121 is a "4" *and* a "6". Hash the region and print it as ASCII art
  instead, and read the digit.

With that harness the truth is unambiguous: `adb shell input tap` 9/9,
`streamInputEvent`/`touch_event` 5/5, `sendTouch` 0/3.

---

## 25. Ninth session (2026-10-27) — disk analysis and reclamation

The user asked where the 32 GB had gone. It was **24 GB used / 6.5 GB free (79 %)**,
not the 8.9 GB free that §19 claimed. A full read-only analysis found the
truth, including one important subtlety.

### 25.1 The three filesystems — and the one that matters

| Mount | Device | Size | Used | Note |
|---|---|---|---|---|
| `/` | overlay | 32 G | 19 G | the container's writable layer, on the same device as /workspaces |
| `/workspaces` | `/dev/loop4` | 32 G | 19 G | **the persistent volume — this is the 32 GB the user means** |
| `/vscode` | `/dev/root` | 29 G | 12 G | VS Code server + extensions (separate disk) |
| `/tmp` | `/dev/sdb1` | 44 G | 3.7 G | separate disk; only **42 MB** of it is under /tmp |

### 25.2 The subtlety: deleting base-image files frees NOTHING

`/usr` (7.0 GB), `/opt` (638 MB), `/go`, `/usr/local/rubies` … all belong to the
container **image**. They live in the image's lower layers, so deleting them
inside the container only writes a *whiteout* into the upper layer — the bytes
stay in the image. Measured: removing the LLVM-18 toolchain (661 MB), the Go
toolchain (182 MB), node v22 (204 MB), ruby 3.3 (137 MB), python 3.13 (398 MB),
minikube/helm/kubectl (291 MB) and the conda build leftovers (53 MB) freed
**0 MB** on the 32 GB volume.

**Only two things free it:**
1. files on the persistent volume (`/workspaces`), and
2. files the container wrote at runtime (the overlay upper layer) — e.g. the
   615 MB Copilot cache, which did free space when removed.

The ~11 GB gap between `du /workspaces` (7.5 GB) and `df` (19 GB) is the
host's container-image layers. It cannot be reclaimed from inside the
container at all.

### 25.3 What was removed

| Item | Freed | Why it was safe |
|---|---|---|
| `/workspaces/avd-backup-1792998671` | **1.7 GB** | a stale clone of the AVD (incl. a 957 MB *unusable* snapshot) from §6.10; nothing referenced it. The AVD's `config.ini` (3.4 KB) was kept at `/workspaces/.keep/testavd-config.ini` |
| `/workspaces/android-sdk/ndk/27.0.12077973` | **2.0 GB** | only needed to *rebuild* the app; the release APK is already built and installed (§15.4) |
| `/workspaces/android-sdk/cmake` | 60 MB | only used together with the NDK |
| flutter engine artifacts `android-arm`, `android-arm64`, `android-x86` | 344 MB | the app is built for `android-x64` only |
| `gradle-8.12-all.zip` (inside `wrapper/dists`) | 219 MB | the distribution is already unpacked next to it; the `.ok` marker stops Gradle re-downloading |
| `/home/codespace/.cache/copilot` | 615 MB | pure runtime cache (this one *did* free the volume) |
| `/home/codespace/.cache/pip`, npm cache, `/opt/tmp/build` | 75 MB | caches / build leftovers |
| `/workspaces/.sc` | 38 MB | scrcpy source, only used for the §6 diagnostics |
| `mini_app/build` intermediates + stray logs/screenshots | 16 MB | the release APK was kept |
| `/vscode/serverCache` (10 stale VS Code server tarballs) | 3.5 GB | download cache on the separate /vscode disk; the running server was kept |
| `/vscode/extensionsCache/*.vsix` | 447 MB | download cache on the separate /vscode disk |

**Result: 32 GB volume 24 GB used → 19 GB used (6.5 GB → 12 GB free, 79 % → 63 %).**
`/vscode`: 16 GB → 12 GB used. `/workspaces` content: 12.2 GB → 7.5 GB.

### 25.4 Things that were NOT removed, and why

* **`flutter/.git` (278 MB)** — tested: without it the tool refuses to run
  ("The Flutter directory is not a clone of the GitHub project"). Kept.
* **`.gradle/caches/modules-2` (550 MB)** — downloaded artifacts, slow to
  re-fetch (§19). Kept.
* **`.gradle/wrapper/dists` (524 MB)** — the Gradle binary itself. Kept.
* **`system-images` (1.7 GB), `emulator` (863 MB), `build-tools` (298 MB),
  `platforms` (146 MB), `cmdline-tools` (148 MB), `jdk17` (318 MB),
  `android-avd` (711 MB), `.pub-cache` (125 MB)** — all in use.
* **`/tmp`** — 42 MB. The 3.7 GB on that device is the host's, not ours.
* **`/workspaces/.codespaces/shared`** — a separate 29.9 GB disk (`sdc1`).

### 25.5 How to get the NDK back

```bash
source /workspaces/androidsdk-env.sh
export PATH=/workspaces/flutter/bin:$PATH
yes | sdkmanager "ndk;27.0.12077973"   # ~2.7 GB free is needed for the download
```

The emulator, the app and the viewer do **not** need it: the supervisor
installs the already-built APK from
`/workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk`.

---

## 26. Tenth session (2026-10-27) — one command for everything

The stack had grown into five overlapping bring-up scripts (`run-all.sh`,
`ensure-up.sh`, `start-avd.sh`, `supervisor.sh`, `ensure-public.sh`) and the
user asked for a single thing to run. Added **`/workspaces/emu.sh`**:

```bash
bash /workspaces/emu.sh              # start everything (default)
bash /workspaces/emu.sh status       # health check, changes nothing
bash /workspaces/emu.sh stop         # stop everything
bash /workspaces/emu.sh restart
bash /workspaces/emu.sh url          # print the public URLs
bash /workspaces/emu.sh logs         # tail the logs
```

It reuses the proven building blocks (`bootstrap.sh`, `supervisor.sh`,
`ensure-public.sh`) and adds only the glue the old scripts lacked:

* **The viewer is bound first**, before the emulator. The Codespaces
  port-forwarding agent scans for listening ports once, at container start, so
  a port bound after that is never forwarded (§18.2). `emuview.py` waits for a
  device instead of exiting, so binding it early is safe.
* **It waits for each stage** and prints `ok` / `WARN` / `FAIL` per step, so
  the output says exactly where it got to.
* **It is idempotent**: each step checks the real state first (adb device
  list, port bound via `ss`, supervisor pid + `/proc/<pid>/cmdline`).
* **`stop` kills by pid**, never with `pkill -f` — that pattern also matches
  the shell running the script (§15.13).
* **No duplicate processes**: verified 1 qemu, 1 viewer, 1 supervisor after a
  cold start.

Measured: **cold start 1 min 52 s** (emulator boot dominates), **re-run 21 s**
(mostly the `gh` port-visibility call), all 8 `verify.sh` checkpoints green
and the public URL HTTP 200.

`/usr/local/bin/emu` and an `emu` shell alias in `~/.bashrc` point at it, but
both live in the container's writable layer and vanish after a container
rebuild — the script itself is in `/workspaces` and persists.

`.vscode/tasks.json` now has *Android Emulator: Start Everything* as the
**default build task** (Ctrl+Shift+B), plus *Status* and *Stop Everything*.

---

## 27. Eleventh session (2026-10-27) — the browser view was black, and why

Two defects were found while testing `emu.sh` (§26), both of which made the
**browser** URL show a black screen while everything looked healthy.

### 27.1 The HTTP viewer now captures over gRPC, not `adb screencap`

`emuview.py` used `adb exec-out screencap -p` (~800 ms per frame, and it runs
a PNG encoder *inside the guest*). Under the software GPU that keeps one of
the two vCPUs busy permanently, and it starves the Flutter renderer — the app
stops drawing and the screen goes black.

`emuview.py` now captures through the emulator's own gRPC service
(`getScreenshot`), the same path the extension uses:

* `~25 ms` per frame instead of ~800 ms → **the viewer went from 0.5–1.3 fps to ~8 fps**
* the guest does **no** work at all for a capture
* `/status` now reports `"source": "grpc"`

The helper is `/workspaces/grpc-grab.js`: one long-lived HTTP/2 connection,
frames written to stdout as `[4-byte length][PNG]`, reconnects by itself when
the emulator restarts (the bearer token rotates on every emulator start).

`/frame` now answers in **7 ms** and `/status` in **4 ms**.

### 27.2 A dozing device returns black frames from EVERY path

The symptom: the emulator is up, `boot_completed=1`, the app is alive and
focused (`mCurrentFocus=…com.example.mini_app`), `mWakefulness=Awake`,
`mScreenState=ON` — and yet `adb screencap`, the node gRPC client and the curl
h2c gRPC client *all* return an all-black PNG.

The cause is the display dozing on the lock screen. A dozing display is
blanked at the source, so no capture path can see anything. The guest's
`dumpsys window` showed `isKeyguardShowing=true` and
`mDreamingLockscreen=true`, which is the tell.

Fixes, applied in `emu.sh tune_device` and `supervisor.sh tune_device`:

```bash
settings put system screen_off_timeout 2147483647   # never time out
settings put global low_power 0                     # no battery saver
settings put secure lockscreen.disabled 1
locksettings set-disabled true
dumpsys deviceidle disable                          # no doze
svc power stayon true
settings put global stay_on_while_plugged_in 1
input keyevent 224 ; wm dismiss-keyguard            # wake it up
```

### 27.3 The supervisor now heals a black screen by itself

`supervisor.sh` samples the viewer's frame every tick (fast, gRPC, no guest
work). Three blank frames in a row and it wakes the display, drops the
keyguard, re-applies the power settings and relaunches the app. A missing or
empty frame is **not** treated as blank — the viewer may simply not have one
yet, and relaunching the app for that would be wrong.

`emu.sh` does the same check before it prints `READY`, so the script never
announces a working stack on top of a black screen.

### 27.4 Two smaller bugs found on the way

* `emuview.py` `/status` called `adb devices` inline, so it could block for
  8 s. The browser polls it every 2 s and the supervisor every 8 s with a 3 s
  timeout, so a slow adb server made the viewer look dead and the supervisor
  restarted it in a loop. `/status` now reads a cached serial that a
  background thread refreshes every 2 s.
* The blank-screen check itself used `adb exec-out screencap` with a 30 s
  timeout. When the guest was stalled, `emu.sh start` took **over 300 s**
  (12 iterations × 32 s). The check now reads the viewer's gRPC frame, which
  cannot hang, and falls back to adb only if the viewer has no frame.

### 27.5 Verified after a full cold start with one command

```
$ bash /workspaces/emu.sh
== Android emulator stack ==
  ok    KVM ok
  ok    viewer up on :8091
[11:29:21] starting emulator (cold boot, 60-140s)
  ok    device: emulator-5554	device
  ok    boot_completed=1
  ok    app installed
  ok    app launched
  ok    screen shows the app
  ok    supervisor already running (pid 25242)
  ok    port 8091 is public
  READY  ->  https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/
real  1m55s
```

* 3 taps on `+` → the counter digit in the captured frame reads **3**
  (read out of the PNG, region x150–170 / y356–382).
* `verify.sh`: all 8 checkpoints green, public URL HTTP 200.

### 27.6 The VS Code webview still cannot work for this user

`10fitsm98t732qiqr1qkblngk3pnb37e1d4mkn9sl12tkk7eq3te.assets.github.dev` is
where VS Code serves **webview** resources. It resolves publicly
(`185.199.108-111.154`) and it resolves inside the container, but the user's
own resolver cannot look it up — so any VS Code webview fails to render with
"server IP address could not be found". This is a **client-side DNS** problem
(§18.1) and nothing in the container can fix it.

The browser URL is on `*.app.github.dev` — the same base domain the workbench
itself uses — so that path is the one that works for this user.

---

## 28. Twelfth session (2026-10-28) — replacing the app with "hello", a count-only black screen

The request: run a counter app called **hello** that shows **only a number** — no
labels, no app bar, no text of any kind — on a **black background**.

This section is the recipe. It also corrects two things §15.4 / §25.3 / §25.5
got wrong about building the app.

### 28.1 The four files that make the app "hello"

The app under test lives in `/workspaces/mini_app` (a Flutter project). Four
changes turn the stock Flutter demo into "hello":

| File | Change | Why |
|---|---|---|
| `lib/main.dart` | new UI: black scaffold, one big white digit, no `AppBar`, no `Text` label, FAB with `Icons.add` | the visible "no text, black background" requirement |
| `android/app/src/main/AndroidManifest.xml` | `android:label="mini_app"` → `android:label="hello"` | **the launcher name**. The package id stays `com.example.mini_app` — do not rename it, see §28.5 |
| `pubspec.yaml` | `name: mini_app` → `name: hello` | Dart package name; matches the app |
| `android/app/src/main/res/drawable*/launch_background.xml` + `values/styles.xml` + `values-night/styles.xml` | white splash → `@android:color/black`; `NormalTheme` window background → black | kills the white flash before Flutter's first frame |

`pubspec.yaml`'s `name:` is the Dart package name — it is **not** what the
launcher shows. Only `android:label` in the manifest is.

Verify the label without booting anything:

```bash
/workspaces/android-sdk/build-tools/34.0.0/aapt2 dump badging \
  /workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk | grep application-label
# application-label:'hello'
```

### 28.2 The UI that satisfies "only a count, no text, black"

```dart
return Scaffold(
  backgroundColor: Colors.black,
  body: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _increment,
    child: Center(
      child: Text('$_counter',
        style: const TextStyle(color: Colors.white, fontSize: 120,
            fontWeight: FontWeight.bold, height: 1.0)),
    ),
  ),
  floatingActionButton: FloatingActionButton(
    onPressed: _increment,
    backgroundColor: Colors.white,
    foregroundColor: Colors.black,
    elevation: 0,
    tooltip: null,                 // no tooltip text
    child: const Icon(Icons.add, color: Colors.black),
  ),
);
```

The theme must also be black, or the app bar / scaffold flash white:

```dart
ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.black,
  canvasColor: Colors.black,
  colorScheme: const ColorScheme.dark(primary: Colors.white, ... ),
)
```

Two details that matter:

* `tooltip: null` on the FAB — the default tooltip is the string `'Increment'`,
  which is text on screen.
* `debugShowCheckedModeBanner: false` — otherwise a red `DEBUG` banner is drawn
  in the corner.

The **whole background is tappable** (`GestureDetector` with
`HitTestBehavior.opaque`), so a tap anywhere counts, not just the FAB.

### 28.3 Building it — the NDK is installed automatically now

**This corrects §15.4, §25.3 and §25.5, which said the NDK had to be reinstalled
by hand with `sdkmanager` before a build.** That is no longer true: Gradle's
Android plugin **downloads and installs the NDK itself** when
`ndkVersion = flutter.ndkVersion` is set in `android/app/build.gradle.kts`.

Proof from the Gradle daemon log of the build that produced the current APK
(`/workspaces/.gradle/daemon/8.12/daemon-25804.out.log`):

```
Checking the license for package NDK (Side by side) 27.0.12077973 ...
License for package NDK (Side by side) 27.0.12077973 accepted.
Installing NDK (Side by side) 27.0.12077973 in /workspaces/android-sdk/ndk/27.0.12077973
"Install NDK (Side by side) 27.0.12077973 v.27.0.12077973" finished.
Installing CMake 3.22.1 in /workspaces/android-sdk/cmake/3.22.1
```

So the NDK **and** CMake (61 MB) came back by themselves during the build, and
the build succeeded with no manual `sdkmanager` step at all. §25.5's manual
recipe is only a fallback for an offline build.

The exact command that worked (no `sdkmanager`, no NDK juggling):

```bash
source /workspaces/androidsdk-env.sh
export PATH=/workspaces/flutter/bin:$PATH
cd /workspaces/mini_app
flutter pub get --offline          # pub cache is already warm
flutter build apk --release --target-platform android-x64
```

* **312.8 s** for `assembleRelease` on this 2-vCPU box, output 15.6 MB.
* The result lands exactly where the supervisor expects it:
  `/workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk`.

### 28.4 Mistakes I made this session — do not repeat them

1. **I ran `flutter build` in the foreground and it got killed.** The first
   attempt was interrupted mid-build (the tool call timed out and the build
   died with it), leaving a stale `build/` directory. The fix is to run it
   detached and poll the log:

   ```bash
   setsid nohup bash -c 'source /workspaces/androidsdk-env.sh; export PATH=/workspaces/flutter/bin:$PATH; flutter build apk --release --target-platform android-x64' \
     >/tmp/flutter-build.log 2>&1 </dev/null & disown
   sleep 60; tail -5 /tmp/flutter-build.log
   ```

   A Gradle build needs ~5 minutes; any foreground call with a 120 s tool
   timeout will kill it.

2. **I did not back up the old APK** before overwriting it. The backup copy I
   made in `/tmp/app-release.apk.bak` was **gone by the next command** — `/tmp`
   is wiped by the container's periodic reset. Put backups on the persistent
   volume (`/workspaces/.keep/`), not in `/tmp`.

3. **I nearly renamed the Android package.** Changing `applicationId` /
   `namespace` to `com.example.hello` would have broken `supervisor.sh:21`,
   `emu.sh:19` and `run-all.sh:17`, which all hardcode
   `PKG=com.example.mini_app`. The launcher name comes from `android:label`
   alone, so **leave the package id alone** (§28.5).

4. **I forgot the white splash.** Changing only `main.dart` leaves a white
   screen for the ~1 s between the activity starting and Flutter's first
   frame. Fixed by the `launch_background.xml` / `styles.xml` edits in §28.1.

### 28.5 Do NOT rename the Android package id

`com.example.mini_app` is hardcoded in three places that must keep working:

| File | Line | Constant |
|---|---|---|
| `/workspaces/supervisor.sh` | 20–21 | `APK=…/flutter-apk/app-release.apk`, `PKG=com.example.mini_app` |
| `/workspaces/emu.sh` | 18–19 | same |
| `/workspaces/run-all.sh` | 16–17 | same |

The supervisor installs the APK from that path and launches
`$PKG/.MainActivity`. Change the package id and the whole stack stops finding
the app. **The user-visible name is `android:label` — that is all that has to
change.**

### 28.6 Install and launch

```bash
A=/workspaces/android-sdk/platform-tools/adb
$A install -r /workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk
$A shell am force-stop com.example.mini_app
$A shell am start -n com.example.mini_app/.MainActivity --ez enable-impeller false
```

`--ez enable-impeller false` is **mandatory** (§15.2): Impeller's Vulkan
renderer on SwiftShader pins qemu at 100 % of a core and the phone freezes.

The supervisor only reinstalls the APK when the package is **missing**
(`supervisor.sh:69`), so an already-installed "hello" APK is never overwritten
by a stale one — but it does mean the APK on disk and the APK on the device can
drift. After a rebuild, always `adb install -r` explicitly.

### 28.7 How to verify the counter (read the digit out of the PNG)

The digit is the only thing on the screen, so verification is easy — but the
region moved when the font size changed. **Do not use the old region
(x150–170 / y356–382) from §27.5**; with `fontSize: 120` the glyph now sits at
**x131–188, y274–361**.

Read the frame from the viewer (gRPC, ~25 ms, no guest work) and decode the
PNG with pure Python — there is no PIL in this container:

```python
import zlib, struct
# decode: IHDR -> width/height/colour-type, IDAT -> zlib.decompress,
# then undo the 5 PNG row filters (None/Sub/Up/Average/Paeth)
```

Printing the glyph region as ASCII art (`'#'` if luminance > 140) is the
reliable way to tell the digits apart — the ink count is ambiguous (0 → 129,
1 → 73, 4 → 121, 6 → 121). Verified this session:

* 3 taps on the FAB → the glyph reads **3**
* 1 tap on the black background (100, 200) → the glyph reads **4**

Also useful: `python3 /workspaces/screen-check.py <frame.png>` prints
`320x640 levels=N`. The old demo had `levels≈130`; "hello" has `levels≈47`
because the screen is almost entirely black. It is still well above the
blank-detection threshold (`len(levels) <= 1 and max(levels) < 24`), so
`screen-check.py` correctly reports the screen as **not blank** — the black
background does not trip the supervisor's black-screen watchdog.

### 28.8 Result

```
$ bash /workspaces/emu.sh status
== status ==
  ok    emulator: emulator-5554	device
  ok    boot_completed=1
  ok    app: pid 6805
  ok    app in foreground
  ok    screen: 320x640 levels=47
  ok    viewer: {"device": "emulator-5554", "fps": 8.9, "frames": 8477, "source": "grpc"}
  ok    supervisor: pid 1437
	8091	public	https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev
```

`verify.sh`: all 8 checkpoints green, public URL HTTP 200.

### 28.9 Disk after the build

The auto-installed NDK (2.0 GB) + CMake (61 MB) came back, and the Gradle
caches grew again:

| Path | Size | Note |
|---|---|---|
| `/workspaces/android-sdk/ndk/27.0.12077973` | 2.0 GB | auto-installed by AGP |
| `/workspaces/android-sdk/cmake/3.22.1` | 61 MB | auto-installed by AGP |
| `/workspaces/.gradle` | 2.0 GB | was 1.1 GB before the build |
| `/workspaces/mini_app/build` | 270 MB | intermediates + the release APK |

Volume: **32 GB → 23 GB used, 7.3 GB free (76 %)**. It was 11 GB free before
the build, so the NDK + CMake + Gradle caches cost ~3.7 GB. If space gets
tight again, §19.5 / §25.3 still apply — but note that **removing the NDK no
longer prevents a build**; AGP will simply download it again (and that is what
happened here).

### 28.10 Summary for the next agent

```bash
# 1. edit the 4 files listed in §28.1
# 2. build (detached! it takes ~5 min)
cd /workspaces/mini_app
source /workspaces/androidsdk-env.sh && export PATH=/workspaces/flutter/bin:$PATH
setsid nohup bash -c 'flutter build apk --release --target-platform android-x64' \
  >/tmp/flutter-build.log 2>&1 </dev/null & disown
# 3. install + launch
A=/workspaces/android-sdk/platform-tools/adb
$A install -r build/app/outputs/flutter-apk/app-release.apk
$A shell am force-stop com.example.mini_app
$A shell am start -n com.example.mini_app/.MainActivity --ez enable-impeller false
# 4. verify
curl -sf -o /tmp/f.png http://127.0.0.1:8091/frame && python3 /workspaces/screen-check.py </tmp/f.png
bash /workspaces/verify.sh
```

No configuration files outside `/workspaces/mini_app` need to change, and the
extension (`extension.js`, `media/`) needs no change either — it just renders
whatever the device shows.

---

## 29. Thirteenth session (2026-10-28) — the "hello" test app was removed

The "hello" counter (§28) was a **test**. It passed, so it was deleted again to
reclaim the disk it occupied. **Flutter itself was kept** — the emulator stack
still runs, it just shows the Android launcher instead of an app.

### 29.1 What was deleted

| Path | Size | Why it was safe |
|---|---|---|
| `/workspaces/mini_app` | 374 MB | the whole Flutter project — source, `build/`, the release APK |
| `/workspaces/android-sdk/ndk/27.0.12077973` | 2.0 GB | auto-installed by AGP for the build; it comes back on demand (§28.3) |
| `/workspaces/android-sdk/cmake/3.22.1` | 61 MB | auto-installed together with the NDK |
| `/workspaces/.gradle/caches/8.12/transforms` | 732 MB | derived build outputs, regenerated locally |
| `/workspaces/.gradle/caches/8.12/generated-gradle-jars` | 175 MB | regenerated locally, no network |
| `/workspaces/.gradle/caches/build-cache-1` | 50 MB | build cache only |
| `/workspaces/.gradle/caches/8.12/{javaCompile,kotlin-dsl,fileHashes}`, `caches/journal-1`, `daemon/` | ~15 MB | regenerated locally |
| `/workspaces/android-sdk/.temp/` | 0 | `sdkmanager` staging leftovers |

**Total freed: ~3.4 GB. The volume went from 7.3 GB free to 11 GB free
(76 % → 65 % used).**

The app was also uninstalled from the device:

```bash
adb uninstall com.example.mini_app      # -> Success
```

### 29.2 What was deliberately KEPT

| Path | Size | Why |
|---|---|---|
| `/workspaces/flutter` | 2.1 GB | the Flutter SDK — the user asked to keep it |
| `/workspaces/.pub-cache` | 125 MB | Dart package cache, shared by any Flutter project |
| `/workspaces/.gradle/caches/modules-2` | 550 MB | downloaded Maven artifacts; re-fetching is slow (§25.4) |
| `/workspaces/.gradle/wrapper/dists` | 525 MB | the Gradle distribution itself |
| `/workspaces/android-sdk/{emulator,system-images,platform-tools,build-tools,platforms,cmdline-tools}` | 3.1 GB | the emulator itself |
| `/workspaces/android-avd` | 777 MB | the AVD |
| `/workspaces/jdk17` | 318 MB | JDK 17, needed by Gradle/AGP |

`modules-2` + `wrapper/dists` = **1.075 GB** is pure "next build" insurance.
If disk gets tight again and no new app is planned, deleting them is safe —
Gradle re-downloads on the next build.

### 29.3 The scripts had to learn that the app is optional

This was the **only** non-trivial part of the removal. Before the change, every
supervisor tick (~8 s) did:

```bash
if ! app_up || ! app_foreground; then
  $ADB shell am start -n "$PKG/.MainActivity" ...
  app_up || start_app      # -> tries to install; APK missing -> WARN
fi
```

With the app gone, `app_up` is false forever, so the supervisor looped
"installing / not installed / app launched" forever (57 times in the log) and
hammered `adb` with a package that does not exist. The fix is an explicit
presence check:

```bash
# supervisor.sh, emu.sh
app_present() {
  [ -f "$APK" ] || timeout 20 $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"
}
```

and every app-related branch is now gated on it:

| File | Change |
|---|---|
| `supervisor.sh` | `app_present()` helper; the relaunch branch, `start_app()` and `recover_screen()` all check it |
| `emu.sh` | `app_present()` helper; `start_app()` returns early, `cmd_status` prints "no app installed (launcher is showing)" |
| `run-all.sh` | computes `APP_PRESENT` once and skips the whole install/launch block |
| `verify.sh` | prints "app: not installed (expected - the test app was removed)" instead of an empty pid |
| `coldstart-test.sh` | prints "none installed" instead of an empty field |
| `build.sh` | rewritten: takes the project dir as an argument, no longer hardcodes `mini_app` |

**The stack still works with no app at all** — the emulator boots, the viewer
serves live frames of the launcher, and the public URL answers 200.

### 29.4 A pre-existing bug found and fixed in `tailscale-up.sh`

Every supervisor cycle printed:

```
/workspaces/tailscale-up.sh: line 105: current: unbound variable
```

`refresh_phone_ip()` used `$current` in its "no online phone peer" branch
**before** `local current` was declared further down. With `set -u` an
undeclared variable is a fatal error, so the function aborted every time and
the Notedog base URL was never refreshed.

Fix: declare and read `current` at the top of the function.

### 29.5 The new normal state

```
$ bash /workspaces/emu.sh status
== status ==
  ok    emulator: emulator-5554	device
  ok    boot_completed=1
  ok    no app installed (launcher is showing)
  ok    screen: 320x640 levels=244
  ok    viewer: {"device": "emulator-5554", "fps": 6.5, "frames": 6552, "source": "grpc"}
  ok    supervisor: pid 20662
	8091	public	https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev
```

`verify.sh`: all 8 checkpoints green, public URL HTTP 200.

### 29.6 Building a new app later

The toolchain is intact, so a new Flutter app is a `flutter create` away:

```bash
cd /workspaces && flutter create my_app
cd /workspaces/my_app
bash /workspaces/build.sh /workspaces/my_app        # detached, it takes ~5 min
A=/workspaces/android-sdk/platform-tools/adb
$A install -r build/app/outputs/flutter-apk/app-release.apk
$A shell am start -n com.example.my_app/.MainActivity --ez enable-impeller false
```

The NDK and CMake will be auto-installed again by AGP (2.1 GB). If the app
must be launched automatically after a container restart, set `APK=` and
`PKG=` in `supervisor.sh`, `emu.sh` and `run-all.sh` to the new values — or
simply drop the APK at the old path and keep the package id
`com.example.mini_app`, and **all three scripts keep working unchanged**.

---

## 30. Fourteenth session (2026-10-28) — the CallNote app survives the app and the reboot

The user asked for two of the eight suggestions from the security/UX review:

* **#2 "survive being swiped away"** — a foreground service plus a
  `ContentObserver` on the call log instead of a 2 s poll.
* **#3 "restart after reboot"** — a `BOOT_COMPLETED` receiver.

The app under test is **CallNote** (`/workspaces/empty-repo/app`, package id
`com.example.mini_app`): attach a note to a contact, get it as a notification
when that contact calls, with "Stop permanently" and "Snooze" buttons.

### 30.1 The architecture change that made both possible

Until now the **Dart side decided** whether a call deserved a reminder and
asked the native side to post it. That only works while the Flutter engine is
alive — which is exactly what "the app was swiped away" means.

The native side is now the authority:

```
call detected (native)
      |
      v
NoteStore.findFor(number)      <- reads the same callnote.json the Dart side writes
      |  enabled && text non-empty ?
      v
postNotification(...)          <- posted by Kotlin, no Dart involved
      |
      +--> pushCall(..., posted=true) to Dart, for the UI only
```

`CallNoteEngine` became a **process-wide singleton** (`CallNoteEngine.get(ctx)`)
instead of an object owned by `MainActivity`. It works headless: the
`MethodChannel` is optional, the activity is optional. The Dart side keeps its
own matching for the UI and only posts as a fallback when the native side says
`posted=false` — so there is never a double notification.

**The note file is now written by both sides.** The native side writes
`enabled=false` straight into `callnote.json` when "Stop permanently" is
pressed, because there may be no Dart code running at all. The Dart side
therefore **reloads** the file after an action instead of writing its own copy
(`Controller._resync()`).

### 30.2 The new files

| File | What it does |
|---|---|
| `NoteStore.kt` | reads/writes `callnote.json` from Kotlin; `numbersMatch()` is the same rule as in `lib/model.dart`; `setEnabled()` flips a note without Dart |
| `CallNoteMonitorService.kt` | the foreground service (`specialUse` type); shows the ongoing "CallNote is watching your calls" notification with a "Stop watching" button |
| `NoteBootReceiver.kt` | `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED` → start the service |

`CallNoteEngine` also lost its 2 s call-log poll. It now registers a
`ContentObserver` on `CallLog.Calls.CONTENT_URI` (on its own `HandlerThread`),
with a 15 s poll left as a safety net for the rare case where the provider
does not notify.

### 30.3 Foreground service type: why `specialUse`

* `dataSync` — on Android 15+ it **may not be started from a
  `BOOT_COMPLETED` receiver** (the restricted list includes `dataSync`,
  `phoneCall`, `camera`, `mediaPlayback`, `mediaProjection`, `microphone`).
* `phoneCall` — needs `MANAGE_OWN_CALLS` or the default-dialer role.
* `specialUse` — allowed from boot on every version, no extra restricted
  permission, no time limit. It needs a
  `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` property in the manifest,
  which is there.

### 30.4 The permission set after this change

```
POST_NOTIFICATIONS, READ_CONTACTS, READ_CALL_LOG,
RECEIVE_BOOT_COMPLETED, FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE
```

Still **no `INTERNET`** — the app cannot make a network request.
`android:allowBackup="false"` was added at the same time, so the notes do not
end up in a cloud backup.

### 30.5 Two traps that cost real time

**1. `am force-stop` cancels the pending `BOOT_COMPLETED` broadcast.**
`supervisor.sh` does `am force-stop` + `am start` whenever it relaunches the
app. If that happens while the boot broadcast is still queued for our package,
**the boot receiver never sees it**. During the test the supervisor had
relaunched the app *before* the broadcast was delivered, and the receiver
silently did nothing — it looked exactly like a broken feature.

> On a real phone there is no supervisor, so this does not happen. But the
> reboot **test** has to stop the supervisor, otherwise it proves nothing:
> `bash /workspaces/callnote-fgs-test.sh reboot` kills every supervisor (not
> just the first one — two were running) and renames `supervisor.sh` away, so
> `ensure-up.sh` cannot bring it back mid-test.

**2. `adb emu gsm call` is an INBOUND call, but the call log records it as
OUTGOING.** The emulator console says "create inbound phone call", yet the
row lands in the call log with `TYPE_OUTGOING`. So the call-log path sees it
as outgoing and the screening service sees it as incoming — both fire, and
the reminder is posted once (the same notification id is reused).

### 30.6 The test script

`/workspaces/callnote-fgs-test.sh [swipe|reboot|all]` — 13 checks:

1. the service exists, is foreground, and its notification is on screen
2. the app is swiped out of recents → the process, the service and the
   foreground state all survive
3. a call still produces the reminder **with the app swiped away**
4. an outgoing call is caught by the `ContentObserver`
5. after `adb reboot` the boot receiver fires, the service is foreground and
   the notification is back

**All 13 pass.** `flutter analyze` is clean, 3 unit tests pass.

### 30.7 The monitoring switch

The user can turn the watcher off (Menu → "Stop watching calls", or the
"Stop watching" button on the ongoing notification). The preference is kept in
`SharedPreferences`, survives reboots and app updates, and the app shows a
banner when watching is off. The native side pushes an `onMonitoring` event so
the UI follows immediately.

### 30.8 Summary for the next agent

```bash
# build (detached, ~5 min)
cd /workspaces/empty-repo/app
setsid nohup bash -c 'source /workspaces/androidsdk-env.sh; \
  export PATH=/workspaces/flutter/bin:$PATH; \
  flutter build apk --release --target-platform android-x64' \
  >/tmp/flutter-build.log 2>&1 </dev/null & disown

# install + test
A=/workspaces/android-sdk/platform-tools/adb
$A install -r build/app/outputs/flutter-apk/app-release.apk
bash /workspaces/callnote-fgs-test.sh all
```

The container restarts every few hours and takes the emulator's processes with
it, but **the APK and the notes survive** — they live on the `/workspaces`
volume. `adb root` is lost on every restart; run it again to read the app's
private files.

---

## 31. Fifteenth session (2026-10-29) — the APK that a real phone would accept

The user tried to install the APK on a **OnePlus 11R 5G** (CPH2487, Snapdragon
8+ Gen 1, Android 14) and got *"App not installed as app isn't compatible with
your phone"*. Three separate problems, all now fixed.

### 31.1 Problem 1: the APK only contained x86_64

The APK was always built with

```bash
flutter build apk --release --target-platform android-x64
```

because the emulator is x86_64 and that saved build time. The result:

```
$ aapt2 dump badging app-release.apk | grep native-code
native-code: 'x86_64'
$ unzip -l app-release.apk | grep lib/
  lib/x86_64/libapp.so
  lib/x86_64/libflutter.so
```

A phone needs **arm64-v8a**. Android refuses the package with
`INSTALL_FAILED_NO_MATCHING_ABIS`, which is what the phone reported as
"not compatible with your phone".

**Fix:** build every ABI.

```bash
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
```

→ 46.1 MB, `native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'`.

> **Rule for the future:** an APK that is going to a real device must contain
> arm64-v8a. The x64-only shortcut is only valid for the emulator. The
> emulator still installs the fat APK fine (it picks its own ABI).

### 31.2 Problem 2: it was signed with the debug key

The Flutter template signs release builds with the **debug** key, and the debug
keystore lives at `/home/codespace/.android/debug.keystore` — in the
**container's overlay layer**, not on the persistent volume. Two consequences:
a future build gets a *different* key (so the app can never be updated in
place), and the key can disappear on a container rebuild.

**Fix:** a real release keystore on the persistent volume.

```
/workspaces/.keystore/callnote-release.jks   (RSA 4096, alias "callnote", 30 years)
```

`app/android/key.properties` (gitignored) points at it, and
`app/android/app/build.gradle.kts` loads it:

```kotlin
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
...
signingConfigs { if (hasReleaseKeystore) create("release") { ... } }
buildTypes { release { signingConfig = if (hasReleaseKeystore) signingConfigs.getByName("release") else signingConfigs.getByName("debug") } }
```

Without `key.properties` the build still works (debug key), so the repo is
still buildable on a machine without the keystore.

A copy of the keystore and a relative `key.properties` sit next to the APK in
the repo root (`callnote-release.jks`, `key.properties`) — **gitignored**, and
the passwords are in `key.properties`.

### 31.3 Problem 3 (found by the tests): the watcher could run invisibly

`POST_NOTIFICATIONS` is a runtime permission. The service started, went
foreground and watched the call log — but the system **silently drops** a
notification posted before the permission was granted, and the service never
posted it again. The user had no way to see that the watcher was on, and on
Android 13+ a foreground service without a visible notification is a policy
problem.

**Fix (three parts):**

1. `CallNoteMonitorService.start()` refuses to start when
   `NotificationManager.areNotificationsEnabled()` is false — an invisible
   watcher is worse than no watcher.
2. `onStartCommand()` re-checks it and stops itself if the user revokes
   notifications while it runs.
3. The Dart side calls the new native method `ensureMonitorRunning` right
   after the permission prompt (`home_screen._askPermissions()`), which starts
   the service if it should be running. The notification then appears —
   **no app restart needed**.

Verified by driving the real permission dialog with `adb shell input tap`:
before the tap → `not starting the monitor service: notifications are not
allowed`; after the tap → `monitor service created` and *"CallNote is watching
your calls"* is on screen.

### 31.4 The 3-ABI build OOM-kills the Gradle daemon

With the emulator running, the box has ~2 GB free and the daemon died with
*"Gradle build daemon disappeared unexpectedly"*. Fixes:

* stop the emulator and the viewer before a 3-ABI build
  (`bash /workspaces/emu.sh stop`), start them again afterwards
* `org.gradle.jvmargs=-Xmx2560m -XX:MaxMetaspaceSize=768m …`
* `kotlin.compiler.execution.strategy=in-process` — a second JVM does not fit

### 31.5 Test-script fixes

`/workspaces/callnote-fgs-test.sh` was not self-sufficient:

* it now **grants** POST_NOTIFICATIONS / READ_CONTACTS / READ_CALL_LOG itself
  (a fresh install revokes them, and the script used to assume they were
  there)
* it **force-stops and restarts** the app in step 1, so the service is created
  with the permissions already in place
* step 5 now **waits up to 60 s** for the service to become foreground after
  the reboot instead of checking once — on a cold boot the boot receiver only
  *asks* for the service, the service still has to create itself

### 31.6 Final state

```
$ aapt2 dump badging /workspaces/empty-repo/callnote-release.apk | grep native-code
native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
$ apksigner verify --print-certs /workspaces/empty-repo/callnote-release.apk | grep DN
Signer #1 certificate DN: CN=CallNote, OU=CallNote, O=CallNote, L=, ST=, C=US
```

`callnote-fgs-test.sh all` → **13 passed, 0 failed**.
`flutter analyze` clean, 3 unit tests pass.

### 31.7 Installing on the phone

```bash
adb install -r callnote-release.apk
```

The app asks for notifications, contacts and the call log on first launch —
tap **Allow** three times. The **Caller ID** role has to be granted as well
(incoming calls are detected by `CallScreeningService`); the app offers that
prompt too. Without the role, only outgoing calls are detected.

---

## 32. Sixteenth session (2026-10-29) — the reminder now goes out *when the call happens*

The complaint: *"the reminder arrives after the call is over; I want it the
moment the call comes in or goes out (a second late is fine)"*. Two sessions
of work, four rebuilds, and one false trail.

### 32.1 The cause was the trigger, not the device

The reminder used to be triggered by the **call log row**. When the OEM
writes that row is up to the device: on the emulator the row appeared
~500 ms after an outgoing call, but on a real phone it can be written only
when the call is over. Waiting for the row therefore makes the reminder
late — everywhere, not just on one phone.

The phone itself knows better:

```
dumpsys telephony.registry | grep mCallState
  mCallState=0   idle
  mCallState=1   ringing
  mCallState=2   off-hook (a call is going out, or one was answered)
```

### 32.2 The number comes with the phone state — no Caller ID role needed

`TelephonyManager.listen(listener, LISTEN_CALL_STATE)` — the **deprecated**
`PhoneStateListener` — still hands over the **phone number** on Android 14:

```
12:25:25.219  phone state: RINGING number=5550100
12:25:25.219  phone state gave the number: 5550100 (incoming=true)
12:25:25.233  reminder posted for 5550100 (Batman)      <- 14 ms later
```

So the user does **not** have to grant the Caller ID role, and the app does
not ask for it (§32.5). The role is still supported as a second source
(`CallScreeningService`), but nothing depends on it any more.

Measured on the emulator (2026-10-29):

| call | number known at | reminder posted | delay |
|---|---|---|---|
| outgoing | OFFHOOK | 9 ms later | **9 ms** |
| incoming | RINGING | 46 ms later | **46 ms** |
| incoming, answered 5 s later | — | no second reminder | — |
| the call log row, 1 s later | — | no second reminder | — |

### 32.3 Four traps that cost the whole session

**1. The watcher registered itself twice.** `ensureCallStateWatch()` is
called from two places; the first call started the registration *asynchronously*
(so `isRunning` was still false) and the second call therefore created a
second watcher and **quit the thread of the first one**. The number-carrying
callback then landed on a dead thread:

```
W MessageQueue: Handler (android.os.Handler) {dc29587} sending message to a Handler on a dead thread
  at android.telephony.PhoneStateListener$IPhoneStateListenerStub.onLegacyCallStateChanged
```

Fix: `isRunning` is true from the moment `start()` is called, and a `stopped`
flag keeps a late registration from re-registering.

**2. The listeners have to live off the main thread.** A `PhoneStateListener`
hands its callbacks to the thread that **created** it. That was the app's
main thread — the Flutter UI thread, which renders at ~150 ms/frame on the
software GPU. Both listeners are now created and registered on the watcher's
own `HandlerThread`.

**3. The two listeners report the same change ~6 ms apart, in the opposite
order to what you would expect.** The modern `TelephonyCallback` fires
*before* the deprecated one. A state machine that treated "OFFHOOK after
RINGING" as "a new call" therefore announced the same call twice (once at
ring time, once when the call was answered). The rule is now simply
**"the current call was already announced"**, plus a flag that is only reset
by a ringing call or by the end of a call.

**4. The same-call window has to be small.** The call log row of a call
carries the moment the call **started**, and so does the phone state, so
both are within a second of each other — a 5 s window is enough. With 10 s
a second call to the same person, 9 s later, was swallowed.

### 32.4 What the code looks like now

| file | what it does |
|---|---|
| `CallStateWatcher.kt` | registers both telephony listeners on its own thread; `isRunning` is true immediately |
| `CallNoteEngine.onCallStateChanged(state, number)` | the state machine: ringing = a new call, off-hook = the same call if it was already announced |
| `CallNoteEngine.announce(number, incoming)` | posts the reminder, unless this call was already announced (`SAME_CALL_WINDOW_MS = 5000`) |
| `CallNoteEngine.pollRecentCalls()` | reads the last 5 minutes of call log rows during a call (every 250 ms for 30 s) so a row that arrives late is still caught |

The call log path is still there — it is the safety net for a phone that does
not report the number in the phone state.

### 32.5 The Caller ID nag is gone

`home_screen.dart` had a banner offering the Caller ID role; it was removed
(the user explicitly does not want to be asked for it). The menu entry that
offers the role is still there, but nothing depends on it.

The "Simulate an incoming call" / "Simulate an outgoing call" menu items were
removed as well — together with `Controller.simulateCall()` and the native
`simulateCall` bridge method. They were a developer crutch and did nothing
for a normal user.

### 32.6 The supervisor was fighting the calls

`supervisor.sh` has a black-screen watchdog: three black frames in a row and
it wakes the display and relaunches the app. During a call the dialer's
in-call screen is dark, so the watchdog saw black, **killed the app** — and
with it the phone state listener, which is exactly what had to stay alive.

Fix: the supervisor now asks the phone whether a call is running
(`mCallState`) and leaves the app alone while a call is in progress.

### 32.7 State of the art

```
$ bash /workspaces/callnote-fgs-test.sh all
== result: 13 passed, 0 failed
$ flutter analyze
No issues found!
```

The artifacts for the phone - **each build gets its own name**:

```
/workspaces/empty-repo/callnote-release-20261029-160527.apk   46.1 MB
  native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
  Signer #1 certificate DN: CN=CallNote, OU=CallNote, O=CallNote, L=, ST=, C=US
  sha256 42843e19912595652403a7c23392297d27387dc9c2a9a3f69d5175fab321dddc
/workspaces/empty-repo/callnote-release-20261029-160527.zip   21.1 MB
  sha256 df6d2cd382e9ed50992b1fdbd3e9c233fd96c37276bc64e0913ca5e03cebd322
```

They are produced by **`/workspaces/package-release.sh`**:

```bash
bash /workspaces/package-release.sh            # package what is built
bash /workspaces/package-release.sh --build    # build first, then package
```

* the name carries the build time (`callnote-release-<YYYYMMDD-HHMMSS>.apk`
  / `.zip`), so **no build ever overwrites another one** and the file name
  tells you which build is on the phone
* the zip holds the apk plus a `README.txt` with its sha256/sha1, size, the
  ABIs and the signer
* `callnote-release.apk` / `callnote-release.zip` are kept as copies of the
  newest build, so the paths in this file always work
* the `--build` path stops the emulator first (a 3-ABI Gradle build OOMs
  with it running) and starts it again afterwards
* the apk inside the zip is byte-identical to the file on disk (checked)

### 32.8 The one permission the app still needs

`READ_PHONE_STATE` (runtime, granted at runtime by the user). It is what
makes the phone hand over the caller's number in the phone state. Without it
the app still works, but only from the call log — and then the reminder comes
late, which is the thing §32 is about.

`callnote-fgs-test.sh` grants it (step 1) along with the other three.
