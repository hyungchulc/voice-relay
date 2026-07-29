This alpha hardens Voice Relay's conversation boundaries during interruption-heavy real use.

- User barge-ins no longer leave queued turns frozen when a cancelled Realtime response acknowledges late or never reports a terminal event.
- Codex finals wait while a user utterance is active, and superseded answers are discarded instead of speaking over a newer request.
- Provisional wake-phrase prefixes remain open for a command spoken in the same utterance, while finalized wake-only activation stays fast.
- Ordinary voice and presentation settings preserve the current Codex Session ID unless the user deliberately changes the task binding.
- Direct replies keep one spoken register, numeric ranges are spoken as ranges, and link-only references or opaque metadata remain visible without being read aloud.
- Spoken stop acknowledgements are mirrored visibly before teardown, while commands to stop media or another external object continue through the active Codex task.
- Build 27 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
