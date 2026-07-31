#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-release-policy.XXXXXX")"
NOTES_FILE="$TEST_DIR/notes.md"
HEADING_NOTES_FILE="$TEST_DIR/heading-notes.md"
FAKE_GH="$TEST_DIR/gh"
FAKE_GH_CAPTURE="$TEST_DIR/published-notes-first-line.txt"
ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-development-signed.dmg"
CHECKSUM_FILE="$ASSET_FILE.sha256"
UPDATE_ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-update.zip"
UPDATE_CHECKSUM_FILE="$UPDATE_ASSET_FILE.sha256"
APPCAST_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.9-appcast.xml"
WRONG_ASSET_FILE="$TEST_DIR/Voice-Relay-0.4.0-alpha.8-development-signed.dmg"
WRONG_CHECKSUM_FILE="$WRONG_ASSET_FILE.sha256"

cleanup() {
  /usr/bin/unlink "$NOTES_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$HEADING_NOTES_FILE" >/dev/null 2>&1 || true
  /usr/bin/unlink "$FAKE_GH" >/dev/null 2>&1 || true
  /usr/bin/unlink "$FAKE_GH_CAPTURE" >/dev/null 2>&1 || true
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
printf '# Voice Relay 0.4.0-alpha.9\n\nActual release body\n' \
  > "$HEADING_NOTES_FILE"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == "release" && "$2" == "view" ]]; then' \
  '  exit 1' \
  'fi' \
  'if [[ "$1" == "release" && "$2" == "create" ]]; then' \
  '  shift 2' \
  '  while [[ "$#" -gt 0 ]]; do' \
  '    if [[ "$1" == "--notes-file" ]]; then' \
  '      /usr/bin/head -n 1 "$2" > "$VOICE_RELAY_FAKE_GH_CAPTURE"' \
  '      exit 0' \
  '    fi' \
  '    shift' \
  '  done' \
  '  exit 4' \
  'fi' \
  'if [[ "$1" == "api" && "$*" == *"/releases/tags/"* ]]; then' \
  "  printf 'false\\tfalse\\ttrue\\n'" \
  '  exit 0' \
  'fi' \
  'if [[ "$1" == "api" && "$*" == *"/contents/appcast.xml?ref=main"* ]]; then' \
  '  exit 1' \
  'fi' \
  'if [[ "$1" == "api" && "$*" == *"--method PUT"* ]]; then' \
  "  printf 'fake-content-sha\\n'" \
  '  exit 0' \
  'fi' \
  'exit 5' \
  > "$FAKE_GH"
/bin/chmod 700 "$FAKE_GH"
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
if [[ "$ALPHA_OUTPUT" == *"--prerelease"* ]]; then
  echo "FAIL: preview-channel releases must be ordinary GitHub releases" >&2
  exit 1
fi
if [[ "$ALPHA_OUTPUT" == *"--latest"* ]]; then
  echo "FAIL: GitHub must choose Latest automatically for preview-channel releases" >&2
  exit 1
fi

VOICE_RELAY_FAKE_GH_CAPTURE="$FAKE_GH_CAPTURE" \
VOICE_RELAY_GH_BIN="$FAKE_GH" \
VOICE_RELAY_RELEASE_NOTES_FILE="$HEADING_NOTES_FILE" \
"$ROOT/publish-github-release.sh" \
  v0.4.0-alpha.9 \
  "$ASSET_FILE" \
  "$CHECKSUM_FILE" \
  "$UPDATE_ASSET_FILE" \
  "$UPDATE_CHECKSUM_FILE" \
  "$APPCAST_FILE" >/dev/null
if [[ "$(/usr/bin/head -n 1 "$FAKE_GH_CAPTURE")" != "Actual release body" ]]; then
  echo "FAIL: a duplicate leading Markdown heading must be removed before publication" >&2
  exit 1
fi
if ! /usr/bin/awk '
  /^[[:space:]]*$/ {
    previous_nonempty = 0
    next
  }
  previous_nonempty && $0 !~ /^- / {
    exit 1
  }
  {
    previous_nonempty = 1
  }
' "$ROOT/RELEASE_NOTES.md"; then
  echo "FAIL: public release-note paragraphs and bullets must not contain manual soft wraps" >&2
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
  echo "FAIL: preview-channel asset names must match the publication tag" >&2
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
if [[ "$STABLE_OUTPUT" == *"--latest"* ]]; then
  echo "FAIL: GitHub must choose Latest automatically for an approved v1.0.0" >&2
  exit 1
fi
if [[ "$STABLE_OUTPUT" == *"--prerelease"* ]]; then
  echo "FAIL: an explicitly approved v1.0.0 must not be a prerelease" >&2
  exit 1
fi

if ! /usr/bin/grep -q \
  'The fetched public source does not match the audited packaging contract' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must reject an unaudited public tag" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  '"$ROOT/audit-public-source.sh" "$SOURCE_ROOT"' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must audit the fetched public source" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  '"$SOURCE_ROOT/build.sh"' \
  "$ROOT/package-alpha-dmg.sh"; then
  echo "FAIL: alpha packaging must build the fetched public source" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  '"$ROOT/audit-public-source.sh" "$SOURCE_ROOT"' \
  "$ROOT/package-release.sh"; then
  echo "FAIL: stable packaging must audit the fetched public source" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  '"$SOURCE_ROOT/build.sh"' \
  "$ROOT/package-release.sh"; then
  echo "FAIL: stable packaging must build the fetched public source" >&2
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
  echo "FAIL: preview-channel publication must publish the stable Sparkle feed" >&2
  exit 1
fi
if ! /usr/bin/grep -Eq \
  '\^\#\{1,6\}\[\[:space:\]\]' \
  "$ROOT/publish-github-release.sh"; then
  echo "FAIL: release publication must detect a duplicate leading Markdown heading" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  'PUBLISH_NOTES_FILE="$SANITIZED_NOTES_FILE"' \
  "$ROOT/publish-github-release.sh"; then
  echo "FAIL: release publication must use sanitized notes when a leading heading is present" >&2
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
