import Foundation

struct RealtimeAudioAdmissionPolicy {
    private var suppressedResponseIDs: Set<String> = []
    private var reportedSuppressionIDs: Set<String> = []

    mutating func register(responseID: String, responseKind: String) {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty,
              responseKind == "route_classifier" else {
            return
        }
        suppressedResponseIDs.insert(normalizedID)
    }

    func shouldAdmit(responseID: String) -> Bool {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if normalizedID.isEmpty {
            return suppressedResponseIDs.isEmpty
        }
        return !suppressedResponseIDs.contains(normalizedID)
    }

    mutating func shouldReportSuppression(responseID: String) -> Bool {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let diagnosticID = normalizedID.isEmpty
            ? "unknown-route-response"
            : normalizedID
        return reportedSuppressionIDs.insert(diagnosticID).inserted
    }

    mutating func finish(responseID: String) {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        suppressedResponseIDs.remove(normalizedID)
        reportedSuppressionIDs.remove(normalizedID)
    }

    mutating func reset() {
        suppressedResponseIDs.removeAll()
        reportedSuppressionIDs.removeAll()
    }
}
