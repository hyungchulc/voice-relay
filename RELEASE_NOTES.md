This alpha makes Codex the single content authority for Voice Relay conversations.

- Realtime classifier labels for direct chat, stable local answers, and configured identity questions now normalize to the persistent Codex task.
- Pure assistant-playback echo suppression, stop, repeat, and closed device-local actions remain local.
- Every Codex voice handoff carries the current configured assistant, product, and user display names as bounded JSON data.
- The current request identity supersedes stale persistent-task context, and missing values never fall back to a model, provider, or platform identity.
- Regression coverage verifies direct chat, stable knowledge, translation, and identity routes cannot produce a competing Realtime-authored answer.
- Build 40 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
