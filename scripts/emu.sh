#!/usr/bin/env bash
# One command to bring up the whole Android emulator stack.
#
#   bash /workspaces/emu.sh              # start everything (default)
#   bash /workspaces/emu.sh start        # same
#   bash /workspaces/emu.sh status       # health check
#   bash /workspaces/emu.sh stop         # stop everything
#   bash /workspaces/emu.sh restart      # stop + start
#   bash /workspaces/emu.sh url          # print the public URL
#   bash /workspaces/emu.sh logs         # tail the logs
#
# Idempotent: running it when everything is already up changes nothing.
# It also starts the supervisor, which relaunches whatever dies afterwards.
set -u

ADB=/workspaces/android-sdk/platform-tools/adb
EMU=/workspaces/android-sdk/emulator/emulator
APK=/workspaces/mini_app/build/app/outputs/flutter-apk/app-release.apk
PKG=com.example.mini_app
ACT=$PKG/.MainActivity
PORT=8091
ALT_PORT=9123
SUP=/workspaces/supervisor.sh
PIDFILE=/tmp/supervisor.pid
CS=${CODESPACE_NAME:-$(env | grep '^CODESPACE_NAME=' | cut -d= -f2)}

say()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }
err()  { echo "  FAIL  $*"; }

# ---------------------------------------------------------------- helpers
# `ps -eo args` + a bracket in the pattern, so the pattern never matches the
# shell that is running this script.
alive() { ps -eo args --no-headers | grep -q "$1"; }

# The supervisor writes its pid to a file; check /proc/<pid>/cmdline too, so a
# recycled pid is not mistaken for the supervisor.
sup_alive() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'supervisor\.sh'
}

# Is anything listening on the port? The VS Code extension starts its own
# viewer as plain "python3 /workspaces/emuview.py", so matching on the argv
# would miss it and we would start a duplicate that dies with EADDRINUSE.
port_bound() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

viewer_up()  { curl -sf -m 3 -o /dev/null "http://127.0.0.1:$PORT/status" 2>/dev/null; }
dev_present(){ timeout 20 $ADB devices 2>/dev/null | grep -qE '^emulator-[0-9]+'; }
dev_up()     { timeout 20 $ADB devices 2>/dev/null | grep -qE '^emulator-[0-9]+[[:space:]]+device'; }
dev_booted() { [ "$(timeout 20 $ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
app_up()     { [ -n "$(timeout 20 $ADB shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; }
app_front()  { timeout 20 $ADB shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*$PKG"; }
# The app is optional. After the test app was removed there is no APK and
# nothing installed, and the device just shows the launcher.
app_present(){ [ -f "$APK" ] || timeout 20 $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"; }

# True when the screen shows something.
#
# It reads the viewer's frame, which is captured over the emulator's gRPC
# service: ~25 ms and no guest work. "adb exec-out screencap" can take 800 ms
# - and hang for 30 s when the guest is stalled - so it is only the fallback.
screen_has_content() {
  local tmp=/tmp/emu-screen.png
  if curl -sf -m 5 -o "$tmp" "http://127.0.0.1:$PORT/frame" 2>/dev/null && [ -s "$tmp" ]; then
    python3 /workspaces/screen-check.py <"$tmp" >/dev/null 2>&1 && return 0
    return 1
  fi
  timeout 10 $ADB exec-out screencap -p >"$tmp" 2>/dev/null
  python3 /workspaces/screen-check.py <"$tmp" >/dev/null 2>&1
}

# ---------------------------------------------------------------- start
start_viewer() {
  if port_bound "$PORT"; then
    ok "viewer already listening on :$PORT"
    return 0
  fi
  setsid nohup env EMUVIEW_PORT="$PORT" python3 /workspaces/emuview.py \
    >>/tmp/emuview.log 2>&1 </dev/null &
  disown
  for _ in $(seq 1 15); do viewer_up && break; sleep 1; done
  if viewer_up; then ok "viewer up on :$PORT"; else warn "viewer did not answer on :$PORT (see /tmp/emuview.log)"; fi
}

start_emulator() {
  if dev_up; then
    ok "emulator already running"
  else
    rm -rf /home/codespace/.android/avd/running 2>/dev/null
    say "starting emulator (cold boot, 60-140s)"
    setsid nohup "$EMU" @testavd -no-window -no-boot-anim -gpu swiftshader_indirect \
      -no-snapshot-save -no-snapshot-load \
      >>/tmp/emulator.log 2>&1 </dev/null &
    disown
    for _ in $(seq 1 60); do dev_up && break; sleep 5; done
  fi
  if ! dev_up; then err "emulator did not come up (see /tmp/emulator.log)"; return 1; fi
  ok "device: $(timeout 20 $ADB devices 2>/dev/null | grep emulator- | head -1)"

  for _ in $(seq 1 40); do dev_booted && break; sleep 5; done
  if dev_booted; then ok "boot_completed=1"; else warn "boot_completed is not 1 yet (it may still be booting)"; fi
}

tune_device() {
  # Animations off: SystemUI ANRs constantly under the software GPU.
  timeout 30 $ADB shell settings put global window_animation_scale 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global transition_animation_scale 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global animator_duration_scale 0 >/dev/null 2>&1
  # Suppress the "Process system isn't responding" dialogs, which otherwise
  # cover the app right after a boot.
  timeout 30 $ADB shell settings put global hide_error_dialogs 1 >/dev/null 2>&1
  # Keep the screen on. A sleeping display hands out an all-black frame, so
  # the browser would show a black screen while everything is actually fine.
  timeout 30 $ADB shell svc power stayon true >/dev/null 2>&1
  timeout 30 $ADB shell settings put global stay_on_while_plugged_in 1 >/dev/null 2>&1
  # Never let the display time out, and never let the device doze on the lock
  # screen: a dozing device returns an all-black frame from EVERY capture
  # path (adb screencap and the gRPC getScreenshot alike) while the emulator
  # itself looks perfectly healthy.
  timeout 30 $ADB shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1
  timeout 30 $ADB shell settings put global low_power 0 >/dev/null 2>&1
  timeout 30 $ADB shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1
  timeout 30 $ADB shell locksettings set-disabled true >/dev/null 2>&1
  timeout 30 $ADB shell dumpsys deviceidle disable >/dev/null 2>&1
  timeout 30 $ADB shell input keyevent 224 >/dev/null 2>&1
  timeout 30 $ADB shell wm dismiss-keyguard >/dev/null 2>&1
}

start_app() {
  if ! app_present; then
    ok "no app installed (nothing to launch)"
    return 0
  fi

  if timeout 30 $ADB shell pm list packages 2>/dev/null | grep -q "package:$PKG"; then
    ok "app installed"
  elif [ -f "$APK" ]; then
    say "installing app"; timeout 180 $ADB install -r "$APK" 2>&1 | tail -1
  else
    warn "APK missing at $APK"
  fi

  if app_up && app_front; then
    ok "app running in foreground"
  else
    timeout 30 $ADB shell am force-stop "$PKG" >/dev/null 2>&1
    # Impeller off: it runs on SwiftShader (software Vulkan) and pins qemu at
    # ~75% CPU, which makes SystemUI/system_server ANR.
    timeout 60 $ADB shell am start -n "$ACT" --ez enable-impeller false >/dev/null 2>&1
    for _ in $(seq 1 15); do app_up && break; sleep 2; done
    app_up && ok "app launched" || warn "app did not start (check: $ADB logcat -d | grep -i mini_app)"
  fi

  # Wait for the app to actually draw. A just-started Flutter app on a
  # software renderer can hand out an all-black frame for a few seconds, and
  # "READY" on top of a black screen is worse than waiting.
  for _ in $(seq 1 10); do
    if screen_has_content; then
      ok "screen shows the app"
      break
    fi
    sleep 2
  done

  for _ in 1 2 3; do
    timeout 20 $ADB shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1
    sleep 1
  done
}

start_supervisor() {
  if sup_alive; then
    ok "supervisor already running (pid $(cat "$PIDFILE" 2>/dev/null))"
    return 0
  fi
  setsid nohup bash "$SUP" >/tmp/supervisor.out 2>&1 </dev/null &
  disown
  sleep 2
  if sup_alive; then ok "supervisor up (pid $(cat "$PIDFILE" 2>/dev/null))"
  else warn "supervisor failed to start (see /tmp/supervisor.log)"; fi
}

make_public() {
  say "making port $PORT public"
  if timeout 90 bash /workspaces/ensure-public.sh "$PORT" >/dev/null 2>&1; then
    ok "port $PORT is public"
  else
    warn "could not set visibility yet (see /tmp/ensure-public.log) - the supervisor retries"
  fi
}

cmd_start() {
  echo "== Android emulator stack =="

  if [ ! -r /dev/kvm ] || ! sg kvm -c true 2>/dev/null; then
    say "restoring KVM permissions"
    bash /workspaces/bootstrap.sh >/tmp/bootstrap.log 2>&1 || warn "bootstrap warnings (see /tmp/bootstrap.log)"
  fi
  sg kvm -c true 2>/dev/null && ok "KVM ok" || warn "KVM not accessible (the emulator will be slow)"

  $ADB start-server >/dev/null 2>&1

  # Bind the viewer FIRST. The Codespaces port-forwarding agent scans for
  # listening ports once, at container start; a port bound later is never
  # forwarded. The viewer idles until a device shows up, so binding it early
  # is safe and is what makes the public URL work.
  start_viewer

  start_emulator || return 1
  tune_device
  start_app
  start_supervisor
  make_public

  echo
  echo "  READY  ->  https://${CS}-${PORT}.app.github.dev/"
  echo "  (open it in the browser you are logged into GitHub with)"
  echo "  in-VS-Code tab: command palette -> 'Android Emulator: Open Emulator View'"
  echo
}

# ---------------------------------------------------------------- status
cmd_status() {
  echo "== status =="
  if dev_up; then
    ok "emulator: $(timeout 20 $ADB devices 2>/dev/null | grep emulator- | head -1)"
    dev_booted && ok "boot_completed=1" || warn "still booting"
  else
    err "emulator not running"
  fi
  if app_present; then
    if app_up; then ok "app: pid $(timeout 20 $ADB shell pidof "$PKG" 2>/dev/null | tr -d '\r')"; else err "app not running"; fi
    app_front && ok "app in foreground" || warn "app is in the background"
  else
    ok "no app installed (launcher is showing)"
  fi
  if screen_has_content; then
    ok "screen: $(python3 /workspaces/screen-check.py </tmp/emu-screen.png 2>/dev/null)"
  else
    warn "screen looks blank"
  fi
  if viewer_up; then
    ok "viewer: $(curl -sf -m 3 "http://127.0.0.1:$PORT/status" 2>/dev/null)"
  else
    err "viewer not answering on :$PORT"
  fi
  sup_alive && ok "supervisor: pid $(cat "$PIDFILE" 2>/dev/null)" || warn "supervisor not running"
  timeout 30 gh codespace ports -c "$CS" 2>/dev/null | grep -E "^[[:space:]]*${PORT}" || true
}

# ---------------------------------------------------------------- stop
cmd_stop() {
  echo "== stopping =="
  if sup_alive; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && ok "supervisor stopped"
  else
    ok "supervisor not running"
  fi
  # Kill by pid, never with `pkill -f` - that pattern also matches the shell
  # running this script and would kill the script itself.
  for pid in $(pgrep -f '[q]emu-system-x86_64-headless' 2>/dev/null); do
    kill "$pid" 2>/dev/null && ok "emulator stopped (pid $pid)"
  done
  for pid in $(pgrep -f '[e]muview.py' 2>/dev/null); do
    kill "$pid" 2>/dev/null && ok "viewer stopped (pid $pid)"
  done
  timeout 30 $ADB emu kill >/dev/null 2>&1
  echo "done"
}

# ---------------------------------------------------------------- misc
cmd_url() {
  echo "https://${CS}-${PORT}.app.github.dev/"
  echo "https://${CS}-${ALT_PORT}.app.github.dev/   (backup viewer port)"
}

cmd_logs() {
  exec tail -f /tmp/supervisor.log /tmp/emulator.log /tmp/emuview.log /tmp/emulator-view.log
}

case "${1:-start}" in
  start)   cmd_start ;;
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 2; cmd_start ;;
  url)     cmd_url ;;
  logs)    cmd_logs ;;
  *)       echo "usage: bash /workspaces/emu.sh [start|status|stop|restart|url|logs]"; exit 1 ;;
esac
