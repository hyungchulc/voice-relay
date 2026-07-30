This alpha hardens long-running Voice Relay conversations, turn control, and speech recovery.

- Active-turn status, repeat, stop, and steering requests now fail closed instead of silently mutating the wrong task or speaking success before acceptance.
- One absolute deadline follows every steering request through Swift, the local helper, the backend, and the real Codex client, so stale or late receipts cannot produce a second mutation or a false spoken success.
- Speech recognition and classifier output stay inside the primary and additional languages configured in Voice Relay, while short uncertain input asks for clarification in the configured fallback language.
- Rapid adjacent speech segments are preserved and assembled in order, including out-of-order transcription events, so a later fragment cannot replace the beginning of a longer request.
- Codex handoff receives bounded recent Voice context for deictic follow-ups, while echo-like or suppressed speech is excluded and spoken progress never repeats private identifiers or secret-like values.
- Commentary and final speech remain ordered through interruption and recovery, interrupted finals remain explicitly repeatable, and weak empty-transcript activity cannot destructively cancel playback.
- Spoken response speed can be adjusted within a safe range in Settings without changing the default voice behavior.
- Build 29 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
