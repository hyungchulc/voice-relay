This alpha keeps the persistent Voice task ready and makes spoken corrections observable from receipt through effect.

- A saved Voice task that is not loaded is resumed in place, re-read, and validated before use instead of failing the first request or replacing the task prematurely.
- Voice Relay refreshes task residency in the background and reconciles it again immediately before each command, while concurrent checks share one load operation.
- A finalized spoken correction appears immediately with its exact text and a pending state, accompanied by a local audible receipt.
- The same correction becomes applied, failed, expired, or superseded only after the active Codex turn reports its real control outcome.
- A bounded exact-repeat guard suppresses silence-driven duplicate corrections without dropping distinct corrections or changing their wording.
- Wake recognition now journals microphone audio across analyzer rearm and replays the ordered gap so the first phoneme is not silently discarded after idle maintenance.
- Build 41 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
