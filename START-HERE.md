# START HERE — rebuild this project from nothing

> **Audience:** an agent (or a human) opening this repository in a fresh
> GitHub Codespace. You have the code and this file. You have *nothing else*
> — no SDK, no emulator, no AVD, no installed extension.
>
> **This file is the procedure.** Follow it top to bottom and you end up with
> a running Android emulator, the CallNote app on it, and a live screen in the
> browser. Every command is copy-pasteable and every step has a check.
>
> Read the other two documents when you need the *why*:
> * `CALLNOTE.md` — the app: features, architecture, permissions, the timing
>   problem and how it was solved.
> * `AGENTS.md` — the full session-by-session history, measurements and every
>   dead end. 130 KB. Do not read it unless something below fails.

---

## 1. What this project is

Two things live in this repository:

| Piece | Where | What it is |
|---|---|---|
| **the emulator stack** | `scripts/` | a headless Android 14 emulator inside the Codespace, with a live view of its screen and working touch input |
| **the app under test** | `app/` | **CallNote** — attach a note to a contact, get it as a notification the instant that contact calls |

Plus a VS Code extension (`extension.js`, `media/`, `package.json`) that renders
the emulator's screen **inside a VS Code tab**.

The goal: everything runs on the phone you hold. The emulator is the
development and test rig; the release APK is built for a real device.

```
  Codespace container
  ├─ qemu (emulator)              AVD "testavd", Android 14, KVM, SwiftShader
  │    ├─ adb on emulator-5554    the app lives here
  │    └─ gRPC :8554              host-side framebuffer (fast capture, ~25 ms)
  ├─ supervisor.sh                watchdog: emulator + app + viewer + port
  ├─ emuview.py  :8091            HTTP: /frame (PNG), /tap, /swipe, /key, /status
  │    └─ grpc-grab.js            streams frames from the emulator's gRPC
  ├─ emu.sh                       the one command (start/status/stop/…)
  └─ VS Code extension host
       └─ codespace.emulator-view  renders the screen in a VS Code tab
```

---

## 2. The one-line version

```bash
bash scripts/install-toolchain.sh   # SDK + emulator + AVD + JDK 17 + Flutter  (~15 min)
bash scripts/install-stack.sh       # link this repo into /workspaces + install the extension
bash /workspaces/emu.sh             # start the emulator                     (~2 min)
```

Then open the URL it prints. Then:

```bash
bash scripts/build-callnote.sh     # build the APK  (detached! ~5 min)
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
bash /workspaces/callnote-fgs-test.sh all   # 13 checks
```

**From now on, one command:**

```bash
bash /workspaces/emu.sh
```

---

## 3. Rebuild from scratch — the full procedure

### Step 0 — what you have, and what you need to download

**In git (you already have it):** the app source, the extension, all the
scripts, the tuned AVD config (`avd/testavd.config.ini`), this file.

**Not in git (you must download or regenerate it):**

| Thing | Size | How |
|---|---|---|
| Android SDK + emulator + system image | 3.1 GB | `scripts/install-toolchain.sh` |
| Flutter SDK 3.35.1 | 2.1 GB | same script |
| JDK 17 (Temurin) | 318 MB | same script |
| Gradle caches + NDK | 3.4 GB | created by the first build |
| The AVD's userdata partition | 2.0 GB | created with the AVD |
| The **release keystore** | 4 KB | `scripts/create-keystore.sh` — **see §7** |

> The keystore is deliberately **not** in git (it is a secret). If it is
> missing, the build falls back to the **debug** key, and the APK can no
> longer be installed over an existing copy on a real phone.

### Step 1 — install the toolchain

```bash
cd /workspaces/empty-repo     # wherever you cloned this
bash scripts/install-toolchain.sh
```

What it does, and how to do it by hand if you prefer:

| Step | Command | Notes |
|---|---|---|
| host libs | `sudo apt-get install -y libx11-xcb1 libxcb1 libx11-6 libxcb-xfixes0 libxcb-shm0 libxcb-render0 libxext6 libxfixes3 libxi6 libxtst6 libnss3 libpulse0 libasound2t64` | without these the emulator does not start |
| `/dev/kvm` | `sudo chmod 666 /dev/kvm` + add yourself to the `kvm` group | **loses every container rebuild** — `bash scripts/bootstrap.sh` re-applies it |
| JDK 17 | Adoptium Temurin 17 into `/workspaces/jdk17` | the container's default Java is **25**, which Gradle rejects |
| cmdline-tools | `https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip` → `/workspaces/android-sdk/cmdline-tools/latest` | |
| packages | `sdkmanager "platform-tools" "emulator" "system-images;android-34;default;x86_64" "build-tools;34.0.0" "platforms;android-34"` | **`default`, never `aosp_atd`** — see §6 |
| AVD | `avdmanager create avd -n testavd -k "system-images;android-34;default;x86_64" -d pixel_5 --force`, then copy `avd/testavd.config.ini` over `config.ini` | the tuned file is what makes the screen 320×640, the GPU software, the data partition 2048 M and the snapshots off |
| Flutter | `git clone --depth 1 --branch 3.35.1 https://github.com/flutter/flutter.git /workspaces/flutter` | the `.git` directory is required — Flutter refuses to run without it |

**Check it worked:**

```bash
/workspaces/android-sdk/platform-tools/adb version
/workspaces/android-sdk/emulator/emulator -list-avds      # must print testavd
/workspaces/jdk17/bin/java -version                      # must print 17
```

### Step 2 — link this repository into the runtime layout

Every script, the extension and the supervisor use the absolute path
`/workspaces/<something>`. `install-stack.sh` makes those paths symlinks into
this repository, so **this repository is the single source of truth** and
nothing else has to change.

```bash
bash scripts/install-stack.sh
```

It creates:

* `/workspaces/<script>` → `scripts/<script>` for every runtime script
* `/workspaces/mini_app` → `app/` (the path the supervisor installs the APK from)
* `~/.vscode-remote/extensions/codespace.emulator-view-0.1.0/` from
  `extension.js`, `package.json` and `media/`

> `code --install-extension` does **not** work in this environment. Copying
> the files does. After copying, the user must run **Developer: Reload Window**
> once — the extension host does not respawn on its own.

### Step 3 — start the emulator

```bash
bash /workspaces/emu.sh
```

```
== Android emulator stack ==
  ok    KVM ok
  ok    viewer up on :8091
[10:49:47] starting emulator (cold boot, 60-140s)
  ok    device: emulator-5554	device
  ok    boot_completed=1
  ok    app installed
  ok    app launched
  ok    screen shows the app
  ok    supervisor up (pid 11825)
  ok    port 8091 is public

  READY  ->  https://<codespace-name>-8091.app.github.dev/
```

* Cold start **~1 min 50 s** (the emulator boot dominates). Already running:
  **~20 s**.
* Subcommands: `start` (default), `status`, `stop`, `restart`, `url`, `logs`.
* In VS Code: **Ctrl+Shift+B** runs it (task *Android Emulator: Start
  Everything*). The task *Android Emulator: Ensure Up (auto)* runs on every
  folder open, so in normal use **the user does nothing** — the stack comes up
  by itself, including after a container restart.

The public URL is `https://<codespace-name>-8091.app.github.dev/`. Get the
name with `echo $CODESPACE_NAME`, or `bash /workspaces/emu.sh url`.

### Step 4 — build and install the app

```bash
# 1. build - DETACHED, it takes ~5 minutes
cd /workspaces/empty-repo/app
setsid nohup bash /workspaces/build-callnote.sh >/tmp/flutter-build.log 2>&1 </dev/null & disown
sleep 60; tail -5 /tmp/flutter-build.log

# 2. install and launch
A=/workspaces/android-sdk/platform-tools/adb
$A install -r app/build/app/outputs/flutter-apk/app-release.apk
$A shell am force-stop com.example.mini_app
$A shell am start -n com.example.mini_app/.MainActivity --ez enable-impeller false
```

* **`--ez enable-impeller false` is mandatory.** Impeller's Vulkan renderer on
  a software GPU pins qemu at 100 % of a core and the phone freezes.
* **All three ABIs** are built (`android-arm,android-arm64,android-x64`).
  An x86_64-only APK is refused by a real phone.
* **Stop the emulator before a build** — `bash /workspaces/emu.sh stop` — or the
  Gradle daemon gets OOM-killed on this 2-vCPU / 7.8 GB / no-swap box.
* The NDK (2.0 GB) and CMake (61 MB) are downloaded automatically by AGP on
  the first build. Nothing to install by hand.

### Step 5 — verify the whole thing

```bash
bash /workspaces/verify.sh
```

Eight checkpoints, all of which must pass:

| # | Check | Healthy value |
|---|---|---|
| 1 | emulator | `emulator-5554  device` |
| 2 | `sys.boot_completed` | `1` |
| 3 | app process | a pid |
| 4 | extension host | a pid (not `none`) |
| 5 | capture path | `frame N (320x640, ...B, via grpc)` |
| 6 | viewer | `{"device": "emulator-5554", ...}` |
| 7 | forwarded port | `8091 public https://<cs>-8091.app.github.dev` |
| 8 | public URL | `http=200` |

Then the functional test suite:

```bash
bash /workspaces/callnote-fgs-test.sh all     # 13 checks, ~4 min (it reboots the device)
```

```
== 1. service + notification are up
== 2. app is swiped out of recents
== 3. a reminder still arrives with the app swiped away
== 4. outgoing call is caught
== 5. after a reboot the watcher comes back by itself
== result: 13 passed, 0 failed
```

### Step 6 — make a release for a phone

```bash
bash scripts/package-release.sh --build
```

Produces `callnote-release-<YYYYMMDD-HHMMSS>.apk` and `.zip` in the repository
root, each with its own name so no build overwrites another. The zip holds the
APK plus a `README.txt` with its hashes, size, ABIs and signer.

```bash
adb install -r callnote-release-<stamp>.apk
```

---

## 4. Day-to-day operation

| Situation | What to do |
|---|---|
| Container restarted / VS Code reconnected | **nothing** — the extension re-runs the start hook; allow ~90 s |
| The stack is down, VS Code still connected | `bash /workspaces/emu.sh start` |
| Just a health check | `bash /workspaces/emu.sh status` |
| Shut it down | `bash /workspaces/emu.sh stop` |
| Only the emulator died | wait ~30 s — the supervisor restarts it |
| Only the app died or was backgrounded | wait ~15 s — the supervisor re-focuses it |
| Port 8091 is not public | `bash /workspaces/ensure-public.sh 8091` |
| The extension code changed | the user runs **Developer: Reload Window** |
| The whole stack must be proven | `bash /workspaces/coldstart-test.sh` (destroys everything, then proves the one command brings it back) |

Logs:

| File | Content |
|---|---|
| `/tmp/emulator-view.log` | the extension: attach, frames, input timings |
| `/tmp/supervisor.log` | the supervisor: what it started or restarted |
| `/tmp/emulator.log` | qemu |
| `/tmp/emuview.log` | the HTTP viewer |
| `/tmp/flutter-build.log` | the Gradle build |

---

## 5. How the system behaves — what "normal" looks like

Use this as the baseline when deciding whether something is broken.

| Path | Time |
|---|---|
| emulator touch → visible screen change | ~490 ms |
| of which the touch itself | 70–200 ms (`adb shell input tap`) |
| frame capture over gRPC | 18–84 ms, avg 42 ms |
| cold boot of the emulator | 60–140 s |
| container wipe → working public page | ~90 s |

* The guest OS is idle ~90 % of the time while the **host** is saturated: the
  emulator rasterises every pixel on the CPU (SwiftShader) and the Codespace
  has 2 vCPUs shared with VS Code. The phone's own UI therefore feels slower
  than on real hardware. **This is a limit of the environment, not a bug.**
* SystemUI logs ANRs under load. `hide_error_dialogs 1` is set so those
  dialogs never cover the app.
* Animation scales are `0` and the screen timeout is the maximum, so the
  phone stays awake and still.
* The extension keeps **one frame in flight**: the webview acknowledges a
  frame after decoding it, and only then is the next one sent. That keeps the
  picture smooth and stops input messages from queueing behind frames.

---

## 6. The traps — everything that cost real time

These are the failures that look like "the emulator is broken" when they are
not. Each one is a *silent* failure: no error message, just a screen that
does not update or a tap that does nothing.

### 6.1 The system image must be `default`, never `aosp_atd`

`aosp_atd` (Automated Test Device) wipes `/data/local/tmp` and blocks the
scrcpy jar under SELinux — streaming silently never works.

```bash
sdkmanager "system-images;android-34;default;x86_64"     # correct
```

### 6.2 The default Java is 25 — Gradle needs 17

```bash
source /workspaces/androidsdk-env.sh      # always, before any flutter/gradle command
```

### 6.3 Impeller must be off, or the phone freezes

```bash
adb shell am start -n com.example.mini_app/.MainActivity --ez enable-impeller false
```

Impeller's Vulkan renderer on SwiftShader pins qemu at 100 % of a core, and
SystemUI throws "Process system isn't responding" dialogs over the app.

### 6.4 `adb exec-out screencap` is the wrong way to capture

It takes **~800 ms** and runs a PNG encoder *inside the guest*, which starves
the Flutter renderer on a 2-vCPU box — the app stops drawing and the screen
goes **black**. Use the emulator's own gRPC `getScreenshot` (~25 ms, zero guest
work). That is what `scripts/grpc-grab.js` does.

### 6.5 The emulator's gRPC **input** API is a silent no-op

Measured on emulator 37.2.12.0:

| method | taps registered |
|---|---|
| `sendTouch(TouchEvent)` | **0 of 3** |
| `streamInputEvent` with `android_event` | **0 of 1** |
| `adb shell input tap` | **9 of 9** |

The failing calls answer `grpc-status 0` — they look successful, but the guest
never receives the event. **Use `adb shell input tap`.** The gRPC input code
was deleted from the extension so it cannot be re-enabled by accident.

### 6.6 A gRPC status arrives in the **trailers**, not the headers

```js
req.on("response", h => h["grpc-status"])     // WRONG - always undefined
req.on("trailers", t => t["grpc-status"])     // RIGHT
```

Reading it from the headers made every failed call look like a success, so the
adb fallback was never reached.

### 6.7 The port is only forwarded if the extension calls `asExternalUri()`

A socket that merely *listens* is invisible to the Codespaces tunnel.

```js
const uri = await vscode.env.asExternalUri(vscode.Uri.parse("http://127.0.0.1:8091"));
```

The extension does this on startup and re-asserts it every ~2 minutes.

### 6.8 Bind the viewer **before** the emulator

The port-forwarding agent scans for listening ports **once, at container
start**. A port bound later is never forwarded, and rebinding does not help.
`emu.sh` therefore starts the viewer first; `emuview.py` waits for a device
instead of exiting, so starting it early is safe.

### 6.9 Use `gh codespace ports visibility`, not the generic REST API

```bash
gh codespace ports visibility 8091:public -c "$CODESPACE_NAME"
```

The generic `/repos/.../codespaces/.../ports` endpoints return **404** in a
Codespace. The `gh` CLI uses a different API and works. It fails with 404 if
the port is not forwarded yet — retry.

### 6.10 A `302` from the public URL is expected, not a fault

An unauthenticated client is redirected to `github.dev/pf-signin`. A browser
logged into GitHub passes straight through. The port is `public`, so no
sign-in is needed at all.

### 6.11 A dozing display returns black frames from **every** path

`adb screencap`, the node gRPC client and curl all return an all-black PNG
while the emulator looks perfectly healthy. The tell is in
`dumpsys window`: `isKeyguardShowing=true`, `mDreamingLockscreen=true`.

The fix is applied by `emu.sh` and `supervisor.sh`:
`screen_off_timeout 2147483647`, `low_power 0`, `lockscreen.disabled 1`,
`locksettings set-disabled true`, `dumpsys deviceidle disable`, `svc power
stayon true`. The supervisor also heals a black screen by itself: three blank
frames in a row and it wakes the display and relaunches the app.

### 6.12 `pkill -f` kills the shell that runs it

The pattern matches the invoking shell's own command line.

```bash
kill -9 "$(pgrep -f '[q]emu-system-x86_64-headless' | head -1)"   # by pid
pgrep -x qemu-system-x86                                             # 'comm' is capped at 15 chars
```

Never use an unanchored `pgrep -f supervisor.sh` either — the same trap.

### 6.13 The extension host does not respawn

The workbench owns that request. After a container restart the emulator, the
app and the HTTP viewer keep running (the browser URL still works), but the
in-VS-Code tab is gone until the user runs **Developer: Reload Window**.

### 6.14 The in-VS-Code tab cannot render for this user

`*.assets.github.dev` is where VS Code serves webview resources. It resolves
publicly and inside the container, but this user's own resolver cannot look it
up, so the tab dies with *"server IP address could not be found"*. **This is a
client-side DNS problem and nothing in the container can fix it.** Use the
browser URL — it is on `*.app.github.dev`, the same base domain as the
workbench.

### 6.15 `am force-stop` cancels the pending `BOOT_COMPLETED` broadcast

The supervisor force-stops the app when it relaunches it, and that cancels a
boot broadcast still queued for the package — the boot receiver never sees it.
On a real phone there is no supervisor, so it does not happen. **The reboot
test must stop the supervisor first** (the test script does).

### 6.16 Build detached, and stop the emulator first

A Gradle build takes ~5 minutes; any foreground tool call kills it and leaves
a stale `build/` directory behind. A 3-ABI build with the emulator running
gets the daemon OOM-killed.

### 6.17 The disk is 32 GB and the SDK is greedy

`disk.dataPartition.size` stays at **2048M** (6G does not fit next to the
SDK, Flutter and the Gradle caches). If the disk gets tight, delete
`/workspaces/android-sdk/.temp/` (sdkmanager leftovers), `conda clean --all`,
`/home/codespace/.cache/*`. **Never** delete
`/workspaces/.gradle/caches/modules-2` (slow to re-download).

### 6.18 The boot takes 60–140 s

Not 30 s. The AVD has **no usable snapshot** (`firstboot.saveToLocalSnapshot=no`
and the emulator runs with `-no-snapshot-save -no-snapshot-load`), so every
boot is a cold boot. `sys.boot_completed=1` is the only reliable readiness
signal.

---

## 7. Signing (the keystore)

The release APK must be signed with a **release key** that lives on the
persistent volume. The Flutter template signs with the **debug** key, and the
debug keystore lives in the container's overlay layer — it changes on every
rebuild, so the app can never be updated in place on a phone.

```bash
bash scripts/create-keystore.sh
```

It creates `/workspaces/.keystore/callnote-release.jks` (RSA 4096, alias
`callnote`, 30 years) and writes `app/android/key.properties` and
`key.properties` pointing at it. Both are **gitignored** — never commit the
keystore or the passwords.

`app/android/app/build.gradle.kts` uses the release key **only if
`key.properties` exists**; without it the build falls back to the debug key,
so the repository stays buildable anywhere.

> If you regenerate the keystore, the app can no longer be installed over the
> old one on a phone (different signature). Uninstall it first.

---

## 8. Changing things

| What | Where | How |
|---|---|---|
| The app | `app/` | edit, then `scripts/build-callnote.sh` (detached) |
| The extension | `extension.js`, `media/view.js`, `media/view.css` | `bash scripts/install-stack.sh`, then the user reloads the window |
| The stack scripts | `scripts/` | edit here; `/workspaces/*` are symlinks into this repo |
| The AVD | `avd/testavd.config.ini` | applies at the next emulator start |
| The public URL / port | `scripts/emu.sh` (`PORT=8091`) | the extension reads the same port |

The **package id stays `com.example.mini_app`** — `supervisor.sh`, `emu.sh` and
`run-all.sh` hardcode it. The launcher name is `android:label` in the
manifest and nothing else.

---

## 9. Where things are

| Path | What |
|---|---|
| `/workspaces/empty-repo/` | this repository |
| `/workspaces/empty-repo/app/` | the CallNote Flutter app |
| `/workspaces/empty-repo/scripts/` | every runtime script (source of truth) |
| `/workspaces/empty-repo/avd/testavd.config.ini` | the tuned AVD config |
| `/workspaces/empty-repo/extension.js` | the VS Code extension |
| `/workspaces/empty-repo/START-HERE.md` | this file |
| `/workspaces/empty-repo/CALLNOTE.md` | the app's documentation |
| `/workspaces/empty-repo/AGENTS.md` | the full history, 130 KB |
| `/workspaces/emu.sh` | start / stop / status the whole stack |
| `/workspaces/supervisor.sh` | the watchdog |
| `/workspaces/emuview.py` | the HTTP screen + input server (:8091) |
| `/workspaces/grpc-grab.js` | the gRPC frame grabber |
| `/workspaces/android-sdk/` | the SDK, emulator, platform-tools |
| `/workspaces/android-avd/testavd.avd/` | the AVD |
| `/workspaces/jdk17/` | the JDK that actually works |
| `/workspaces/flutter/` | the Flutter SDK |
| `/workspaces/.keystore/` | the release keystore (never commit) |

---

## 10. The scripts

| Script | What it does |
|---|---|
| `scripts/install-toolchain.sh` | SDK + emulator + AVD + JDK 17 + Flutter, from nothing |
| `scripts/install-stack.sh` | link this repo into `/workspaces`, install the extension |
| `scripts/create-keystore.sh` | generate the release keystore |
| `scripts/emu.sh` | **the one command**: `start` / `status` / `stop` / `restart` / `url` / `logs` |
| `scripts/supervisor.sh` | the watchdog: relaunches the emulator, the app and the viewer |
| `scripts/ensure-up.sh` | the auto-start hook (returns in ~2 s) |
| `scripts/ensure-public.sh` | makes port 8091 public via the `gh` CLI |
| `scripts/emuview.py` | the HTTP screen + input server (:8091) |
| `scripts/grpc-grab.js` | the gRPC frame grabber (~25 ms/frame) |
| `scripts/screen-check.py` | "is the frame blank?" — the black-screen watchdog |
| `scripts/bootstrap.sh` | restores `/dev/kvm`, the kvm group and the X11 libs |
| `scripts/androidsdk-env.sh` | PATH / JAVA_HOME / ANDROID_HOME — **source before any build** |
| `scripts/start-avd.sh` | boots the emulator only (`stop` to halt it) |
| `scripts/run-all.sh` | the older one-shot bring-up |
| `scripts/verify.sh` | the eight health checkpoints |
| `scripts/coldstart-test.sh` | destroys everything and proves the one command brings it back |
| `scripts/build.sh` | builds a release APK for any Flutter project |
| `scripts/build-callnote.sh` | the CallNote release build (all three ABIs) |
| `scripts/package-release.sh` | the timestamped release packaging |
| `scripts/callnote-fgs-test.sh` | the 13-check test suite |
| `scripts/seed-contacts.sh` | seeds Batman 5550100, Joker 5550200, Alfred 5550300 |

---

## 11. The HTTP viewer API

`emuview.py` listens on `0.0.0.0:8091`.

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | the HTML viewer page |
| GET | `/frame` | the current screen as PNG |
| GET | `/status` | `{"device": …, "fps": …, "frames": …, "source": "grpc"}` |
| POST | `/tap?x=<px>&y=<px>` | tap, in **device** pixels |
| POST | `/swipe?x1&y1&x2&y2[&ms=300]` | swipe |
| POST | `/key?code=<keycode>` | keyevent — `KEYCODE_HOME`, `KEYCODE_BACK`, `KEYCODE_ENTER` |
| POST | `/text?value=<urlencoded>` | type text |

```bash
curl -X POST "http://127.0.0.1:8091/tap?x=275&y=595"
```

The device screen is **320×640** (`hw.lcd.width=320`, `hw.lcd.height=640`,
density 160). The viewer page converts browser pixels to device pixels
client-side, so clicking the picture in the browser is always correct.

---

## 12. Driving the emulator by hand

```bash
A=/workspaces/android-sdk/platform-tools/adb
$A shell input tap 275 595
$A shell input swipe 160 400 160 200 300
$A shell input keyevent 3      # HOME
$A shell input keyevent 4      # BACK
$A shell input keyevent 66     # ENTER
$A shell dumpsys window | grep -m1 mCurrentFocus
$A shell dumpsys telephony.registry | grep mCallState
$A emu gsm call 5550100        # simulate an incoming call
$A emu gsm cancel 5550100
```

The emulator's own gRPC service (`127.0.0.1:8554`, service
`android.emulation.control.EmulatorController`) is used for **screenshots
only** — see §6.5 for why the input half is not used. The bearer token is in
`/home/codespace/.android/avd/running/pid_<pid>.ini` (`grpc.token=…`) and is
**rotated on every emulator start**.
