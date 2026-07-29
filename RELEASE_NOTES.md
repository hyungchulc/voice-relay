# Voice Relay 0.4.0-alpha.11

This prerelease fixes wake detection after long-running SpeechAnalyzer sessions
and adds secure in-app updates.

- Wake matching now starts from the current analyzer phrase instead of
  retaining unrelated finalized speech from the whole monitoring session.
- Every wake phrase configured in onboarding or Settings uses the same
  wake-anchored reducer. The fix is not tied to the default `Aria` name.
- Split and revised analyzer ranges preserve the command spoken after the wake
  phrase without duplicating earlier speech.
- About Voice Relay now uses pinned Sparkle 2.9.4 to download, verify, install,
  and relaunch signed prerelease updates.
- Update archives and the stable appcast are protected by a dedicated Sparkle
  EdDSA key. Sparkle framework components are signed leaf-first.
- Scheduled background checks and silent automatic installation remain
  disabled. Updates begin only when the user chooses **Check for Updates…**.

This is the first Sparkle-enabled build, so install this alpha manually once.
Future updater-enabled prereleases can be installed from inside Voice Relay.
