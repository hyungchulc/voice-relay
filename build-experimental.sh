#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VOICE_RELAY_OUT="${VOICE_RELAY_EXPERIMENTAL_OUT:-${ROOT}/experimental-build}" \
  "$ROOT/build.sh"
