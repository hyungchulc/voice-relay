# Connector v1

Connector v1 is Voice Relay's public, read-only, event-driven extension
boundary. It is separate from Additional Context Providers: connectors answer a
host event directly and never create, rotate, or send a turn to a Codex task.

## Install and trust

1. Put `connector.json` beside one executable regular file.
2. In **Settings → Advanced → Connector v1**, choose `connector.json`.
3. Review its name, data classes, and required permissions.
4. Enable it only after accepting the unsandboxed-code warning.

Voice Relay never searches for connectors. Adding and validating a manifest
uses only the file selected in Settings and never executes its program. A new
binding is disabled and stored in the app's local connector registry. Enabling
records SHA-256 digests for the manifest and executable; a later byte change
fails with `trust_required` until the connector is removed, added, and approved
again. Removing a binding does not delete user files.

Connector programs run unsandboxed with the current macOS user's privileges.
The `requiredPermissions` declaration is an approval boundary and status signal,
not an operating-system sandbox. Review connector code before enabling it.

## Manifest

The authoritative JSON Schema is
[`Resources/connector.schema.json`](Resources/connector.schema.json). Connector
v1 accepts no undeclared manifest fields, requires `readOnly: true`, and only
allows a sibling executable file name.

Every declared data class requires its matching permission:
`calendar_events` requires `calendar.read`, `reminders` requires
`reminders.read`, and `location` requires `location.read`.

```json
{
  "schemaVersion": 1,
  "id": "org.example.daily-brief",
  "version": "1.0.0",
  "name": "Example Daily Brief",
  "executable": "daily-brief",
  "protocol": "voice-relay.connector.v1",
  "capabilities": ["daily_brief"],
  "triggers": ["return", "morning", "manual"],
  "dataClasses": ["calendar_events"],
  "requiredPermissions": ["calendar.read"],
  "readOnly": true,
  "limits": {
    "timeoutMilliseconds": 5000,
    "maxOutputBytes": 32768
  }
}
```

## Host event

Voice Relay reads and verifies the approved executable bytes, writes those exact
bytes to a private host-owned per-run file, and launches that verified copy with
no arguments, a minimal environment, the manifest directory as its working
directory, and one JSON event on standard input. Standard error is discarded.
The host owns event IDs, scheduling, presence heuristics, and the idempotency
key.

```json
{
  "schemaVersion": 1,
  "eventID": "D8D661AA-35D5-4C3B-9D0D-2B11B7F1E880",
  "idempotencyKey": "daily-brief:2026-08-03",
  "trigger": "morning",
  "occurredAt": "2026-08-03T06:00:00Z",
  "localDay": "2026-08-03",
  "absenceSeconds": 1900,
  "presenceEvidence": "user_activity_heuristic"
}
```

`presenceEvidence` is evidence about an input or session signal, not proof of a
person's physical presence. Optional fields may be absent.

## Structured result

The executable must write exactly one bounded JSON object to standard output.
`deliveryID` must equal the event's `eventID`. `expiresAt` must be later than
both `generatedAt` and the host event. The composed title and items must fit the
Realtime admission limit of 8,000 UTF-16 code units.

```json
{
  "schema": "voice-relay-brief-result-v1",
  "deliveryID": "D8D661AA-35D5-4C3B-9D0D-2B11B7F1E880",
  "disposition": "speak",
  "generatedAt": "2026-08-03T06:00:01Z",
  "expiresAt": "2026-08-03T12:00:00Z",
  "title": "Daily brief",
  "items": [
    { "text": "Team review at 10:00" }
  ]
}
```

Supported dispositions are:

- `speak`: present the supplied title and items.
- `no_update`: an explicit successful empty result; `items` must be empty.
- `defer`: do not present this event yet.
- `abstain`: the connector intentionally provides no result.

Missing executables, permission denial, timeouts, stale data, invalid JSON, and
process failures are distinct from `no_update`. Voice Relay never turns those
states into “nothing scheduled.”

## Delivery and privacy

The persistent ledger moves through `reserved → prepared → presented →
completed`, or terminates as `abstained` or `failed`. Daily morning and return
events share one local-day idempotency key. `presented` requires an authoritative
Realtime final whose automatic-speech kind and response ID match the reserved
delivery. `completed` requires native playback drain for that exact response ID.
Presence cooldown begins only after that drain. Automatic speech defers when
other media is active or media status is unavailable.

The app stores connector paths only in the user's local binding file. Paths,
program output, standard error, and user data are not bundled into public source
or release archives. Diagnostics use fixed status and reason codes.
