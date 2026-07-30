This alpha makes wake activation, bilingual transcription, and spoken output more reliable.

- Wake recognition and Realtime now share one persistent native audio graph, with frame-identified post-wake audio preserved across the handoff instead of closing and reopening the microphone.
- A wake-only partial waits for a bounded finalization window, while a wake phrase followed by a command supersedes it and routes the command without a generic greeting.
- Realtime transcription now derives its ordered language list from the primary and additional Voice Relay language settings, normalizes regional variants, and never introduces an unconfigured language.
- Clearly unconfigured-script transcripts ask for clarification instead of being treated as valid Korean or English requests.
- The first canonical user utterance now appears in the notch once by stable turn identity, without exposing partial transcription noise or duplicating a wake phrase.
- Spoken answers omit trailing source labels and link blocks while the full visible answer and its sources remain intact.
- Build 31 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
