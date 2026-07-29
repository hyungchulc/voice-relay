# Voice Relay 0.4.0-alpha.12

This prerelease makes the delegated-work handoff sound like progress instead
of a generic acknowledgement.

- Handoff speech now conveys that Voice Relay needs a moment because checking
  has started, instead of merely acknowledging receipt.
- The route classifier passes only the spoken language's BCP 47 tag to the
  isolated progress response. There is no language-specific phrase table.
- Realtime chooses fresh, idiomatic wording in the user's actual language.
- Handoff speech still stays outside the Realtime conversation and never
  receives the original request, preventing it from inventing an answer.
- Codex is not mentioned in spoken handoff progress.
- The wake-anchored SpeechAnalyzer fix and Sparkle updater from alpha.11 remain
  included.
