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

final class PresenceMonitor {
    private let policy: PresencePolicy
    private let defaults: UserDefaults
    private let pollInterval: TimeInterval
    private let lastGreetingKey = "presenceLastGreetingAt"
    private var timer: Timer?
    private var wasIdle = false
    private var candidateClaimed = false

    var onReturnCandidate: (() -> Bool)?

    init(
        policy: PresencePolicy,
        defaults: UserDefaults = .standard,
        pollInterval: TimeInterval = 2
    ) {
        self.policy = policy
        self.defaults = defaults
        self.pollInterval = pollInterval
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
            wasIdle = true
            candidateClaimed = false
            return
        }

        let lastGreetingAt = defaults.object(forKey: lastGreetingKey) as? Date
        guard !candidateClaimed,
              policy.isReturnCandidate(
                  wasIdle: wasIdle,
                  currentIdleSeconds: idleSeconds,
                  lastGreetingAt: lastGreetingAt,
                  now: now
              ) else {
            return
        }

        candidateClaimed = true
        wasIdle = false
        if onReturnCandidate?() == true {
            defaults.set(now, forKey: lastGreetingKey)
        } else {
            candidateClaimed = false
            wasIdle = true
        }
    }
}
