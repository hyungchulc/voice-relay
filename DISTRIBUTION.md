# Alpha distribution

Voice Relay is a public developer alpha. Source is distributed under GPLv3.
Official builds, setup, and support may be offered separately.

## Current release boundary

- Publish source from a clean, publication-safe Git history.
- Include the Voice Relay icon and complete corresponding source.
- Never include local preferences, Remote enrollment, device keys, Session IDs,
  private context files, access tokens, logs, or developer filesystem paths.
- Fresh installs use `Relay` as the assistant name, `Relay` and `Hey Relay` as
  English wake phrases, and an empty Session ID. The all-zero UUID shown in the
  UI is an example placeholder, not a real binding.
- Fresh installs use an app-owned workspace rather than the user's entire home
  directory as the Codex working folder.
- Authority Pack is disabled with an empty path on fresh installs. The public
  source ships only its generic manifest, loader, UI, tests, and documentation,
  never a selected path or personal Authority contents.
- Voice Relay keeps one dedicated task. Nightly maintenance does not inspect,
  rotate, or mutate it.

## Known alpha limitations

The app bundles the GPLv3 Codex Remote support source it needs. Realtime uses a
short-lived credential from the signed-in local Codex OAuth session and does
not require a separate broker or private support checkout. Voice Relay does not
request, embed, or store an OpenAI API key.

An ad-hoc signature proves bundle integrity only. It is not Developer ID
signing or Apple notarization, and Gatekeeper may block the app. A normal public
binary release requires:

1. a clean checkout and publication audit;
2. a Developer ID Application certificate;
3. hardened runtime signing;
4. notarization and stapling;
5. verification on a non-development Mac.

The public alpha can still be packaged as an ad-hoc signed DMG for testers who
accept that limitation:

```bash
VOICE_RELAY_SOURCE_URL="https://github.com/example/voice-relay/archive/refs/tags/v0.4.0-alpha.2.tar.gz" \
VOICE_RELAY_RELEASE_LABEL="0.4.0-alpha.2" \
./package-alpha-dmg.sh
```

The DMG contains the universal app, an Applications shortcut, GPLv3 license,
installation and Gatekeeper instructions, distribution notes, and the exact
corresponding-source URL. It is ad-hoc signed, not Developer ID signed or
notarized.

## Commercial option

The copyright holder may separately sell official builds, setup, support,
warranty, or a commercial license. The GPLv3 rights for a version already
distributed under GPLv3 remain available for that version.
