#!/bin/bash
# Boot the testavd AVD headless, with the kvm-group wrapper so KVM accel works
# even when launched by an already-running process (e.g. VS Code extension host).
#
# Usage:  ./start-avd.sh          (run detached)
#         ./start-avd.sh stop     (stop it)
set -u

export JAVA_HOME=/workspaces/jdk17
export ANDROID_HOME=/workspaces/android-sdk
export ANDROID_SDK_ROOT=/workspaces/android-sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

AVD=testavd
EMU="$ANDROID_HOME/emulator/emulator"

case "${1:-start}" in
  stop)
    "$ANDROID_HOME/platform-tools/adb" emu kill 2>/dev/null \
      || pkill -f "qemu-system-x86_64" 2>/dev/null
    echo "emulator stop requested"
    ;;
  start)
    "$ANDROID_HOME/platform-tools/adb" start-server >/dev/null 2>&1
    setsid nohup "$EMU" -avd "$AVD" \
      -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect -accel on \
      -camera-back none -camera-front none \
      > /tmp/emulator.log 2>&1 < /dev/null &
    disown
    echo "booting $AVD, log: /tmp/emulator.log"
    ;;
esac