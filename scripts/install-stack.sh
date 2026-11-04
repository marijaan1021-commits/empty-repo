#!/usr/bin/env bash
# Install THIS repository into the runtime layout that the stack expects.
#
#   bash scripts/install-stack.sh
#
# The stack scripts, the VS Code extension and the supervisor all use the
# absolute path /workspaces/<something>. This script makes that path a symlink
# to the file in this repository, so:
#
#   * the repository is the single source of truth (edit here, not in
#     /workspaces), and
#   * nothing else has to change - every absolute path keeps working.
#
# It is idempotent and safe to re-run after every container rebuild.
set -u

# The runtime root. Overridable only so the script can be tested without
# touching the live /workspaces.
WS=${WS:-/workspaces}
SELF=$(readlink -f "$0")
REPO=$(dirname "$(dirname "$SELF")")
EXT_ID=codespace.emulator-view
EXT_VERSION=0.1.0
EXT_DST="$HOME/.vscode-remote/extensions/$EXT_ID-$EXT_VERSION"

say()  { echo; echo "== $* =="; }
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }

# ---------------------------------------------------------------- 1. scripts
say "linking the repo into $WS"
mkdir -p "$WS"
for f in "$REPO"/scripts/*; do
  name=$(basename "$f")
  case "$name" in
    install-stack.sh|install-toolchain.sh|install-extension.sh|create-keystore.sh|README.md)
      continue ;;   # the installers are not part of the runtime
  esac
  target="$WS/$name"
  # keep the first copy of a file we are about to replace
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    mkdir -p "$WS/.keep"
    [ -f "$WS/.keep/$name.pre-repo" ] || cp -p "$target" "$WS/.keep/$name.pre-repo"
  fi
  rm -f "$target"
  ln -s "$f" "$target"
  ok "$WS/$name -> scripts/$name"
done

# ---------------------------------------------------------------- 2. the app
# /workspaces/mini_app is the path the supervisor installs the APK from.
say "linking the app"
APP_TARGET="$REPO/app"
if [ -d "$APP_TARGET" ]; then
  rm -f "$WS/mini_app"
  ln -s "$APP_TARGET" "$WS/mini_app"
  ok "$WS/mini_app -> app/"
else
  warn "no app/ directory in the repository - the emulator will show the launcher"
fi

# ---------------------------------------------------------------- 3. the extension
say "installing the VS Code extension"
if [ -d "$REPO/media" ] && [ -f "$REPO/extension.js" ]; then
  mkdir -p "$EXT_DST/media"
  cp "$REPO/extension.js" "$REPO/package.json" "$EXT_DST/"
  cp "$REPO/media/"* "$EXT_DST/media/"
  ok "$EXT_DST"
  echo "        the user must run  Developer: Reload Window  once to pick it up"
else
  warn "extension.js / media/ not found in the repository"
fi

# ---------------------------------------------------------------- 4. summary
say "done"
cat <<EOF
  Start the emulator:      bash $WS/emu.sh
  Health check:            bash $WS/emu.sh status
  The whole stack check:   bash $WS/verify.sh
  Public URL:              bash $WS/emu.sh url

  The stack starts by itself when VS Code opens the folder
  (.vscode/tasks.json -> "Android Emulator: Ensure Up (auto)").
EOF
