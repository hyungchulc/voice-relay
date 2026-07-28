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
