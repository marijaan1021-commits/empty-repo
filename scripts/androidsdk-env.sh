#!/usr/bin/env bash
# Shared environment for Flutter + Android SDK on this Codespace
export JAVA_HOME=/workspaces/jdk17
export ANDROID_HOME=/workspaces/android-sdk
export ANDROID_SDK_ROOT=/workspaces/android-sdk
export ANDROID_AVD_HOME=/workspaces/android-avd
export FLUTTER_HOME=/workspaces/flutter
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$FLUTTER_HOME/bin:$PATH"
export PUB_CACHE=/workspaces/.pub-cache
export GRADLE_USER_HOME=/workspaces/.gradle