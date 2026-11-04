#!/usr/bin/env bash
# Package an app's release APK for a real phone.
#
#   bash /workspaces/package-release.sh [app-dir] [package-id] [name]
#
# Defaults:
#   app-dir    /workspaces/mini_app
#   package-id com.example.mini_app
#   name       the app's directory name
#
# Every run produces files with a timestamp in the name, so no build ever
# overwrites another one - you can tell which APK is on the phone by its
# name alone:
#
#   myapp-release-20261029-152500.apk
#   myapp-release-20261029-152500.zip   (apk + README.txt)
#
# The stable names (<name>-release.apk / .zip) are kept as copies of the
# newest build, so the paths in the docs always work.
#
#   package-release.sh            package what is already built
#   package-release.sh --build    build first (stops the emulator, ~5 min)
set -u

# The repository root. Resolved through any symlink so the script works both
# as scripts/package-release.sh and as /workspaces/package-release.sh.
SELF=$(readlink -f "$0")
REPO=$(dirname "$(dirname "$SELF")")

BUILD=0
if [ "${1:-}" = "--build" ]; then
  BUILD=1
  shift
fi

APP_DIR=${1:-/workspaces/mini_app}
PKG=${2:-com.example.mini_app}
NAME=${3:-$(basename "$APP_DIR")}
BUILT_APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_APK="$REPO/$NAME-release-$STAMP.apk"
OUT_ZIP="$REPO/$NAME-release-$STAMP.zip"
README="$REPO/README.txt"

say() { echo "== $*"; }

if [ "$BUILD" = "1" ]; then
  say "stopping the emulator (a 3-ABI Gradle build OOMs with it running)"
  bash /workspaces/emu.sh stop >/dev/null 2>&1
  sleep 3
  say "building (this takes 2-12 minutes)"
  (
    source /workspaces/androidsdk-env.sh
    export PATH=/workspaces/flutter/bin:$PATH
    cd "$APP_DIR"
    flutter build apk --release --target-platform android-arm,android-arm64,android-x64
  )
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL  the build failed (exit $rc) - nothing was packaged"
    exit 1
  fi
  say "starting the emulator again"
  setsid nohup bash /workspaces/emu.sh >/workspaces/.keep/emu-start-pkg.log 2>&1 </dev/null &
  disown
fi

if [ ! -f "$BUILT_APK" ]; then
  echo "FAIL  no APK at $BUILT_APK - build it first (package-release.sh --build)"
  exit 1
fi

say "packaging"
cp "$BUILT_APK" "$OUT_APK"

SHA256=$(sha256sum "$OUT_APK" | cut -d' ' -f1)
SHA1=$(sha1sum "$OUT_APK" | cut -d' ' -f1)
SIZE=$(stat -c %s "$OUT_APK")

AAPT=/workspaces/android-sdk/build-tools/34.0.0/aapt2
ABIS=$($AAPT dump badging "$OUT_APK" 2>/dev/null | grep -o "native-code:.*" | head -1)
DN=$(/workspaces/android-sdk/build-tools/34.0.0/apksigner verify --print-certs "$OUT_APK" 2>/dev/null \
      | grep -m1 "Signer #1 certificate DN" | sed 's/.*DN: //')

cat >"$README" <<EOF
$NAME
$(printf '=%.0s' $(seq 1 ${#NAME}))

$NAME-release-$STAMP.apk
  sha256 : $SHA256
  sha1   : $SHA1
  size   : $SIZE bytes
  abis   : ${ABIS#native-code: }
  signer : $DN

Install
-------
  adb install -r $NAME-release-$STAMP.apk

or copy the apk to the phone and open it (you need "install from unknown
sources" for your file manager).

The package contains arm64-v8a, armeabi-v7a and x86_64, so it installs on
any phone.

First start
-----------
Allow the permissions the app asks for. Without them it cannot do what it is
supposed to do - a notification app stays silent without the notification
permission.
EOF

rm -f "$REPO/$NAME-release.zip"
(cd "$REPO" && zip -q -X "$OUT_ZIP" "$NAME-release-$STAMP.apk" README.txt)
ZIPSHA=$(sha256sum "$OUT_ZIP" | cut -d' ' -f1)

# the stable names are copies of the newest build
cp "$OUT_APK" "$REPO/$NAME-release.apk"
cp "$OUT_ZIP" "$REPO/$NAME-release.zip"

say "done"
echo "  apk : $OUT_APK"
echo "        sha256 $SHA256"
echo "  zip : $OUT_ZIP"
echo "        sha256 $ZIPSHA"
echo "  latest also at $NAME-release.apk / $NAME-release.zip"
