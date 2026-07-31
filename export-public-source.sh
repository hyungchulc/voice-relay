#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_ROOT/public-source-files.txt"

if [[ "$#" -ne 2 || ! -d "$1" || ! -d "$2" ]]; then
  echo "usage: $0 <maintained-source-root> <fresh-public-clone-root>" >&2
  exit 2
fi

SOURCE_ROOT="$(cd "$1" && pwd)"
DESTINATION_ROOT="$(cd "$2" && pwd)"
if [[ "$SOURCE_ROOT" == "$DESTINATION_ROOT" ]]; then
  echo "Public source export requires distinct source and destination roots." >&2
  exit 2
fi

while IFS= read -r relative_path; do
  source_path="$SOURCE_ROOT/$relative_path"
  destination_path="$DESTINATION_ROOT/$relative_path"
  if [[ "$relative_path" == "appcast.xml" ]]; then
    if [[ ! -f "$destination_path" || -L "$destination_path" ]]; then
      echo "The public Sparkle feed must already exist in the fresh public clone." >&2
      exit 3
    fi
    continue
  fi
  if [[ ! -f "$source_path" || -L "$source_path" ]]; then
    echo "Manifest source is missing or is not a regular file: $relative_path" >&2
    exit 3
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "$destination_path")"
  /usr/bin/ditto "$source_path" "$destination_path"
done < "$MANIFEST"

"$SCRIPT_ROOT/audit-public-source.sh" "$DESTINATION_ROOT"
