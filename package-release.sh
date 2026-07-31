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

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-release.XXXXXX")"
cleanup() {
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
if [[ ! -x "$SOURCE_ROOT/audit-public-source.sh" ]] \
    || ! /usr/bin/cmp -s \
      "$ROOT/public-source-files.txt" \
      "$SOURCE_ROOT/public-source-files.txt" \
    || ! /usr/bin/cmp -s \
      "$ROOT/audit-public-source.sh" \
      "$SOURCE_ROOT/audit-public-source.sh" \
    || ! /usr/bin/cmp -s \
      "$ROOT/package-release.sh" \
      "$SOURCE_ROOT/package-release.sh"; then
  echo "The fetched public source does not match the audited packaging contract." >&2
  exit 2
fi
"$ROOT/audit-public-source.sh" "$SOURCE_ROOT"

VOICE_RELAY_ARCHS="arm64 x86_64" \
  VOICE_RELAY_OUT="$STAGE_DIR" \
  VOICE_RELAY_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  "$SOURCE_ROOT/build.sh" >/dev/null
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
  --entitlements "$SOURCE_ROOT/Resources/VoiceRelay.entitlements" \
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
cp "$SOURCE_ROOT/LICENSE" "$DIST_DIR/LICENSE"
cp "$SOURCE_ROOT/ASSETS.md" "$DIST_DIR/ASSETS.md"
{
  echo "Corresponding source for Voice Relay ${VERSION}:"
  echo "$SOURCE_URL"
} > "$DIST_DIR/SOURCE.md"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR" "$NOTARIZED_ZIP"
echo "$NOTARIZED_ZIP"
