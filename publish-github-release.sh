#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 <tag> <asset> [asset ...]" >&2
  exit 2
fi

TAG="$1"
shift

NOTES_FILE="${VOICE_RELAY_RELEASE_NOTES_FILE:-}"
TITLE="${VOICE_RELAY_RELEASE_TITLE:-Voice Relay ${TAG#v}}"
STABLE_APPROVED="${VOICE_RELAY_STABLE_RELEASE_APPROVED:-false}"
DRY_RUN="${VOICE_RELAY_RELEASE_DRY_RUN:-0}"
GH_BIN="${VOICE_RELAY_GH_BIN:-gh}"
REPOSITORY="${VOICE_RELAY_GITHUB_REPOSITORY:-hyungchulc/voice-relay}"

if [[ -z "$NOTES_FILE" || ! -s "$NOTES_FILE" ]]; then
  echo "Set VOICE_RELAY_RELEASE_NOTES_FILE to a non-empty release notes file." >&2
  exit 2
fi

for asset in "$@"; do
  if [[ ! -f "$asset" ]]; then
    echo "Release asset does not exist: $asset" >&2
    exit 2
  fi
done

RELEASE_KIND=""
if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)(\.[0-9]+)?$ ]]; then
  RELEASE_KIND="prerelease"
elif [[ "$TAG" == "v1.0.0" ]]; then
  if [[ "$STABLE_APPROVED" != "true" ]]; then
    echo "v1.0.0 requires explicit user approval through VOICE_RELAY_STABLE_RELEASE_APPROVED=true." >&2
    exit 2
  fi
  RELEASE_KIND="stable"
else
  echo "Stable publication is locked to an explicitly approved v1.0.0. Use an alpha, beta, or rc tag." >&2
  exit 2
fi

if [[ "$RELEASE_KIND" == "prerelease" ]]; then
  if [[ "$#" -ne 5 ]]; then
    echo "Prereleases require DMG, Sparkle update ZIP, checksums, and appcast." >&2
    exit 2
  fi
  RELEASE_LABEL="${TAG#v}"
  DMG_ASSET=""
  DMG_CHECKSUM_ASSET=""
  UPDATE_ASSET=""
  UPDATE_CHECKSUM_ASSET=""
  APPCAST_ASSET=""
  for asset in "$@"; do
    case "$(basename "$asset")" in
      Voice-Relay-"$RELEASE_LABEL"-*.dmg)
        DMG_ASSET="$asset"
        ;;
      Voice-Relay-"$RELEASE_LABEL"-*.dmg.sha256)
        DMG_CHECKSUM_ASSET="$asset"
        ;;
      Voice-Relay-"$RELEASE_LABEL"-*.zip)
        UPDATE_ASSET="$asset"
        ;;
      Voice-Relay-"$RELEASE_LABEL"-*.zip.sha256)
        UPDATE_CHECKSUM_ASSET="$asset"
        ;;
      Voice-Relay-"$RELEASE_LABEL"-appcast.xml)
        APPCAST_ASSET="$asset"
        ;;
    esac
  done
  if [[ -z "$DMG_ASSET" || -z "$DMG_CHECKSUM_ASSET" \
        || -z "$UPDATE_ASSET" || -z "$UPDATE_CHECKSUM_ASSET" \
        || -z "$APPCAST_ASSET" \
        || "$DMG_CHECKSUM_ASSET" != "${DMG_ASSET}.sha256" \
        || "$UPDATE_CHECKSUM_ASSET" != "${UPDATE_ASSET}.sha256" ]]; then
    echo "Prerelease DMG and updater asset names must match the tag." >&2
    exit 2
  fi
  EXPECTED_DMG_CHECKSUM="$(
    /usr/bin/shasum -a 256 "$DMG_ASSET" | /usr/bin/awk '{print $1}'
  )"
  RECORDED_DMG_CHECKSUM="$(
    /usr/bin/awk 'NR == 1 {print $1}' "$DMG_CHECKSUM_ASSET"
  )"
  EXPECTED_UPDATE_CHECKSUM="$(
    /usr/bin/shasum -a 256 "$UPDATE_ASSET" | /usr/bin/awk '{print $1}'
  )"
  RECORDED_UPDATE_CHECKSUM="$(
    /usr/bin/awk 'NR == 1 {print $1}' "$UPDATE_CHECKSUM_ASSET"
  )"
  if [[ "$EXPECTED_DMG_CHECKSUM" != "$RECORDED_DMG_CHECKSUM" \
        || "$EXPECTED_UPDATE_CHECKSUM" != "$RECORDED_UPDATE_CHECKSUM" ]]; then
    echo "Prerelease checksums do not match the packaged assets." >&2
    exit 2
  fi
  if ! /usr/bin/grep -q 'sparkle:edSignature=' "$APPCAST_ASSET"; then
    echo "Prerelease appcast is missing a signed Sparkle enclosure." >&2
    exit 2
  fi
fi

COMMAND=(
  "$GH_BIN"
  release
  create
  "$TAG"
  "$@"
  --verify-tag
  --title
  "$TITLE"
  --notes-file
  "$NOTES_FILE"
  --repo
  "$REPOSITORY"
)

if [[ "$RELEASE_KIND" == "prerelease" ]]; then
  COMMAND+=(--prerelease)
else
  COMMAND+=(--latest)
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%q ' "${COMMAND[@]}"
  printf '\n'
  if [[ "$RELEASE_KIND" == "prerelease" ]]; then
    printf '%q ' "$ROOT/publish-sparkle-feed.sh" "$TAG" "$APPCAST_ASSET"
    printf '\n'
  fi
  exit 0
fi

if "$GH_BIN" release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "GitHub release already exists for tag $TAG." >&2
  exit 3
fi

"${COMMAND[@]}"
if [[ "$RELEASE_KIND" == "prerelease" ]]; then
  VOICE_RELAY_GH_BIN="$GH_BIN" \
    "$ROOT/publish-sparkle-feed.sh" "$TAG" "$APPCAST_ASSET"
fi
