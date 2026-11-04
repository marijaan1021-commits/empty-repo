#!/usr/bin/env bash
# Install the whole toolchain from nothing: Android SDK, emulator, system
# image, AVD, JDK 17 and Flutter.
#
#   bash scripts/install-toolchain.sh
#
# This is the script to run in a brand-new Codespace, before anything else.
# It is idempotent: every step checks whether it is already done.
#
# It installs into /workspaces (the persistent volume). Nothing is written
# outside it, except the host-level bits in step 1 (sudo), which the
# container loses on every rebuild - `bootstrap.sh` re-applies those.
#
# Disk needed: ~8 GB free (SDK 3.1 GB, system image 1.7 GB, emulator 863 MB,
# Flutter 2.1 GB, AVD 711 MB, JDK 318 MB).
set -u

WS=/workspaces
SDK=$WS/android-sdk
AVD_HOME=$WS/android-avd
JDK=$WS/jdk17
FLUTTER=$WS/flutter
AVD_NAME=testavd
IMG="system-images;android-34;default;x86_64"
CMDLINE_ZIP_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
FLUTTER_BRANCH=3.35.1

say()  { echo; echo "== $* =="; }
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }
die()  { echo "  FAIL  $*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. disk
say "disk"
df -h "$WS" | tail -1
AVAIL=$(df -BG "$WS" | awk 'NR==2{gsub(/G/,"",$4); print $4}')
[ "${AVAIL:-0}" -ge 8 ] || warn "only ${AVAIL}G free - 8G is needed for a clean install"

# ------------------------------------------------- 1. host-level bits (sudo)
# These live in the container image and are lost on every rebuild.
say "host prerequisites (sudo)"
if [ ! -r /dev/kvm ] || ! sg kvm -c true 2>/dev/null; then
  sudo sed -i 's/^kvm:x:109:/kvm:x:109:codespace/' /etc/group 2>/dev/null
  sudo groupadd -g 109 kvm 2>/dev/null
  sudo usermod -aG kvm "$(id -un)" 2>/dev/null
  sudo apt-get update -q
  sudo apt-get install -y -q \
    libx11-xcb1 libxcb1 libx11-6 libxcb-xfixes0 libxcb-shm0 libxcb-render0 \
    libxext6 libxfixes3 libxi6 libxtst6 libnss3 libpulse0 libasound2t64
  sudo ldconfig
  sudo chmod 666 /dev/kvm
  ok "kvm group, X11 libs, /dev/kvm"
else
  ok "kvm + X11 libs already present"
fi
ls -l /dev/kvm

# ---------------------------------------------------------------- 2. JDK 17
# The container's default Java is JDK 25, which Gradle/AGP does not support.
# Everything Android-related must use this JDK 17.
say "JDK 17"
if [ -x "$JDK/bin/java" ]; then
  ok "already there: $("$JDK/bin/java" -version 2>&1 | head -1)"
else
  mkdir -p "$JDK"
  tmp=$(mktemp -d)
  # Adoptium Temurin 17 - the same build that is in use today (17.0.20.1+1)
  curl -fsSL -o "$tmp/jdk.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    || die "could not download the JDK"
  tar -xzf "$tmp/jdk.tar.gz" -C "$tmp"
  # the tarball has one top-level directory
  d=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d -name 'jdk*' | head -1)
  [ -n "$d" ] || die "unexpected JDK tarball layout"
  cp -a "$d/." "$JDK/"
  rm -rf "$tmp"
  ok "installed $("$JDK/bin/java" -version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------- 3. SDK
say "Android SDK"
mkdir -p "$SDK/cmdline-tools"
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/cmdline.zip" "$CMDLINE_ZIP_URL" || die "could not download cmdline-tools"
  unzip -q "$tmp/cmdline.zip" -d "$tmp"
  mkdir -p "$SDK/cmdline-tools/latest"
  cp -a "$tmp/cmdline-tools/." "$SDK/cmdline-tools/latest/"
  rm -rf "$tmp"
  ok "cmdline-tools installed"
else
  ok "cmdline-tools already there"
fi

export JAVA_HOME=$JDK
export ANDROID_HOME=$SDK
export ANDROID_SDK_ROOT=$SDK
export ANDROID_AVD_HOME=$AVD_HOME
export PATH="$JDK/bin:$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$SDK/emulator:$PATH"

yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "emulator" "$IMG" "build-tools;34.0.0" "platforms;android-34" \
  || die "sdkmanager failed"
ok "platform-tools, emulator, system image, build-tools, platform"

# ---------------------------------------------------------------- 4. the AVD
say "AVD '$AVD_NAME'"
mkdir -p "$AVD_HOME"
if [ ! -f "$AVD_HOME/$AVD_NAME.avd/config.ini" ]; then
  echo no | avdmanager create avd -n "$AVD_NAME" -k "$IMG" -d pixel_5 --force \
    || die "avdmanager failed"
  ok "created"
else
  ok "already exists"
fi

# Overwrite the generated config with the tuned one. This is the exact file
# that has been booting for the last 16 sessions - do not hand-edit it.
SELF=$(readlink -f "$0")
REPO=$(dirname "$(dirname "$SELF")")
if [ -f "$REPO/avd/testavd.config.ini" ]; then
  cp "$REPO/avd/testavd.config.ini" "$AVD_HOME/$AVD_NAME.avd/config.ini"
  ok "config.ini applied from avd/testavd.config.ini"
fi

# The emulator needs this wrapper, because the AVD home lives outside $HOME.
mkdir -p "$SDK/emulator"
if [ ! -f "$SDK/emulator/emulator" ]; then
  cat >"$SDK/emulator/emulator" <<'WRAP'
#!/usr/bin/env bash
# Wrapper: the real emulator binary lives next to this file as
# .emulator-real, but the AVD home must be set explicitly.
D=$(readlink -f "$(dirname "$0")")
export ANDROID_AVD_HOME=/workspaces/android-avd
exec "$D/.emulator-real" "$@"
WRAP
  chmod +x "$SDK/emulator/emulator"
  ok "emulator wrapper created"
fi

# ---------------------------------------------------------------- 5. Flutter
say "Flutter $FLUTTER_BRANCH"
if [ -x "$FLUTTER/bin/flutter" ]; then
  ok "already there: $(cat "$FLUTTER/version" 2>/dev/null)"
else
  git clone --depth 1 --branch "$FLUTTER_BRANCH" \
    https://github.com/flutter/flutter.git "$FLUTTER" \
    || die "flutter clone failed"
  ok "cloned"
fi
export PATH="$FLUTTER/bin:$PATH"
export PUB_CACHE=$WS/.pub-cache
export GRADLE_USER_HOME=$WS/.gradle

# ---------------------------------------------------------------- 6. PATH
say "PATH"
# /usr/local/bin survives until the container is rebuilt.
sudo ln -sf "$SDK/platform-tools/adb" /usr/local/bin/adb
sudo ln -sf "$SDK/emulator/emulator" /usr/local/bin/emulator
ok "adb and emulator on the global PATH"

cat >"$WS/androidsdk-env.sh" <<'ENV'
export JAVA_HOME=/workspaces/jdk17
export ANDROID_HOME=/workspaces/android-sdk
export ANDROID_SDK_ROOT=/workspaces/android-sdk
export ANDROID_AVD_HOME=/workspaces/android-avd
export FLUTTER_HOME=/workspaces/flutter
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$FLUTTER_HOME/bin:$PATH"
export PUB_CACHE=/workspaces/.pub-cache
export GRADLE_USER_HOME=/workspaces/.gradle
ENV
ok "$WS/androidsdk-env.sh written"

echo
echo "== toolchain ready =="
echo "  next:  bash scripts/install-stack.sh    # link the repo into /workspaces"
echo "  then:  bash /workspaces/emu.sh           # start the emulator"
