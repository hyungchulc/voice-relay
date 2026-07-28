# Voice Relay promotion kit

This kit keeps public descriptions aligned with the current public alpha. It
can be reused for GitHub, a product page, a launch post, or a demo video.

## Core positioning

**Voice Relay turns the full Codex desktop runtime into a native, persistent,
context-aware voice assistant on macOS, without copying or storing an OpenAI
API key or creating a separate AI stack.**

## Short description

A native macOS voice interface for the Codex/ChatGPT desktop runtime, combining
direct OpenAI Realtime Voice with persistent Codex sessions, tools, approvals,
streamed progress, and mid-turn steering.

## Thirty-second pitch

ChatGPT now has a powerful built-in Voice experience for Work and Codex. Voice
Relay explores a different shape. It puts an open-source, always-ready notch or
Orb on macOS, binds it to one deliberate Codex task, and lets you wake it
locally or extend it with your own guidance and bounded current context. Quick
conversation stays on direct OpenAI Realtime Voice. Substantive work uses the
model and thinking level you selected in Codex, with the same tools, approvals,
and session. You hear a short handoff, see and hear live commentary, can steer
the task while it is running, and can stop both Voice and Codex with one
control. There is no OpenAI API key to copy or store.

## Product proof points

- **Native Codex execution**
  The desktop app remains the task, tool, approval, and session owner. Voice
  Relay does not simulate a separate agent runtime.
- **Exact Codex model and thinking passthrough**
  Choose the model and thinking level in Codex. Voice Relay reads the effective
  `config.toml` profile through the desktop app, validates the model and
  reasoning effort against `model/list`, and runs its dedicated task with those
  exact choices.
- **OAuth with no API-key setup**
  The signed-in desktop session supplies an in-memory, short-lived Realtime
  credential. No OpenAI API key is requested, embedded, or stored.
- **Direct Realtime Voice**
  Native microphone capture and playback connect directly through the
  Realtime WebSocket path.
- **Persistent session continuity**
  Users can resume an existing Session ID or let Voice Relay create and persist
  one dedicated task.
- **Semantic hybrid routing**
  Realtime handles immediate conversation. Codex owns personal, current,
  analytical, verified, contextual, and tool-using work.
- **Natural, visible handoff**
  A short contextual progress line starts the transition without pre-answering
  the request.
- **Streamed work**
  Codex commentary and the final answer remain visible and are spoken through
  the active Realtime voice.
- **Mid-turn voice steering**
  Corrections and additional instructions can be sent to the active Codex turn.
- **Unified interruption**
  Stop and Escape cancel Realtime output and interrupt the active Codex turn.
- **Context without private bundling**
  Optional Authority Packs and Additional Context Providers stay user-selected,
  bounded, and disabled by default in public builds.
- **Native macOS experience**
  Voice Relay includes notch-aware placement, an Orb fallback, local wake
  phrases, native permissions, system appearance, and launch at login.
- **Open source**
  The project is available under GPLv3. Official builds, setup, and support may
  be offered separately.

## Primary competitive frame

The closest comparison is OpenAI's built-in ChatGPT Voice in Work and Codex.
The products overlap, but optimize for different things.

| ChatGPT Voice in Work and Codex | Voice Relay |
| --- | --- |
| First-party integrated experience | Open-source Mac-first control surface |
| GPT-Live full-duplex conversation where Live is available | Direct `gpt-realtime-2.1` speech with semantic Codex handoff |
| Instant, Medium, and High reasoning choices, with deeper work delegated to an OpenAI-managed background frontier model | Human-selected Codex model and thinking level inherited from the effective `config.toml` and validated before use |
| Multiple agents, conversations, and projects | One explicit persistent Codex Session ID |
| Desktop app on macOS and Windows, plus paired iOS access | Notch or Orb on macOS, local wake phrase, and launch at login |
| Available project context and connected tools | Optional Authority Pack and bounded Additional Context Providers |
| Normal product setup and support | Inspectable GPLv3 source and a customizable public alpha |

Do not market Voice Relay as more natural than GPT-Live-1. Lead with ambient
macOS access, explicit session ownership, open-source control, and personal
context extensibility.

Planned, not current alpha: a direct model and thinking-level picker inside
Voice Relay. The current build inherits the human-selected values from the
desktop app's effective `config.toml`.

## Demo video outline

### 1. Open with the product boundary

Show Voice Relay at the notch or as the Orb while the signed-in Codex/ChatGPT
desktop app is already running.

On-screen line:

> Not another chatbot. A native voice interface for the full Codex desktop runtime.

### 2. Show instant Realtime conversation

Ask a greeting or device-local time question. Show the immediate transcript and
native Realtime reply.

On-screen line:

> Direct OpenAI Realtime Voice

### 3. Show the semantic handoff

Ask for a current, source-dependent, or tool-using task. Capture the short
handoff, visible commentary, and final answer.

On-screen line:

> Realtime speed when it is enough. Codex depth when it matters.

### 4. Steer the active task

While Codex is working, add a correction or extra instruction by voice. Show
that it joins the same active turn.

On-screen line:

> Speak again to steer the work in progress.

### 5. Show session continuity

Open Settings, show the optional Session ID, then return to Voice and continue
the same task context.

On-screen line:

> One persistent task across voice turns and restarts.

### 6. Close on setup and control

Show OAuth pairing, the empty API-key surface, then demonstrate Stop or Escape.

On-screen line:

> OAuth. No API key to manage. One stop control.

## Launch post

Voice Relay is now available as a public alpha.

ChatGPT now has built-in Voice for Work and Codex, and its supported Live
experience is powered by GPT-Live. Voice Relay explores a different direction.
It is an open-source, always-ready macOS notch or Orb bound to one persistent
Codex task. Direct OpenAI Realtime Voice handles immediate conversation, while
current, contextual, analytical, and tool-using work moves to Codex.

The desktop app keeps ownership of tools, approvals, Browser Use, Computer Use,
skills, connectors, the selected model and thinking level, and session state.
Voice Relay adds spoken handoff, streamed commentary, mid-turn voice steering,
unified Stop and Escape, local wake phrases, optional Authority Packs, and
bounded Additional Context Providers.

It uses the existing signed-in OAuth session, never asks you to copy or store an
OpenAI API key, and ships without private context or local developer state.

Public alpha, GPLv3:

https://github.com/hyungchulc/voice-relay

## Honest alpha note

The current downloadable build is ad-hoc signed and not notarized, so macOS may
show an unidentified-developer warning and require **System Settings > Privacy
& Security > Open Anyway**. APIs, setup, and packaging may change before 1.0.
Capabilities remain subject to the user's Codex/ChatGPT desktop configuration,
permissions, account access, and the current public alpha implementation.
