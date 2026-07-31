This alpha makes the Voice Relay Codex profile selected in Settings authoritative for the next actual turn.

- Explicit Model and Thinking selections are applied and verified on the bound Voice task before a new turn is dispatched.
- Default or Inherit re-reads the current host Codex configuration for every request instead of caching a previously resolved value.
- Turning Fast mode off explicitly clears the Voice priority override and returns service-tier behavior to the host configuration.
- A normal new request never becomes a profile-less steer of an already active turn; it fails busy before dispatch while the dedicated correction path remains separate.
- Accepted-turn validation is bound to an immutable per-request profile snapshot and reports both expected and actual values if a mismatch is observed.
- Codex failures use a sanitized deterministic playback notice, so Realtime cannot invent plausible requested content after a failed route.
- Regression coverage protects explicit medium reasoning on an existing xhigh task, inherited config changes, priority clearing, root-versus-correction routing, and failure-speech fidelity.
- Build 38 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
