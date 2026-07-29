This alpha validates the signed in-app update path and simplifies GitHub release metadata.

- Alpha, beta, and release-candidate builds are published as ordinary GitHub releases.
- The release publisher leaves GitHub's `Latest` selection automatic instead of forcing or suppressing the marker.
- Sparkle feed publication requires the matching ordinary GitHub release and signed update archive.
- The internal preview channel, signed update feed, and explicit `v1.0.0` approval gate remain unchanged.
- Build 24 provides the next signed update target for installed alpha.12 builds.
