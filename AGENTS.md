# Android Emulator in GitHub Codespaces — Session Handoff

> **If you are a new agent with no prior context: read this whole file before doing anything.**
> Everything below was already built and debugged by a previous session. Your job is to
> **start it, not rebuild it.** The hard problems are already solved — do not re-derive them.

---

## 1. TL;DR — first 60 seconds

```bash
bash /workspaces/run-all.sh
```

That single command brings up the emulator, installs/launches the app, and starts the web
viewer. It is **idempotent** — safe to run when everything is already up (finishes in ~2s).

Then open in your browser (already logged into GitHub):

```
https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/
```

You will see a live screenshot of the emulator with click-to-tap support.

**Run `run-all.sh` after every Codespace restart/stop.** Nothing survives a restart except
files on disk. That is the *only* reason the stack needs restarting — it is not broken.

---

## 2. Verified current state

Checked live on 2026-10-23:

| Component | State |
|---|---|
| Emulator | `emulator-5554`, `sys.boot_completed=1` |
| App | `com.example.mini_app` installed + running |
| Viewer `/status` | HTTP 200 |
| Viewer `/frame` | HTTP 200, ~15 KB PNG |
| Tap input | verified end-to-end (3 taps → counter showed 3) |
| Disk free | ~4.8 GB |

Quick health check:

```bash
/workspaces/android-sdk/platform-tools/adb devices
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8091/status
```

---

## 3. Port visibility — READ THIS, IT WILL WASTE YOUR TIME IF YOU SKIP IT

**Port 8091 is Private, and that is fine. Do not try to change it.**

- Private ports redirect unauthenticated clients to `https://github.dev/pf-signin`.
- A browser **already logged into GitHub** passes through that redirect automatically.
  This is why it works for the user with zero manual port configuration.
- An unauthenticated `curl` will still get `302`. **That is expected, not a failure.**

### Dead end — do not retry

Changing port visibility **cannot be automated in this environment.** All of these were
tried and failed:

- GitHub REST API with `GITHUB_TOKEN` → `404`
- GitHub REST API with `GITHUB_CODESPACE_TOKEN` → `404`
- `gh` CLI (authenticated) → port endpoints `404`

Only the VS Code **PORTS panel** can change it, and it is **not needed**. If a future
requirement appears for sharing the URL with a logged-out browser, that is the one manual
step required, and nothing in this repo can automate it.

---

## 4. Architecture

Three independent pieces. Only the first two need restarting.

```
1. Emulator        qemu @testavd, -no-window -gpu swiftshader_indirect, ports 5554/5555
2. Flutter app     com.example.mini_app, the thing being visually tested
3. emuview.py      HTTP server :8091 — screencap -> PNG, POST input -> adb
                   binds 0.0.0.0 so GitHub's port forwarder can reach it
```

`emuview.py` needs no scrcpy, no WebSocket bridge, no browser extension. It polls
`adb exec-out screencap -p`, which is why it is far more reliable than the alternatives
that were tried and abandoned (see §6).

---

## 5. `emuview` HTTP API

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | HTML viewer page (live frames + click to tap) |
| GET | `/frame` | current screen as PNG |
| GET | `/status` | JSON status; `200` = healthy |
| POST | `/tap?x=<px>&y=<px>` | tap at pixel coords |
| POST | `/swipe?x1&y1&x2&y2[&ms=300]` | swipe/drag |
| POST | `/key?code=<keycode>` | e.g. `code=KEYCODE_HOME` |
| POST | `/text?value=<urlencoded>` | type text |

Coordinates are in **emulator screen pixels** (720×1280 portrait), *not* browser pixels —
the viewer page scales the image and converts clicks client-side.

Example:

```bash
curl -X POST "http://127.0.0.1:8091/tap?x=283&y=570"
```

---

## 6. EmbeDroid — the failed path (do not go back down it)

The user originally wanted the **EmbeDroid** extension
(`utpalbarman.embedroid-1.0.2`) for video streaming. It was fully patched and still
abandoned in favour of `emuview.py`.

Patches applied to
`/home/codespace/.vscode-remote/extensions/utpalbarman.embedroid-1.0.2/dist/extension.js`
(all already on disk, backups `extension.js.orig` / `.bak-csp` / `.bak-host` alongside):

1. `asExternalUri()` so the webview can load through the Codespaces hostname
2. bridge port fixed `8099`
3. `scid` masked with `0x7fffffff` (sign-int bug, see §7.5)
4. boot timeout `12e4` → `42e4` ms
5. CSP widened to allow `wss:`, `wss://*.app.github.dev`, `http:`, `ws:`, `blob:`
6. bridge host `127.0.0.1` → `0.0.0.0`

If you want to revisit it: it still requires **pressing the extension's Play button**, which
defeats the "fully autonomous" requirement, and `/workspaces/patch_embedroid.py` only
reproduces the `asExternalUri` patch — **an extension reinstall would silently lose 2–6.**

---

## 7. Traps already paid for — do not re-learn these

Each of these presents as an indefinite "Connecting…" with no error message.

1. **Wrong system image.** `aosp_atd` (and any ATD image) wipes `/data/local/tmp` and
   blocks the scrcpy jar under SELinux. We use plain
   `system-images;android-34;default;x86_64`. Correct already.
2. **Disk.** `disk.dataPartition.size=6G` does not fit the 32 GB disk. Capped to `2048M`.
3. **Boot timeout.** Cold boot takes ~127 s; EmbeDroid's default limit was 120 s. Hence patch 4.
4. **CSP.** The extension's default `Content-Security-Policy` allowed only
   `ws://127.0.0.1`, so the browser WebSocket was silently blocked.
5. **`scid` sign bug.** ~50% of launches died with `NumberFormatException`.
6. **Java version.** System default is **JDK 25**, which breaks Gradle. The working JDK 17
   lives at `/workspaces/jdk17` and is exported by `/workspaces/androidsdk-env.sh`.
   **Source that file before any Flutter/Gradle build**, or you will chase a phantom failure.
7. **Manual emulator blocks the extension.** If `adb devices` already shows an emulator,
   EmbeDroid's own launch fails to attach. Kill the manual one first.
8. **SELinux `Enforcing` is fine.** The AVD stays enforcing and scrcpy's server still runs.

---

## 8. Other dead ends

- **Local scrcpy SDL client** in the browser terminal — cannot open a display. Irrelevant
  to `emuview`, which needs no SDL.
- **`aosp_atd` images** — see §7.1.
- **Scripts that auto-toggled port visibility** — removed; they were making 404 calls in a
  loop. `port-watchdog.sh` and `run-stream-test.sh` were deleted as useless.

---

## 9. File map

| Path | Purpose |
|---|---|
| `/workspaces/run-all.sh` | **the one command.** Brings up everything, idempotent |
| `/workspaces/emuview.py` | HTTP screen + input server on :8091 |
| `/workspaces/androidsdk-env.sh` | correct PATH / `JAVA_HOME` / `ANDROID_HOME` |
| `/workspaces/bootstrap.sh` | restores `/dev/kvm` perms + X11 libs after rebuild |
| `/workspaces/build.sh` | builds the Flutter APK |
| `/workspaces/start-avd.sh` | emulator-only launcher |
| `/workspaces/mini_app/` | minimal Flutter app (`com.example.mini_app`) |
| `/workspaces/mini_app/android/gradle.properties` | memory-constrained Gradle settings |
| `/workspaces/android-avd/` | AVD home (`testavd`) |
| `/workspaces/flutter/` | Flutter 3.35.1 SDK |
| `/workspaces/android-sdk/` | Android SDK, emulator, platform-tools |
| `/workspaces/jdk17/` | the JDK that actually works |
| `/workspaces/.vscode/tasks.json` | `Ctrl+Shift+B` runs `run-all.sh` |
| `/workspaces/.devcontainer/devcontainer.json` | `postStartCommand` → `run-all.sh` |

Logs: `/tmp/emulator.log`, `/tmp/emuview.log`, `/tmp/bootstrap.log`, `/tmp/autostart.log`.

AVD config worth knowing: 2 cores, `hw.ramSize=2560`, `hw.sdCard=no`,
`disk.dataPartition.size=2048M`.

---

## 10. Resource limits (2 vCPU, 7.8 GB RAM, no swap, 32 GB disk)

- **Never** let Gradle use its default. Flutter's default `-Xmx8G` **OOM-killed** the build
  here. `gradle.properties` is already capped to ~1.5 GB heap / 1 worker — keep it that way.
- Sizes: sdk 6.2 GB, flutter 2.4 GB, `.gradle` 2.2 GB.
- Android NDK was deleted after the build to reclaim space. **Do not delete
  `.gradle`** — re-downloading it is slow.
- Emulator runs headless with software GPU (`swiftshader_indirect`). Expect ~3–8 fps in the
  viewer; that is a rendering limit, not a bug.

---

## 11. If you break it

```bash
# full reset — safe at any time
adb kill-server
pkill -f emuview.py
pkill -f qemu-system
bash /workspaces/run-all.sh
```

If `run-all.sh` reports the emulator never came up, check `/tmp/emulator.log` and confirm
KVM: `ls -l /dev/kvm` should show the `codespace` user in group `kvm`, or run
`bash /workspaces/bootstrap.sh`.

---

## 12. If the Codespace is rebuilt from scratch

Disk-persistent paths (`/workspaces/*`) survive; the runtime does not. Expect to:

1. `bash /workspaces/bootstrap.sh` — restores KVM perms
2. `bash /workspaces/run-all.sh` — brings up the stack
3. Reinstall extensions (the EmbeDroid patches in §6 would be **lost**)

`/workspaces/.devcontainer/devcontainer.json` runs step 2 automatically as `postStartCommand`,
but only takes effect for Codespaces **created from** that config — not one already running.
Until then use `Ctrl+Shift+B` or `bash /workspaces/run-all.sh`.