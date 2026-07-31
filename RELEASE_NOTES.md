This alpha separates session transport from microphone input and adds supported Codex profile controls to Settings.

- The expanded overlay now keeps exactly three controls in order: Settings, microphone input, and Play or Stop.
- Microphone mute stops capture and recognition without stopping playback, the active voice session, or the current Codex task, and unmute resumes the appropriate input path.
- Settings now persist Model, Thinking level, and Fast mode selections discovered from the live Codex capability surface.
- Unsupported profile combinations fail closed, while Fast mode maps to the supported accelerated service tier and the default path omits any tier override.
- Selected profile values propagate through task preparation, session resume, new turns, and same-task follow-ups instead of remaining UI-only state.
- Accepted same-turn corrections now form an exact response-revision boundary, so an obsolete pending final cannot be combined with corrected post-steer finals while multiple distinct finals from the corrected revision remain ordered and exactly once.
- Collapsed notch and answer content now yield cleanly during Settings-driven overlay rebuilds instead of producing Auto Layout constraint conflicts.
- Regression coverage protects control ordering, independent microphone state, preference persistence, capability gating, and actual request propagation.
- Build 37 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
