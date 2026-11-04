#!/bin/bash
# Tests the two new features of CallNote:
#   1. the watcher keeps running after the app is swiped out of recents
#   2. the watcher comes back by itself after a reboot
#
# Usage: bash /workspaces/callnote-fgs-test.sh [swipe|reboot|all]
set -u
A=/workspaces/android-sdk/platform-tools/adb
PKG=com.example.mini_app
MODE="${1:-all}"
PASS=0
FAIL=0

ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "== $1"; }

service_running() {
    $A shell dumpsys activity services "$PKG" 2>/dev/null | grep -q "CallNoteMonitorService"
}

service_is_foreground() {
    $A shell dumpsys activity services "$PKG" 2>/dev/null \
        | grep -A 20 "ServiceRecord.*CallNoteMonitorService" \
        | grep -q "isForeground=true"
}

# Removes the reminder notifications (the monitoring one stays, it is ongoing).
clear_reminders() {
    $A shell service call notification 1 i32 0 >/dev/null 2>&1
    sleep 1
}

# Titles of the notifications this app currently has on screen.
notification_titles() {
    $A shell dumpsys notification --noredact 2>/dev/null \
        | grep -oE "android.title=String \(.*\)" \
        | sed 's/android.title=String (//; s/)$//'
}

has_notification_containing() {
    notification_titles | grep -qi "$1"
}

process_alive() {
    $A shell pidof "$PKG" >/dev/null 2>&1
}

step "1. service + notification are up"

# A fresh install (or a reinstall over a differently-signed build) revokes every
# runtime permission. The app asks for them in the UI; the test grants them
# directly so it does not depend on a human tapping "Allow".
for p in POST_NOTIFICATIONS READ_CONTACTS READ_CALL_LOG READ_PHONE_STATE; do
    $A shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
# Restart the app: a service that started while the permission was missing
# never shows its notification, and the app only (re)starts the watcher when
# it starts up.
$A shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
$A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 6
if service_running; then ok "monitor service exists"; else bad "monitor service missing"; fi
if service_is_foreground; then ok "monitor service is foreground"; else bad "monitor service is not foreground"; fi
if has_notification_containing "watching your calls"; then
    ok "monitoring notification is on screen"
else
    bad "monitoring notification missing"
    echo "        titles: $(notification_titles | tr '\n' '|')"
fi

step "2. app is swiped out of recents"
$A shell input keyevent KEYCODE_APP_SWITCH >/dev/null 2>&1
sleep 3
# swipe the task card away (upwards)
$A shell input swipe 160 400 160 40 200 >/dev/null 2>&1
sleep 5
if process_alive; then
    ok "process is still alive after the swipe"
else
    bad "process was killed by the swipe"
fi
if service_running; then
    ok "monitor service survived the swipe"
else
    bad "monitor service died with the swipe"
fi
if service_is_foreground; then
    ok "monitor service is still foreground"
else
    bad "monitor service is no longer foreground"
fi

step "3. a reminder still arrives with the app swiped away"
clear_reminders
$A emu gsm call 5550100 >/dev/null 2>&1
sleep 7
if has_notification_containing "Batman"; then
    ok "reminder for Batman appeared with the app closed"
else
    bad "no reminder for Batman"
    echo "        titles: $(notification_titles | tr '\n' '|')"
fi
$A emu gsm cancel 5550100 >/dev/null 2>&1
sleep 2

step "4. outgoing call is caught by the call log observer"
clear_reminders
$A shell am start -a android.intent.action.CALL -d tel:5550100 >/dev/null 2>&1
sleep 8
if has_notification_containing "Batman"; then
    ok "reminder for the outgoing call appeared"
else
    bad "no reminder for the outgoing call"
    echo "        titles: $(notification_titles | tr '\n' '|')"
fi
$A emu gsm cancel 5550100 >/dev/null 2>&1

if [ "$MODE" = "reboot" ] || [ "$MODE" = "all" ]; then
    step "5. after a reboot the watcher comes back by itself"
    # The supervisor force-stops and relaunches the app whenever it sees it
    # missing, and "am force-stop" cancels a pending BOOT_COMPLETED for the
    # package. Stop it for the test, otherwise the supervisor would do the
    # job instead of the boot receiver and the test would prove nothing.
    # The script itself is renamed away too - ensure-up.sh starts it again
    # within seconds otherwise.
    # Kill every supervisor, not just the first one - a second instance would
    # still launch the app and the test would prove nothing.
    for p in $(pgrep -f "^bash /workspaces/supervisor\.sh$"); do
        kill "$p" 2>/dev/null
    done
    sleep 3
    echo "        supervisors stopped: $(pgrep -f "^bash /workspaces/supervisor\.sh$" | tr '\n' ' ')"
    [ -f /workspaces/supervisor.sh ] && mv /workspaces/supervisor.sh /workspaces/supervisor.sh.testoff
    $A shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 2
    $A reboot >/dev/null 2>&1
    $A wait-for-device >/dev/null 2>&1
    # wait for the system to finish booting
    for i in $(seq 1 60); do
        b=$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$b" = "1" ] && break
        sleep 5
    done
    echo "        boot_completed=$b (waited $((i*5))s)"
    sleep 25
    if $A logcat -d -s CallNote:I 2>/dev/null | grep -q "boot: starting monitor service"; then
        ok "the boot receiver fired (logcat proves it)"
    else
        bad "the boot receiver did not fire"
        echo "        logcat: $($A logcat -d -s CallNote:I 2>/dev/null | tail -3 | tr '\n' '|')"
    fi
    if process_alive; then
        ok "the app was started by the boot receiver"
    else
        bad "the app was not started after the reboot"
    fi
    # The boot receiver only asks for the service; the service still has to
    # create itself and call startForeground. That takes a moment on a cold
    # boot, so wait for it instead of checking once and giving up.
    fg=0
    for i in $(seq 1 12); do
        if service_is_foreground && has_notification_containing "watching your calls"; then
            fg=1
            break
        fi
        sleep 5
    done
    if service_running; then
        ok "monitor service is running after the reboot"
    else
        bad "monitor service is missing after the reboot"
    fi
    if service_is_foreground; then
        ok "monitor service is foreground after the reboot"
    else
        bad "monitor service is not foreground after the reboot"
    fi
    if has_notification_containing "watching your calls"; then
        ok "monitoring notification is back after the reboot"
    else
        bad "no monitoring notification after the reboot"
    fi
    # put the supervisor back
    [ -f /workspaces/supervisor.sh.testoff ] && mv /workspaces/supervisor.sh.testoff /workspaces/supervisor.sh
    setsid nohup bash /workspaces/supervisor.sh >/tmp/supervisor.out 2>&1 </dev/null &
    sleep 3
    echo "        supervisor restarted"
fi

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
