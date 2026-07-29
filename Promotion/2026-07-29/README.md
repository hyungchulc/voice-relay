# Voice Relay promotion pack

This is a draft-only campaign pack for the Voice Relay public developer alpha.
It does not authorize publication or account use.

## Verified release snapshot

- Checked on `2026-07-29`.
- Current GitHub release is `v0.5.1-alpha.1`, published at
  `2026-07-29T16:34:53Z`.
- GitHub reports `draft=false` and `prerelease=false`, and the release is
  returned by the official `releases/latest` endpoint.
- This is intentional for the current release policy. Alpha, beta, and release
  candidate tags are ordinary GitHub releases. GitHub chooses the Latest marker
  automatically.
- The app remains on the internal
  `VoiceRelayDistributionChannel=prerelease` Sparkle preview channel.
- Stable publication remains locked until explicit approval of `v1.0.0`.
- The current public DMG is Apple Development signed and not notarized.

The Latest marker means newest published build. It does not make the alpha a
stable or production-ready release.

## Campaign decision

Lead with one interaction that is specific to Voice Relay.

> Start by voice, let Codex work, then speak again to steer the same task.

Local wake phrases support the story, but they are not the main proof. Authority
Packs and Additional Context Providers belong in later technical material.

## Capture readiness

The Voice Relay development lane repaired the voice-turn boundary in commit
`da04b58`. Its exact queue regression, full isolated test suite, signed
universal build, and live relaunch checks passed. A physical spoken canary was
not performed, so the pack is ready for a controlled recording take, not for
publishing unreviewed footage. The recorded take must still pass every
acceptance check in `VIDEO_PLAN.md`.

## Contents

- `COPY.md` contains English X copy, exactly three Korean Threads options, and
  Reddit drafts.
- `VIDEO_PLAN.md` contains the hero demo, cutdowns, capture checklist, and
  acceptance gate.
- `SOURCES.md` records the inspected product and platform sources.
- `assets/` contains deterministic PNG exports.
- `motion/voice-relay-bumper-16x9-6s.mp4` is an asset-only silent bumper, not a
  product demo.
- `captions/` contains draft English and Korean SRT timing. Retiming against
  the final recording is mandatory.
- `manifest.json` records dimensions, copy, provenance, and freshness gates.
- `render_assets.py` reproduces the deterministic visual exports.

## Rebuild

```bash
python3 Promotion/2026-07-29/render_assets.py
```
