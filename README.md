# Voice Relay

![Voice Relay icon](Resources/VoiceRelayIcon-1024.png)

[![CI](https://github.com/hyungchulc/voice-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/hyungchulc/voice-relay/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-2EA44F.svg)](LICENSE)

> Public alpha. APIs, setup, and packaging may change before 1.0.

**Turn the full Codex desktop runtime into a native, persistent,
context-aware voice assistant on macOS.**

Voice Relay connects direct OpenAI Realtime Voice to the already-running
Codex/ChatGPT desktop app. Fast conversation stays live in Realtime. Requests
that need current facts, tools, apps, files, memory, approvals, or more than a
few seconds are handed to the same dedicated Codex task. There is no OpenAI API
key to copy, embed, or store, and no separate task-owning agent stack.

[Download the public alpha](https://github.com/hyungchulc/voice-relay/releases)
· [Build from source](#build-and-launch)

## Why Voice Relay is different

| Capability | What Voice Relay does |
| --- | --- |
| Full Codex desktop runtime | The Codex/ChatGPT desktop app remains the owner of tools, approvals, Browser Use, Computer Use, skills, connectors, and session state, subject to your app configuration and permissions. |
| Exact Codex model and thinking passthrough | Choose the model and thinking level in Codex. Voice Relay reads the effective `config.toml` profile through the desktop app, validates the model and reasoning effort against `model/list`, and runs its dedicated task with those exact choices. |
| OAuth, not API-key setup | Voice Relay uses the signed-in desktop session and keeps its short-lived Realtime credential in memory. It never asks for or bundles an OpenAI API key. |
| Direct Realtime Voice | Microphone capture, WebSocket transport, transcript display, and audio playback stay on a native low-latency Realtime path. |
| Persistent task continuity | Use an existing Session ID or let Voice Relay create and persist a dedicated task that keeps context across voice turns and restarts. |
| Live progress, not silent waiting | The handoff line, streamed Codex commentary, and final answer remain visible and play through the selected Realtime voice. |
| Mid-turn voice steering | Add a correction or instruction while Codex is working and Voice Relay steers the active turn instead of starting a disconnected request. |
| One stop control | Stop or Escape interrupts both Realtime output and the active Codex turn, then rejects late results. |
| Personal operating context | Optional Authority Packs add persistent guidance. Optional Additional Context Providers add bounded current data only to Codex-bound turns. Both are blank and disabled in public builds. |
| Native macOS surface | A notch-aware compact interface, a movable Orb fallback, local wake phrases, native permissions, launch at login, and system appearance support keep Voice as the primary surface. |

## How it works

```text
You speak
  |
  +-> Immediate social or device-local request
  |     -> OpenAI Realtime
  |     -> native transcript and audio reply
  |
  +-> Current, personal, analytical, or tool-using request
        -> short contextual handoff
        -> persistent Codex/ChatGPT desktop task
        -> app-owned tools, approvals, and session
        -> streamed commentary and final answer
        -> the same Realtime voice and visible surface
```

Realtime decides the route semantically. Greetings, thanks, identity questions,
hearing checks, and device-local time can stay direct. Personal state, current
facts, lookups, analysis, verification, and work that may take more than about
five seconds go to Codex. When the boundary is uncertain, Codex owns the turn.

## Compared with ChatGPT Voice in Work and Codex

The closest comparison is now OpenAI's built-in
[ChatGPT Voice in Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex),
not a generic API wrapper. OpenAI documents GPT-Live as a full-duplex voice
architecture, and the paid Live experience uses GPT-Live-1 where available.
Voice Relay's current public alpha uses a direct `gpt-realtime-2.1` path and
does not claim to match GPT-Live-1's conversational model behavior.

| Area | ChatGPT Voice in Work and Codex | Voice Relay |
| --- | --- | --- |
| Best fit | The integrated first-party default for eligible ChatGPT users | An open, customizable, Mac-first control surface around one dedicated Codex task |
| Voice experience | Built-in ChatGPT Voice. The Live option provides continuous GPT-Live full-duplex listening and speaking on supported accounts | Direct Realtime speech plus a semantic handoff to Codex for substantive work |
| Task coordination | Can start, prioritize, interrupt, redirect, and coordinate multiple agents across active conversations and projects | Keeps voice work pinned to one explicit existing or app-created persistent Session ID |
| Model and thinking control | ChatGPT Voice offers Instant, Medium, and High reasoning choices. GPT-Live can delegate deeper work to a background frontier model that OpenAI updates over time | Reads the human-selected Codex model and thinking level from the effective `config.toml`, validates both, and keeps the dedicated task on that explicit profile |
| Surface | Built into the ChatGPT desktop app on macOS and Windows, with paired iOS remote access | macOS notch or movable Orb, local wake phrases, launch at login, and an always-ready surface outside the main app window |
| Personal context | Uses available project context and supported connected tools | Adds opt-in Authority Packs and bounded Additional Context Providers |
| Extensibility | First-party product behavior and workspace controls | GPLv3 source that can be inspected, modified, and self-hosted |
| Setup and maturity | Supported first-party feature whose availability depends on plan, workspace, region, and app version | Public developer alpha requiring a signed-in desktop app, Remote pairing, and Gatekeeper override for the current DMG |

GPT-Live-1 is the stronger choice for first-party integration, natural
full-duplex conversation, multi-agent coordination, and paired iOS access.
Voice Relay is for Mac users who want a persistent notch or Orb, a local wake
phrase, one deliberate Codex session, inspectable source, and user-owned context
extensions. It does not recreate or proxy Codex features. It leaves execution,
permissions, and approvals in the desktop app. It also shows the effective
model, thinking level, sandbox, and approval policy instead of treating the
Codex execution profile as an opaque background delegation.

Official references

- [Introducing GPT-Live](https://openai.com/index/introducing-gpt-live/)
- [ChatGPT Voice](https://help.openai.com/en/articles/20001274)
- [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)

## Planned next

- **Direct Codex profile picker**
  Choose the Codex model and thinking level inside Voice Relay. This is planned,
  not part of the current public alpha. The current build inherits the
  human-selected values from the desktop app's effective `config.toml`.

## Requirements

- macOS 14 or newer
- The latest stable macOS release is recommended
- Current development and validation environment: macOS 27 beta
- This minimum follows the current
  [ChatGPT desktop requirement](https://help.openai.com/en/articles/9395554-what-are-the-system-requirements-for-the-chatgpt-macos-app),
  because Voice Relay connects to the desktop Chat/Work/Codex runtime
- The Codex/ChatGPT desktop app installed, running, and signed in
- Xcode Command Line Tools for local builds
- Node.js 20 or newer for the current Remote helper

Task turns use the authenticated desktop app Remote. Realtime Voice uses a
short-lived credential minted from the signed-in local Codex OAuth session and
does not wait on Remote. OAuth and ephemeral credentials are kept in memory and
are never logged or bundled. Voice Relay does not embed an OpenAI API key,
Remote enrollment, Session ID, private context, or other developer state.

The current public alpha bundles its GPLv3 Codex Remote support source inside
the app. It remains a developer preview because it is not notarized.

## Build and launch

```bash
./launch-voice-relay.sh
```

The launcher builds the current source, stops only the existing Voice Relay
process, starts one fresh app instance, and verifies that it stayed running. It
does not register a persistent `launchd` restart job.

The default build output is:

```text
build/Voice Relay.app
```

Set `VOICE_RELAY_OUT` to choose another output directory. The normal build is universal for Apple silicon and Intel. For a faster local build:

```bash
VOICE_RELAY_ARCHS=arm64 ./build.sh
```

`build-experimental.sh` is retained only as a compatibility wrapper for a
separate output directory:

```bash
./build-experimental.sh
```

It has the same runtime behavior as the normal build. Voice Relay always keeps
its own dedicated task. External nightly maintenance never rotates or rewrites
that task.

## First launch

The onboarding window opens automatically and keeps Voice Relay setup inside the app.

The seven-page flow introduces Voice Relay, uses `Relay` as the default
assistant name and `Relay` / `Hey Relay` as the default English wake phrases,
checks microphone and speech-recognition permissions, requires a verified
Codex/ChatGPT Remote pairing, offers an optional existing Session ID, verifies
Realtime Voice, and confirms the ready state. The all-zero UUID shown in the
field is a placeholder only. The stored Session ID starts empty, so Voice Relay
creates and persists a new dedicated session during its first Remote warm-up.

### Latest on-device SpeechAnalyzer

Local wake-phrase recognition is a first-class native feature. On macOS 26 or
newer, Voice Relay can use Apple's latest SpeechAnalyzer with short-form and
far-field content hints, per-language asset checks, contextual wake phrases,
frequent finalization of old volatile state, sample-timed bounded input, and
two-minute clean session rotation. A running analyzer recovers through the same
modern backend with bounded backoff instead of changing recognition semantics.
Startup incompatibility and older systems retain the classic on-device
recognizer as a last-resort fallback. SpeechAnalyzer is used only for local
wake phrases; the main conversation still uses the selected Realtime voice and
the paired Codex task.

Open Settings later with `⌘,`. Settings exposes product and assistant names,
permissions, the optional editable Session ID, wake phrases, system or custom
speech languages, a user-facing latest SpeechAnalyzer preference, a documented
Realtime voice selector, the Realtime prompt, an optional Authority Pack,
presence preferences, Reset, and Quit. Marin and Cedar appear first as
the recommended voices; a change takes effect when the next Realtime session
starts. On macOS 26 or newer, the latest analyzer is used only when every
selected speech locale is available; otherwise the complete wake-phrase session
falls back to the classic on-device recognizer. System, Light, and Dark
appearance previews refresh every Settings surface immediately, while Cancel
restores the persisted appearance. The native toolbar keeps General, Voice,
Connection, Permissions, and Advanced separate.

Advanced includes an About Voice Relay section with the exact embedded release
tag and build number. **Check for Updates…** uses pinned Sparkle 2 with an
EdDSA-signed prerelease feed. Sparkle downloads, verifies, installs, and
relaunches the selected update inside the app. Scheduled background checks and
silent automatic installation remain disabled. The first Sparkle-enabled alpha
must be installed manually once; later alphas can update in place.

General settings also exposes `Open Voice Relay at login`. It uses the native
macOS Login Items service and reflects the current system registration or
approval state rather than storing a second preference inside the app. A
missing Background Tasks record is treated as the registerable first-run state,
not as a permanent build limitation.

## Optional Authority Pack

Authority Pack is a public, optional feature for people who want Voice Relay to
use their own persistent operating guidance. It is disabled and blank on a
fresh install. Voice Relay does not ship Hyungchul Choi's Authority files or
select a folder on the user's behalf.

Create a folder containing exactly these required files:

```text
AGENTS.md
SOUL.md
USER.md
SOURCE_RULES.md
TOOLS.md
IDENTITY.md
WORKFLOW_AUTO.md
```

You can start by copying
[`Examples/AuthorityPack`](Examples/AuthorityPack) and editing its seven
Markdown files:

```bash
cp -R Examples/AuthorityPack ~/VoiceRelayAuthority
```

Open `Settings > Advanced`, select `Use Authority Pack`, choose that folder,
and save. The seven UTF-8 text files are validated, bounded in size, and sent
with each substantive Codex request as user-authored operating guidance. The
app does not execute scripts, follow URLs, recurse into subfolders, or include
the selected filesystem path in a request.

Changing the selected content starts a new app-managed dedicated session so an
older session cannot silently retain a different Authority Pack. If the
Session ID was pasted by the user, clear it explicitly before saving a changed
pack. The public manifest is
[`Resources/authority-pack.json`](Resources/authority-pack.json).

## Optional Additional Context Providers

Additional Context Providers are a separate public extension point for current,
request-specific grounding such as local app state, device context, or a
user-owned data source. They are disabled and blank on a fresh install. The app
does not ship a personal provider or select a provider folder.

Open `Settings > Advanced`, enable `Additional Context Providers`, choose a
folder, and save. Voice Relay runs at most eight executable regular files from
that exact folder in filename order. Each provider receives the current request
on standard input and has five seconds to return either plain UTF-8 text or this
versioned JSON envelope:

```json
{
  "schema": "voice-relay-context-v1",
  "generatedAt": "2026-07-28T10:00:00.000Z",
  "expiresAt": "2026-07-28T10:02:00.000Z",
  "text": "# Current Context\nSynthetic example only"
}
```

Provider output is limited to 32 KB per file and 96 KB combined. It is appended
only to Codex-bound turns under `Voice Relay Additional Context` and is labeled
as grounding data, never Authority or executable instructions. Voice Relay
does not include provider paths in the request.

[`Examples/AdditionalContextProviders`](Examples/AdditionalContextProviders)
contains a copyable executable example. A normal local folder is:

```text
~/Library/Application Support/Voice Relay/Additional Context Providers
```

Provider scripts are user-owned code and run with that user's local account
permissions. Review them before enabling the folder, keep their output bounded,
and never print credentials or unrelated private data.

## Interaction

- Click the compact left status indicator to start or stop Voice. Hover expands the surface without starting a session.
- Say a configured wake phrase such as `Hey Relay` when the local wake phrase is enabled. A name-only invocation is acknowledged inside Realtime and never handed to Codex.
- Press Escape to collapse the surface.
- The compact surface stays pure black, keeps a subtle left status indicator,
  and shows active listening, thinking, or speaking motion without status text.
- Automatic display mode uses the measured hardware notch when one exists and a
  floating top-center Orb on a display without one. Notch and Orb can also be
  selected explicitly.
- The Orb keeps a fixed pointer-independent center, draws a continuously moving
  full-spectrum caustic flow over a dedicated clear glass material, and scales
  only its internal artwork from the live microphone level while listening.
- Dragging moves and persists the Orb. Clicking starts or stops Voice, and a
  reply opens in a separate six-direction, appearance-aware low-frost glass
  bubble without widening the Orb.
- Recoverable startup failures use a short friendly message, do not enter
  conversation history, and collapse automatically.

Realtime is the main user interface, while the Codex/ChatGPT app remains the
task and approval owner. Greetings, thanks, configured identity questions,
hearing checks, and current device-local time or date can stay in Realtime.
Personal state, current facts, lookups, analysis, verification, and anything
that may take more than about five seconds or benefit from context, tools,
files, apps, memory, or sources are handed to the same app Remote task. When
the boundary is uncertain, Codex owns the turn. The short spoken progress line
describes only the action being taken and never pre-answers the request. Direct
replies, progress lines, commentary, and returned Codex answers are displayed
and play through the Realtime audio path. Escape or Stop interrupts both the
Realtime session and the active app Remote turn.

After completed onboarding, Realtime starts with the app instead of waiting for
Codex Remote. The first-install greeting is persisted so an ordinary restart
does not greet again. When no accepted user speech arrives for the configured
interval, Realtime closes and the local wake-phrase listener resumes. The
default interval is five minutes and can be changed in Voice settings.
When Return Greeting is enabled, fresh input after the configured away interval
starts one short, naturally worded Realtime welcome only after microphone
capture is safe. Active media, another voice session, or pending Codex work
defers the greeting instead of consuming it or showing a fixed toast.

## License and commercial builds

Copyright © 2026 Hyungchul Choi.

Voice Relay is open source under the [GNU General Public License
v3.0](LICENSE). You may use, study, modify, and redistribute it under the GPLv3
terms, including commercially. Official builds, setup, support, warranty, or a
separate commercial license that does not impose GPL obligations may be offered
for a fee by the copyright holder. See
[COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

Issues and security reports are welcome. Code contributions are paused during
the alpha until a contributor agreement is available, so the project can
preserve a clear copyright chain for optional commercial licensing. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## Verification

`build.sh` compiles the app, runs the local policy tests, validates both property
lists, and signs with `VOICE_RELAY_SIGNING_IDENTITY` when provided. Without an
explicit identity it uses an ad-hoc signature for local source testing only. A
manual Codex app Remote smoke harness is also included:

```bash
xcrun swiftc \
  -parse-as-library \
  Sources/AppLocalization.swift \
  Sources/AuthorityPackComposer.swift \
  Sources/OverlayPlacement.swift \
  Sources/SettingsStore.swift \
  Sources/CodexAppRemoteClient.swift \
  Tests/CodexClientSmoke.swift \
  -o /tmp/VoiceRelayCodexSmoke \
  -framework Cocoa \
  -framework Security
/tmp/VoiceRelayCodexSmoke
```

The smoke test requires the Voice Relay controller and desktop app host to be paired, then performs a real turn through the already-running desktop app.

## Release packaging

For the public developer alpha, create an Apple Development signed universal
DMG. This is a developer build, not an App Store or notarized distribution:

```bash
VOICE_RELAY_SIGNING_IDENTITY="Apple Development: Example Person (TEAMID)" \
VOICE_RELAY_SOURCE_URL="https://github.com/example/voice-relay/archive/refs/tags/v0.4.0-alpha.4.tar.gz" \
VOICE_RELAY_RELEASE_LABEL="0.4.0-alpha.4" \
./package-alpha-dmg.sh
```

The DMG includes `Voice Relay.app`, an Applications shortcut, GPLv3 license,
installation instructions, distribution notes, and the exact corresponding
source URL. Because this path is not notarized, macOS may require
**System Settings → Privacy & Security → Open Anyway**.

Publish every alpha, beta, and release-candidate tag as an ordinary GitHub
release. The helper passes neither `--prerelease` nor a `--latest` option, so
GitHub chooses the `Latest` marker automatically. Until the user explicitly
approves `v1.0.0`, the release helper still rejects stable tags:

```bash
VOICE_RELAY_RELEASE_NOTES_FILE="./release-notes.md" \
./publish-github-release.sh \
  v0.4.0-alpha.12 \
  releases/Voice-Relay-0.4.0-alpha.12-development-signed.dmg \
  releases/Voice-Relay-0.4.0-alpha.12-development-signed.dmg.sha256 \
  releases/Voice-Relay-0.4.0-alpha.12-update.zip \
  releases/Voice-Relay-0.4.0-alpha.12-update.zip.sha256 \
  releases/Voice-Relay-0.4.0-alpha.12-appcast.xml
```

The release helper uploads the preview-channel assets as an ordinary GitHub
release and then publishes the signed feed to the stable `appcast.xml` URL. If
feed publication alone needs retrying, run `publish-sparkle-feed.sh` with the
tag and versioned appcast. The internal
`VoiceRelayDistributionChannel=prerelease` value and Sparkle preview feed are
separate from GitHub release metadata.

Only after explicit user approval for the first stable release may the same
helper be invoked with `VOICE_RELAY_STABLE_RELEASE_APPROVED=true` and
`v1.0.0`. GitHub also chooses the `Latest` marker for that ordinary release
automatically.

For a normal trusted public build, a Developer ID Application certificate is
required:

```bash
VOICE_RELAY_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
VOICE_RELAY_NOTARY_PROFILE="notarytool-profile" \
VOICE_RELAY_SOURCE_URL="https://github.com/example/voice-relay/archive/refs/tags/v0.4.0.tar.gz" \
./package-release.sh
```

All three values are required. The script refuses to create a public archive
without Developer ID signing, notarization and stapling, or an exact
corresponding-source URL. The final archive includes the app, GPLv3 license,
asset notice, and source pointer.

## Privacy and permissions

- Accessibility remains optional and is not required for the Voice path.
- After onboarding, Realtime connects automatically at launch when microphone permission is available.
- Local rebuilds use a stable bundle-identifier designated requirement so an
  unchanged app identity does not turn each development build into a new
  macOS permission target.
- No OpenAI API key, Remote token, pairing state, Session ID, private context,
  or local preferences are embedded in the app bundle or release archive.
- A selected Authority Pack stays in the user's folder. Its path and contents
  are never embedded in source or a release archive. When enabled, its contents
  are intentionally sent to the user's Codex task with each substantive turn.
- Additional Context Providers are disabled and blank by default. Provider
  scripts and selected paths are never bundled. When enabled, their bounded
  output is intentionally sent as grounding only with each Codex-bound turn.
- Voice Relay keeps its own local Remote controller enrollment under
  `~/Library/Application Support/Voice Relay/Remote`.
- The public app uses bundle identifier `com.hyungchulc.voice-relay`, executable
  name `VoiceRelay`, and Remote identity `Voice Relay`, so it does not inherit
  older private-build preferences, process control, or enrollment.
- A fresh install starts with an empty Session ID and uses an app-owned
  workspace under `~/Library/Application Support/Voice Relay`
  instead of granting the task the user's entire home directory as its default
  working folder.
- Codex filesystem, command access, and approvals remain governed by the effective desktop app config.
