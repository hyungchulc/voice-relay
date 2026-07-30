This alpha keeps live corrections attached to the authoritative Codex reply.

- Each accepted same-turn steer now creates a durable unresolved response revision.
- Candidate finals remain buffered until they are safe to commit, so an unbound answer cannot close the bridge after a live correction.
- Every distinct buffered final is preserved in chronological order and delivered through one terminal payload unless explicit protocol metadata proves supersession.
- Later turn activity delays candidate settlement without discarding valid partial output.
- Ordinary requests without a steer retain bounded final settlement, while timeout and abort paths remain fail-closed.
- Build 34 is the signed update target for installed Voice Relay preview-channel builds.

This public build is Apple Development signed and is not notarized.
