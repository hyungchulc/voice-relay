This alpha hardens always-on wake capture, multilingual routing, response completion, task control, and opt-in Connectors.

- Idle wake monitoring now uses a raw input-only capture plane, while active Realtime conversations retain full-duplex voice processing and echo cancellation.
- Capture ownership, mute and unmute, restart recovery, startup failure, playback-reference lifetime, and wake-to-conversation cutover are fenced for ordered, exact-once audio delivery.
- Locale selection follows a language-independent evidence hierarchy with confidence-aware clarification and user override, without per-language phrase tables.
- Short incomplete or uncertain turns clarify instead of opening work, while answer cancellation, Voice Relay session stop, external-object commands, and follow-up steering remain distinct.
- Playback completion has generation-fenced watchdog recovery so a missing native callback cannot leave the interface stuck responding or inflate a successor deadline.
- Model, reasoning, and service-tier settings preserve explicit choices, inheritance, and Fast-off behavior.
- The public Connector v1 contract supports explicit browse-and-select installation, validation, permissions, availability and error states, enable and remove controls, safe empty or unavailable degradation, and idempotent briefing delivery.
- No private connector is bundled or auto-discovered. Connector bindings are user-selected and stored only in app-local settings, and source and package audits reject private paths, credentials, and identity-specific data.
- Build 42 is the signed update target for Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
