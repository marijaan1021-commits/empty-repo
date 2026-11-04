#!/usr/bin/env bash
# Verify the whole emulator stack in one shot.
#   bash /workspaces/verify.sh
# The codespace name changes when the Codespace is recreated, so read it from
# the environment first and only fall back to the old name.
CS=${CODESPACE_NAME:-$(gh codespace list --json name -q '.[0].name' 2>/dev/null)}
CS=${CS:-zany-space-carnival-p79jxxwgj4wvfr95j}
ADB=/workspaces/android-sdk/platform-tools/adb

echo "== emulator =="
timeout 15 $ADB devices
echo "boot_completed: $(timeout 10 $ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
if timeout 10 $ADB shell pm list packages 2>/dev/null | grep -q 'package:com.example.mini_app'; then
  echo "app pid: $(timeout 10 $ADB shell pidof com.example.mini_app 2>/dev/null | tr -d '\r')"
else
  echo "app: not installed (expected - the test app was removed)"
fi

echo
echo "== extension host =="
EP=$(pgrep -f 'bootstrap-fork --type=extension[H]ost' | head -1)
echo "extension host pid: ${EP:-none}"
tail -6 /tmp/emulator-view.log 2>/dev/null

echo
echo "== capture path (last frames) =="
grep -o "frame [0-9]* ([^)]*)" /tmp/emulator-view.log 2>/dev/null | tail -3

echo
echo "== viewer =="
timeout 10 curl -s -m 8 http://127.0.0.1:8091/status; echo

echo
echo "== forwarded ports =="
timeout 30 gh codespace ports -c "$CS" 2>/dev/null | grep -E '8091|8099' || echo "8091 NOT forwarded"

echo
echo "== public URL =="
timeout 20 curl -s -o /dev/null -w "http=%{http_code}\n" -m 15 \
  "https://$CS-8091.app.github.dev/status"
