# CallNote — complete project documentation

> A Flutter/Android app that reminds you, **the instant a call happens**, what you
> wanted to remember about that person. Plus the emulator/CI harness it is
> developed and tested against.
>
> Written 2026-10-29. Source of truth for the code is this repo; the deep
> session-by-session history lives in `AGENTS.md` (§1–§32) and `/workspaces/START-HERE.md`.

---

## 1. What the app does

You attach a short note to a contact — *"tell them about the surgery"*, *"it's
the anniversary"*, *"ask about the invoice"*. When that contact calls, the app
posts a notification containing your note. While the call is still ringing.

The whole point is the **timing**: the reminder must arrive with the call, not
after it. On the emulator it arrives **9–46 ms** after the phone reports the
call.

---

## 2. Feature inventory

### 2.1 Notes (the data)

| Feature | Where | Notes |
|---|---|---|
| Note per contact | `lib/note_editor.dart`, `lib/controller.dart` | contact, free text, on/off switch |
| Contact picker | `lib/contact_picker.dart` | searches the device contacts, permission-gated |
| Enable / disable a note | note switch in the list | a disabled note never fires |
| Delete a note | trash icon on the note row | |
| Notes survive everything | `NoteStore.kt` → `files/callnote.json` | survives an app restart, a reboot and an app update |
| "Stop permanently" from the notification | `NoteActionReceiver.kt` | writes `enabled:false` into the note file **from the native side**, because the app may not be running |
| "Snooze" from the notification | same | the note stays enabled; it just reminds again on the next call |
| Notes are mirrored in both directions | `Controller._resync()` | the Dart side re-reads the file after an action instead of writing its own copy — the native side is the authority |

**Number matching** (`NoteStore.numbersMatch`): digits only; equal → match;
otherwise the shorter number (≥ 7 digits) must be a suffix of the longer one.
So `5550100` matches `+1 555 0100`, but `555` never matches anything.

### 2.2 The reminder notification

| Property | Value |
|---|---|
| Title | the contact name (`Batman`) |
| Text | the note (`tgh`) — also as `BigTextStyle` so long notes are fully visible |
| Category | `CATEGORY_CALL` |
| Priority | `PRIORITY_HIGH` |
| Visibility | `VISIBILITY_PRIVATE` (shows on the lock screen, but not the content) |
| Tap | opens the app |
| Button 1 | **Stop permanently** — switches the note off |
| Button 2 | **Snooze** — reminds again on the next call |
| Auto-cancel | yes (tapping it removes it) |
| Channel | `call_notes` (id `com.example.mini_app/callnote`) |
| Notification id | derived from the note id, so one note = one notification that is *replaced*, never duplicated |
| No screen-on / full-screen intent | deliberately **not** used: it would interrupt the call screen |

### 2.3 The "watching" notification (foreground service)

A permanent notification that says the app is watching calls, with a
**Stop watching** button. It exists so the user can see the watcher is on —
a foreground service without a visible notification is a policy problem on
Android 13+, and an invisible watcher is worse than no watcher.

* service type: **`specialUse`** (`FOREGROUND_SERVICE_SPECIAL_USE` +
  `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`) — `dataSync` may not be started from a
  boot receiver on Android 15+, and `phoneCall` would need the default-dialer role.

### 2.4 Watching (the detection machinery)

| Source | What it gives | When it fires |
|---|---|---|
| **`PhoneStateListener`** (deprecated) | **the phone number** + the state | instantly, on every call |
| `TelephonyCallback.CallStateListener` | the state (no number) | instantly, ~6 ms *before* the deprecated one |
| call-log `ContentObserver` | the number, a few hundred ms later | when the OS writes the row |
| fast call-log poll | the number | every **250 ms** for **30 s** after a call starts |
| backstop poll | the number | every **15 s**, always |
| `CallScreeningService` | the number at ring time | only if the user grants the Caller ID role — **nothing depends on it** |

Constants (all in `CallNoteEngine.kt`):

```
FAST_POLL_MS            = 250     ms   (during a call)
FAST_POLL_WINDOW_MS     = 30_000  ms
BACKSTOP_POLL_MS        = 15_000  ms
RECENT_CALL_WINDOW_MS   = 300_000 ms   (the "recent calls" look-back)
SAME_CALL_WINDOW_MS     = 5_000   ms   (two detections = one call)
```

**Deduplication**: a call is identified by the moment it *started*, not by the
number. The phone state and the call-log row of one call carry the same
timestamp, so a 5 s window matches them; two calls to the same person a
moment later are two calls and both get a reminder.

**State machine** (`onCallStateChanged`):

```
RINGING  -> a new call. Reset "already announced", announce if we have a number.
OFFHOOK  -> the same call if it was already announced, otherwise a new outgoing call.
IDLE     -> the call is over. Reset.
```

### 2.5 Surviving the phone

| Feature | How |
|---|---|
| Survives being swiped out of recents | foreground service + `ContentObserver` instead of a 2 s poll |
| Survives a reboot | `NoteBootReceiver` (`BOOT_COMPLETED` + `MY_PACKAGE_REPLACED`) starts the service |
| Survives an app update | `MY_PACKAGE_REPLACED` |
| Starts itself on the first launch | `MainActivity` → `ensureMonitorRunning` |
| The watcher can be turned off | menu → *Stop watching calls*, or the *Stop watching* button on the notification |
| The UI follows the watcher state | the native side pushes `onMonitoring` to Dart |

### 2.6 Deliberately **not** in the app

* **No `INTERNET` permission** — the app cannot make a network request.
* **No full-screen intent** — it would cover the call screen.
* **No "Simulate a call"** menu items — removed 2026-10-29; they were a
  developer crutch and useless to a real user.
* **No Caller ID nag** — the app does not ask for the role; it does not need it.
* `android:allowBackup="false"` — the notes do not end up in a cloud backup.

### 2.7 Permissions

| Permission | Why | Runtime? |
|---|---|---|
| `POST_NOTIFICATIONS` | the reminder is a notification | yes (Android 13+) |
| `READ_CONTACTS` | pick a contact for a note | yes |
| `READ_CALL_LOG` | the fallback source for the number | yes |
| `READ_PHONE_STATE` | **the number, at the moment the call starts** — this is what makes the reminder fast | yes |
| `RECEIVE_BOOT_COMPLETED` | restart the watcher after a reboot | no |
| `FOREGROUND_SERVICE` | the watcher service | no |
| `FOREGROUND_SERVICE_SPECIAL_USE` | the watcher service type | no |

### 2.8 Components

| Component | Role |
|---|---|
| `.MainActivity` | hosts the Flutter UI, wires the `MethodChannel` |
| `CallNoteMonitorService` | the foreground service ("watching") |
| `NoteBootReceiver` | `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED` |
| `NoteActionReceiver` | the notification buttons (not exported) |
| `NoteCallScreeningService` | optional extra source when the role is granted |

### 2.9 Bridge API

Dart → native (`Bridge.invoke`): `dataDir`, `hasPermission`,
`requestPermission`, `listContacts`, `lookupContact`, `notify`,
`cancelNotification`, `drainActions`, `hasCallerIdRole`,
`requestCallerIdRole`, `isMonitoring`, `setMonitoring`, `ensureMonitorRunning`.

Native → Dart: `onCall` (number, incoming, sessionId, posted), `onMonitoring`
(on/off), `onNotificationAction` (action, id).

The native side posts the reminder **itself** — it has to, because it also
works while no Dart code is running. It tells Dart `posted=true/false`, and
only the `false` case makes the Dart side post a fallback.

---

## 3. The code

```
/workspaces/empty-repo/app/
├── lib/
│   ├── main.dart          61    app entry, dark theme
│   ├── controller.dart   298    state, bridge calls, dedup of call events
│   ├── home_screen.dart  358    the list, the menu, permissions, monitoring banner
│   ├── note_editor.dart  179    create / edit a note
│   ├── contact_picker.dart 181  contact search
│   ├── model.dart        110    the CallNote model
│   └── bridge.dart        42    the MethodChannel wrapper
├── android/app/src/main/kotlin/com/example/mini_app/
│   ├── CallNoteEngine.kt         994    the core: notifications, detection, dedup, state machine
│   ├── CallNoteMonitorService.kt 174    the foreground service
│   ├── CallStateWatcher.kt       176    the telephony listeners
│   ├── NoteStore.kt              168    the note file, number matching
│   ├── NoteCallScreeningService.kt 51   optional caller-ID source
│   ├── NoteActionReceiver.kt      30    the notification buttons
│   ├── NoteBootReceiver.kt        30    reboot / update
│   └── MainActivity.kt            46    the bridge
└── test/widget_test.dart
```

**2 898 lines** of Dart + Kotlin. Package id `com.example.mini_app`
(deliberately never changed — the supervisor scripts hardcode it), launcher
name `CallNote`.

---

## 4. The emulator / CI harness

The app is developed against a headless Android emulator inside a GitHub
Codespace, and everything is scripted.

| Script | What it does |
|---|---|
| `/workspaces/emu.sh` | **the one command**: `start` / `status` / `stop` / `restart` / `url` / `logs` |
| `/workspaces/supervisor.sh` | watchdog: relaunches the emulator, the app and the viewer if they die |
| `/workspaces/emuview.py` | HTTP server on :8091 → live PNG of the device screen + tap/swipe/key input |
| `/workspaces/grpc-grab.js` | reads the framebuffer through the emulator's own gRPC service (~25 ms/frame) |
| `/workspaces/ensure-up.sh` | the auto-start hook (returns in ~2 s) |
| `/workspaces/ensure-public.sh` | makes port 8091 **public** via the `gh` CLI |
| `/workspaces/package-release.sh` | packages the release with a timestamped name |
| `/workspaces/build-callnote.sh` | the release build (all three ABIs) |
| `/workspaces/callnote-fgs-test.sh` | the 13-check test suite |
| `/workspaces/seed-contacts.sh` | seeds Batman 5550100, Joker 5550200, Alfred 5550300 |
| `/workspaces/screen-check.py` | "is the frame blank?" — used by the black-screen watchdog |

**Live view**: `https://zany-space-carnival-p79jxxwgj4wvfr95j-8091.app.github.dev/`
(public port, so it opens without a GitHub sign-in).

The VS Code extension in this repo (`extension.js`, `media/`) renders the
emulator **inside a VS Code tab** at ~37 fps using the emulator's gRPC
screenshot API.

---

## 5. Everything we did, session by session

### Phase 1 — the emulator (16 sessions)

| # | What |
|---|---|
| 1 | Tried the **EmbeDroid** VS Code extension, patched it six times, abandoned it — it needs a manual click |
| 2 | Wrote `emuview.py` from scratch: a ~180-line HTTP server that shows the emulator in the browser and forwards taps |
| 3 | Discovered that the port must be **public**, and that `gh codespace ports visibility` is the way (the generic REST API returns 404) |
| 4 | Found the two traps: `aosp_atd` images block scrcpy, and the cold boot takes ~127 s (EmbeDroid's limit was 120 s) |
| 5 | Learned that the browser cannot resolve `*.assets.github.dev` on this machine → any VS Code webview is dead on arrival |
| 6 | Found that the port-forwarding agent only registers a port when the extension calls `asExternalUri()` |
| 7 | Replaced `adb screencap` (~800 ms) with the emulator's own **gRPC `getScreenshot`** (~25 ms) — 30× faster |
| 8 | Found and fixed the double-tap bug (a click was sent twice, or not at all) |
| 9 | Found that the AVD had **no touchscreen** — the emulator was silently dropping every touch |
| 10 | The "sad face" in the browser was **our** bug: 8 image requests in flight; fixed by chaining them |
| 11 | A dozing display returns black frames from **every** path — fixed with `screen_off_timeout`, `dumpsys deviceidle disable`, `locksettings set-disabled true` |
| 12 | `supervisor.sh` checks the **foreground**, not just the process, so a backgrounded app is not killed |
| 13 | The supervisor's black-screen watchdog now leaves the app alone **while a call is in progress** |
| 14 | Disk archaeology: 24 GB → 19 GB used (the image layers cannot be reclaimed from inside the container) |

### Phase 2 — the app itself (8 sessions)

| # | What |
|---|---|
| 1 | The first version: a note per contact, a call-log observer, a notification with Done/Snooze |
| 2 | The app was **swiped away** and the reminder stopped → a foreground service + a `ContentObserver` instead of a poll |
| 3 | It did not come back after a **reboot** → a `BOOT_COMPLETED` receiver; the service type had to become `specialUse` because `dataSync` may not be started from boot on Android 15+ |
| 4 | The APK was **x86_64-only** → "app isn't compatible with your phone" on the OnePlus 11R. Fixed by building all three ABIs |
| 5 | The APK was signed with the **debug key** (which lives in the container's overlay layer) → a real release keystore on the persistent volume |
| 6 | The watcher could run **invisibly**: a notification posted before the permission was granted is dropped by the system forever → the service now refuses to start without the notification permission |
| 7 | The reminder arrived **after the call was over** → the trigger was moved from the call log to the **phone state** (§6) |
| 8 | Removed the *Simulate a call* menu items and the Caller ID nag banner; added the timestamped release packaging |

---

## 6. The timing problem — and how it was solved

This was the hardest part of the whole project and deserves its own section.

### 6.1 The symptom

> "the reminder arrives after the call is over; I want it the moment the call
> comes in or goes out (a second late is fine)"

### 6.2 Why it was late

The trigger was the **call-log row**. When the OEM writes that row is up to
the device: on the emulator it was ~500 ms after an outgoing call, but on a
real phone it can be written only when the call is over. Waiting for the row
makes the reminder late **everywhere** — it was never a device-specific bug.

A second bug made it worse: rows whose `NUMBER` was momentarily empty were
skipped while `lastCallLogId` advanced, so they were never looked at again.

### 6.3 The answer

The phone knows instantly, and the **deprecated `PhoneStateListener` still
delivers the phone number on Android 14**:

```
$ adb shell dumpsys telephony.registry | grep mCallState
  mCallState=0   idle
  mCallState=1   ringing
  mCallState=2   off-hook (a call is going out, or one was answered)
```

```
12:25:25.219  phone state: RINGING number=5550100
12:25:25.219  phone state gave the number: 5550100 (incoming=true)
12:25:25.233  reminder posted for 5550100 (Batman)      <- 14 ms later
```

**This is why the Caller ID role is not needed** — the number comes with the
phone state, not with the screening service.

### 6.4 Measured result

| call | number known at | reminder posted | delay |
|---|---|---|---|
| outgoing | OFFHOOK | 9–39 ms later | ✅ |
| incoming | RINGING | 23–46 ms later | ✅ |
| incoming, answered 5 s later | — | no second reminder | ✅ |
| the call-log row, 1 s later | — | no second reminder | ✅ |
| the app swiped out of recents | — | still works | ✅ |
| after a reboot | — | still works | ✅ |

### 6.5 The four traps

1. **The watcher registered itself twice.** `ensureCallStateWatch()` is called
   from two places; the first call registered *asynchronously*, so the second
   call saw `isRunning == false`, created a second watcher and **quit the
   thread of the first one**. The number-carrying callback then landed on a
   dead thread:
   ```
   W MessageQueue: Handler (android.os.Handler) {dc29587} sending message to a Handler on a dead thread
     at android.telephony.PhoneStateListener$IPhoneStateListenerStub.onLegacyCallStateChanged
   ```
   → `isRunning` is now true from the moment `start()` is called, and a
   `stopped` flag stops a late registration.

2. **The listeners have to live off the main thread.** A `PhoneStateListener`
   hands its callbacks to the thread that **created** it. That was the Flutter
   UI thread, which renders at ~150 ms/frame on the software GPU. Both
   listeners now live on the watcher's own `HandlerThread`.

3. **The two listeners report the same change ~6 ms apart, in the opposite
   order.** The modern `TelephonyCallback` fires *before* the deprecated one.
   A state machine that read "OFFHOOK after RINGING" as "a new call"
   announced the same call twice — once at ring time, once when it was
   answered. The rule is now simply **"the current call was already
   announced"**.

4. **The same-call window has to be small.** 10 s swallowed a second call to
   the same person 9 s later. 5 s is enough, because the call-log row carries
   the moment the call *started* — the same moment the phone state does.

---

## 7. The other problems we hit (and fixed)

| Problem | Cause | Fix |
|---|---|---|
| "App not installed as app isn't compatible with your phone" | the APK contained only `x86_64` | build `android-arm,android-arm64,android-x64` → `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| every future build had a different signature | signed with the debug key in the container's overlay | a release keystore on the persistent volume: `/workspaces/.keystore/callnote-release.jks` |
| the watcher ran but the phone stayed silent | a notification posted before the permission was granted is dropped **forever** | the service refuses to start when `areNotificationsEnabled()` is false, and re-checks in `onStartCommand` |
| the reminder arrived twice | the modern and the deprecated listener both reported the state | one rule: "the current call was already announced" |
| the reminder never arrived during a call | the **supervisor** killed the app: the dialer's in-call screen is dark → the black-screen watchdog fired | the supervisor now checks `mCallState` and leaves the app alone during a call |
| the app was killed mid-call by the supervisor | same as above | fixed |
| `am force-stop` cancelled the boot broadcast | the supervisor force-stops the app when it relaunches it | the reboot test stops the supervisor first |
| the emulator "was not working" | the container restarts every 30–40 min and takes the processes with it | `supervisor.sh` + `ensure-up.sh` bring everything back |
| the port kept vanishing | the Codespaces agent only registers a port that `asExternalUri()` was called for | the extension calls it and re-asserts it every ~2 min |
| `curl` to the public URL returned 302 | that is the expected answer for an unauthenticated client | ignore |
| `pgrep -f 'qemu-system'` killed my own shell | the pattern matches the calling shell's own command line | use `pgrep -x qemu-system-x86` (the `comm` field is capped at 15 chars) |
| the 3-ABI build OOM-killed Gradle | the emulator takes 2.4 GB of 7.8 GB, with no swap | stop the emulator before building; `kotlin.compiler.execution.strategy=in-process` |
| the build died when a tool call timed out | a foreground build gets killed with the shell | run it detached: `setsid nohup … & disown` |
| the app was still named "mini_app" | the launcher name comes from `android:label` | `android:label="CallNote"`; the **package id stays `com.example.mini_app`** (three scripts hardcode it) |

---

## 8. Testing

### 8.1 The suite — `/workspaces/callnote-fgs-test.sh all` (13 checks)

```
== 1. service + notification are up
  ok    monitor service exists
  ok    monitor service is foreground
  ok    monitoring notification is on screen
== 2. app is swiped out of recents
  ok    process is still alive after the swipe
  ok    monitor service survived the swipe
  ok    monitor service is still foreground
== 3. a reminder still arrives with the app swiped away
  ok    reminder for Batman appeared with the app closed
== 4. outgoing call is caught
  ok    reminder for the outgoing call appeared
== 5. after a reboot the watcher comes back by itself
  ok    the boot receiver fired (logcat proves it)
  ok    the app was started by the boot receiver
  ok    monitor service is running after the reboot
  ok    monitor service is foreground after the reboot
  ok    monitoring notification is back after the reboot

== result: 13 passed, 0 failed
```

The script grants the four runtime permissions itself, so it does not depend
on a human tapping "Allow".

### 8.2 Other checks

* `flutter analyze` → **No issues found!**
* `flutter test` → **3 tests passed**:
  * `numbers match across country codes`
  * `a note only reminds when it is enabled and has text`
  * `notes survive a json round trip`
* the timing is measured from the **device's own logcat**, not by eye
* the APK is verified with `aapt2 dump badging` (ABIs, label) and
  `apksigner verify --print-certs` (signer)
* the apk inside the release zip is byte-identical to the file on disk

### 8.3 How to verify a change

```bash
bash /workspaces/emu.sh                # start the stack
bash /workspaces/build-callnote.sh     # build (detached)
bash /workspaces/callnote-fgs-test.sh all
bash /workspaces/package-release.sh    # package with a timestamped name
```

---

## 9. The release artifacts

Each build gets its own name, so no build ever overwrites another one:

```
/workspaces/empty-repo/callnote-release-20261029-160527.apk   46.1 MB
  native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
  Signer #1 certificate DN: CN=CallNote, OU=CallNote, O=CallNote, L=, ST=, C=US
  sha256 42843e19912595652403a7c23392297d27387dc9c2a9a3f69d5175fab321dddc
/workspaces/empty-repo/callnote-release-20261029-160527.zip   21.1 MB
  sha256 df6d2cd382e9ed50992b1fdbd3e9c233fd96c37276bc64e0913ca5e03cebd322
```

The zip contains the apk and a `README.txt` with its hashes, size, ABIs and
signer. The stable names `callnote-release.apk` / `.zip` are copies of the
newest build, so the documented paths always work.

**Signing key**: `/workspaces/.keystore/callnote-release.jks`
(RSA 4096, alias `callnote`, 30 years, cert SHA-256
`ca9af9263db018d6fcf7bcb6b6fabd096877f534112cbfe71571ada7de8e3b00`).
`app/android/key.properties` points at it and is **gitignored**; without that
file the build falls back to the debug key, so the repo stays buildable
anywhere. **Never commit the keystore or the passwords.**

**Installing on a phone**

```bash
adb install -r callnote-release-20261029-160527.apk
```

Then allow the four permissions when the app asks. The notification
permission is the one that matters most — without it the phone stays silent.

---

## 10. Known limitations / open points

* **A device that hides the number** (a withheld caller ID, or a carrier that
  does not pass it on) leaves the app with nothing but the call-log row, so
  the reminder is late again. There is no public API around this.
* **Call waiting / a second call while one is running**: the "already
  announced" flag is only reset by a ringing call or by the end of a call, so
  a second call to a *different* number during a call may not get its own
  reminder.
* **The screening service** only helps if the user grants the Caller ID role;
  it is optional and not required.
* The **emulator** is slow (SwiftShader, 2 shared vCPUs): the Flutter UI
  renders at ~150 ms/frame and `adb screencap` takes ~800 ms. The gRPC path
  (25 ms) is what the viewer uses.
* The container **restarts every 30–40 minutes** and takes the emulator with
  it; the supervisor brings it back.
* The release still needs a human to tap "Allow" four times on first start.

---

## 11. Where things are

| Path | What |
|---|---|
| `/workspaces/empty-repo/` | this repository (the app + the VS Code extension + the docs) |
| `/workspaces/empty-repo/app/` | the Flutter app |
| `/workspaces/empty-repo/AGENTS.md` | the session-by-session history (§1–§32) |
| `/workspaces/START-HERE.md` | the short "how to work in this project" guide |
| `/workspaces/emu.sh` | start / stop / status the whole stack |
| `/workspaces/supervisor.sh` | the watchdog |
| `/workspaces/emuview.py` | the HTTP screen + input server (:8091) |
| `/workspaces/package-release.sh` | the timestamped release packaging |
| `/workspaces/callnote-fgs-test.sh` | the 13-check test suite |
| `/workspaces/build-callnote.sh` | the release build |
| `/workspaces/.keystore/` | the release keystore (never commit) |

---

## 12. A note on git

Six commits exist. **The work of the last several sessions is not committed
yet** (23 changed/untracked files). Before committing:

* never commit `*.apk`, `*.zip`, `*.jks`, `*.keystore` or `key.properties`
  (the `.gitignore` already covers them),
* never commit the keystore or the passwords,
* the docs (`AGENTS.md`, this file) are meant to be committed.


# 1. Create OpenCode config directory mkdir -p ~/.config/opencode # 2. Backup existing configuration if present [ -f ~/.config/opencode/opencode.json ] && cp ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.bak # 3. Add Notion MCP server opencode mcp add notion --url https://mcp.notion.com/mcp # 4. Authenticate with Notion opencode mcp auth notion # 5. Verify MCP connection opencode mcp list # 6. Start OpenCode opencode

