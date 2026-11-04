#!/usr/bin/env bash
# Instant "make sure the stack is coming up" hook.
#
# Returns immediately. The supervisor does the actual work in the background.
# Safe to run any number of times, including on every VS Code folder open.
set -u

SUP=/workspaces/supervisor.sh
PIDFILE=/tmp/supervisor.pid

# ---------------------------------------------------------------------------
# Bind the viewer port FIRST, before anything else and unconditionally.
#
# The Codespaces port-forwarding agent scans for listening ports ONCE, at
# container start. A port that is not bound at that moment is never forwarded
# and rebinding it later does not help. So the viewer must be listening as
# early as possible; it idles until the emulator is up (emuview waits for a
# device instead of exiting).
# ---------------------------------------------------------------------------
viewer_bound() {
  local port=$1
  # Is anything listening on the port? The extension starts its own viewer as
  # plain "python3 /workspaces/emuview.py" (no EMUVIEW_PORT in argv), so
  # matching on the argv used to miss it and start a duplicate every time -
  # which then died with "Address already in use" in /tmp/emuview.log.
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
  return 1
}

start_viewer() {
  local port=$1
  viewer_bound "$port" && return 0
  setsid nohup env EMUVIEW_PORT="$port" python3 /workspaces/emuview.py \
    >>/tmp/emuview.log 2>&1 </dev/null &
  disown
  echo "viewer bound on :$port"
}

start_viewer 8091

# ---------------------------------------------------------------------------
# Tailscale
#
# The container is reset periodically and every process dies with it. The
# Notedog MCP server reaches the phone over the tailnet, so without tailscaled
# the journal reads fail with "fetch failed". The node state lives in the
# persistent volume, so this reconnects on its own - no browser login.
# ---------------------------------------------------------------------------
if [ -f /workspaces/tailscale-up.sh ]; then
  bash /workspaces/tailscale-up.sh || echo "WARN: tailscale-up.sh did not complete"
fi

# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------

# NOTE: never use an unanchored `pgrep -f supervisor.sh` here - the invoking
# shell's own command line contains that string, so it matches itself.
#
# The supervisor is ALWAYS launched as `bash /workspaces/supervisor.sh`
# (a symlink to scripts/supervisor.sh, created by scripts/install-stack.sh),
# so the anchored pattern below is what actually matches. Keep both in sync.
SUP_RE="^bash ${SUP//./\\.}\$"

alive() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # a recycled pid must not be mistaken for the supervisor
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'supervisor\.sh'
}

if alive; then
  echo "supervisor already running (pid $(cat "$PIDFILE" 2>/dev/null))"
  exit 0
fi

if pgrep -f "$SUP_RE" >/dev/null 2>&1; then
  echo "supervisor already running"
  exit 0
fi

if [ ! -f "$SUP" ]; then
  echo "WARN: $SUP not found"
  exit 0
fi

setsid nohup bash "$SUP" >/tmp/supervisor.out 2>&1 </dev/null &
disown
sleep 2
if pgrep -f "$SUP_RE" >/dev/null 2>&1; then
  echo "supervisor started (pid $(cat "$PIDFILE" 2>/dev/null))"
else
  echo "WARN: supervisor failed to start (see /tmp/supervisor.log)"
fi