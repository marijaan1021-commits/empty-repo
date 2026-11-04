#!/usr/bin/env bash
# Brings up the whole emulator stack after any Codespace start/restart.
# Idempotent: safe to run repeatedly, and safe to run with services already up.
#
#   bash /workspaces/run-all.sh
#
# Starts, in order:
#   1. KVM permissions (lost on container rebuild)
#   2. Android emulator (cold boot, 66-135s; snapshots disabled)
#   3. Flutter app (install if missing, then launch)
#   4. emuview HTTP viewer on :8091 (live frames + tap/swipe/key)
set -u

ADB=/workspaces/android-sdk/platform-tools/adb
EMU=/workspaces/android-sdk/emulator/emulator
# The AVD lives outside $HOME - the emulator has to be told where to look.
export ANDROID_AVD_HOME=/workspaces/android-avd
# The app under test - optional. Without APP_PKG the stack just runs the
# emulator and shows the launcher.
APP_DIR=${APP_DIR:-/workspaces/mini_app}
APK=${APP_APK:-$APP_DIR/build/app/outputs/flutter-apk/app-release.apk}
PKG=${APP_PKG:-}
APP_ACTIVITY=${APP_ACTIVITY:-.MainActivity}
VIEW_PORT=8091
CS=${CODESPACE_NAME:-$(env | grep '^CODESPACE_NAME=' | cut -d= -f2)}

say() { echo "[$(date +%H:%M:%S)] $*"; }
alive() { ps -eo args --no-headers | grep -q "$1"; }

# ---- 1. KVM permissions -------------------------------------------------
if [ ! -r /dev/kvm ] || ! sg kvm -c true 2>/dev/null; then
  say "restoring KVM permissions"
  bash /workspaces/bootstrap.sh >/tmp/bootstrap.log 2>&1 || say "bootstrap had warnings (see /tmp/bootstrap.log)"
fi
sg kvm -c true 2>/dev/null && say "KVM ok" || say "WARN: KVM not accessible"

$ADB start-server >/dev/null 2>&1

# ---- 2. Emulator --------------------------------------------------------
dev_up() { $ADB devices 2>/dev/null | grep -qE '^emulator-[0-9]+[[:space:]]+device'; }
dev_boot() { [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

if dev_up; then
  say "emulator already running"
else
  rm -rf /home/codespace/.android/avd/running 2>/dev/null
  say "starting emulator"
  setsid nohup $EMU @testavd -no-window -no-boot-anim -gpu swiftshader_indirect \
    -no-snapshot-save -no-snapshot-load \
    >/tmp/emulator.log 2>&1 </dev/null &
  disown
  for i in $(seq 1 60); do dev_up && break; sleep 5; done
fi

if ! dev_up; then say "ERROR: emulator did not come up"; exit 1; fi
say "device: $($ADB devices | grep emulator- | head -1)"

for i in $(seq 1 40); do dev_boot && break; sleep 5; done
say "boot_completed=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"

# ---- 3. App -------------------------------------------------------------
# Animations off: SystemUI ANRs constantly under software GPU (see notes).
$ADB shell settings put global window_animation_scale 0 >/dev/null 2>&1
$ADB shell settings put global transition_animation_scale 0 >/dev/null 2>&1
$ADB shell settings put global animator_duration_scale 0 >/dev/null 2>&1

# The app is optional. With no APP_PKG there is nothing to manage - the
# emulator then just shows the launcher.
APP_PRESENT=0
if [ -n "$PKG" ]; then
  if [ -f "$APK" ] || $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"; then
    APP_PRESENT=1
  fi
fi

if [ "$APP_PRESENT" = "1" ]; then
  if $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"; then
    say "app already installed"
  elif [ -f "$APK" ]; then
    say "installing app"; $ADB install -r "$APK" 2>&1 | tail -1
  else
    say "WARN: APK missing at $APK"
  fi
  say "launching app"
  # Impeller OFF: it runs on SwiftShader (software Vulkan) here and pins qemu at
  # ~75% CPU, which makes SystemUI/system_server ANR ("Process system isn't
  # responding"). Skia/OpenGL is far lighter. This is the same extra the Flutter
  # tool passes for `flutter run --no-enable-impeller`.
  if [ -n "$($ADB shell pidof $PKG 2>/dev/null | tr -d '\r')" ]; then
    say "app already running"
  else
    $ADB shell am force-stop $PKG >/dev/null 2>&1
    $ADB shell am start -n $PKG$APP_ACTIVITY --ez enable-impeller false >/dev/null 2>&1
  fi
else
  say "no app configured - showing the launcher"
fi

# Dismiss any stale ANR dialogs left over from a previous run.
for i in 1 2 3; do
  $ADB shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1
  sleep 1
done

# ---- 4. Viewer ----------------------------------------------------------
if alive '[e]muview.py'; then
  say "viewer already running"
else
  say "starting viewer on :$VIEW_PORT"
  setsid nohup python3 /workspaces/emuview.py >/tmp/emuview.log 2>&1 </dev/null &
  disown
  for i in $(seq 1 15); do
    curl -sf -m 3 -o /dev/null "http://127.0.0.1:$VIEW_PORT/status" && break
    sleep 1
  done
fi

say "READY -> https://${CS}-${VIEW_PORT}.app.github.dev/"
say "(open that URL in the browser you are logged into GitHub with)"

# ---- 5. Make the port public --------------------------------------------
# Without this the URL redirects to GitHub's sign-in page for anyone who is
# not already logged in. Scriptable via the Codespaces CLI - no UI needed.
say "making port $VIEW_PORT public"
bash /workspaces/ensure-public.sh "$VIEW_PORT" || say "WARN: could not set visibility (see /tmp/ensure-public.log)"

# ---- 5. Supervisor ------------------------------------------------------
# The Codespace container gets reset periodically, which kills qemu, the app
# and the viewer with no error. The supervisor relaunches whatever died, so the
# page keeps showing a live screen instead of a frozen one.
if alive '[s]upervisor.sh'; then
  say "supervisor already running"
else
  say "starting supervisor"
  setsid nohup bash /workspaces/supervisor.sh >/tmp/supervisor.out 2>&1 </dev/null &
  disown
  sleep 2
  alive '[s]upervisor.sh' && say "supervisor up (pid $(cat /tmp/supervisor.pid 2>/dev/null))" \
    || say "WARN: supervisor failed to start (see /tmp/supervisor.log)"
fi
