#!/usr/bin/env bash
# Create the release keystore for an app's APK.
#
#   bash scripts/create-keystore.sh [name]
#
# Why this exists: the Flutter template signs release builds with the DEBUG
# key, and the debug keystore lives in the container's overlay layer - it
# changes on every rebuild, so the app can never be updated in place on a
# real phone. A release key on the persistent volume fixes that.
#
# The keystore and the passwords are NEVER committed. Both are gitignored.
set -u

WS=/workspaces
KS_DIR=$WS/.keystore
ALIAS=${1:-app}
NAME=$ALIAS-release
KS=$KS_DIR/$NAME.jks
PASS_FILE=$KS_DIR/.pass
DAYS=10950          # 30 years
DNAME="CN=$ALIAS, OU=$ALIAS, O=$ALIAS, L=, ST=, C=US"

say() { echo; echo "== $* =="; }
ok()  { echo "  ok    $*"; }

SELF=$(readlink -f "$0")
REPO=$(dirname "$(dirname "$SELF")")

say "keystore"
if [ -f "$KS" ]; then
  ok "already exists: $KS"
  echo "        (delete it first if you really want a new one - the app then"
  echo "         cannot be installed over the old copy on a phone)"
else
  mkdir -p "$KS_DIR"
  chmod 700 "$KS_DIR"
  if [ -f "$PASS_FILE" ]; then
    PASS=$(cat "$PASS_FILE")
  else
    PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    printf '%s' "$PASS" >"$PASS_FILE"
    chmod 600 "$PASS_FILE"
  fi
  KEYTOOL=/workspaces/jdk17/bin/keytool
  [ -x "$KEYTOOL" ] || KEYTOOL=$(command -v keytool)
  "$KEYTOOL" -genkeypair -v \
    -keystore "$KS" -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity "$DAYS" \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "$DNAME" 2>/dev/null \
  || "$KEYTOOL" -genkeypair -v \
    -keystore "$KS" -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity "$DAYS" \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=$ALIAS, OU=$ALIAS, O=$ALIAS, C=US"
  chmod 600 "$KS"
  ok "created $KS (RSA 4096, alias $ALIAS, $DAYS days)"
fi

say "key.properties"
# The build reads app/android/key.properties; key.properties in the repo root
# is the copy that travels with the release artifacts.
for target in "$REPO/app/android/key.properties" "$REPO/key.properties"; do
  cat >"$target" <<EOF
storeFile=$KS
storePassword=$PASS
keyAlias=$ALIAS
keyPassword=$PASS
EOF
  chmod 600 "$target"
  ok "$target"
done

say "verify"
/workspaces/android-sdk/build-tools/34.0.0/apksigner --help >/dev/null 2>&1 && \
  echo "  (apksigner is available at /workspaces/android-sdk/build-tools/34.0.0/)"

cat <<EOF

  Done. The next release build is signed with this key:
    bash scripts/package-release.sh --build

  The keystore and the passwords are gitignored - never commit them.
EOF
