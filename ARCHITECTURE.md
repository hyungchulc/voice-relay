# Voice Relay architecture

Voice Relay supports macOS 14 or newer and recommends the latest stable macOS
release. The minimum matches the current ChatGPT desktop requirement because
Voice Relay connects to the desktop Chat/Work/Codex runtime. Current
development and validation use macOS 27 beta.

## Product boundary

Voice Relay is a Mac-only native Voice surface with two related connection layers:

1. A direct Realtime WebSocket session with native microphone capture and speaker playback.
2. A dedicated first-party Remote controller paired to the already-running Codex/ChatGPT desktop app for substantive work.

The desktop app remains the execution, session, approval, Browser Use, Computer Use, skills, and connector owner. Voice Relay does not type into the composer, use CDP for dispatch, or launch a second task-owning app-server.

## Codex/ChatGPT app Remote path

```text
top-notch Voice UI
  -> CodexAppRemoteClient
  -> Voice Relay JSONL helper
  -> dedicated CodexRemoteControlClient enrollment
  -> already-running Codex/ChatGPT app host
  -> explicitly selected or app-created Codex task
  -> app-owned tools, approvals, and session state
  -> streamed commentary and final answer
```

Onboarding uses the desktop app Remote flow:

1. Enroll a Voice Relay-specific Remote controller through browser step-up authentication.
2. In the Codex/ChatGPT app, open `Settings > Connections > Control this Mac > Add`, choose `Computer`, and enter the short-lived eight-character code.
3. Validate the live Remote with `account/read`, `config/read`, and `model/list`.
4. Resume an optional user-selected Session ID, or create and persist a new
   dedicated session when the field is blank.
5. Dispatch the voice request through the app Remote and stream the task result.

Voice Relay owns its helper lifetime, request IDs, session-binding persistence,
streaming assembly, and interruption. The desktop app owns approvals. Verified
Codex/ChatGPT pairing is mandatory in onboarding, while the Session ID is
optional. A user may explicitly paste an existing ID during onboarding or edit
it later in Settings. A blank ID explicitly ignores stale helper state, creates
one new dedicated session during Voice warm-up, and writes that generated ID
back to Settings. The app records whether the binding came from the user or an
app-created session. Ambient environment variables cannot silently replace the
binding. External nightly maintenance never inspects, rotates, or mutates the
dedicated Voice Relay task.

## Realtime voice path

```text
local wake plane
  -> system default microphone
  -> SpeechAnalyzer or local Speech recognition
  -> fully quiesced before handoff

active Realtime plane
  -> one Voice Processing AVAudioEngine
  -> system default microphone and output
  -> 24 kHz mono PCM16 capture
  -> URLSessionWebSocketTask
  -> gpt-realtime-2.1
  -> media-free WKWebView routing reducer
  -> deterministic direct route or route_voice_turn
  -> Codex/ChatGPT app Remote
  -> function_call_output
  -> native PCM16 playback and transcript
```

The two audio planes are mutually exclusive. A wake match is delivered only
after the active SpeechAnalyzer has finished cancellation, released its
reserved assets, removed its tap, and stopped its engine. Realtime audio starts
only after the server session is ready. It uses the current macOS default input
and output without selecting, pinning, or changing an audio device.

Realtime keeps Apple Voice Processing active only for the bounded conversation
lease. On macOS 14 or newer it enables advanced other-audio ducking at Apple's
minimum level. The public API minimizes attenuation but cannot guarantee zero
ducking while AEC is active. Keeping Realtime always connected would extend
that attenuation, network microphone streaming, and idle failure exposure, so
idle monitoring remains local.

Swift requests a short-lived Realtime credential with the signed-in local Codex
OAuth session, keeps both OAuth and ephemeral values only in memory, and
establishes the Realtime WebSocket directly. No OpenAI API key is requested or
stored. Realtime does not depend on Codex Remote being ready.

After Realtime reaches a live speaking or listening state, the helper prewarms
the selected Remote session. If Session ID is blank, the request explicitly
creates and persists a new dedicated session rather than reusing hidden helper
state. A first-install greeting therefore overlaps Remote warm-up, while Remote
readiness never blocks microphone startup or the greeting.

Completed transcripts pass a deterministic speech-stability gate before they
can change UI state or route a turn. Provisional VAD start and stop events do
nothing. Accepted turns are serialized so overlapping transcripts cannot reuse
one mutable slot. Realtime semantically answers only pure social speech that it
can complete immediately, such as greetings, thanks, its configured identity,
hearing checks, or the current device-local time. Personal state, current
facts, lookups, analysis, and any request that may take more than about five
seconds or benefit from context, tools, files, apps, memory, or source
verification are handed to Codex. If the boundary is uncertain, Codex owns the
turn. The short handoff progress response may describe only the action being
taken and cannot pre-answer the request or claim uncertainty. Output audio
deltas are decoded and scheduled on the native player. Stop and Escape
interrupt the active app Remote turn and reject late UI results.

Completed onboarding starts Realtime as soon as the overlay is presented unless
microphone access is explicitly denied or restricted. The first greeting marker
persists separately from transient conversation UI. Accepted user or assistant
speech refreshes a configurable inactivity deadline. The default five-minute
deadline closes the socket and audio engine and restores the local wake-phrase
listener.

## Public-state boundary

Fresh public builds start with an empty Session ID. The all-zero UUID in
onboarding and Settings is display-only example text. The app bundle does not
contain local preferences, Remote enrollment, device keys, tokens, logs, or
private context files. Remote enrollment is created only after the user
completes pairing and is stored under the user's Application Support directory.

Authority Pack is an optional public feature and is blank and disabled by
default. A user may explicitly select one folder containing the seven files
declared in `Resources/authority-pack.json`. Voice Relay reads only those
bounded UTF-8 regular files, rejects symlink escapes and incomplete packs, and
never transmits the selected path. It does not execute pack content or discover
additional files. The resulting fragments are delivered as user-authored
guidance below governing platform, system, developer, app, permission, and
safety instructions. A content fingerprint rotates an app-managed dedicated
session when the pack changes. A user-selected existing Session ID must be
cleared explicitly before a changed pack can be saved.

Additional Context Providers are a distinct optional boundary and are also
blank and disabled by default. The helper executes only bounded executable
regular files from the exact selected folder, in filename order, with the
current request on standard input. Versioned output includes generation and
expiry timestamps. Provider output is never merged into the Authority Pack. It
is appended under one grounding-only heading and provider paths are not sent.
Changing the provider configuration follows the same dedicated-session
rotation rule as changing Authority content, while external nightly
maintenance has no access to or ownership of that session.

## Surface states

1. Dormant
   - Compact surface sits at the physical top edge of the selected `NSScreen.frame`.
   - No active Realtime microphone session.
2. Compact
   - Resolves Automatic from `safeAreaInsets` and the auxiliary top areas.
   - Uses Notch on hardware with a measured notch and Orb otherwise.
   - The notch footprint is `max(276, physical notch width + 56)` points. On the current 220-point notch, the 18-point typing-dot group keeps an eight-point outer margin while remaining outside the hardware notch.
   - Is an opaque black AppKit surface with native-scale lower corners.
   - Keeps a three-dot Messages-style activation indicator in the left wing and uses sequential vertical motion for active phases.
3. Expanded
   - Preserves the top edge and grows downward.
   - Shows the bounded scrollable conversation with Settings and Voice controls in the bottom action bar.
   - Collapses by clipping the visible content with geometry; it does not fade content early and leave a blank card.
4. Orb
   - Uses the selected screen's visible top center with a small inset.
   - Keeps a fixed outer hit target and pointer-independent center.
   - Uses a dedicated clear `NSGlassEffectView` material rather than the Notch
     surface implementation.
   - Draws seven spectral accents, continuously moving caustic pools, a rotating
     spectral field, a stable highlight, and a glass rim. Infinite motion stays
     on Core Animation and stops when hidden or Reduce Motion is enabled.
   - Receives normalized live microphone RMS only while listening and scales
     the internal artwork and optical intensity without moving the panel or
     changing its hit target.
   - Persists click-drag position and opens answers in a separate bubble placed
     inward from the Orb in one of six directions. The bubble uses faint white
     regular frost with dark text in Light mode and faint black frost with light
     text in Dark mode.
   - Provides the same voice-state semantics for external or no-notch displays.

Screen-parameter changes rebuild from the selected display's current geometry,
so resolution, scaling, external-display, and notch changes do not reuse stale
coordinates.

The notch surface has no editable command field, paste route, or hidden keyboard-input implementation.

Stale voice generations are rejected by generation ID and a native media epoch. Stopping or starting a newer generation closes the older socket, capture tap, and playback queue.
Recoverable startup errors are transient UI state, never conversation history or
the last answer, and collapse back to the compact surface after a bounded delay.

## Settings and reset boundary

Settings uses native toolbar panes for General, Voice, Connection, Permissions,
and Advanced. Product and assistant display names, wake phrases, system or
custom speech languages, the latest SpeechAnalyzer preference, the Realtime
voice, prompt, inactivity timeout, optional Session ID, and display surface are
user-configurable. Advanced also exposes the optional generic Authority Pack
folder while internal bundle and preference identifiers remain
stable. Supported Realtime voices are constrained to the current built-in set,
with Marin and Cedar presented first as recommended choices. The Settings window
keeps an unsaved appearance draft and refreshes its canvas, cards, scroll views,
and controls whenever effective appearance changes. System appearance leaves
the AppKit window appearance inherited instead of freezing the launch-time Aqua
variant. On macOS 26 or newer, SpeechAnalyzer is selected only when every
configured locale is available; a partial locale set uses one coherent legacy
recognition session instead of silently dropping languages. Reset clears only
the app's local preferences, task binding, onboarding marker, first-greeting
marker, and local Remote enrollment state. It never deletes the corresponding
Codex task. Quit terminates the app through AppKit.

## Distribution boundary

`build.sh` creates a universal app and uses an explicit Apple signing identity
when one is supplied. Its ad-hoc fallback exists only for local source testing
and keeps an explicit bundle-identifier designated requirement. All builds
carry the same audio-input entitlement as release builds; an authorized
permission without that entitlement is not treated as a working capture path.
`package-release.sh` creates a hardened Developer ID build and can notarize when
a notarytool Keychain profile is supplied. Public release proof requires
successful codesign verification, Gatekeeper assessment, notarization, and
stapler validation on the produced artifact.
