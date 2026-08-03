#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_ROOT/public-source-files.txt"
PRIVATE_CONTENT_PATTERN='-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{24,}|/Users/[^/[:space:]]+|/home/[^/[:space:]]+|[A-Za-z]:\\Users\\[^\\[:space:]]+|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|~/(\.omx|\.agents|\.codex/(agents|memories|plugins|skills))(/|[[:space:]]|$)|\$HOME/(\.omx|\.agents|\.codex/(agents|memories|plugins|skills))(/|[[:space:]]|$)|\$\{HOME\}/(\.omx|\.agents|\.codex/(agents|memories|plugins|skills))(/|[[:space:]]|$)|/(\.omx|\.agents|\.codex/(agents|memories|plugins|skills))/'

contains_private_content() {
  /usr/bin/grep -RIlE \
    --exclude-dir=.git \
    --exclude=LICENSE \
    --exclude=audit-public-source.sh \
    -- \
    "$PRIVATE_CONTENT_PATTERN" \
    "$1" >/dev/null
}

if [[ "$#" -eq 2 && "$1" == "--content-only" ]]; then
  CONTENT_TARGET="$2"
  if [[ ! -e "$CONTENT_TARGET" ]]; then
    echo "usage: $0 --content-only <file-or-directory>" >&2
    exit 2
  fi
  if contains_private_content "$CONTENT_TARGET"; then
    echo "Public package content contains credential-like or private local content." >&2
    exit 3
  fi
  echo "Voice Relay public package content audit passed"
  exit 0
fi

TARGET="${1:-$SCRIPT_ROOT}"

if [[ "$#" -gt 1 || ! -d "$TARGET" || ! -f "$MANIFEST" ]]; then
  echo "usage: $0 [public-source-root]" >&2
  exit 2
fi

TARGET="$(cd "$TARGET" && pwd)"
TARGET_MANIFEST="$TARGET/public-source-files.txt"
if [[ ! -f "$TARGET_MANIFEST" ]] \
    || ! /usr/bin/cmp -s "$MANIFEST" "$TARGET_MANIFEST"; then
  echo "Public source manifest is missing or does not match the audited exporter." >&2
  exit 3
fi

if ! LC_ALL=C /usr/bin/sort -c -u "$MANIFEST"; then
  echo "Public source manifest must be sorted and contain unique paths." >&2
  exit 3
fi

ACTUAL_FILES="$(mktemp "${TMPDIR:-/tmp}/voice-relay-public-files.XXXXXX")"
cleanup() {
  /bin/unlink "$ACTUAL_FILES" >/dev/null 2>&1 || true
}
trap cleanup EXIT

(
  cd "$TARGET"
  /usr/bin/find . \
    -path './.git' -prune -o \
    -type f -print
) | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort > "$ACTUAL_FILES"

if ! /usr/bin/diff -u "$MANIFEST" "$ACTUAL_FILES" >/dev/null; then
  echo "Public source tracked-file boundary does not match public-source-files.txt." >&2
  /usr/bin/diff -u "$MANIFEST" "$ACTUAL_FILES" >&2 || true
  exit 3
fi

if /usr/bin/find "$TARGET" \
    -mindepth 1 \
    -path "$TARGET/.git" -prune -o \
    -type l -print -quit | /usr/bin/grep -q .; then
  echo "Public source must not contain symbolic links." >&2
  exit 3
fi

if /usr/bin/find "$TARGET" \
    -mindepth 1 \
    -path "$TARGET/.git" -prune -o \
    \( -type f -o -type d \) -prune -o \
    -print -quit | /usr/bin/grep -q .; then
  echo "Public source must contain only regular files and directories." >&2
  exit 3
fi

if /usr/bin/find "$TARGET" \
    -path "$TARGET/.git" -prune -o \
    -type d \
    \( -name Promotion -o -name build -o -name experimental-build \
       -o -name release -o -name releases -o -name logs -o -name Logs \
       -o -name sessions -o -name Sessions -o -name .codex -o -name .omx \
       -o -name private -o -name private-context \) \
    -print -quit | /usr/bin/grep -q .; then
  echo "Public source contains a prohibited local, generated, or promotional directory." >&2
  exit 3
fi

if /usr/bin/find "$TARGET" \
    -path "$TARGET/.git" -prune -o \
    -type f \
    \( -name '.env' -o -name '.env.*' -o -name '*.log' -o -name '*.jsonl' \
       -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \
       -o -name '*.dSYM' -o -name '*.xcarchive' -o -name '*.pkg' \
       -o -name '*.zip' -o -name '*.pem' -o -name '*.p12' \
       -o -name '*.mobileprovision' \) \
    ! -name '.env.example' \
    -print -quit | /usr/bin/grep -q .; then
  echo "Public source contains a prohibited local-state, credential, log, or build file." >&2
  exit 3
fi

if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C "$TARGET" ls-files -s \
      | /usr/bin/awk '$1 == "160000" { found = 1 } END { exit !found }'; then
  echo "Public source must not contain Git submodules." >&2
  exit 3
fi

if contains_private_content "$TARGET"; then
  echo "Public source contains credential-like or private local content." >&2
  exit 3
fi

echo "Voice Relay public source audit passed"
