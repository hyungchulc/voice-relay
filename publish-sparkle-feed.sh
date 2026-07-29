#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="hyungchulc/voice-relay"
BRANCH="main"
GH_BIN="${VOICE_RELAY_GH_BIN:-gh}"

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <tag> <versioned-appcast.xml>" >&2
  exit 2
fi

TAG="$1"
APPCAST="$2"
RELEASE_LABEL="${TAG#v}"
EXPECTED_APPCAST="Voice-Relay-${RELEASE_LABEL}-appcast.xml"
EXPECTED_ARCHIVE="Voice-Relay-${RELEASE_LABEL}-update.zip"
EXPECTED_DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${TAG}/${EXPECTED_ARCHIVE}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)(\.[0-9]+)?$ \
      || "$(basename "$APPCAST")" != "$EXPECTED_APPCAST" \
      || ! -s "$APPCAST" ]]; then
  echo "The Sparkle feed input must match the preview-channel tag." >&2
  exit 2
fi
if ! /usr/bin/grep -Fq "url=\"${EXPECTED_DOWNLOAD_URL}\"" "$APPCAST" \
    || ! /usr/bin/grep -q 'sparkle:edSignature=' "$APPCAST"; then
  echo "The Sparkle feed does not bind the expected signed update archive." >&2
  exit 2
fi

RELEASE_STATE="$(
  "$GH_BIN" api "repos/${REPOSITORY}/releases/tags/${TAG}" \
    --jq '[.draft, .prerelease, ([.assets[].name] | index("'"$EXPECTED_ARCHIVE"'") != null)] | @tsv'
)"
if [[ "$RELEASE_STATE" != $'false\tfalse\ttrue' ]]; then
  echo "Publish the matching ordinary GitHub release and update archive first." >&2
  exit 3
fi

CONTENT="$(
  /usr/bin/base64 < "$APPCAST" | /usr/bin/tr -d '\n'
)"
EXISTING_SHA="$(
  "$GH_BIN" api "repos/${REPOSITORY}/contents/appcast.xml?ref=${BRANCH}" \
    --jq .sha 2>/dev/null || true
)"
API_ARGS=(
  --method PUT
  "repos/${REPOSITORY}/contents/appcast.xml"
  -f "message=release: publish Sparkle feed for ${TAG}"
  -f "content=${CONTENT}"
  -f "branch=${BRANCH}"
)
if [[ -n "$EXISTING_SHA" ]]; then
  API_ARGS+=(-f "sha=${EXISTING_SHA}")
fi
PUBLISHED_SHA="$("$GH_BIN" api "${API_ARGS[@]}" --jq .content.sha)"
if [[ -z "$PUBLISHED_SHA" ]]; then
  echo "GitHub did not confirm the published Sparkle feed." >&2
  exit 3
fi

echo "https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}/appcast.xml"
