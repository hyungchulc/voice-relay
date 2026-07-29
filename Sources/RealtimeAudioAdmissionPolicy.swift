import Foundation

struct RealtimeAudioAdmissionPolicy {
    private var suppressedResponseIDs: Set<String> = []
    private var reportedSuppressionIDs: Set<String> = []
    private var activeAudioResponseIDs: Set<String> = []

    @discardableResult
    mutating func register(
        responseID: String,
        responseKind: String
    ) -> Bool {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty else {
            return false
        }
        let textOnlyResponseKinds: Set<String> = [
            "route_classifier",
            "active_codex_control",
        ]
        if textOnlyResponseKinds.contains(responseKind) {
            suppressedResponseIDs.insert(normalizedID)
            return false
        }
        activeAudioResponseIDs.insert(normalizedID)
        return true
    }

    mutating func suppressActiveAudioResponses() -> Set<String> {
        suppressedResponseIDs.formUnion(activeAudioResponseIDs)
        return activeAudioResponseIDs
    }

    mutating func suppressAudioResponse(responseID: String) {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty else { return }
        activeAudioResponseIDs.insert(normalizedID)
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
        activeAudioResponseIDs.remove(normalizedID)
    }

    mutating func reset() {
        suppressedResponseIDs.removeAll()
        reportedSuppressionIDs.removeAll()
        activeAudioResponseIDs.removeAll()
    }
}

struct RealtimePendingAudioPreemptionPolicy {
    private var pendingResponseCreateEventIDs: [String] = []
    private var preemptedResponseCreateEventIDs: Set<String> = []

    var pendingResponseCreates: Int {
        pendingResponseCreateEventIDs.count
    }

    var preemptionsOnCreate: Int {
        preemptedResponseCreateEventIDs.count
    }

    mutating func registerOutboundAudioResponseCreate(
        eventID: String
    ) {
        let normalizedID = eventID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty,
              !pendingResponseCreateEventIDs.contains(normalizedID) else {
            return
        }
        pendingResponseCreateEventIDs.append(normalizedID)
    }

    mutating func admitUserSpeech() {
        preemptedResponseCreateEventIDs.formUnion(
            pendingResponseCreateEventIDs
        )
    }

    mutating func registerCreatedAudioResponse() -> Bool {
        guard !pendingResponseCreateEventIDs.isEmpty else { return false }
        let eventID = pendingResponseCreateEventIDs.removeFirst()
        return preemptedResponseCreateEventIDs.remove(eventID) != nil
    }

    mutating func rejectOutboundAudioResponseCreate(
        eventID: String
    ) {
        let normalizedID = eventID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty else { return }
        pendingResponseCreateEventIDs.removeAll {
            $0 == normalizedID
        }
        preemptedResponseCreateEventIDs.remove(normalizedID)
    }

    mutating func reset() {
        pendingResponseCreateEventIDs.removeAll()
        preemptedResponseCreateEventIDs.removeAll()
    }
}
