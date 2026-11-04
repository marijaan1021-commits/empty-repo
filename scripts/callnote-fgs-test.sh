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

# Step 5 renames the supervisor script out of the way so nothing restarts it
# during the reboot. If the test is interrupted (or the container is reset)
# the file has to go back, or the stack never starts again.
restore_supervisor() {
    if [ -f /workspaces/supervisor.sh.testoff ] && [ ! -f /workspaces/supervisor.sh ]; then
        mv /workspaces/supervisor.sh.testoff /workspaces/supervisor.sh
    fi
}
trap restore_supervisor EXIT

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

# The whole notification dump - title AND body.
#
# The reminder's body is the note itself, so matching on the note text proves
# that the notification came from CallNote. Matching on the contact name
# would not: the dialer's own "Missed call" notification also contains it.
has_notification_text() {
    $A shell dumpsys notification --noredact 2>/dev/null | grep -qi "$1"
}

process_alive() {
    $A shell pidof "$PKG" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Fixtures
#
# The test needs two things that a fresh install does NOT have:
#
#   1. a note for the test contact, in files/callnote.json
#   2. the watcher switched on, in shared_prefs/callnote.xml
#
# Without them the suite is meaningless: no note means no reminder, and
# without the note the assertions in steps 3 and 4 pass for the wrong reason
# (the dialer's own incoming-call notification also contains the contact
# name). Both live in the app's private storage, so they are written with
# `adb root` (the emulator allows it) while the app is stopped.
# ---------------------------------------------------------------------------
NOTE_ID=test-note-1
NOTE_JSON='[{"id":"test-note-1","contactId":"1","name":"Batman","numbers":["5550100"],"text":"test reminder","enabled":true,"updatedAt":0}]'
PREFS_XML='<?xml version='"'"'1.0'"'"' encoding='"'"'utf-8'"'"' standalone='"'"'yes'"'"' ?>
<map>
    <boolean name="monitoring_enabled" value="true" />
</map>'

prepare_fixtures() {
    step "0. preparing the fixtures (note + watcher)"

    # adb root restarts adbd, so the device drops off for a moment.
    $A root >/dev/null 2>&1
    $A wait-for-device >/dev/null 2>&1
    sleep 2

    # The app must not be running while its files are replaced.
    $A shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1

    uid=$($A shell "stat -c %u /data/data/$PKG" 2>/dev/null | tr -d '\r')
    gid=$($A shell "stat -c %g /data/data/$PKG" 2>/dev/null | tr -d '\r')
    if [ -z "$uid" ]; then
        bad "could not read the app's data directory (is the app installed?)"
        return 1
    fi

    $A shell "mkdir -p /data/data/$PKG/files /data/data/$PKG/shared_prefs" >/dev/null 2>&1
    printf '%s' "$NOTE_JSON" | $A shell "cat > /data/data/$PKG/files/callnote.json" 2>/dev/null
    printf '%s' "$PREFS_XML" | $A shell "cat > /data/data/$PKG/shared_prefs/callnote.xml" 2>/dev/null
    # the files were written as root - the app may not read them otherwise
    $A shell "chown $uid:$gid /data/data/$PKG/files/callnote.json /data/data/$PKG/shared_prefs/callnote.xml" >/dev/null 2>&1
    $A shell "chmod 600 /data/data/$PKG/files/callnote.json /data/data/$PKG/shared_prefs/callnote.xml" >/dev/null 2>&1

    got=$($A shell "cat /data/data/$PKG/files/callnote.json" 2>/dev/null | tr -d '\r')
    case "$got" in
        *'"5550100"'*) ok "note for Batman (5550100) is in place" ;;
        *)             bad "the note file was not written" ;;
    esac
    mon=$($A shell "cat /data/data/$PKG/shared_prefs/callnote.xml" 2>/dev/null | tr -d '\r')
    case "$mon" in
        *'monitoring_enabled'*) ok "the watcher is switched on" ;;
        *)                      bad "the preferences file was not written" ;;
    esac

    # The emulator's radio has to be registered, or the simulated calls never
    # reach OFFHOOK and the phone state never fires.
    $A emu gsm operator 310260 >/dev/null 2>&1
    sleep 1
    reg=$($A shell dumpsys telephony.registry 2>/dev/null | grep -m1 "mVoiceRegState=" | tr -d '\r')
    case "$reg" in
        *"mVoiceRegState=0"*) ok "the radio is registered" ;;
        *)                    bad "the radio is not registered ($reg)" ;;
    esac

    # An outgoing call that is still up makes the next incoming call a
    # "waiting" call: the phone stays in OFFHOOK and never rings, so no
    # reminder is posted. End whatever is still running.
    $A shell input keyevent KEYCODE_ENDCALL >/dev/null 2>&1
    $A emu gsm cancel 5550100 >/dev/null 2>&1
    sleep 2
}

prepare_fixtures

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
# The service is created a moment after the activity starts, and the emulator
# is slow (software renderer). Poll instead of guessing a sleep.
for i in $(seq 1 15); do
    service_running && service_is_foreground && break
    sleep 2
done
sleep 1
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
# Make sure nothing is still in a call, or the incoming call below would
# only be a "waiting" call and the phone would never ring.
$A shell input keyevent KEYCODE_ENDCALL >/dev/null 2>&1
sleep 1
$A emu gsm call 5550100 >/dev/null 2>&1
sleep 7
if has_notification_text "test reminder"; then
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
if has_notification_text "test reminder"; then
    ok "reminder for the outgoing call appeared"
else
    bad "no reminder for the outgoing call"
    echo "        titles: $(notification_titles | tr '\n' '|')"
fi
$A emu gsm cancel 5550100 >/dev/null 2>&1
# End the outgoing call as well. A call that stays up turns the next
# incoming call into a "waiting" call, and the phone never rings.
$A shell input keyevent KEYCODE_ENDCALL >/dev/null 2>&1
sleep 2

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
    # NOTE: do NOT "am force-stop" the app here. A force-stopped package is in
    # the "stopped" state, and a package in that state does NOT receive
    # BOOT_COMPLETED - so the boot receiver would never run and the test
    # would prove nothing. "adb reboot" kills all processes anyway.
    sleep 2
    # Make sure the device is responsive, then remember how long it has been
    # up. A reboot command that is sent while adbd is restarting is lost, and
    # a guest that never rebooted makes this whole step meaningless.
    $A wait-for-device >/dev/null 2>&1
    pre=$($A shell cat /proc/uptime 2>/dev/null | awk '{print int($1)}' | tr -d '\r')
    $A reboot >/dev/null 2>&1
    $A wait-for-device >/dev/null 2>&1
    # wait for the system to finish booting
    for i in $(seq 1 60); do
        b=$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$b" = "1" ] && break
        sleep 5
    done
    post=$($A shell cat /proc/uptime 2>/dev/null | awk '{print int($1)}' | tr -d '\r')
    if [ -n "$pre" ] && [ -n "$post" ] && [ "$post" -ge "$pre" ]; then
        echo "        the guest did not actually reboot (uptime $pre -> $post) - retrying"
        $A reboot >/dev/null 2>&1
        $A wait-for-device >/dev/null 2>&1
        for i in $(seq 1 60); do
            b=$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
            [ "$b" = "1" ] && break
            sleep 5
        done
    fi
    echo "        boot_completed=$b (waited $((i*5))s)"

    # Since Android 8, BOOT_COMPLETED is only delivered after the device has
    # been unlocked for the first time after the boot - the emulator comes up
    # on the keyguard, and the supervisor that normally swipes it away was
    # just killed on purpose. So the test unlocks it, exactly like the user
    # would with a finger. It takes a couple of tries.
    for i in $(seq 1 12); do
        $A shell input keyevent 224 >/dev/null 2>&1
        $A shell wm dismiss-keyguard >/dev/null 2>&1
        $A shell input swipe 160 500 160 60 200 >/dev/null 2>&1
        locked=$($A shell dumpsys window 2>/dev/null | grep -m1 "isKeyguardShowing" | grep -c "true")
        [ "$locked" = "0" ] && break
        sleep 5
    done
    echo "        the keyguard was dismissed after $((i*5))s"

    # The broadcast goes out on the unlock, but the delivery can take a
    # minute. Keep appending the log, because the ring buffer is recycled
    # and the line can roll out of it.
    BOOTLOG=/tmp/callnote-boot.log
    : >"$BOOTLOG"
    fired=0
    for i in $(seq 1 24); do
        $A logcat -d -s CallNote:I >>"$BOOTLOG" 2>/dev/null
        if grep -q "boot: starting monitor service" "$BOOTLOG"; then fired=1; break; fi
        sleep 5
    done
    if [ "$fired" = "1" ]; then
        ok "the boot receiver fired (logcat proves it)"
    else
        bad "the boot receiver did not fire"
        echo "        logcat: $(tail -3 "$BOOTLOG" | tr '\n' '|')"
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
    for i in $(seq 1 24); do
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
