#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNING_IDENTITY="${VOICE_RELAY_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${VOICE_RELAY_NOTARY_PROFILE:-}"
SOURCE_URL="${VOICE_RELAY_SOURCE_URL:-}"
RELEASE_DIR="${VOICE_RELAY_RELEASE_DIR:-${ROOT}/releases}"

if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Set VOICE_RELAY_SIGNING_IDENTITY to a Developer ID Application identity." >&2
  exit 2
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set VOICE_RELAY_NOTARY_PROFILE to a notarytool keychain profile." >&2
  exit 2
fi
if [[ "$SOURCE_URL" != https://github.com/*/archive/* ]]; then
  echo "Set VOICE_RELAY_SOURCE_URL to the exact public source archive for this build." >&2
  exit 2
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-release.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

VOICE_RELAY_ARCHS="arm64 x86_64" \
  VOICE_RELAY_OUT="$STAGE_DIR" \
  "$ROOT/build.sh" >/dev/null
APP="$STAGE_DIR/Voice Relay.app"
BINARY="$APP/Contents/MacOS/VoiceRelay"
/usr/bin/lipo "$BINARY" -verify_arch arm64 x86_64
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BASE_NAME="Voice-Relay-${VERSION}"
NOTARIZED_ZIP="$RELEASE_DIR/${BASE_NAME}-notarized.zip"
SUBMISSION_ZIP="$STAGE_DIR/${BASE_NAME}-submission.zip"
DIST_DIR="$STAGE_DIR/$BASE_NAME"

mkdir -p "$RELEASE_DIR"
if [[ -e "$NOTARIZED_ZIP" ]]; then
  echo "Release artifact already exists for version ${VERSION}." >&2
  exit 3
fi

/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/Resources/VoiceRelay.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP" "$DIST_DIR/Voice Relay.app"
cp "$ROOT/LICENSE" "$DIST_DIR/LICENSE"
cp "$ROOT/ASSETS.md" "$DIST_DIR/ASSETS.md"
{
  echo "Corresponding source for Voice Relay ${VERSION}:"
  echo "$SOURCE_URL"
} > "$DIST_DIR/SOURCE.md"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR" "$NOTARIZED_ZIP"
echo "$NOTARIZED_ZIP"
