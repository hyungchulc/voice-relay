This alpha makes spoken session endings reliable and context-aware.

- An accepted spoken stop now owns one protected acknowledgement transaction from creation through authoritative playback drain.
- Repeated speech while stopping cannot cancel, duplicate, reroute, or silently discard that acknowledgement.
- A transport failure cannot tear down terminal audio that is already queued; the retained acknowledgement remains the only completion authority.
- The short spoken-stop watchdog may observe a missing drain but cannot authorize teardown; the minutes-scale idle timeout remains unchanged.
- Wake standby resumes exactly once after acknowledged teardown, including the bounded transport-terminal fallback.
- Conversational closure now uses the immediate dialogue trajectory and tone instead of requiring explicit farewell vocabulary.
- Realtime receives the configured assistant, user, and product identities from General settings through the generated non-editable identity context.
- Build 35 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
