import Foundation

struct RealtimeAudioAdmissionPolicy {
    private var suppressedResponseIDs: Set<String> = []
    private var reportedSuppressionIDs: Set<String> = []
    private var activeAudioResponseIDs: Set<String> = []
    private var terminalResponseIDs: Set<String> = []

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
        if responseKind == "semantic_stop" {
            terminalResponseIDs.insert(normalizedID)
        }
        return true
    }

    mutating func suppressActiveAudioResponses() -> Set<String> {
        let suppressibleResponseIDs =
            activeAudioResponseIDs.subtracting(terminalResponseIDs)
        suppressedResponseIDs.formUnion(suppressibleResponseIDs)
        return suppressibleResponseIDs
    }

    var hasActiveTerminalResponse: Bool {
        !activeTerminalResponseIDs.isEmpty
    }

    var activeTerminalResponseIDs: Set<String> {
        activeAudioResponseIDs.intersection(terminalResponseIDs)
    }

    func isTerminalResponse(responseID: String) -> Bool {
        terminalResponseIDs.contains(
            responseID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
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
        terminalResponseIDs.remove(normalizedID)
    }

    mutating func reset() {
        suppressedResponseIDs.removeAll()
        reportedSuppressionIDs.removeAll()
        activeAudioResponseIDs.removeAll()
        terminalResponseIDs.removeAll()
    }
}

struct RealtimePendingAudioPreemptionPolicy {
    private struct PendingResponseCreate {
        let eventID: String
        let terminal: Bool
    }

    private var pendingCreates: [PendingResponseCreate] = []
    private var preemptedResponseCreateEventIDs: Set<String> = []

    var pendingResponseCreates: Int {
        pendingCreates.count
    }

    var preemptionsOnCreate: Int {
        preemptedResponseCreateEventIDs.count
    }

    var hasPendingTerminalResponseCreate: Bool {
        pendingCreates.contains(where: \.terminal)
    }

    mutating func registerOutboundAudioResponseCreate(
        eventID: String,
        responseKind: String = ""
    ) {
        let normalizedID = eventID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty,
              !pendingCreates.contains(where: {
                  $0.eventID == normalizedID
              }) else {
            return
        }
        pendingCreates.append(
            PendingResponseCreate(
                eventID: normalizedID,
                terminal: responseKind == "semantic_stop"
            )
        )
    }

    mutating func admitUserSpeech() {
        preemptedResponseCreateEventIDs.formUnion(
            pendingCreates
                .filter { !$0.terminal }
                .map(\.eventID)
        )
    }

    mutating func registerCreatedAudioResponse(
        responseKind: String = ""
    ) -> Bool {
        guard !pendingCreates.isEmpty else { return false }
        let terminal = responseKind == "semantic_stop"
        let matchingIndex = pendingCreates.firstIndex {
            $0.terminal == terminal
        } ?? pendingCreates.startIndex
        let pending = pendingCreates.remove(at: matchingIndex)
        let wasPreempted = preemptedResponseCreateEventIDs.remove(
            pending.eventID
        ) != nil
        return !terminal && wasPreempted
    }

    mutating func rejectOutboundAudioResponseCreate(
        eventID: String
    ) {
        let normalizedID = eventID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedID.isEmpty else { return }
        pendingCreates.removeAll {
            $0.eventID == normalizedID
        }
        preemptedResponseCreateEventIDs.remove(normalizedID)
    }

    mutating func reset() {
        pendingCreates.removeAll()
        preemptedResponseCreateEventIDs.removeAll()
    }
}

enum RealtimeTerminalFailurePolicy {
    static func shouldDeferTransportTeardown(
        terminalPlaybackBufferCount: Int
    ) -> Bool {
        terminalPlaybackBufferCount > 0
    }
}
