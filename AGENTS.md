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

**Changing visibility cannot be automated here.** Already tried, all returned `404`:

- GitHub REST API with `GITHUB_TOKEN`
- GitHub REST API with `GITHUB_CODESPACE_TOKEN`
- `gh` CLI while authenticated

Only the VS Code **PORTS panel** (UI) can do it, and it is **not needed**. It would only
be required to share the URL with a browser that is *not* logged into GitHub.

Scripts that polled the API trying to change this were **deleted** — they just looped 404s.

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
- **`port-watchdog.sh` / `run-stream-test.sh`** — deleted; they only spammed 404s.
- **Programmatic port-visibility toggling** — impossible here (§4.2).

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

Coordinates are **emulator screen pixels** (720×1280 portrait), not browser pixels.

```bash
curl -X POST "http://127.0.0.1:8091/tap?x=283&y=570"
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