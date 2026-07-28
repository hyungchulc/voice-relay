#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${VOICE_RELAY_OUT:-${ROOT}/build}"
APP="${OUT_DIR}/Voice Relay.app"
PROCESS_NAME="VoiceRelay"

"$ROOT/build.sh" >/dev/null

if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null; then
  /usr/bin/pkill -TERM -x "$PROCESS_NAME"
  for _ in {1..50}; do
    if ! /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null; then
      break
    fi
    /bin/sleep 0.1
  done
fi

if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null; then
  echo "Voice Relay did not stop cleanly" >&2
  exit 1
fi

/usr/bin/open -n "$APP"

for _ in {1..50}; do
  if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null; then
    exit 0
  fi
  /bin/sleep 0.1
done

echo "Voice Relay did not start" >&2
exit 1
