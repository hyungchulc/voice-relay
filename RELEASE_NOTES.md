This alpha preserves the complete first utterance when wake detection hands audio to Realtime.

- Capture admission now waits for the Realtime session to commit before replay can finish or clear the wake journal.
- The replay journal has one owner, and replay pumping is non-destructive until the handoff outcome is committed.
- WebSocket send completion is recorded against the immutable ticket and generation so late callbacks cannot finish a newer handoff.
- Failed or stale admissions remain retryable instead of silently dropping the committed audio tail.
- Regression coverage now exercises the capture barrier, replay ownership, stale generations, send completion, and retry behavior.
- Build 36 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
