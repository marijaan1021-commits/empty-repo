#!/bin/bash
# Build the release APK for the CallNote app.
# Runs detached because a Gradle build takes ~5 minutes and a foreground
# build gets killed by short tool timeouts.
#
# ALL THREE ABIs are built on purpose: an x86_64-only APK refuses to install
# on a real phone ("app isn't compatible with your phone" =
# INSTALL_FAILED_NO_MATCHING_ABIS). arm64-v8a is what a phone needs;
# x86_64 is what the emulator needs.
#
# Stop the emulator before building - a 3-ABI Gradle build OOMs with it
# running (2 vCPU, 7.8 GB RAM, no swap).
set -u
source /workspaces/androidsdk-env.sh
export PATH=/workspaces/flutter/bin:$PATH
# The repository root, resolved through any symlink.
SELF=$(readlink -f "$0")
APP_DIR=$(dirname "$(dirname "$SELF")")
cd "$APP_DIR/app" || exit 1
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
echo "BUILD_EXIT=$?"
ls -la "$APP_DIR/app/build/app/outputs/flutter-apk/" 2>/dev/null
