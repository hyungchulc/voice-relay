import Foundation

struct AudioConfigurationRecoveryPlan: Equatable {
    let token: Int
    let delay: TimeInterval
}

struct AudioConfigurationRecoveryPolicy {
    private(set) var changeToken = 0
    let quietWindow: TimeInterval

    init(quietWindow: TimeInterval = 0.45) {
        self.quietWindow = quietWindow
    }

    mutating func registerChange(
        now: TimeInterval,
        recoveryNotBefore: TimeInterval
    ) -> AudioConfigurationRecoveryPlan {
        changeToken &+= 1
        return AudioConfigurationRecoveryPlan(
            token: changeToken,
            delay: max(quietWindow, recoveryNotBefore - now)
        )
    }

    func isCurrent(token: Int) -> Bool {
        token == changeToken
    }

    mutating func invalidate() {
        changeToken &+= 1
    }
}

struct AudioCaptureRoutingToken: Equatable, Hashable {
    let epoch: UInt64
    let beginsAtHostTime: UInt64
}

enum AudioCaptureBindingActivationDecision: Equatable {
    case use(AudioCaptureRoutingToken)
    case activate(atHostTime: UInt64)
    case awaitValidTimestamp
}

struct AudioCaptureBindingActivationPolicy {
    static func decision(
        existingToken: AudioCaptureRoutingToken?,
        firstBufferHostTime: UInt64?
    ) -> AudioCaptureBindingActivationDecision {
        if let existingToken {
            return .use(existingToken)
        }
        guard let firstBufferHostTime else {
            return .awaitValidTimestamp
        }
        return .activate(atHostTime: firstBufferHostTime)
    }
}

enum AudioCaptureReleaseCompletionMilestone: Hashable {
    case engineRetired
    case routingDrained
}

final class AudioCaptureReleaseCompletionBarrier {
    private let lock = NSLock()
    private var pending: Set<AudioCaptureReleaseCompletionMilestone> = [
        .engineRetired,
        .routingDrained,
    ]
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    func signal(_ milestone: AudioCaptureReleaseCompletionMilestone) {
        let completionToRun: (() -> Void)? = lock.withLock {
            pending.remove(milestone)
            guard pending.isEmpty, let completion else { return nil }
            self.completion = nil
            return completion
        }
        completionToRun?()
    }
}

enum AudioCaptureStopCompletionDecision: Equatable {
    case waitForTransportHandoff
    case finishAndResumeWake
}

struct AudioCaptureStopCompletionPolicy {
    static func decision(
        audioHandoffReady: Bool
    ) -> AudioCaptureStopCompletionDecision {
        audioHandoffReady
            ? .finishAndResumeWake
            : .waitForTransportHandoff
    }
}

struct AudioCaptureInputTapFence {
    private(set) var snapshot: UInt64 = 0

    mutating func invalidate() {
        snapshot &+= 1
    }
}

struct AudioCaptureInputTapFenceSet {
    private var idleWakeRaw = AudioCaptureInputTapFence()
    private var realtimeFullDuplex = AudioCaptureInputTapFence()

    func snapshot(for plane: AudioCapturePlane) -> UInt64 {
        switch plane {
        case .idleWakeRaw:
            return idleWakeRaw.snapshot
        case .realtimeFullDuplex:
            return realtimeFullDuplex.snapshot
        }
    }

    mutating func invalidate(_ plane: AudioCapturePlane) {
        switch plane {
        case .idleWakeRaw:
            idleWakeRaw.invalidate()
        case .realtimeFullDuplex:
            realtimeFullDuplex.invalidate()
        }
    }

    mutating func invalidateAll() {
        idleWakeRaw.invalidate()
        realtimeFullDuplex.invalidate()
    }
}

struct AudioCaptureInputCallbackPolicy {
    static func acceptsBeforeRouting(
        capturedTapRevision: UInt64,
        currentTapRevision: UInt64,
        microphoneInputEnabled: Bool
    ) -> Bool {
        microphoneInputEnabled
            && capturedTapRevision == currentTapRevision
    }

    static func accepts(
        capturedMediaEpoch: Int,
        currentMediaEpoch: Int,
        capturedTapRevision: UInt64,
        currentTapRevision: UInt64,
        microphoneInputEnabled: Bool,
        routingTokenRecognized: Bool
    ) -> Bool {
        guard acceptsBeforeRouting(
                  capturedTapRevision: capturedTapRevision,
                  currentTapRevision: currentTapRevision,
                  microphoneInputEnabled: microphoneInputEnabled
              ),
              routingTokenRecognized else {
            return false
        }
        _ = capturedMediaEpoch
        _ = currentMediaEpoch
        return true
    }
}

enum AudioCaptureSessionStopInputFenceDecision: Equatable {
    case preserveAdmittedCallbacks
    case invalidateAll
}

struct AudioCaptureSessionStopInputFencePolicy {
    static func decision(
        preserveCaptureContinuity: Bool
    ) -> AudioCaptureSessionStopInputFenceDecision {
        preserveCaptureContinuity
            ? .preserveAdmittedCallbacks
            : .invalidateAll
    }
}

struct AudioCapturePlaybackReferenceCallbackPolicy {
    static func accepts(
        capturedMediaEpoch: Int,
        currentMediaEpoch: Int,
        routingTokenRecognized: Bool
    ) -> Bool {
        _ = capturedMediaEpoch
        _ = currentMediaEpoch
        return routingTokenRecognized
    }
}

struct AudioCaptureAsynchronousCallbackDrain {
    static func perform(
        processing: () -> Void,
        completion: () -> Void
    ) {
        defer { completion() }
        processing()
    }
}

final class AudioCaptureRouteBinding {
    let plane: AudioCapturePlane
    private let callbackLock = NSLock()
    private var routingToken: AudioCaptureRoutingToken?
    private var activationHandlers: [
        (AudioCaptureRoutingToken?) -> Void
    ] = []
    private var acceptsCallbacks = true
    private var callbacksInFlight = 0
    private var retirementScheduled = false
    private var retirementCompletions: [() -> Void] = []
    private var provisionalUnavailableTimestamps = 0
    private let maximumProvisionalUnavailableTimestamps = 3

    init(plane: AudioCapturePlane) {
        self.plane = plane
    }

    var token: AudioCaptureRoutingToken? {
        get { callbackLock.withLock { routingToken } }
        set { callbackLock.withLock { routingToken = newValue } }
    }

    func registerActivationHandler(
        _ handler: @escaping (AudioCaptureRoutingToken?) -> Void
    ) {
        let disposition: (
            invokeImmediately: Bool,
            token: AudioCaptureRoutingToken?
        ) = callbackLock.withLock {
            if let routingToken {
                return (true, routingToken)
            }
            guard acceptsCallbacks, !retirementScheduled else {
                return (true, nil)
            }
            activationHandlers.append(handler)
            return (false, nil)
        }
        if disposition.invokeImmediately {
            handler(disposition.token)
        }
    }

    func publish(
        token: AudioCaptureRoutingToken
    ) -> [(AudioCaptureRoutingToken?) -> Void] {
        publishIfAccepting { token }?.handlers ?? []
    }

    func publishIfAccepting(
        tokenProvider: () -> AudioCaptureRoutingToken
    ) -> (
        token: AudioCaptureRoutingToken,
        handlers: [(AudioCaptureRoutingToken?) -> Void]
    )? {
        callbackLock.withLock {
            guard routingToken == nil,
                  acceptsCallbacks,
                  !retirementScheduled else {
                return nil
            }
            let token = tokenProvider()
            routingToken = token
            let handlers = activationHandlers
            activationHandlers.removeAll(keepingCapacity: false)
            return (token, handlers)
        }
    }

    func cancelPendingActivationHandlers() {
        let handlers = callbackLock.withLock {
            let handlers = activationHandlers
            activationHandlers.removeAll(keepingCapacity: false)
            return handlers
        }
        for handler in handlers {
            handler(nil)
        }
    }

    func registerRetirementCompletion(
        _ completion: @escaping () -> Void
    ) {
        callbackLock.withLock {
            retirementCompletions.append(completion)
        }
    }

    func takeRetirementCompletions() -> [() -> Void] {
        callbackLock.withLock {
            let completions = retirementCompletions
            retirementCompletions.removeAll(keepingCapacity: false)
            return completions
        }
    }

    func recordProvisionalTiming(
        timestampAvailable: Bool
    ) -> AudioCaptureProvisionalTimingDisposition {
        callbackLock.withLock {
            if routingToken != nil {
                return .ready
            }
            guard acceptsCallbacks, !retirementScheduled else {
                return .ignoredStale
            }
            if timestampAvailable {
                provisionalUnavailableTimestamps = 0
                return .ready
            }
            provisionalUnavailableTimestamps += 1
            return provisionalUnavailableTimestamps
                >= maximumProvisionalUnavailableTimestamps
                ? .failed
                : .awaitingValidTimestamp
        }
    }

    func beginCaptureCallback() -> Bool {
        callbackLock.withLock {
            guard acceptsCallbacks, !retirementScheduled else {
                return false
            }
            callbacksInFlight += 1
            return true
        }
    }

    func requestRetirement() -> Bool {
        callbackLock.withLock {
            acceptsCallbacks = false
            guard callbacksInFlight == 0, !retirementScheduled else {
                return false
            }
            retirementScheduled = true
            return true
        }
    }

    func finishCaptureCallback() -> Bool {
        callbackLock.withLock {
            callbacksInFlight = max(0, callbacksInFlight - 1)
            guard !acceptsCallbacks,
                  callbacksInFlight == 0,
                  !retirementScheduled else {
                return false
            }
            retirementScheduled = true
            return true
        }
    }
}

struct AudioCaptureSuccessorActivationPolicy {
    static func register(
        successor: AudioCaptureRouteBinding,
        onActivated: @escaping (AudioCaptureRoutingToken) -> Void
    ) {
        successor.registerActivationHandler { token in
            guard let token else { return }
            onActivated(token)
        }
    }
}

final class AudioCaptureStopHandoffOwnership {
    let generation: Int

    private enum State {
        case active
        case releaseClaimed
        case wakeRearmClaimed
        case finished
    }

    private let lock = NSLock()
    private let realtimeEngineIdentity: ObjectIdentifier
    private let realtimeBindingIdentity: ObjectIdentifier
    private let wakeEngineIdentity: ObjectIdentifier?
    private let wakeBindingIdentity: ObjectIdentifier?
    private var state: State = .active
    private var completion: (() -> Void)?

    init(
        generation: Int,
        realtimeEngine: AnyObject,
        realtimeBinding: AudioCaptureRouteBinding,
        wakeEngine: AnyObject? = nil,
        wakeBinding: AudioCaptureRouteBinding? = nil,
        completion: (() -> Void)? = nil
    ) {
        precondition((wakeEngine == nil) == (wakeBinding == nil))
        self.generation = generation
        realtimeEngineIdentity = ObjectIdentifier(realtimeEngine)
        realtimeBindingIdentity = ObjectIdentifier(realtimeBinding)
        wakeEngineIdentity = wakeEngine.map(ObjectIdentifier.init)
        wakeBindingIdentity = wakeBinding.map(ObjectIdentifier.init)
        self.completion = completion
    }

    func ownsTransition(
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?,
        wakeEngine: AnyObject?,
        wakeBinding: AudioCaptureRouteBinding?
    ) -> Bool {
        lock.withLock {
            state == .active
                && generationMatches(activeGeneration)
                && Self.matches(
                    realtimeEngine,
                    identity: realtimeEngineIdentity
                )
                && Self.matches(
                    realtimeBinding,
                    identity: realtimeBindingIdentity
                )
                && Self.matches(
                    wakeEngine,
                    optionalIdentity: wakeEngineIdentity
                )
                && Self.matches(
                    wakeBinding,
                    optionalIdentity: wakeBindingIdentity
                )
        }
    }

    @discardableResult
    func claimTransitionRelease(
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?,
        wakeEngine: AnyObject?,
        wakeBinding: AudioCaptureRouteBinding?
    ) -> Bool {
        claimRelease(
            activeGeneration: activeGeneration,
            realtimeEngine: realtimeEngine,
            realtimeBinding: realtimeBinding,
            wakeEngine: wakeEngine,
            wakeBinding: wakeBinding,
            requiresWakeOwnership: true
        )
    }

    @discardableResult
    func claimRealtimeRelease(
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?
    ) -> Bool {
        claimRelease(
            activeGeneration: activeGeneration,
            realtimeEngine: realtimeEngine,
            realtimeBinding: realtimeBinding,
            wakeEngine: nil,
            wakeBinding: nil,
            requiresWakeOwnership: false
        )
    }

    @discardableResult
    func claimWakeRearm(
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?,
        wakeEngine: AnyObject?,
        wakeBinding: AudioCaptureRouteBinding?
    ) -> Bool {
        lock.withLock {
            guard state == .releaseClaimed,
                  activeGeneration == nil,
                  realtimeEngine == nil,
                  realtimeBinding == nil,
                  wakeEngine == nil,
                  wakeBinding == nil else {
                return false
            }
            state = .wakeRearmClaimed
            return true
        }
    }

    func revoke() {
        finish()
    }

    func finish() {
        let completionToRun: (() -> Void)? = lock.withLock {
            guard state != .finished else { return nil }
            state = .finished
            let completionToRun = completion
            completion = nil
            return completionToRun
        }
        completionToRun?()
    }

    private func claimRelease(
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?,
        wakeEngine: AnyObject?,
        wakeBinding: AudioCaptureRouteBinding?,
        requiresWakeOwnership: Bool
    ) -> Bool {
        lock.withLock {
            guard state == .active,
                  generationMatches(activeGeneration),
                  Self.matches(
                      realtimeEngine,
                      identity: realtimeEngineIdentity
                  ),
                  Self.matches(
                      realtimeBinding,
                      identity: realtimeBindingIdentity
                  ) else {
                return false
            }
            if requiresWakeOwnership {
                guard let wakeEngineIdentity,
                      let wakeBindingIdentity,
                      Self.matches(
                          wakeEngine,
                          identity: wakeEngineIdentity
                      ),
                      Self.matches(
                          wakeBinding,
                          identity: wakeBindingIdentity
                      ) else {
                    return false
                }
            }
            state = .releaseClaimed
            return true
        }
    }

    private func generationMatches(_ activeGeneration: Int?) -> Bool {
        activeGeneration == nil || activeGeneration == generation
    }

    private static func matches(
        _ object: AnyObject?,
        identity: ObjectIdentifier
    ) -> Bool {
        guard let object else { return false }
        return ObjectIdentifier(object) == identity
    }

    private static func matches(
        _ object: AnyObject?,
        optionalIdentity: ObjectIdentifier?
    ) -> Bool {
        guard let optionalIdentity else { return object == nil }
        return matches(object, identity: optionalIdentity)
    }
}

final class AudioCaptureStopHandoffFailureFallback {
    private let lock = NSLock()
    private var ownership: AudioCaptureStopHandoffOwnership?
    private var binding: AudioCaptureRouteBinding?
    private var action: (() -> Void)?

    func arm(
        ownership: AudioCaptureStopHandoffOwnership,
        binding: AudioCaptureRouteBinding,
        action: @escaping () -> Void
    ) {
        let previousOwnership = lock.withLock {
            let previousOwnership = self.ownership
            self.ownership = ownership
            self.binding = binding
            self.action = action
            return previousOwnership
        }
        previousOwnership?.revoke()
    }

    @discardableResult
    func disarm(
        ownership: AudioCaptureStopHandoffOwnership,
        binding: AudioCaptureRouteBinding
    ) -> Bool {
        lock.withLock {
            guard self.ownership === ownership,
                  self.binding === binding else { return false }
            self.ownership = nil
            self.binding = nil
            action = nil
            return true
        }
    }

    @discardableResult
    func triggerIfArmed(
        for binding: AudioCaptureRouteBinding,
        activeGeneration: Int?,
        realtimeEngine: AnyObject?,
        realtimeBinding: AudioCaptureRouteBinding?,
        wakeEngine: AnyObject?,
        wakeBinding: AudioCaptureRouteBinding?
    ) -> Bool {
        let pending: (
            ownership: AudioCaptureStopHandoffOwnership,
            action: () -> Void
        )? = lock.withLock {
            guard self.binding === binding else { return nil }
            guard let ownership, let action else { return nil }
            self.ownership = nil
            self.binding = nil
            self.action = nil
            return (ownership, action)
        }
        guard let pending else { return false }
        guard pending.ownership.ownsTransition(
            activeGeneration: activeGeneration,
            realtimeEngine: realtimeEngine,
            realtimeBinding: realtimeBinding,
            wakeEngine: wakeEngine,
            wakeBinding: wakeBinding
        ) else {
            pending.ownership.revoke()
            return false
        }
        pending.action()
        return true
    }

    func cancel() {
        let pendingOwnership = lock.withLock {
            let pendingOwnership = ownership
            ownership = nil
            binding = nil
            action = nil
            return pendingOwnership
        }
        pendingOwnership?.revoke()
    }
}

enum AudioCaptureProvisionalTimingDisposition: Equatable {
    case ready
    case awaitingValidTimestamp
    case ignoredStale
    case failed
}

struct AudioCaptureEngineBindingPolicy {
    static func microphoneTapRestartBinding(
        activeBinding: AudioCaptureRouteBinding?
    ) -> AudioCaptureRouteBinding? {
        activeBinding
    }

    static func canReusePersistentRealtimeBinding(
        routingTokenRecognized: Bool,
        routingTokenIsCurrent: Bool
    ) -> Bool {
        routingTokenRecognized && routingTokenIsCurrent
    }
}

struct AudioCaptureRoutingEpoch {
    private var orderedTokens = [
        AudioCaptureRoutingToken(
            epoch: 0,
            beginsAtHostTime: 0
        )
    ]

    var token: AudioCaptureRoutingToken {
        orderedTokens[orderedTokens.count - 1]
    }

    var previousToken: AudioCaptureRoutingToken? {
        guard orderedTokens.count > 1 else { return nil }
        return orderedTokens[orderedTokens.count - 2]
    }

    var retiringTokens: [AudioCaptureRoutingToken] {
        Array(orderedTokens.dropLast())
    }

    @discardableResult
    mutating func advance(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingToken {
        let nextToken = AudioCaptureRoutingToken(
            epoch: token.epoch &+ 1,
            beginsAtHostTime: hostTime
        )
        orderedTokens.append(nextToken)
        return nextToken
    }

    func accepts(
        _ candidate: AudioCaptureRoutingToken,
        bufferHostTime: UInt64?
    ) -> Bool {
        guard let bufferHostTime else {
            return false
        }
        guard let index = orderedTokens.firstIndex(of: candidate),
              bufferHostTime >= candidate.beginsAtHostTime else {
            return false
        }
        guard index + 1 < orderedTokens.count else { return true }
        return bufferHostTime < orderedTokens[index + 1].beginsAtHostTime
    }

    func acceptedFrameRange(
        _ candidate: AudioCaptureRoutingToken,
        bufferStartHostTime: UInt64,
        frameCount: Int,
        sampleRate: Double,
        hostClockFrequency: Double
    ) -> Range<Int>? {
        guard frameCount > 0,
              sampleRate > 0,
              hostClockFrequency > 0 else {
            return nil
        }
        guard let index = orderedTokens.firstIndex(of: candidate) else {
            return nil
        }
        let lowerBound = Self.frameIndex(
            atOrAfter: candidate.beginsAtHostTime,
            bufferStartHostTime: bufferStartHostTime,
            frameCount: frameCount,
            sampleRate: sampleRate,
            hostClockFrequency: hostClockFrequency
        )
        let upperBound: Int
        if index + 1 < orderedTokens.count {
            upperBound = Self.frameIndex(
                atOrAfter: orderedTokens[index + 1].beginsAtHostTime,
                bufferStartHostTime: bufferStartHostTime,
                frameCount: frameCount,
                sampleRate: sampleRate,
                hostClockFrequency: hostClockFrequency
            )
        } else {
            upperBound = frameCount
        }
        let range = min(lowerBound, upperBound)..<upperBound
        return range.isEmpty ? nil : range
    }

    func recognizes(_ candidate: AudioCaptureRoutingToken) -> Bool {
        orderedTokens.contains(candidate)
    }

    @discardableResult
    mutating func retire(
        _ candidate: AudioCaptureRoutingToken
    ) -> Bool {
        guard let index = orderedTokens.firstIndex(of: candidate),
              index < orderedTokens.count - 1 else {
            return false
        }
        orderedTokens.remove(at: index)
        return true
    }

    func isCurrent(_ candidate: AudioCaptureRoutingToken) -> Bool {
        candidate == token
    }

    mutating func invalidate(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingToken {
        let invalidationToken = AudioCaptureRoutingToken(
            epoch: token.epoch &+ 1,
            beginsAtHostTime: hostTime
        )
        orderedTokens = [invalidationToken]
        return invalidationToken
    }

    private static func frameIndex(
        atOrAfter boundaryHostTime: UInt64,
        bufferStartHostTime: UInt64,
        frameCount: Int,
        sampleRate: Double,
        hostClockFrequency: Double
    ) -> Int {
        guard boundaryHostTime > bufferStartHostTime else { return 0 }
        let ticksUntilBoundary = Double(
            boundaryHostTime - bufferStartHostTime
        )
        return min(
            frameCount,
            max(
                0,
                Int(ceil(
                    ticksUntilBoundary
                        * sampleRate
                        / hostClockFrequency
                ))
            )
        )
    }
}

struct AudioCapturePCMBuffer: Equatable {
    let token: AudioCaptureRoutingToken
    let startHostTime: UInt64
    let sampleRate: Double
    let hostClockFrequency: Double
    let samples: [Float]
}

struct AudioCaptureRoutedPCMBuffer: Equatable {
    let token: AudioCaptureRoutingToken
    let startHostTime: UInt64
    let sampleRate: Double
    let hostClockFrequency: Double
    let samples: [Float]
}

struct AudioCaptureRoutingTransition: Equatable {
    let token: AudioCaptureRoutingToken
    let retiredTokens: [AudioCaptureRoutingToken]
    let readyBuffers: [AudioCaptureRoutedPCMBuffer]
}

enum AudioCaptureRoutingRetirementDisposition: Equatable {
    case deferred
    case retired
    case unknown
}

struct AudioCaptureRoutingRetirement: Equatable {
    let disposition: AudioCaptureRoutingRetirementDisposition
    let retiredTokens: [AudioCaptureRoutingToken]
    let readyBuffers: [AudioCaptureRoutedPCMBuffer]
}

struct AudioCaptureTimelineRouter {
    private(set) var routingEpoch = AudioCaptureRoutingEpoch()
    private var pendingBuffers: [AudioCaptureRoutedPCMBuffer] = []
    private var requestedRetirements: Set<AudioCaptureRoutingToken> = []

    @discardableResult
    mutating func advance(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingToken {
        routingEpoch.advance(atHostTime: hostTime)
    }

    mutating func activate(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingTransition {
        let token = routingEpoch.advance(atHostTime: hostTime)
        let retirement = drainRequestedRetirements()
        return AudioCaptureRoutingTransition(
            token: token,
            retiredTokens: retirement.tokens,
            readyBuffers: retirement.readyBuffers
        )
    }

    mutating func requestRetirement(
        _ token: AudioCaptureRoutingToken
    ) -> AudioCaptureRoutingRetirement {
        if routingEpoch.isCurrent(token) {
            requestedRetirements.insert(token)
            return AudioCaptureRoutingRetirement(
                disposition: .deferred,
                retiredTokens: [],
                readyBuffers: []
            )
        }
        guard routingEpoch.recognizes(token) else {
            requestedRetirements.remove(token)
            return AudioCaptureRoutingRetirement(
                disposition: .unknown,
                retiredTokens: [],
                readyBuffers: []
            )
        }
        requestedRetirements.insert(token)
        let retirement = drainRequestedRetirements()
        guard !retirement.tokens.isEmpty else {
            return AudioCaptureRoutingRetirement(
                disposition: .deferred,
                retiredTokens: [],
                readyBuffers: []
            )
        }
        return AudioCaptureRoutingRetirement(
            disposition: .retired,
            retiredTokens: retirement.tokens,
            readyBuffers: retirement.readyBuffers
        )
    }

    mutating func requestRelease(
        _ token: AudioCaptureRoutingToken,
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingRetirement {
        if routingEpoch.isCurrent(token) {
            _ = sealCurrentForRelease(atHostTime: hostTime)
        }
        return requestRetirement(token)
    }

    func recognizes(_ token: AudioCaptureRoutingToken) -> Bool {
        routingEpoch.recognizes(token)
    }

    func isCurrent(_ token: AudioCaptureRoutingToken) -> Bool {
        routingEpoch.isCurrent(token)
    }

    mutating func route(
        _ buffer: AudioCapturePCMBuffer
    ) -> [AudioCaptureRoutedPCMBuffer] {
        guard let acceptedRange = routingEpoch.acceptedFrameRange(
            buffer.token,
            bufferStartHostTime: buffer.startHostTime,
            frameCount: buffer.samples.count,
            sampleRate: buffer.sampleRate,
            hostClockFrequency: buffer.hostClockFrequency
        ) else {
            return []
        }
        let ticksPerFrame =
            buffer.hostClockFrequency / buffer.sampleRate
        let acceptedStart = buffer.startHostTime &+ UInt64(
            (Double(acceptedRange.lowerBound) * ticksPerFrame).rounded()
        )
        let routed = AudioCaptureRoutedPCMBuffer(
            token: buffer.token,
            startHostTime: acceptedStart,
            sampleRate: buffer.sampleRate,
            hostClockFrequency: buffer.hostClockFrequency,
            samples: Array(buffer.samples[acceptedRange])
        )
        guard !routingEpoch.retiringTokens.isEmpty else {
            return [routed]
        }
        pendingBuffers.append(routed)
        return []
    }

    mutating func retirePrevious(
        _ token: AudioCaptureRoutingToken
    ) -> [AudioCaptureRoutedPCMBuffer] {
        requestRetirement(token).readyBuffers
    }

    private mutating func drainRequestedRetirements() -> (
        tokens: [AudioCaptureRoutingToken],
        readyBuffers: [AudioCaptureRoutedPCMBuffer]
    ) {
        var retiredTokens: [AudioCaptureRoutingToken] = []
        var readyBuffers: [AudioCaptureRoutedPCMBuffer] = []
        while let oldest = routingEpoch.retiringTokens.first,
              requestedRetirements.contains(oldest) {
            requestedRetirements.remove(oldest)
            retiredTokens.append(oldest)
            readyBuffers.append(contentsOf: retireRoutingToken(oldest))
        }
        return (retiredTokens, readyBuffers)
    }

    private mutating func retireRoutingToken(
        _ token: AudioCaptureRoutingToken
    ) -> [AudioCaptureRoutedPCMBuffer] {
        guard routingEpoch.retire(token) else { return [] }
        requestedRetirements.remove(token)
        guard routingEpoch.retiringTokens.isEmpty else { return [] }
        let ready = Self.orderedWithoutOverlap(pendingBuffers)
        pendingBuffers.removeAll(keepingCapacity: true)
        return ready
    }

    mutating func invalidate(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingToken {
        pendingBuffers.removeAll(keepingCapacity: false)
        requestedRetirements.removeAll(keepingCapacity: false)
        let invalidationToken = routingEpoch.invalidate(
            atHostTime: hostTime
        )
        requestedRetirements.insert(invalidationToken)
        return invalidationToken
    }

    mutating func sealCurrentForRelease(
        atHostTime hostTime: UInt64
    ) -> AudioCaptureRoutingToken {
        let boundary = routingEpoch.advance(atHostTime: hostTime)
        requestedRetirements.insert(boundary)
        return boundary
    }

    private static func orderedWithoutOverlap(
        _ buffers: [AudioCaptureRoutedPCMBuffer]
    ) -> [AudioCaptureRoutedPCMBuffer] {
        let ordered = buffers.sorted {
            if $0.startHostTime != $1.startHostTime {
                return $0.startHostTime < $1.startHostTime
            }
            return $0.token.epoch < $1.token.epoch
        }
        var result: [AudioCaptureRoutedPCMBuffer] = []
        var coveredUntilHostTime: Double?
        for buffer in ordered where !buffer.samples.isEmpty {
            let ticksPerFrame =
                buffer.hostClockFrequency / buffer.sampleRate
            var trimmedFrames = 0
            if let coveredUntilHostTime,
               Double(buffer.startHostTime) < coveredUntilHostTime {
                trimmedFrames = min(
                    buffer.samples.count,
                    max(
                        0,
                        Int(ceil(
                            (coveredUntilHostTime
                                - Double(buffer.startHostTime))
                                / ticksPerFrame
                        ))
                    )
                )
            }
            guard trimmedFrames < buffer.samples.count else { continue }
            let trimmedStart = buffer.startHostTime &+ UInt64(
                (Double(trimmedFrames) * ticksPerFrame).rounded()
            )
            let trimmedSamples = Array(buffer.samples[trimmedFrames...])
            result.append(
                AudioCaptureRoutedPCMBuffer(
                    token: buffer.token,
                    startHostTime: trimmedStart,
                    sampleRate: buffer.sampleRate,
                    hostClockFrequency: buffer.hostClockFrequency,
                    samples: trimmedSamples
                )
            )
            coveredUntilHostTime = max(
                coveredUntilHostTime ?? -Double.greatestFiniteMagnitude,
                Double(trimmedStart)
                    + Double(trimmedSamples.count) * ticksPerFrame
            )
        }
        return result
    }
}

enum AudioCapturePlane: Equatable {
    case idleWakeRaw
    case realtimeFullDuplex
}

struct AudioCaptureGraphRequirements: Equatable {
    let voiceProcessing: Bool
    let outputPlayback: Bool
    let playbackReferenceTap: Bool
}

enum AudioCapturePlaneHandoffDecision: Equatable {
    case keepCurrentPlane
    case retireIdleWake
    case retireRealtime
    case retireRealtimeAndRearmWake
}

struct AudioCapturePlanePolicy {
    static func requirements(
        for plane: AudioCapturePlane
    ) -> AudioCaptureGraphRequirements {
        switch plane {
        case .idleWakeRaw:
            return AudioCaptureGraphRequirements(
                voiceProcessing: false,
                outputPlayback: false,
                playbackReferenceTap: false
            )
        case .realtimeFullDuplex:
            return AudioCaptureGraphRequirements(
                voiceProcessing: true,
                outputPlayback: true,
                playbackReferenceTap: true
            )
        }
    }

    static func realtimeStartupDecision(
        succeeded: Bool
    ) -> AudioCapturePlaneHandoffDecision {
        succeeded ? .retireIdleWake : .keepCurrentPlane
    }

    static let realtimeStartupFailurePlan =
        AudioCaptureStartupFailurePlan(
            preserveCaptureForWake: true,
            preserveHandoffJournal: true,
            rearmWakeAnalyzer: true
        )

    static func wakeStartupDecision(
        succeeded: Bool
    ) -> AudioCapturePlaneHandoffDecision {
        succeeded ? .retireRealtime : .retireRealtimeAndRearmWake
    }
}

struct AudioCaptureTimingHealth {
    let maximumUnavailableBuffers: Int
    private(set) var consecutiveUnavailableBuffers = 0

    init(maximumUnavailableBuffers: Int = 3) {
        self.maximumUnavailableBuffers = max(1, maximumUnavailableBuffers)
    }

    mutating func record(timestampAvailable: Bool) -> Bool {
        if timestampAvailable {
            consecutiveUnavailableBuffers = 0
            return false
        }
        consecutiveUnavailableBuffers += 1
        return consecutiveUnavailableBuffers >= maximumUnavailableBuffers
    }

    mutating func reset() {
        consecutiveUnavailableBuffers = 0
    }
}

enum AudioCaptureTimingDisposition: Equatable {
    case ignoredStale
    case accepted
    case failed
}

struct AudioCaptureTimingTracker {
    let maximumUnavailableBuffers: Int
    private var healthByEpoch: [UInt64: AudioCaptureTimingHealth] = [:]

    init(maximumUnavailableBuffers: Int = 3) {
        self.maximumUnavailableBuffers = max(1, maximumUnavailableBuffers)
    }

    mutating func activate(_ token: AudioCaptureRoutingToken) {
        healthByEpoch[token.epoch] = AudioCaptureTimingHealth(
            maximumUnavailableBuffers: maximumUnavailableBuffers
        )
    }

    mutating func retire(_ token: AudioCaptureRoutingToken) {
        healthByEpoch.removeValue(forKey: token.epoch)
    }

    mutating func record(
        token: AudioCaptureRoutingToken,
        timestampAvailable: Bool,
        recognized: Bool,
        isCurrent: Bool
    ) -> AudioCaptureTimingDisposition {
        guard recognized else { return .ignoredStale }
        guard isCurrent || timestampAvailable else {
            return .ignoredStale
        }
        var health = healthByEpoch[token.epoch]
            ?? AudioCaptureTimingHealth(
                maximumUnavailableBuffers: maximumUnavailableBuffers
            )
        let failed = health.record(
            timestampAvailable: timestampAvailable
        )
        healthByEpoch[token.epoch] = health
        return failed ? .failed : .accepted
    }

    mutating func reset() {
        healthByEpoch.removeAll(keepingCapacity: false)
    }
}

struct AudioCaptureStartupFailurePlan: Equatable {
    let preserveCaptureForWake: Bool
    let preserveHandoffJournal: Bool
    let rearmWakeAnalyzer: Bool

    static let teardown = AudioCaptureStartupFailurePlan(
        preserveCaptureForWake: false,
        preserveHandoffJournal: false,
        rearmWakeAnalyzer: false
    )

    var allowsTransportRetry: Bool {
        !rearmWakeAnalyzer
    }

    func eventFields(
        wakePhraseEnabled: Bool
    ) -> [String: Bool] {
        [
            "preserveWakeCapture":
                preserveCaptureForWake && wakePhraseEnabled,
            "preserveWakeJournal":
                preserveHandoffJournal && wakePhraseEnabled,
            "rearmWakeAnalyzer":
                rearmWakeAnalyzer && wakePhraseEnabled,
        ]
    }

    static func fromEventFields(
        _ event: [String: Any],
        wakePhraseEnabled: Bool
    ) -> AudioCaptureStartupFailurePlan {
        AudioCaptureStartupFailurePlan(
            preserveCaptureForWake:
                (event["preserveWakeCapture"] as? Bool ?? false)
                && wakePhraseEnabled,
            preserveHandoffJournal:
                (event["preserveWakeJournal"] as? Bool ?? false)
                && wakePhraseEnabled,
            rearmWakeAnalyzer:
                (event["rearmWakeAnalyzer"] as? Bool ?? false)
                && wakePhraseEnabled
        )
    }
}

enum PersistentAudioCaptureOwner: Equatable {
    case realtime(generation: Int)
    case wake
    case none
}

struct PersistentAudioCaptureOwnerPolicy {
    static func resolve(
        activeGeneration: Int?,
        realtimeStopping: Bool,
        wakeConsumerBound: Bool
    ) -> PersistentAudioCaptureOwner {
        if let activeGeneration, !realtimeStopping {
            return .realtime(generation: activeGeneration)
        }
        if activeGeneration == nil, wakeConsumerBound {
            return .wake
        }
        return .none
    }
}

struct RealtimeEchoFilterResult {
    enum Classification: Equatable {
        case noPlaybackReference
        case echoOnly
        case uncertainSpeech
        case residualSpeech
    }

    let samples: [Float]
    let classification: Classification
    let correlation: Float
}

struct RealtimeEchoAdmissionPolicy {
    static let sampleRate = 24_000.0

    private let maximumReferenceSamples = 72_000
    private let maximumEchoDelaySamples = 6_000
    private let delayStepSamples = 120
    private let minimumCorrelation: Float = 0.68
    private let minimumResidualRMS: Float = 0.012
    private let audibleReferenceHoldDuration: TimeInterval = 0.12
    private let playbackTailDuration: TimeInterval = 1.6
    private let bargeInPermitDuration: TimeInterval = 2.5
    private let uncertainSpeechConfirmationDuration: TimeInterval = 0.30
    private let uncertainSpeechGapTolerance: TimeInterval = 0.20
    private let minimumSustainedSpeechObservations = 4

    private var referenceStartTick: Int64?
    private var referenceSamples: [Float] = []
    private var audibleReferenceUntil = -Double.greatestFiniteMagnitude
    private var playbackGuardUntil = -Double.greatestFiniteMagnitude
    private var bargeInPermitUntil = -Double.greatestFiniteMagnitude
    private var uncertainSpeechStartedAt: TimeInterval?
    private var uncertainSpeechLastObservedAt: TimeInterval?
    private var uncertainSpeechObservationCount = 0
    private var discardingUnadmittedServerTurn = false

    mutating func appendPlaybackReference(
        _ samples: [Float],
        startTime: TimeInterval
    ) {
        guard !samples.isEmpty, startTime.isFinite else { return }
        let startTick = Self.tick(for: startTime)
        guard let currentStart = referenceStartTick else {
            referenceStartTick = startTick
            referenceSamples = samples
            trimReference()
            return
        }

        let currentEnd = currentStart + Int64(referenceSamples.count)
        if startTick > currentEnd + Int64(maximumEchoDelaySamples) {
            referenceStartTick = startTick
            referenceSamples = samples
            trimReference()
            return
        }

        if startTick > currentEnd {
            referenceSamples.append(
                contentsOf: repeatElement(
                    0,
                    count: Int(startTick - currentEnd)
                )
            )
        }

        if startTick < currentStart {
            let prefixCount = Int(currentStart - startTick)
            referenceSamples.insert(
                contentsOf: repeatElement(0, count: prefixCount),
                at: 0
            )
            referenceStartTick = startTick
        }

        guard let adjustedStart = referenceStartTick else { return }
        let offset = Int(startTick - adjustedStart)
        let requiredCount = offset + samples.count
        if requiredCount > referenceSamples.count {
            referenceSamples.append(
                contentsOf: repeatElement(
                    0,
                    count: requiredCount - referenceSamples.count
                )
            )
        }
        referenceSamples.replaceSubrange(
            offset..<(offset + samples.count),
            with: samples
        )
        trimReference()
    }

    mutating func markPlaybackActive(at time: TimeInterval) {
        guard time.isFinite else { return }
        audibleReferenceUntil = max(
            audibleReferenceUntil,
            time + audibleReferenceHoldDuration
        )
        playbackGuardUntil = max(
            playbackGuardUntil,
            time + playbackTailDuration
        )
    }

    mutating func markPlaybackEnded(at time: TimeInterval) {
        guard time.isFinite else { return }
        playbackGuardUntil = max(
            playbackGuardUntil,
            time + playbackTailDuration
        )
    }

    mutating func filterCapture(
        _ input: [Float],
        startTime: TimeInterval,
        playbackActive: Bool,
        playbackProvisionallyPaused: Bool = false
    ) -> RealtimeEchoFilterResult {
        guard !input.isEmpty else {
            return RealtimeEchoFilterResult(
                samples: [],
                classification: .noPlaybackReference,
                correlation: 0
            )
        }
        let isPlaybackWindow =
            playbackActive || startTime <= playbackGuardUntil
        guard isPlaybackWindow else {
            uncertainSpeechStartedAt = nil
            uncertainSpeechLastObservedAt = nil
            uncertainSpeechObservationCount = 0
            return RealtimeEchoFilterResult(
                samples: input,
                classification: .noPlaybackReference,
                correlation: 0
            )
        }
        guard let referenceStartTick,
              !referenceSamples.isEmpty else {
            return classifyUncorrelatedPlaybackInput(
                input,
                startTime: startTime,
                correlation: 0
            )
        }

        let inputStartTick = Self.tick(for: startTime)
        var bestCorrelation: Float = 0
        var bestReference: [Float]?
        for delay in stride(
            from: 0,
            through: maximumEchoDelaySamples,
            by: delayStepSamples
        ) {
            let candidateStart =
                inputStartTick - Int64(delay) - referenceStartTick
            guard candidateStart >= 0 else { continue }
            let offset = Int(candidateStart)
            guard offset + input.count <= referenceSamples.count else {
                continue
            }
            let candidate = Array(
                referenceSamples[offset..<(offset + input.count)]
            )
            let correlation = Self.normalizedCorrelation(
                input,
                candidate
            )
            if abs(correlation) > abs(bestCorrelation) {
                bestCorrelation = correlation
                bestReference = candidate
            }
        }

        guard abs(bestCorrelation) >= minimumCorrelation,
              let bestReference else {
            return classifyUncorrelatedPlaybackInput(
                input,
                startTime: startTime,
                correlation: bestCorrelation
            )
        }

        let gain = Self.leastSquaresGain(
            input: input,
            reference: bestReference
        )
        let residual = zip(input, bestReference).map {
            max(-1, min(1, $0 - gain * $1))
        }
        let inputRMS = Self.rms(input)
        let residualRMS = Self.rms(residual)
        let echoOnlyThreshold = max(
            minimumResidualRMS,
            inputRMS * 0.30
        )
        if residualRMS <= echoOnlyThreshold {
            expireUncertainSpeechIfGapExceeded(at: startTime)
            return RealtimeEchoFilterResult(
                samples: [],
                classification: .echoOnly,
                correlation: bestCorrelation
            )
        }

        guard confirmSustainedSpeech(
            startTime: startTime
        ) else {
            return RealtimeEchoFilterResult(
                samples: residual,
                classification: .uncertainSpeech,
                correlation: bestCorrelation
            )
        }
        return RealtimeEchoFilterResult(
            samples: residual,
            classification: .residualSpeech,
            correlation: bestCorrelation
        )
    }

    private mutating func classifyUncorrelatedPlaybackInput(
        _ input: [Float],
        startTime: TimeInterval,
        correlation: Float = 0
    ) -> RealtimeEchoFilterResult {
        guard Self.rms(input) >= minimumResidualRMS else {
            expireUncertainSpeechIfGapExceeded(at: startTime)
            return RealtimeEchoFilterResult(
                samples: [],
                classification: .echoOnly,
                correlation: correlation
            )
        }
        if confirmSustainedSpeech(
            startTime: startTime
        ) {
            return RealtimeEchoFilterResult(
                samples: input,
                classification: .residualSpeech,
                correlation: correlation
            )
        }
        return RealtimeEchoFilterResult(
            samples: input,
            classification: .uncertainSpeech,
            correlation: correlation
        )
    }

    private mutating func confirmSustainedSpeech(
        startTime: TimeInterval
    ) -> Bool {
        if let lastObservedAt = uncertainSpeechLastObservedAt,
           startTime - lastObservedAt > uncertainSpeechGapTolerance {
            uncertainSpeechStartedAt = nil
            uncertainSpeechObservationCount = 0
        }
        let startedAt = uncertainSpeechStartedAt ?? startTime
        uncertainSpeechStartedAt = startedAt
        uncertainSpeechLastObservedAt = startTime
        uncertainSpeechObservationCount += 1
        guard startTime - startedAt
                >= uncertainSpeechConfirmationDuration,
              uncertainSpeechObservationCount
                >= minimumSustainedSpeechObservations else {
            return false
        }
        bargeInPermitUntil = max(
            bargeInPermitUntil,
            startTime + bargeInPermitDuration
        )
        uncertainSpeechStartedAt = nil
        uncertainSpeechLastObservedAt = nil
        uncertainSpeechObservationCount = 0
        return true
    }

    private mutating func expireUncertainSpeechIfGapExceeded(
        at time: TimeInterval
    ) {
        guard let lastObservedAt = uncertainSpeechLastObservedAt else {
            return
        }
        if time - lastObservedAt > uncertainSpeechGapTolerance {
            uncertainSpeechStartedAt = nil
            uncertainSpeechLastObservedAt = nil
            uncertainSpeechObservationCount = 0
        }
    }

    mutating func shouldRetainPendingSpeechCandidate(
        at time: TimeInterval
    ) -> Bool {
        expireUncertainSpeechIfGapExceeded(at: time)
        return uncertainSpeechStartedAt != nil
    }

    mutating func cancelProvisionalSpeech() {
        uncertainSpeechStartedAt = nil
        uncertainSpeechLastObservedAt = nil
        uncertainSpeechObservationCount = 0
    }

    mutating func shouldForwardServerEvent(
        type: String,
        playbackActive: Bool,
        now: TimeInterval
    ) -> Bool {
        let isPlaybackWindow =
            playbackActive || now <= playbackGuardUntil
        if type == "input_audio_buffer.speech_started" {
            if isPlaybackWindow && now > bargeInPermitUntil {
                discardingUnadmittedServerTurn = true
                return false
            }
            discardingUnadmittedServerTurn = false
            return true
        }

        guard discardingUnadmittedServerTurn else { return true }
        let suppressedTypes: Set<String> = [
            "input_audio_buffer.speech_stopped",
            "conversation.item.input_audio_transcription.delta",
            "conversation.item.input_audio_transcription.completed",
        ]
        guard suppressedTypes.contains(type) else { return true }
        if type == "conversation.item.input_audio_transcription.completed" {
            discardingUnadmittedServerTurn = false
        }
        return false
    }

    mutating func reset() {
        referenceStartTick = nil
        referenceSamples.removeAll(keepingCapacity: false)
        audibleReferenceUntil = -Double.greatestFiniteMagnitude
        playbackGuardUntil = -Double.greatestFiniteMagnitude
        bargeInPermitUntil = -Double.greatestFiniteMagnitude
        uncertainSpeechStartedAt = nil
        uncertainSpeechLastObservedAt = nil
        uncertainSpeechObservationCount = 0
        discardingUnadmittedServerTurn = false
    }

    private mutating func trimReference() {
        guard referenceSamples.count > maximumReferenceSamples,
              let referenceStartTick else {
            return
        }
        let removalCount =
            referenceSamples.count - maximumReferenceSamples
        referenceSamples.removeFirst(removalCount)
        self.referenceStartTick =
            referenceStartTick + Int64(removalCount)
    }

    private static func tick(for time: TimeInterval) -> Int64 {
        Int64((time * sampleRate).rounded())
    }

    private static func normalizedCorrelation(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0
        var lhsEnergy: Double = 0
        var rhsEnergy: Double = 0
        for (left, right) in zip(lhs, rhs) {
            dot += Double(left * right)
            lhsEnergy += Double(left * left)
            rhsEnergy += Double(right * right)
        }
        let denominator = sqrt(lhsEnergy * rhsEnergy)
        guard denominator > 0.000_000_1 else { return 0 }
        return Float(dot / denominator)
    }

    private static func leastSquaresGain(
        input: [Float],
        reference: [Float]
    ) -> Float {
        var cross: Double = 0
        var referenceEnergy: Double = 0
        for (sample, referenceSample) in zip(input, reference) {
            cross += Double(sample * referenceSample)
            referenceEnergy += Double(referenceSample * referenceSample)
        }
        guard referenceEnergy > 0.000_000_1 else { return 0 }
        return max(-2, min(2, Float(cross / referenceEnergy)))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) {
            $0 + Double($1 * $1)
        }
        return Float(sqrt(energy / Double(samples.count)))
    }
}
