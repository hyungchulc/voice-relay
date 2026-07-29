This alpha makes delegated-task progress speech match the user's actual request.

- Initial progress cues now name the concrete action underway instead of repeating a generic checking or waiting phrase.
- The current request is isolated as untrusted data and used only to shape a short progress cue, without exposing prior Realtime conversation context.
- Progress cues cannot claim a result, finding, success, or completion before the delegated task finishes.
- The first Codex commentary remains visible but is not spoken again after request-aware progress succeeds.
- Later commentary speaks only its new suffix, while the final answer continues through the existing detached speech queue.
- Build 28 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
