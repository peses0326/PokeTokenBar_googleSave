#!/bin/bash
# Mac: pull.sh SSH_ALIAS [REMOTE_COMMAND]
# REMOTE_COMMAND is executed by the remote login shell; configure a trusted fixed path.
set -euo pipefail
umask 077

POKE_SSH_HOST="${1:?Usage: pull.sh SSH_ALIAS [REMOTE_COMMAND]}"
POKE_REMOTE_COMMAND="${2:-.local/share/poketokenbar-remote/run.sh}"
POKE_STATE_DIR="${PTB_STATE_DIR:-$HOME/Library/Application Support/PokeTokenBar}"

mkdir -p "$POKE_STATE_DIR"
POKE_TEMP=$(mktemp "$POKE_STATE_DIR/.remote-usage.XXXXXX")
trap 'rm -f "$POKE_TEMP"' EXIT

/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$POKE_SSH_HOST" "$POKE_REMOTE_COMMAND" > "$POKE_TEMP"

if [ "$(/usr/bin/wc -c < "$POKE_TEMP")" -gt 262144 ]; then
  echo 'Remote summary exceeds 256 KiB; keeping the previous summary' >&2
  exit 1
fi
/usr/bin/plutil -lint -s "$POKE_TEMP"
/bin/mv -f "$POKE_TEMP" "$POKE_STATE_DIR/remote-usage.json"
/bin/date '+Remote usage synced: %Y-%m-%d %H:%M:%S'
