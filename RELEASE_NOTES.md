This bugfix keeps Voice Relay's on-device wake recognition responsive during long-running listening.

- SpeechAnalyzer sessions now complete a clean two-minute rotation before the observed late-session failure window.
- Converted microphone buffers carry an explicit sample timeline, so bounded input buffering cannot silently compress skipped audio.
- Sustained analyzer backpressure is detected and recovered instead of accumulating into an unreported recognition failure.
- Old volatile recognition state is finalized regularly while split wake and command ranges are still reassembled into the complete request.
- Runtime analyzer failures restart the modern SpeechAnalyzer with bounded backoff instead of unexpectedly changing to the legacy recognizer.
- A live development-build soak ran for more than four hours with repeated clean rotations and no runtime analyzer failure, input drop, or legacy selection in the inspected windows.
- Build 26 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
