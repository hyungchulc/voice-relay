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

An Apple Development signature identifies a developer build, but it is not
Developer ID signing or Apple notarization, and Gatekeeper may still require
Open Anyway. A normal trusted public binary release requires:

1. a clean checkout and publication audit;
2. a Developer ID Application certificate;
3. hardened runtime signing;
4. notarization and stapling;
5. verification on a non-development Mac.

The public alpha packager requires an explicit Apple signing identity so an
identity-less artifact cannot be uploaded accidentally:

```bash
VOICE_RELAY_SIGNING_IDENTITY="Apple Development: Example Person (TEAMID)" \
VOICE_RELAY_SOURCE_URL="https://github.com/example/voice-relay/archive/refs/tags/v0.4.0-alpha.4.tar.gz" \
VOICE_RELAY_RELEASE_LABEL="0.4.0-alpha.4" \
./package-alpha-dmg.sh
```

The DMG contains the universal app, an Applications shortcut, GPLv3 license,
installation and Gatekeeper instructions, distribution notes, and the exact
corresponding-source URL. An Apple Development build is signed for development
and testing, but is not notarized.

## GitHub release policy

- Every alpha, beta, and release candidate is a GitHub prerelease.
- No prerelease may carry the GitHub `Latest` marker.
- Stable publication is locked until the user explicitly approves `v1.0.0`.
- `publish-github-release.sh` enforces this policy and rejects other stable
  tags instead of guessing release intent.
- Public prereleases carry a manual-install DMG, a Sparkle update ZIP, their
  checksums, and a versioned signed appcast.
- Sparkle 2.9.4 is checksum-pinned at build time. Its framework and nested
  services are signed leaf-first; application signing never uses `--deep`.
- `publish-sparkle-feed.sh` publishes the verified versioned appcast to the
  stable public `appcast.xml` URL only after the matching prerelease archive is
  visible.
- The first Sparkle-enabled alpha still requires one manual installation.
  Later prereleases can be downloaded, verified, installed, and relaunched
  from About Voice Relay.
- Each release must use an existing verified tag, non-empty release notes, and
  the matching package assets.

Example:

```bash
VOICE_RELAY_RELEASE_NOTES_FILE="./release-notes.md" \
./publish-github-release.sh \
  v0.4.0-alpha.8 \
  releases/Voice-Relay-0.4.0-alpha.8-development-signed.dmg \
  releases/Voice-Relay-0.4.0-alpha.8-development-signed.dmg.sha256
```

After explicit approval of the first stable release, set
`VOICE_RELAY_STABLE_RELEASE_APPROVED=true` and publish exactly `v1.0.0`.

## Commercial option

The copyright holder may separately sell official builds, setup, support,
warranty, or a commercial license. The GPLv3 rights for a version already
distributed under GPLv3 remain available for that version.
