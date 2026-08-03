# Security policy

## Supported versions

Only the newest public alpha receives security fixes.

## Reporting

Please use GitHub's private vulnerability reporting for the Voice Relay
repository. Do not open a public issue for a suspected vulnerability.

Include:

- the affected version or commit;
- the smallest reproducible case;
- expected and observed behavior;
- impact and required local permissions;
- whether credentials, Remote state, audio, or user data may be exposed.

Do not send real tokens, pairing state, private context files, or personal
logs. Replace sensitive values with clearly synthetic examples.

## Release boundary

Public source and archives must not contain local preferences, Remote
enrollment, device keys, Session IDs, private context bundles, access tokens,
logs, or developer filesystem paths.

Authority Pack is disabled and blank by default. Public source includes only
the generic loader, fixed manifest, tests, and documentation. It must never
contain a contributor's selected path or Authority file contents. When a user
enables the feature, those seven files are intentionally sent to that user's
Codex task. Users should therefore treat the folder as sensitive configuration
and avoid putting secrets, credentials, logs, dynamic tool output, or unrelated
personal data in it.

Additional Context Providers are also disabled and blank by default. Provider
scripts are user-owned executable code and are never bundled or discovered
automatically. When enabled, their bounded output is intentionally sent to the
user's Codex task as grounding data. Review provider code before enabling it,
keep provider folders private, and never emit credentials, access tokens,
unrelated personal data, or unbounded logs.

Connector v1 is disabled by default and never auto-discovers or bundles a
connector. Adding a manifest validates only data and does not execute code.
Enabling requires an explicit warning because the selected executable runs
unsandboxed with the current user's macOS privileges. Approval is bound to the
exact manifest and executable SHA-256 digests; changed bytes fail closed and
require a fresh binding. Settings never auto-discovers connectors: it validates
only the explicitly selected manifest and stores that binding in app-local
state. Manifests are strict, read-only, require permissions matching declared
data classes, and are limited to one sibling regular executable. Runs execute a
private per-run copy made from the exact verified bytes, with a minimal
environment, bounded time and output, structured result validation, discarded
standard error, privacy-safe reason codes, and a persistent idempotency ledger.
Declared connector permissions do not create an OS sandbox, so users must still
review connector code and its requested data access.
