This alpha fixes the Thinking level menu order in Voice Relay Settings.

- Known reasoning levels are presented in semantic ascending order rather than alphabetically.
- The ordering covers none, minimal, low, medium, high, xhigh, max, and ultra whenever the host reports them.
- Duplicate capability identifiers are removed without dropping supported values.
- Unknown future identifiers remain available and are ordered deterministically after known levels.
- Spoken work-in-progress cues now describe one resolved action and referent instead of voicing classifier categories, alternatives, or unresolved option lists.
- Progress cues preserve conversational deixis, address the listener naturally, and omit unresolved or sensitive referents across languages and domains.
- Regression coverage protects shuffled input, duplicates, and future capability identifiers.
- Build 39 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
