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

Most voice assistants are separate chatbots. Voice Relay is different. It
connects a native macOS Voice surface to the Codex/ChatGPT desktop app you are
already signed into. Quick conversation stays on direct OpenAI Realtime Voice.
Anything that needs current facts, tools, apps, files, memory, approvals, or
deeper work moves to the same persistent Codex task. You hear a short handoff,
see and hear live commentary, can steer the task while it is running, and can
stop both Voice and Codex with one control. There is no OpenAI API key to copy
or store.

## Product proof points

- **Native Codex execution**
  The desktop app remains the task, tool, approval, and session owner. Voice
  Relay does not simulate a separate agent runtime.
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

It is a native macOS voice interface for the Codex/ChatGPT desktop runtime, not
a separate chatbot. Direct OpenAI Realtime Voice handles immediate
conversation, while current, contextual, analytical, and tool-using work moves
to one persistent Codex task.

The desktop app keeps ownership of tools, approvals, Browser Use, Computer Use,
skills, connectors, and session state. Voice Relay adds spoken handoff,
streamed commentary, mid-turn voice steering, unified Stop and Escape, local
wake phrases, optional Authority Packs, and bounded Additional Context
Providers.

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
