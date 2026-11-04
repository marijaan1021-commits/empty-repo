#!/usr/bin/env bash
# Package the CallNote release for a real phone.
#
# Every run produces files with a timestamp in the name, so no build ever
# overwrites another one - you can tell which APK is on the phone by its
# name alone:
#
#   callnote-release-20261029-152500.apk
#   callnote-release-20261029-152500.zip   (apk + README.txt)
#
# The stable names (callnote-release.apk / .zip) are kept as copies of the
# newest build, so the paths in the docs always work.
#
#   package-release.sh            package what is already built
#   package-release.sh --build    build first (stops the emulator, ~5 min)
set -u

# The repository root. Resolved through any symlink so the script works both
# as scripts/package-release.sh and as /workspaces/package-release.sh.
SELF=$(readlink -f "$0")
APP_DIR=$(dirname "$(dirname "$SELF")")
BUILT_APK="$APP_DIR/app/build/app/outputs/flutter-apk/app-release.apk"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_APK="$APP_DIR/callnote-release-$STAMP.apk"
OUT_ZIP="$APP_DIR/callnote-release-$STAMP.zip"
README="$APP_DIR/README.txt"

say() { echo "== $*"; }

if [ "${1:-}" = "--build" ]; then
  say "stopping the emulator (a 3-ABI Gradle build OOMs with it running)"
  bash /workspaces/emu.sh stop >/dev/null 2>&1
  sleep 3
  say "building (this takes 2-7 minutes)"
  (
    source /workspaces/androidsdk-env.sh
    export PATH=/workspaces/flutter/bin:$PATH
    cd "$APP_DIR/app"
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
CallNote - a reminder for the calls you care about
================================================

callnote-release-$STAMP.apk
  sha256 : $SHA256
  sha1   : $SHA1
  size   : $SIZE bytes
  abis   : ${ABIS#native-code: }
  signer : $DN

Install
-------
  adb install -r callnote-release-$STAMP.apk

or copy the apk to the phone and open it (you need "install from unknown
sources" for your file manager).

The package contains arm64-v8a, armeabi-v7a and x86_64, so it installs on
any phone.

First start
-----------
1. Allow the permissions when the app asks: notifications, contacts, the
   call log and phone state. The reminder is a notification - without the
   notification permission the phone stays silent. Phone state is what lets
   the app know the caller's number while the call is still ringing.
2. Add a note: pick a contact, type what you want to be reminded about and
   switch the note on.
3. That is all. The app watches the calls and tells you when one of the
   contacts with a note calls - within a few tens of milliseconds.

The app makes no network request.
EOF

rm -f "$APP_DIR/callnote-release.zip"
(cd "$APP_DIR" && zip -q -X "$OUT_ZIP" "callnote-release-$STAMP.apk" README.txt)
ZIPSHA=$(sha256sum "$OUT_ZIP" | cut -d' ' -f1)

# the stable names are copies of the newest build
cp "$OUT_APK" "$APP_DIR/callnote-release.apk"
cp "$OUT_ZIP" "$APP_DIR/callnote-release.zip"

say "done"
echo "  apk : $OUT_APK"
echo "        sha256 $SHA256"
echo "  zip : $OUT_ZIP"
echo "        sha256 $ZIPSHA"
echo "  latest also at callnote-release.apk / callnote-release.zip"
