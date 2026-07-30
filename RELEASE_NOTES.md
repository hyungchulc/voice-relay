This alpha makes wake handoff, stop acknowledgements, and Realtime semantic routing more coherent.

- A wake-only recognition followed by a replayed command suffix now becomes one canonical visible utterance, while the model receives only the suffix and only once.
- True wake-only activation remains bounded and does not create a conversational user turn.
- Stop requests keep their full Voice and active Codex cancellation behavior, while Realtime acknowledges the user's conversational intent instead of narrating backend operations.
- Realtime production instructions now use one English semantic contract and respond in the user's language without phrase tables, language-specific reply lists, or example-specific routing branches.
- Request-aware progress cues receive only a bounded semantic summary, and unsafe or unvalidated details fail closed to a generic cue.
- Existing custom Realtime instructions are preserved, while prior generated defaults migrate to the current common contract.
- Build 33 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
