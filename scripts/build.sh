#!/bin/bash
# Build a Flutter Android app for the x86_64 emulator.
#
#   bash /workspaces/build.sh [project-dir] [target-platform]
#
# Defaults to android-x64, which is the ABI of the AVD (x86_64).
#
# The test app that used to live in /workspaces/mini_app was removed on
# 2026-10-28 (see AGENTS.md section 29). Point this at whatever app you
# are working on now.
#
# Run it DETACHED - a Gradle build takes ~5 minutes and a foreground run
# gets killed by any 120 s tool timeout:
#
#   setsid nohup bash /workspaces/build.sh /path/to/app \
#     >/tmp/flutter-build.log 2>&1 </dev/null & disown
set -u

PROJECT=${1:-/workspaces/mini_app}
PLATFORM=${2:-android-x64}

if [ ! -d "$PROJECT" ]; then
  echo "no such project directory: $PROJECT"
  echo "usage: bash /workspaces/build.sh [project-dir] [target-platform]"
  exit 1
fi

source /workspaces/androidsdk-env.sh
export PUB_CACHE=${PUB_CACHE:-/workspaces/.pub-cache}
export GRADLE_USER_HOME=${GRADLE_USER_HOME:-/workspaces/.gradle}
export PATH=/workspaces/flutter/bin:$PATH

cd "$PROJECT" || exit 1
flutter build apk --release --target-platform "$PLATFORM" 2>&1
echo "EXIT_CODE=$?"
