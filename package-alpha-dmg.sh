#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_URL="${VOICE_RELAY_SOURCE_URL:-}"
RELEASE_DIR="${VOICE_RELAY_RELEASE_DIR:-${ROOT}/releases}"
RELEASE_LABEL="${VOICE_RELAY_RELEASE_LABEL:-}"
SIGNING_IDENTITY="${VOICE_RELAY_SIGNING_IDENTITY:-}"

if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi
if [[ "$SOURCE_URL" != https://github.com/*/archive/* ]]; then
  echo "Set VOICE_RELAY_SOURCE_URL to the exact public source archive for this build." >&2
  exit 2
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Set VOICE_RELAY_SIGNING_IDENTITY to an Apple Development or Developer ID Application identity." >&2
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

SOURCE_ARCHIVE="$STAGE_DIR/source.tar.gz"
SOURCE_EXTRACT_DIR="$STAGE_DIR/source"
/usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --output "$SOURCE_ARCHIVE" \
  "$SOURCE_URL"
mkdir -p "$SOURCE_EXTRACT_DIR"
/usr/bin/tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_EXTRACT_DIR"
SOURCE_ROOTS=("$SOURCE_EXTRACT_DIR"/*)
if [[ "${#SOURCE_ROOTS[@]}" -ne 1 || ! -d "${SOURCE_ROOTS[0]}" ]]; then
  echo "The corresponding-source archive must contain one project root." >&2
  exit 2
fi
SOURCE_ROOT="${SOURCE_ROOTS[0]}"
if ! /usr/bin/diff \
  -qr \
  -x .DS_Store \
  -x build \
  -x releases \
  -x experimental-build \
  "$ROOT" \
  "$SOURCE_ROOT" >/dev/null; then
  echo "The maintained Voice Relay source differs from the public source archive." >&2
  /usr/bin/diff \
    -qr \
    -x .DS_Store \
    -x build \
    -x releases \
    -x experimental-build \
    "$ROOT" \
    "$SOURCE_ROOT" >&2 || true
  exit 2
fi
SOURCE_ARCHIVE_SHA256="$(
  /usr/bin/shasum -a 256 "$SOURCE_ARCHIVE" | /usr/bin/awk '{print $1}'
)"

VOICE_RELAY_ARCHS="arm64 x86_64" \
  VOICE_RELAY_OUT="$STAGE_DIR/build" \
  "$ROOT/build.sh" >/dev/null

APP="$STAGE_DIR/build/Voice Relay.app"
BINARY="$APP/Contents/MacOS/VoiceRelay"
/usr/bin/lipo "$BINARY" -verify_arch arm64 x86_64
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT/Resources/VoiceRelay.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  SIGNING_KIND="developer-id-signed-unnotarized"
  SIGNING_NOTE="This alpha is Developer ID signed but is not notarized."
elif [[ "$SIGNING_IDENTITY" == "Apple Development:"* ]]; then
  SIGNING_KIND="development-signed"
  SIGNING_NOTE="This alpha is Apple Development signed for local development and testing. It is not a notarized public distribution build."
else
  SIGNING_KIND="identity-signed"
  SIGNING_NOTE="This alpha is signed with the requested local identity but is not notarized."
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist"
)"
if [[ -z "$RELEASE_LABEL" ]]; then
  RELEASE_LABEL="${VERSION}-alpha"
fi
SOURCE_TAG="${SOURCE_URL##*/refs/tags/}"
SOURCE_TAG="${SOURCE_TAG%.tar.gz}"
if [[ "$SOURCE_TAG" == "$SOURCE_URL" || "$SOURCE_TAG" != "v${RELEASE_LABEL}" ]]; then
  echo "Release label must match the exact public source tag." >&2
  exit 2
fi
BASE_NAME="Voice-Relay-${RELEASE_LABEL}-${SIGNING_KIND}"
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
  echo "Source archive SHA-256: $SOURCE_ARCHIVE_SHA256"
} > "$DIST_DIR/SOURCE.md"
cat > "$DIST_DIR/INSTALL.md" <<'EOF'
# Install Voice Relay

1. Drag `Voice Relay.app` to `Applications`.
2. Open it from Applications.
3. If macOS blocks this non-notarized alpha, open System Settings, choose
   Privacy & Security, then choose Open Anyway for Voice Relay.
EOF
printf '\n%s\n' "$SIGNING_NOTE" >> "$DIST_DIR/INSTALL.md"

if /usr/sbin/diskutil help image create from >/dev/null 2>&1; then
  /usr/sbin/diskutil image create from \
    --format UDZO \
    --volumeName "Voice Relay ${RELEASE_LABEL}" \
    "$DIST_DIR" \
    "$DMG" >/dev/null
  /usr/sbin/diskutil image info "$DMG" >/dev/null
else
  /usr/bin/hdiutil create \
    -volname "Voice Relay ${RELEASE_LABEL}" \
    -srcfolder "$DIST_DIR" \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null
  /usr/bin/hdiutil imageinfo "$DMG" >/dev/null
fi

MOUNT_DIR="$STAGE_DIR/mount"
mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach \
  "$DMG" \
  -mountpoint "$MOUNT_DIR" \
  -nobrowse \
  -readonly \
  -quiet
test -d "$MOUNT_DIR/Voice Relay.app"
test -f "$MOUNT_DIR/INSTALL.md"
test -f "$MOUNT_DIR/SOURCE.md"
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
