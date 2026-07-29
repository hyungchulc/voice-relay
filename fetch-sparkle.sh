#!/usr/bin/env bash
set -euo pipefail

SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
CACHE_ROOT="${VOICE_RELAY_DEPENDENCY_CACHE:-${TMPDIR:-/tmp}/voice-relay-dependencies}"
TARGET="$CACHE_ROOT/Sparkle-${SPARKLE_VERSION}-${SPARKLE_SHA256:0:12}"

if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

is_complete() {
  [[ -f "$1/Sparkle.framework/Versions/B/Sparkle" \
      && -x "$1/bin/generate_appcast" \
      && -x "$1/bin/generate_keys" \
      && -x "$1/bin/sign_update" ]]
}

if is_complete "$TARGET"; then
  echo "$TARGET"
  exit 0
fi
if [[ -e "$TARGET" ]]; then
  echo "Sparkle cache exists but is incomplete: $TARGET" >&2
  exit 3
fi

mkdir -p "$CACHE_ROOT"
STAGE="$(mktemp -d "$CACHE_ROOT/.Sparkle-${SPARKLE_VERSION}.XXXXXX")"
ARCHIVE="$STAGE/Sparkle.tar.xz"
cleanup() {
  if [[ -d "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT

/usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --output "$ARCHIVE" \
  "$SPARKLE_URL"
ACTUAL_SHA256="$(
  /usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}'
)"
if [[ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]]; then
  echo "Sparkle archive checksum mismatch." >&2
  exit 3
fi

EXTRACTED="$STAGE/extracted"
mkdir -p "$EXTRACTED"
/usr/bin/tar -xJf "$ARCHIVE" -C "$EXTRACTED"
if ! is_complete "$EXTRACTED"; then
  echo "Sparkle archive is missing required framework or release tools." >&2
  exit 3
fi

if /bin/mv "$EXTRACTED" "$TARGET" 2>/dev/null; then
  :
elif ! is_complete "$TARGET"; then
  echo "Could not install the verified Sparkle dependency cache." >&2
  exit 3
fi

echo "$TARGET"
