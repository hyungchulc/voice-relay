#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay-public-audit.XXXXXX")"
MAINTAINED_ROOT="$TEST_DIR/maintained"
PUBLIC_ROOT="$TEST_DIR/public"

cleanup() {
  /bin/rm -rf "$TEST_DIR"
}
trap cleanup EXIT

expect_audit_failure() {
  local label="$1"
  if "$ROOT/audit-public-source.sh" "$PUBLIC_ROOT" >/dev/null 2>&1; then
    echo "FAIL: public source audit accepted $label" >&2
    exit 1
  fi
}

/bin/mkdir -p "$MAINTAINED_ROOT"
/usr/bin/printf '<rss><channel/></rss>\n' > "$MAINTAINED_ROOT/appcast.xml"
"$ROOT/export-public-source.sh" "$ROOT" "$MAINTAINED_ROOT" >/dev/null
/bin/mkdir -p "$MAINTAINED_ROOT/Promotion"
/usr/bin/printf 'internal campaign work\n' \
  > "$MAINTAINED_ROOT/Promotion/draft.txt"
/usr/bin/printf 'internal launch notes\n' > "$MAINTAINED_ROOT/PROMOTION.md"

/bin/mkdir -p "$PUBLIC_ROOT"
/usr/bin/printf '<rss><channel/></rss>\n' > "$PUBLIC_ROOT/appcast.xml"
"$ROOT/export-public-source.sh" "$MAINTAINED_ROOT" "$PUBLIC_ROOT" >/dev/null
"$ROOT/audit-public-source.sh" "$PUBLIC_ROOT" >/dev/null

test -f "$PUBLIC_ROOT/Resources/connector.schema.json"
test -f "$PUBLIC_ROOT/Sources/ConnectorCore.swift"
test -f "$PUBLIC_ROOT/Tests/ConnectorCoreTests.swift"
test -f "$PUBLIC_ROOT/Tests/PresenceMonitorTests.swift"

test -d "$MAINTAINED_ROOT/Promotion"
test -f "$MAINTAINED_ROOT/PROMOTION.md"
test ! -e "$PUBLIC_ROOT/Promotion"
test ! -e "$PUBLIC_ROOT/PROMOTION.md"

/bin/mkdir "$PUBLIC_ROOT/Promotion"
expect_audit_failure "an empty promotional working directory"
/bin/rmdir "$PUBLIC_ROOT/Promotion"

/bin/mkdir "$PUBLIC_ROOT/build"
/usr/bin/touch "$PUBLIC_ROOT/build/VoiceRelay"
expect_audit_failure "build output"
/bin/rm -rf "$PUBLIC_ROOT/build"

/usr/bin/touch "$PUBLIC_ROOT/.env"
expect_audit_failure "an environment file"
/bin/unlink "$PUBLIC_ROOT/.env"

/usr/bin/touch "$PUBLIC_ROOT/runtime.log"
expect_audit_failure "a runtime log"
/bin/unlink "$PUBLIC_ROOT/runtime.log"

/bin/mkdir "$PUBLIC_ROOT/Sessions"
expect_audit_failure "session state"
/bin/rmdir "$PUBLIC_ROOT/Sessions"

/usr/bin/printf '%s\n' \
  "$(printf '%s%s%s' '-----BEGIN ' 'PRIVATE KEY' '-----')" \
  'not-a-real-key' \
  "$(printf '%s%s%s' '-----END ' 'PRIVATE KEY' '-----')" \
  > "$PUBLIC_ROOT/README.md"
expect_audit_failure "credential-like content"
/usr/bin/ditto "$ROOT/README.md" "$PUBLIC_ROOT/README.md"

private_home_path="$(printf '/%s/%s/%s/%s' Users sample-user private-work helper)"
/usr/bin/printf '%s\n' "$private_home_path" \
  > "$PUBLIC_ROOT/Tests/PublicSourceAuditTests.sh"
expect_audit_failure "private content inside a public test fixture"
/usr/bin/ditto "$ROOT/Tests/PublicSourceAuditTests.sh" \
  "$PUBLIC_ROOT/Tests/PublicSourceAuditTests.sh"

private_helper_path="$(printf '%s/%s/%s/%s' '~' .codex memories private-note)"
/usr/bin/printf '%s\n' "$private_helper_path" > "$PUBLIC_ROOT/README.md"
expect_audit_failure "a private home-relative helper path"
/usr/bin/ditto "$ROOT/README.md" "$PUBLIC_ROOT/README.md"

identity_marker="$(printf '%s%s%s' sample-user '@' example.invalid)"
/usr/bin/printf '%s\n' "$identity_marker" \
  > "$PUBLIC_ROOT/Tests/PublicSourceAuditTests.sh"
expect_audit_failure "an identity-bearing public test fixture"
/usr/bin/ditto "$ROOT/Tests/PublicSourceAuditTests.sh" \
  "$PUBLIC_ROOT/Tests/PublicSourceAuditTests.sh"

CONTENT_ROOT="$TEST_DIR/package-content"
/bin/mkdir -p "$CONTENT_ROOT"
/usr/bin/printf 'public package resource\n' > "$CONTENT_ROOT/resource.txt"
"$ROOT/audit-public-source.sh" --content-only "$CONTENT_ROOT" >/dev/null
/usr/bin/printf '%s\n' "$private_helper_path" > "$CONTENT_ROOT/resource.txt"
if "$ROOT/audit-public-source.sh" --content-only "$CONTENT_ROOT" \
    >/dev/null 2>&1; then
  echo "FAIL: package content audit accepted a private helper path" >&2
  exit 1
fi

/bin/ln -s README.md "$PUBLIC_ROOT/readme-link"
expect_audit_failure "a symbolic link"
/bin/unlink "$PUBLIC_ROOT/readme-link"

/usr/bin/touch "$PUBLIC_ROOT/unreviewed-source.txt"
expect_audit_failure "an unmanifested file"
/bin/unlink "$PUBLIC_ROOT/unreviewed-source.txt"

"$ROOT/audit-public-source.sh" "$PUBLIC_ROOT" >/dev/null
echo "Voice Relay public source audit tests passed"
