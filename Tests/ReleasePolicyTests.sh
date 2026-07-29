#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-release-policy.XXXXXX")"
NOTES_FILE="$TEST_DIR/notes.md"
ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-development-signed.dmg"
CHECKSUM_FILE="$ASSET_FILE.sha256"
UPDATE_ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-update.zip"
UPDATE_CHECKSUM_FILE="$UPDATE_ASSET_FILE.sha256"
APPCAST_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-appcast.xml"
WRONG_ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.8-development-signed.dmg"
WRONG_CHECKSUM_FILE="$WRONG_ASSET_FILE.sha256"

cleanup() {
  /usr/bin/unlink "$NOTES_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$ASSET_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$CHECKSUM_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$UPDATE_ASSET_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$UPDATE_CHECKSUM_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$APPCAST_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$WRONG_ASSET_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$WRONG_CHECKSUM_FILE" >/dev/null 2>&1 || true
  /bin/rmdir "$TEST_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf 'Release notes\n' > "$NOTES_FILE"
printf 'test asset\n' > "$ASSET_FILE"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ASSET_FILE")" \
    > "$(basename "$CHECKSUM_FILE")"
)
printf 'test updater asset\n' > "$UPDATE_ASSET_FILE"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$UPDATE_ASSET_FILE")" \
    > "$(basename "$UPDATE_CHECKSUM_FILE")"
)
printf '%s\n' \
  '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://github.com/hyungchulc/voice-relay/releases/download/v0.4.0-alpha.9/Voice-Relay-0.4.0-alpha.9-update.zip" sparkle:edSignature="test"/></item></channel></rss>' \
  > "$APPCAST_FILE"
printf 'wrong release asset\n' > "$WRONG_ASSET_FILE"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$WRONG_ASSET_FILE")" \
    > "$(basename "$WRONG_CHECKSUM_FILE")"
)

ALPHA_OUTPUT="$(
  VOICE_RELAY_RELEASE_DRY_RUN=1 \
  VOICE_RELAY_RELEASE_NOTES_FILE="$NOTES_FILE" \
  "$ROOT/publish-github-release.sh" \
    v0.4.0-alpha.9 \
    "$ASSET_FILE" \
    "$CHECKSUM_FILE" \
    "$UPDATE_ASSET_FILE" \
    "$UPDATE_CHECKSUM_FILE" \
    "$APPCAST_FILE"
)"
if [[ "$ALPHA_OUTPUT" != *"--prerelease"* ]]; then
  echo "FAIL: alpha releases must be published with --prerelease" >&2
  exit 1
fi
if [[ "$ALPHA_OUTPUT" == *"--latest"* ]]; then
  echo "FAIL: alpha releases must never be published with --latest" >&2
  exit 1
fi
if \
  VOICE_RELAY_RELEASE_DRY_RUN=1 \
  VOICE_RELAY_RELEASE_NOTES_FILE="$NOTES_FILE" \
  "$ROOT/publish-github-release.sh" \
    v0.4.0-alpha.9 \
    "$WRONG_ASSET_FILE" \
    "$WRONG_CHECKSUM_FILE" \
    "$UPDATE_ASSET_FILE" \
    "$UPDATE_CHECKSUM_FILE" \
    "$APPCAST_FILE" >/dev/null 2>&1
then
  echo "FAIL: prerelease asset names must match the publication tag" >&2
  exit 1
fi

if \
  VOICE_RELAY_RELEASE_DRY_RUN=1 \
  VOICE_RELAY_RELEASE_NOTES_FILE="$NOTES_FILE" \
  "$ROOT/publish-github-release.sh" \
    v1.0.0 \
    "$ASSET_FILE" >/dev/null 2>&1
then
  echo "FAIL: v1.0.0 must require explicit stable-release approval" >&2
  exit 1
fi

STABLE_OUTPUT="$(
  VOICE_RELAY_RELEASE_DRY_RUN=1 \
  VOICE_RELAY_STABLE_RELEASE_APPROVED=true \
  VOICE_RELAY_RELEASE_NOTES_FILE="$NOTES_FILE" \
  "$ROOT/publish-github-release.sh" \
    v1.0.0 \
    "$ASSET_FILE"
)"
if [[ "$STABLE_OUTPUT" != *"--latest"* ]]; then
  echo "FAIL: an explicitly approved v1.0.0 must be published with --latest" >&2
  exit 1
fi
if [[ "$STABLE_OUTPUT" == *"--prerelease"* ]]; then
  echo "FAIL: an explicitly approved v1.0.0 must not be a prerelease" >&2
  exit 1
fi

if ! /usr/bin/grep -q \
  'The maintained Voice Relay source differs from the public source archive' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must reject source that differs from the public tag" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'Release label must match the exact public source tag' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must bind the release label to the public tag" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'embedded VoiceRelayReleaseTag must match the exact public source tag' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must verify the embedded release tag" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'Source archive SHA-256' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must record the public source archive digest" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'UPDATE_ARCHIVE' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must produce a Sparkle updater archive" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'generate_appcast' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must generate the signed Sparkle appcast" >&2
  exit 1
fi
if ! /usr/bin/grep -q \
  'publish-sparkle-feed.sh' \
  "$ROOT/publish-github-release.sh"; then
  echo "FAIL: prerelease publication must publish the stable Sparkle feed" >&2
  exit 1
fi

if \
  VOICE_RELAY_RELEASE_DRY_RUN=1 \
  VOICE_RELAY_STABLE_RELEASE_APPROVED=true \
  VOICE_RELAY_RELEASE_NOTES_FILE="$NOTES_FILE" \
  "$ROOT/publish-github-release.sh" \
    v0.4.0 \
    "$ASSET_FILE" >/dev/null 2>&1
then
  echo "FAIL: stable tags other than the explicitly approved v1.0.0 must be rejected" >&2
  exit 1
fi

echo "Voice Relay release policy tests passed"
