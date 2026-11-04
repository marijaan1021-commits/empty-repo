#!/usr/bin/env bash
# Makes the emulator viewer port PUBLIC automatically.
#
# The Codespaces UI normally requires a human to right-click the port in the
# PORTS panel and choose "Port Visibility > Public". That step is scriptable:
#
#   gh codespace ports visibility 8091:public -c <codespace>
#
# This uses the Codespaces-specific API, which is a DIFFERENT endpoint from the
# generic GitHub REST API. The generic REST port endpoints return 404 for the
# tokens available in a Codespace - that is why an earlier attempt concluded
# port visibility could not be automated. It can.
#
# The port must already be forwarded by VS Code for this to succeed, so the
# script retries: the viewer binds the port, VS Code notices and forwards it,
# and only then does the visibility call resolve.
set -u

PORT=${1:-8091}
CS=${CODESPACE_NAME:-}
LOG=/tmp/ensure-public.log
ATTEMPTS=${ATTEMPTS:-8}

say() { echo "[$(date +%H:%M:%S)] $*" >>"$LOG"; }

if [ -z "$CS" ]; then
  CS=$(timeout 30 gh codespace list --json name -q '.[0].name' 2>/dev/null)
fi
if [ -z "$CS" ]; then
  say "ERROR: cannot determine codespace name"
  exit 1
fi

for attempt in $(seq 1 "$ATTEMPTS"); do
  out=$(timeout 60 gh codespace ports visibility "$PORT:public" -c "$CS" 2>&1)
  if [ $? -eq 0 ]; then
    say "port $PORT is PUBLIC (attempt $attempt) $out"
    echo "port $PORT is public"
    exit 0
  fi
  say "attempt $attempt: $out"
  sleep 8
done

say "ERROR: could not make port $PORT public"
echo "could not make port $PORT public"
exit 1