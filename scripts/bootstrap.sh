#!/bin/bash
# Re-apply the environment changes that do NOT survive a Codespace rebuild.
#
# Everything under /workspaces (Android SDK, Flutter, JDK, the AVD itself)
# persists automatically. These three things live outside /workspaces and are
# lost whenever the container is recreated - run this script once after that:
#
#   1. the `kvm` group in /etc/group   (emulator refuses to boot without it)
#   2. X11 shared libraries            (emulator segfaults on boot without them)
#   3. /dev/kvm permissions
#
# Run:  bash /workspaces/bootstrap.sh
set -u

echo "==> 1. kvm group"
if grep -q '^kvm:' /etc/group; then
  if grep -q '^kvm:.*codespace' /etc/group; then
    echo "    already present"
  else
    sudo sed -i 's/^kvm:x:109:/kvm:x:109:codespace/' /etc/group
    echo "    added codespace"
  fi
else
  sudo groupadd -g 109 kvm 2>/dev/null || true
  sudo usermod -aG kvm codespace 2>/dev/null || true
  echo "    created"
fi

echo "==> 2. X11 libraries"
if [ -e /usr/lib/x86_64-linux-gnu/libX11-xcb.so.1 ]; then
  echo "    already present"
else
  sudo apt-get update -q >/dev/null 2>&1
  sudo apt-get install -y -q libx11-xcb1 libxcb1 libx11-6 libxcb-xfixes0 \
    libxcb-shm0 libxcb-render0 libxext6 libxfixes3 libxi6 libxtst6 \
    libnss3 libpulse0 libasound2t64 >/dev/null 2>&1
  sudo ldconfig
  echo "    installed"
fi

echo "==> 3. /dev/kvm permissions"
sudo chmod 666 /dev/kvm 2>/dev/null && echo "    set to 666"
ls -l /dev/kvm

echo
echo "==> verifying"
/workspaces/android-sdk/emulator/emulator -list-avds
# Reading raw bytes from /dev/kvm fails with EINVAL even when the open() itself
# succeeds, so check for "Permission denied" rather than testing the exit code.
if sg kvm -c 'head -c 4 /dev/kvm' 2>&1 | grep -qi "permission denied"; then
  echo "    WARNING: /dev/kvm not accessible"
else
  echo "    /dev/kvm accessible via kvm group"
fi

echo
echo "Done. You can now use the EmbeDroid sidebar in VS Code."