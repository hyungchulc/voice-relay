#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_URL="${VOICE_RELAY_SOURCE_URL:-}"
RELEASE_DIR="${VOICE_RELAY_RELEASE_DIR:-${ROOT}/releases}"
RELEASE_LABEL="${VOICE_RELAY_RELEASE_LABEL:-}"

if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi
if [[ "$SOURCE_URL" != https://github.com/*/archive/* ]]; then
  echo "Set VOICE_RELAY_SOURCE_URL to the exact public source archive for this build." >&2
  exit 2
fi
if ! /usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --head \
  "$SOURCE_URL" >/dev/null; then
  echo "The corresponding-source archive is not publicly reachable: $SOURCE_URL" >&2
  exit 2
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-alpha.XXXXXX")"
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

VOICE_RELAY_ARCHS="arm64 x86_64" \
  VOICE_RELAY_OUT="$STAGE_DIR/build" \
  "$ROOT/build.sh" >/dev/null

APP="$STAGE_DIR/build/Voice Relay.app"
BINARY="$APP/Contents/MacOS/VoiceRelay"
/usr/bin/lipo "$BINARY" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist"
)"
if [[ -z "$RELEASE_LABEL" ]]; then
  RELEASE_LABEL="${VERSION}-alpha"
fi
BASE_NAME="Voice-Relay-${RELEASE_LABEL}-unsigned"
DMG="$RELEASE_DIR/${BASE_NAME}.dmg"
CHECKSUM="$DMG.sha256"
DIST_DIR="$STAGE_DIR/Voice Relay"

mkdir -p "$RELEASE_DIR"
if [[ -e "$DMG" || -e "$CHECKSUM" ]]; then
  echo "Release artifact already exists: $DMG" >&2
  exit 3
fi

mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP" "$DIST_DIR/Voice Relay.app"
ln -s /Applications "$DIST_DIR/Applications"
cp "$ROOT/LICENSE" "$DIST_DIR/LICENSE"
cp "$ROOT/ASSETS.md" "$DIST_DIR/ASSETS.md"
cp "$ROOT/README.md" "$DIST_DIR/README.md"
cp "$ROOT/DISTRIBUTION.md" "$DIST_DIR/DISTRIBUTION.md"
{
  echo "Corresponding source for Voice Relay ${RELEASE_LABEL}:"
  echo "$SOURCE_URL"
} > "$DIST_DIR/SOURCE.md"
cat > "$DIST_DIR/INSTALL.md" <<'EOF'
# Install Voice Relay

1. Drag `Voice Relay.app` to `Applications`.
2. Open it from Applications.
3. If macOS blocks this unsigned alpha, open System Settings, choose
   Privacy & Security, then choose Open Anyway for Voice Relay.

This alpha is ad-hoc signed but is not Developer ID signed or notarized.
EOF

/usr/bin/hdiutil create \
  -volname "Voice Relay ${RELEASE_LABEL}" \
  -srcfolder "$DIST_DIR" \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null
/usr/bin/hdiutil imageinfo "$DMG" >/dev/null

MOUNT_DIR="$STAGE_DIR/mount"
mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach \
  "$DMG" \
  -mountpoint "$MOUNT_DIR" \
  -nobrowse \
  -readonly \
  -quiet
/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  --verbose=2 \
  "$MOUNT_DIR/Voice Relay.app"
/usr/bin/lipo \
  "$MOUNT_DIR/Voice Relay.app/Contents/MacOS/VoiceRelay" \
  -verify_arch arm64 x86_64
test -f "$MOUNT_DIR/ASSETS.md"
/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")"
)
if /usr/bin/grep -q '/' "$CHECKSUM"; then
  echo "Checksum must contain only the release filename." >&2
  exit 3
fi
echo "$DMG"
echo "$CHECKSUM"
