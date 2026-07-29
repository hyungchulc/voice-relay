This alpha makes Voice Relay's wake, Realtime, and media handoff substantially more reliable.

- Voice Relay now keeps one microphone capture graph alive when a Realtime session returns to local wake listening, preventing repeated Safari and media playback pauses after spoken stop.
- Spoken stop and short barge-ins interrupt promptly while the app preserves the capture path needed for the next wake phrase.
- Wake listening remains available while other media is playing, with stricter isolation between speaker output and human speech.
- The complete recognized request is handed to Realtime instead of only its final segment.
- Conversation turns remain in chronological order when a stop command arrives during assistant activity.
- Manual microphone resume restores the expanded conversation surface without leaving an empty black panel.
- Realtime follows the user's input language and keeps the configured conversational register without hard-coded language branches.
- Build 25 is the signed update target for installed Voice Relay alpha builds.

macOS voice processing may still apply a brief system-level duck while the microphone path is active, but the repeated Safari pause and resume cycle is removed.
