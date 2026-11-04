#!/usr/bin/env bash
# Full cold-start test: destroy the whole stack, then prove that the single
# documented command brings everything back by itself.
#
#   bash /workspaces/coldstart-test.sh
#
# Kills: supervisor, emulator, viewers, adb server.
# Leaves: the VS Code server / extension host (in a real container restart
#         those die too, and the extension re-activates itself on startup).
set -u
A=/workspaces/android-sdk/platform-tools/adb
CS=${CODESPACE_NAME:-$(gh codespace list --json name -q '.[0].name' 2>/dev/null)}
CS=${CS:-zany-space-carnival-p79jxxwgj4wvfr95j}

echo "### 1. destroying everything"
[ -f /tmp/supervisor.pid ] && kill "$(cat /tmp/supervisor.pid)" 2>/dev/null && echo "  supervisor killed"
for p in $(pgrep -x qemu-system-x86); do kill -9 "$p" 2>/dev/null && echo "  emulator killed ($p)"; done
for p in $(pgrep -f "[e]muview.py"); do kill -9 "$p" 2>/dev/null && echo "  viewer killed ($p)"; done
$A kill-server >/dev/null 2>&1 && echo "  adb server killed"
sleep 3

echo "### 2. running the one documented command"
bash /workspaces/ensure-up.sh

echo "### 3. waiting for the stack (cold boot = 60-140 s)"
ok=0
for i in $(seq 1 40); do
  sleep 10
  b=$(timeout 8 $A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  st=$(timeout 5 curl -s -m 3 http://127.0.0.1:8091/status 2>/dev/null | head -c 60)
  if [ "$b" = "1" ] && [ -n "$st" ]; then
    echo "  t+$((i*10))s booted, viewer: $st"
    ok=1
    break
  fi
  echo "  t+$((i*10))s booting..."
done

echo "### 4. result"
[ "$ok" = "1" ] || { echo "  FAILED: the stack did not come up"; exit 1; }
echo "  supervisor:      $(cat /tmp/supervisor.pid 2>/dev/null) (pid)"
echo "  app foreground:  $(timeout 10 $A shell dumpsys window 2>/dev/null | grep -m1 -o "${APP_PKG:-no.app.configured}[^ ]*" || echo 'none installed')"
echo "  frame:           $(timeout 15 $A exec-out screencap -p 2>/dev/null | wc -c) bytes (0 = black screen)"
timeout 30 gh codespace ports -c "$CS" 2>/dev/null | grep 8091 | sed 's/^/  port:           /'
echo "  public URL:      HTTP $(timeout 20 curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$CS-8091.app.github.dev/status")"
echo "  extension frames: $(grep -o 'frame [0-9]*' /tmp/emulator-view.log 2>/dev/null | tail -1)"
