#!/usr/bin/env bash
set -euo pipefail

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
  if [[ "$#" -ne 2 ]]; then
    echo "Prereleases require exactly one DMG and its SHA-256 file." >&2
    exit 2
  fi
  RELEASE_LABEL="${TAG#v}"
  DMG_ASSET=""
  CHECKSUM_ASSET=""
  for asset in "$@"; do
    case "$(basename "$asset")" in
      Voice-Relay-"$RELEASE_LABEL"-*.dmg)
        DMG_ASSET="$asset"
        ;;
      Voice-Relay-"$RELEASE_LABEL"-*.dmg.sha256)
        CHECKSUM_ASSET="$asset"
        ;;
    esac
  done
  if [[ -z "$DMG_ASSET" || -z "$CHECKSUM_ASSET" \
        || "$CHECKSUM_ASSET" != "${DMG_ASSET}.sha256" ]]; then
    echo "Prerelease asset names must match the publication tag and each other." >&2
    exit 2
  fi
  EXPECTED_CHECKSUM="$(
    /usr/bin/shasum -a 256 "$DMG_ASSET" | /usr/bin/awk '{print $1}'
  )"
  RECORDED_CHECKSUM="$(
    /usr/bin/awk 'NR == 1 {print $1}' "$CHECKSUM_ASSET"
  )"
  if [[ "$EXPECTED_CHECKSUM" != "$RECORDED_CHECKSUM" ]]; then
    echo "Prerelease checksum does not match the DMG." >&2
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
)

if [[ "$RELEASE_KIND" == "prerelease" ]]; then
  COMMAND+=(--prerelease)
else
  COMMAND+=(--latest)
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%q ' "${COMMAND[@]}"
  printf '\n'
  exit 0
fi

if "$GH_BIN" release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release already exists for tag $TAG." >&2
  exit 3
fi

"${COMMAND[@]}"
