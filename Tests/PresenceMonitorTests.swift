import Foundation

private var failures: [String] = []

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures.append(message)
    }
}

@main
private enum PresenceMonitorTests {
    static func main() {
        let policy = PresencePolicy(
            idleThreshold: 1_800,
            returnWindow: 15,
            greetingCooldown: 14_400
        )
        let now = Date(timeIntervalSince1970: 10_000)
        var lifecycle = PresenceDeliveryLifecycle(policy: policy)
        lifecycle.observeIdle(idleSeconds: 1_900, at: now.addingTimeInterval(-20))
        let first = lifecycle.reserveCandidate(
            currentIdleSeconds: 1,
            lastAcknowledgedAt: nil,
            now: now,
            evidence: .userActivityHeuristic
        )
        expect(first != nil, "input after idle must reserve one return candidate")
        expect(
            first?.confidence == .heuristic
                && first?.evidence == .userActivityHeuristic,
            "activity must be labeled heuristic evidence, not physical presence"
        )
        expect(
            lifecycle.lastAcknowledgedAt == nil,
            "startup acceptance must not start the greeting cooldown"
        )
        if let first {
            lifecycle.release(
                candidateID: first.id,
                reason: .activeMedia
            )
        }
        let retry = lifecycle.reserveCandidate(
            currentIdleSeconds: 2,
            lastAcknowledgedAt: nil,
            now: now.addingTimeInterval(2),
            evidence: .userActivityHeuristic
        )
        expect(
            retry != nil,
            "a media-deferred candidate must remain eligible for a safe retry"
        )
        if let retry {
            expect(
                lifecycle.acknowledge(
                    candidateID: retry.id,
                    at: now.addingTimeInterval(4)
                ),
                "acknowledged playback must complete the presence attempt"
            )
        }
        lifecycle.observeIdle(idleSeconds: 1_900, at: now.addingTimeInterval(10))
        expect(
            lifecycle.reserveCandidate(
                currentIdleSeconds: 1,
                lastAcknowledgedAt: lifecycle.lastAcknowledgedAt,
                now: now.addingTimeInterval(60),
                evidence: .userActivityHeuristic
            ) == nil,
            "cooldown must begin only after acknowledged delivery"
        )

        expect(
            PresenceMediaGate.evaluate(
                ExternalAudioPlaybackSnapshot(
                    processLabels: ["org.example.player"]
                )
            ) == .deferred(.activeMedia),
            "active media must defer an automatic presence greeting"
        )
        expect(
            PresenceMediaGate.evaluate(
                ExternalAudioPlaybackSnapshot(
                    processLabels: [],
                    isAvailable: false
                )
            ) == .deferred(.mediaStatusUnavailable),
            "an unavailable media detector must fail closed for automatic speech"
        )
        expect(
            PresenceMediaGate.evaluate(
                ExternalAudioPlaybackSnapshot(processLabels: [])
            ) == .allowed,
            "confirmed idle output may admit automatic speech"
        )
        expect(
            PresenceGateReason.activeMedia.rawValue == "active_media"
                && PresenceGateReason.busy.rawValue == "voice_busy"
                && PresenceGateReason.mediaStatusUnavailable.rawValue
                    == "media_status_unavailable",
            "presence gate telemetry must use stable privacy-safe reason codes"
        )

        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("Presence monitor tests passed")
    }
}
