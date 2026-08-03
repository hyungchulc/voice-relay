import AppKit
import CoreGraphics

struct PresencePolicy {
    let idleThreshold: TimeInterval
    let returnWindow: TimeInterval
    let greetingCooldown: TimeInterval

    func isReturnCandidate(
        wasIdle: Bool,
        currentIdleSeconds: TimeInterval,
        lastGreetingAt: Date?,
        now: Date
    ) -> Bool {
        guard wasIdle, currentIdleSeconds <= returnWindow else { return false }
        guard let lastGreetingAt else { return true }
        return now.timeIntervalSince(lastGreetingAt) >= greetingCooldown
    }
}

enum PresenceConfidence: String, Codable, Equatable {
    case heuristic
}

enum PresenceGateReason: String, Codable, Equatable {
    case activeMedia = "active_media"
    case busy = "voice_busy"
    case mediaStatusUnavailable = "media_status_unavailable"
    case startRejected = "start_rejected"
    case playbackFailed = "playback_failed"
}

enum PresenceGateDecision: Equatable {
    case allowed
    case deferred(PresenceGateReason)
}

enum PresenceMediaGate {
    static func evaluate(_ snapshot: ExternalAudioPlaybackSnapshot) -> PresenceGateDecision {
        guard snapshot.isAvailable else { return .deferred(.mediaStatusUnavailable) }
        guard !snapshot.isPlaying else { return .deferred(.activeMedia) }
        return .allowed
    }
}

struct PresenceReturnCandidate: Equatable {
    let id: UUID
    let observedAt: Date
    let absenceSeconds: TimeInterval
    let evidence: PresenceEvidence
    let confidence: PresenceConfidence
}

struct PresenceDeliveryLifecycle {
    private let policy: PresencePolicy
    private var wasIdle = false
    private var maximumObservedIdle: TimeInterval = 0
    private var inFlightCandidate: PresenceReturnCandidate?
    private(set) var lastAcknowledgedAt: Date?

    init(policy: PresencePolicy) {
        self.policy = policy
    }

    mutating func observeIdle(idleSeconds: TimeInterval, at _: Date) {
        guard idleSeconds.isFinite, idleSeconds >= policy.idleThreshold else { return }
        wasIdle = true
        maximumObservedIdle = max(maximumObservedIdle, idleSeconds)
    }

    mutating func reserveCandidate(
        currentIdleSeconds: TimeInterval,
        lastAcknowledgedAt persistedAcknowledgement: Date?,
        now: Date,
        evidence: PresenceEvidence
    ) -> PresenceReturnCandidate? {
        if let persistedAcknowledgement,
           lastAcknowledgedAt == nil || persistedAcknowledgement > lastAcknowledgedAt! {
            lastAcknowledgedAt = persistedAcknowledgement
        }
        guard inFlightCandidate == nil,
              policy.isReturnCandidate(
                  wasIdle: wasIdle,
                  currentIdleSeconds: currentIdleSeconds,
                  lastGreetingAt: lastAcknowledgedAt,
                  now: now
              ) else {
            return nil
        }
        let candidate = PresenceReturnCandidate(
            id: UUID(),
            observedAt: now,
            absenceSeconds: max(maximumObservedIdle, policy.idleThreshold),
            evidence: evidence,
            confidence: .heuristic
        )
        inFlightCandidate = candidate
        wasIdle = false
        return candidate
    }

    mutating func release(candidateID: UUID, reason _: PresenceGateReason) {
        guard inFlightCandidate?.id == candidateID else { return }
        inFlightCandidate = nil
        wasIdle = true
    }

    @discardableResult
    mutating func acknowledge(candidateID: UUID, at date: Date) -> Bool {
        guard inFlightCandidate?.id == candidateID else { return false }
        inFlightCandidate = nil
        maximumObservedIdle = 0
        lastAcknowledgedAt = date
        wasIdle = false
        return true
    }
}

final class PresenceMonitor {
    private let policy: PresencePolicy
    private let defaults: UserDefaults
    private let pollInterval: TimeInterval
    private let lastGreetingKey = "presenceLastGreetingAt"
    private var timer: Timer?
    private var lifecycle: PresenceDeliveryLifecycle

    var onReturnCandidate: ((PresenceReturnCandidate) -> Bool)?

    init(
        policy: PresencePolicy,
        defaults: UserDefaults = .standard,
        pollInterval: TimeInterval = 2
    ) {
        self.policy = policy
        self.defaults = defaults
        self.pollInterval = pollInterval
        lifecycle = PresenceDeliveryLifecycle(policy: policy)
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample(now: Date = Date()) {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        guard idleSeconds.isFinite else { return }

        if idleSeconds >= policy.idleThreshold {
            lifecycle.observeIdle(idleSeconds: idleSeconds, at: now)
            return
        }

        let lastGreetingAt = defaults.object(forKey: lastGreetingKey) as? Date
        guard let candidate = lifecycle.reserveCandidate(
            currentIdleSeconds: idleSeconds,
            lastAcknowledgedAt: lastGreetingAt,
            now: now,
            evidence: .userActivityHeuristic
        ) else { return }
        if onReturnCandidate?(candidate) != true {
            lifecycle.release(candidateID: candidate.id, reason: .startRejected)
        }
    }

    func acknowledgeDelivery(candidateID: UUID, at date: Date = Date()) {
        guard lifecycle.acknowledge(candidateID: candidateID, at: date) else { return }
        defaults.set(date, forKey: lastGreetingKey)
    }

    func releaseDelivery(candidateID: UUID, reason: PresenceGateReason) {
        lifecycle.release(candidateID: candidateID, reason: reason)
    }
}
