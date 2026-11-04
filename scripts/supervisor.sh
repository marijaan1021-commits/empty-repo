#!/usr/bin/env bash
# Keeps the whole emulator stack alive.
#
#   bash /workspaces/supervisor.sh
#
# Watches, in a loop:
#   1. the Android emulator  -> relaunches it if qemu died
#   2. the Flutter app       -> relaunches it if the process died
#   3. the emuview server    -> relaunches it if it died
#
# The viewer is restarted whenever the emulator was restarted, because
# emuview.capture_loop() exits permanently once it starts without a device.
#
# Safe to run more than once: run-all.sh only launches one instance and
# writes its pid to /tmp/supervisor.pid.
set -u

ADB=/workspaces/android-sdk/platform-tools/adb
EMU=/workspaces/android-sdk/emulator/emulator
# The AVD lives outside $HOME, so the emulator has to be told where to look -
# otherwise it aborts with "Unknown AVD name [testavd]".
export ANDROID_AVD_HOME=/workspaces/android-avd
# The app under test. Empty by default - the stack then only runs the
# emulator and the viewer. Set APP_PKG (and APP_APK) to have the supervisor
# install, launch and keep an app alive.
APP_DIR=${APP_DIR:-/workspaces/mini_app}
APK=${APP_APK:-$APP_DIR/build/app/outputs/flutter-apk/app-release.apk}
PKG=${APP_PKG:-}
VIEW_PORT=8091
ALT_PORT=9123
LOG=/tmp/supervisor.log
PIDFILE=/tmp/supervisor.pid
# how many consecutive checks the device may be missing before we act
MISS_THRESHOLD=3

say() { echo "[$(date +%H:%M:%S)] $*" >>"$LOG"; }

# Every adb call is wrapped in `timeout`. A booting or wedged emulator makes
# `adb shell` hang for minutes; without a timeout one such call stalls the
# whole supervisor loop (and the viewer's /status), which looks like the
# stack is dead.
dev_up() { timeout 20 $ADB devices 2>/dev/null | grep -qE '^emulator-[0-9]+[[:space:]]+device'; }
# The emulator shows up as 'offline' while it is still booting. Treating that
# as 'not there' makes the supervisor start a SECOND emulator, which fights the
# first one over the AVD lock. Any 'emulator-XXXX' line means an emulator exists.
dev_present() { timeout 20 $ADB devices 2>/dev/null | grep -qE '^emulator-[0-9]+'; }
dev_booted() { [ "$(timeout 20 $ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
app_up() { [ -n "$PKG" ] && [ -n "$(timeout 20 $ADB shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; }
# Is there an app to manage at all? Without APP_PKG there is none: the stack
# simply runs the emulator and shows the launcher, and must NOT keep trying to
# install or launch a package that does not exist.
app_present() {
  [ -n "$PKG" ] || return 1
  [ -f "$APK" ] && return 0
  timeout 20 $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"
}
# The app can be alive but sitting in the background (a BACK key press or a
# swipe on the launcher does that). Then it looks healthy but nothing is
# visible on the screen. Check what is actually in the foreground.
app_foreground() {
  [ -n "$PKG" ] && timeout 20 $ADB shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*$PKG"
}
viewer_up() { curl -sf -m 3 -o /dev/null "http://127.0.0.1:$VIEW_PORT/status" 2>/dev/null; }
alt_viewer_up() { curl -sf -m 3 -o /dev/null "http://127.0.0.1:$ALT_PORT/status" 2>/dev/null; }

# Is the emulated radio registered with an operator? mVoiceRegState=0 is
# IN_SERVICE. An unregistered radio silently drops every simulated call.
radio_registered() {
  timeout 20 $ADB shell dumpsys telephony.registry 2>/dev/null | grep -q "mVoiceRegState=0"
}

# Is a qemu process alive at all? An emulator that is still booting is not in
# `adb devices` yet, so the device check alone is not enough to decide that
# the emulator is gone. Launching a second one would kill the first.
emulator_proc() { pgrep -f 'qemu-system-x86_64-headless' >/dev/null 2>&1; }

start_emulator() {
  say "emulator down - launching"
  rm -rf /home/codespace/.android/avd/running 2>/dev/null
  setsid nohup "$EMU" @testavd -no-window -no-boot-anim -gpu swiftshader_indirect \
    -no-snapshot \
    >>/tmp/emulator.log 2>&1 </dev/null &
  disown
  for _ in $(seq 1 60); do dev_up && break; sleep 5; done
  for _ in $(seq 1 40); do dev_booted && break; sleep 5; done
  say "emulator up: $($ADB devices 2>/dev/null | grep emulator- | head -1)"
}

start_app() {
  # Nothing to launch: no APK on disk and nothing installed on the device.
  if ! app_present; then
    say "no app to install (APK missing at $APK)"
    return 0
  fi
  if ! timeout 30 $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"; then
    if [ -f "$APK" ]; then
      say "installing $PKG"
      timeout 180 $ADB install -r "$APK" >/dev/null 2>&1
    else
      say "WARN: $PKG not installed and APK missing"
    fi
  fi
  timeout 30 $ADB shell am force-stop "$PKG" >/dev/null 2>&1
  # Impeller off: it runs on SwiftShader (software Vulkan) and pins qemu at ~75%
  # CPU, which makes SystemUI/system_server ANR. Same extra flutter uses for
  # `flutter run --no-enable-impeller`.
  timeout 60 $ADB shell am start -n "$PKG$APP_ACTIVITY" --ez enable-impeller false >/dev/null 2>&1
  say "app launched"
}
tune_device() {
  # The emulator's radio has to be registered with an operator before it will
  # accept a simulated call: without this, `adb emu gsm call` is accepted by
  # the console but no call ever rings and the call log stays empty.
  if ! radio_registered; then
    say "radio not registered - setting operator"
    timeout 30 $ADB emu gsm operator 310260 >/dev/null 2>&1
  fi
  # Animations off: SystemUI ANRs constantly under the software GPU.
  timeout 30 $ADB shell settings put global window_animation_scale 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global transition_animation_scale 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global animator_duration_scale 0 >/dev/null 2>&1
  # Suppress "Process system isn't responding" / "System UI isn't responding"
  # dialogs. They otherwise cover the app right after a boot, because the
  # emulator is heavily loaded while the system comes up.
  timeout 30 $ADB shell settings put global hide_error_dialogs 1 >/dev/null 2>&1
  # Keep the screen on. A sleeping display hands out an all-black frame, so
  # the user would look at a black browser tab while everything is fine.
  timeout 30 $ADB shell svc power stayon true >/dev/null 2>&1
  timeout 30 $ADB shell settings put global stay_on_while_plugged_in 1 >/dev/null 2>&1
  # Never let the display time out and never doze on the lock screen: a dozing
  # device returns an all-black frame from EVERY capture path (adb screencap
  # and the gRPC getScreenshot alike) while the emulator looks healthy.
  timeout 30 $ADB shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global low_power 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1
  timeout 30 $ADB shell locksettings set-disabled true >/dev/null 2>&1
  timeout 30 $ADB shell dumpsys deviceidle disable >/dev/null 2>&1
}

# True when the current frame is (almost) entirely black. screen-check.py
# exits 0 when the picture has content and 1 when it is blank.
#
# It reads the viewer's frame, which is captured over the emulator's gRPC
# service (~25 ms, no guest work). "adb exec-out screencap" costs ~800 ms and
# can hang for 30 s when the guest is stalled, which would block the whole
# supervisor loop.
#
# A missing or empty frame is NOT treated as black: the viewer may simply not
# have a frame yet, and relaunching the app for that would be wrong.
# True while the phone is in a call (1 = ringing, 2 = off-hook).
#
# The black-screen watchdog must not act during a call: the dialer's in-call
# screen is dark, so the frame looks black, and relaunching the app there
# would kill the phone state listener - the exact moment the app has to
# notice the call.
call_active() {
  timeout 15 $ADB shell dumpsys telephony.registry 2>/dev/null \
    | grep -m1 "mCallState=" | grep -qvE "mCallState=0([[:space:]]|$)"
}

screen_blank() {
  local tmp=/tmp/sup-screen.png
  curl -sf -m 5 -o "$tmp" "http://127.0.0.1:$VIEW_PORT/frame" 2>/dev/null || return 1
  [ -s "$tmp" ] || return 1
  python3 /workspaces/screen-check.py <"$tmp" >/dev/null 2>&1
  [ $? -ne 0 ]
}

# Recover from a black screen: wake the display, drop the keyguard and
# relaunch the app. A dozing or wedged Flutter app stops drawing, and every
# capture then returns solid black even though the emulator looks fine.
recover_screen() {
  say "screen is black - waking the display and relaunching the app"
  timeout 30 $ADB shell input keyevent 224 >/dev/null 2>&1
  timeout 30 $ADB shell wm dismiss-keyguard >/dev/null 2>&1
  timeout 30 $ADB shell svc power stayon true >/dev/null 2>&1
  timeout 30 $ADB shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1
  timeout 30 $ADB shell dumpsys deviceidle disable >/dev/null 2>&1
  if app_present; then
    timeout 30 $ADB shell am force-stop "$PKG" >/dev/null 2>&1
    timeout 60 $ADB shell am start -n "$PKG$APP_ACTIVITY" --ez enable-impeller false >/dev/null 2>&1
    say "app relaunched"
  else
    say "no app installed - woke the display only"
  fi
}

start_viewer() {
  # The extension host may own :8091 (it must be in the VS Code process tree
  # for the Codespaces port-forwarding agent to pick it up). Never fight it
  # for the port.
  if viewer_up; then return; fi
  say "viewer down - launching"
  setsid nohup python3 /workspaces/emuview.py >>/tmp/emuview.log 2>&1 </dev/null &
  disown
  for _ in $(seq 1 15); do viewer_up && break; sleep 1; done
  say "viewer up on :$VIEW_PORT"
}

# Tailscale carries the Notedog traffic to the phone. The container reset
# kills tailscaled, and the journal then fails with "fetch failed". The node
# state is on the persistent volume, so it reconnects without a browser login.
# Only the full script when the daemon is actually gone; otherwise just
# re-resolve the phone's IP occasionally (it changes if the phone re-auths).
tailscale_daemon_down() { ! pgrep -x tailscaled >/dev/null 2>&1; }

echo $$ >"$PIDFILE"
say "supervisor started (pid $$)"

miss=0
tick=0
blank=0
while true; do
  $ADB start-server >/dev/null 2>&1

  # Keep the viewers bound REGARDLESS of the emulator state. The Codespaces
  # port-forwarding agent only scans for listening ports at container start,
  # so the port has to be bound early - it may serve empty frames for a
  # couple of minutes until the emulator finishes booting.
  viewer_up || start_viewer

  if dev_up; then
    miss=0
    dev_booted || { sleep 5; continue; }
    tune_device
    # Only manage the app when there actually IS one. After the test app was
    # removed there is no APK and nothing installed, and the device just shows
    # the launcher - launching a missing package every 8 s would be noise.
    #
    # Only a DEAD process is restarted. An app that is merely in the background
    # is left alone: an app that reacts to calls has to keep running while a
    # call is in progress, and pulling it to the foreground would hide the
    # dialer.
    if app_present && ! app_up; then
      timeout 30 $ADB shell am start -n "$PKG$APP_ACTIVITY" --ez enable-impeller false >/dev/null 2>&1
      app_up || start_app
    fi

    # Black-screen watchdog. The app can be alive, focused and healthy while
    # the display is dozing - then every capture returns solid black and the
    # user sees a black page. Three checks in a row and the display is woken
    # and the app relaunched.
    if screen_blank; then
      blank=$((blank + 1))
      if [ "$blank" -ge 3 ] && ! call_active; then
        blank=0
        recover_screen
      fi
    else
      blank=0
    fi
  else
    miss=$((miss + 1))
    if dev_present || emulator_proc; then
      # a qemu is alive but not yet attached to adb - it is still booting.
      # Do NOT start a second one: that would kill this one.
      [ "$miss" -ge "$MISS_THRESHOLD" ] && say "emulator still attaching (qemu alive)"
      sleep 8
      continue
    fi
    if [ "$miss" -ge "$MISS_THRESHOLD" ]; then
      miss=0
      start_emulator
      tune_device
      start_app
      start_viewer
    else
      sleep 8
    fi
  fi

  # ---- keep Tailscale (and therefore Notedog) alive ----------------------
  # tailscale-up.sh is not part of the repository - it only exists on the
  # machine that runs the Notedog bridge. Skip it when it is missing instead
  # of writing an error to the log on every single tick.
  if [ -f /workspaces/tailscale-up.sh ]; then
    if tailscale_daemon_down; then
      say "tailscaled is down - restarting"
      bash /workspaces/tailscale-up.sh >>"$LOG" 2>&1
    elif [ $((tick % 10)) -eq 0 ]; then
      # The phone's Tailscale IP changes if it re-authenticates; re-resolve it
      # now and then so the MCP server never points at a stale address.
      bash /workspaces/tailscale-up.sh >>"$LOG" 2>&1
    fi
  fi

  # ---- keep the viewer port PUBLIC -------------------------------------
  # Port visibility resets when the Codespace reconnects or the port is
  # re-forwarded. Re-assert it here so the URL keeps working with no human
  # in the loop. Cheap and idempotent; runs every ~48s plus the first ticks.
  tick=$((tick + 1))
  if [ "$tick" -le 3 ] || [ $((tick % 6)) -eq 0 ]; then
    if bash /workspaces/ensure-public.sh "$VIEW_PORT" >/dev/null 2>&1; then
      say "port $VIEW_PORT is public"
    fi
  fi

  sleep 8
done
