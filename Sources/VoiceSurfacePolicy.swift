import Foundation

enum VoiceSurfacePhase: String {
    case dormantWake
    case starting
    case listening
    case thinking
    case speaking
    case stopping
    case failed

    var isSessionActive: Bool {
        switch self {
        case .starting, .listening, .thinking, .speaking, .stopping:
            return true
        case .dormantWake, .failed:
            return false
        }
    }

    var blocksConversationCollapse: Bool {
        self == .speaking
    }

    var animatesNotchIndicator: Bool {
        switch self {
        case .starting, .listening, .thinking, .speaking:
            return true
        case .dormantWake, .stopping, .failed:
            return false
        }
    }

    var usesNotchActivityRing: Bool {
        self == .thinking || self == .speaking
    }
}

struct NotchPresentation: Equatable {
    let headerExpanded: Bool
    let answerExpanded: Bool
    let indicatorAnimated: Bool
    let indicatorUsesRing: Bool
    let showsActivityLabel: Bool
    let showsHoverVoiceAction: Bool

    static func resolve(
        phase: VoiceSurfacePhase,
        answerVisible: Bool,
        hovering: Bool = false
    ) -> NotchPresentation {
        let headerExpanded = answerVisible || hovering
        return NotchPresentation(
            headerExpanded: headerExpanded,
            answerExpanded: answerVisible,
            indicatorAnimated: phase.animatesNotchIndicator,
            indicatorUsesRing: phase.usesNotchActivityRing,
            showsActivityLabel: headerExpanded
                && (phase == .thinking || phase == .speaking),
            showsHoverVoiceAction: hovering && !answerVisible
        )
    }
}

enum NotchUnifiedSurfacePolicy {
    static let nativeGlassOpacity: CGFloat = 0.10
    static let nativeGlassTintAlpha: CGFloat = 0
    static let bottomCornerRadius: CGFloat = 24

    static let blackGradientLocations: [CGFloat] = [
        0,
        0.75,
        1,
    ]

    static let blackGradientAlphas: [CGFloat] = [
        1,
        1,
        0,
    ]

    static func cornerRadius(for _: CGSize) -> CGFloat {
        bottomCornerRadius
    }
}

enum NotchActionIconPolicy {
    static let whiteAlpha: CGFloat = 1
    static let shadowOpacity: Float = 0.90
    static let shadowRadius: CGFloat = 4
    static let shadowOffset = CGSize(width: 0, height: 0)
    static let symbolSize: CGFloat = 17
}

enum NotchAnswerLifecyclePolicy {
    static let minimumReplyRetention: TimeInterval = 4

    static func retentionDeadline(now: Date = Date()) -> Date {
        now.addingTimeInterval(minimumReplyRetention)
    }

    static func collapseDelay(
        requestedDelay: TimeInterval,
        now: Date = Date(),
        retainUntil: Date
    ) -> TimeInterval {
        max(requestedDelay, retainUntil.timeIntervalSince(now))
    }
}

struct StopAcknowledgementLifecycle {
    private(set) var generation: Int?
    private(set) var responseID = ""
    private(set) var retainUntil = Date.distantPast
    private var mirrored = false
    private var completionConsumed = false

    mutating func begin(generation: Int) {
        self.generation = generation
        responseID = ""
        retainUntil = .distantPast
        mirrored = false
        completionConsumed = false
    }

    mutating func mirror(
        generation: Int,
        responseID: String,
        text: String,
        now: Date = Date()
    ) -> String? {
        let normalizedID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard self.generation == generation,
              !normalizedID.isEmpty,
              !normalizedText.isEmpty,
              !mirrored,
              self.responseID.isEmpty || self.responseID == normalizedID else {
            return nil
        }
        self.responseID = normalizedID
        mirrored = true
        retainUntil = NotchAnswerLifecyclePolicy.retentionDeadline(now: now)
        return normalizedText
    }

    mutating func consumeDrain(
        generation: Int,
        responseID: String
    ) -> Bool {
        guard self.generation == generation,
              mirrored,
              !completionConsumed,
              !self.responseID.isEmpty,
              self.responseID == responseID else {
            return false
        }
        completionConsumed = true
        return true
    }

    func remainingRetention(
        generation: Int,
        now: Date = Date()
    ) -> TimeInterval {
        guard self.generation == generation, mirrored else { return 0 }
        return max(0, retainUntil.timeIntervalSince(now))
    }

    func isAwaitingAuthoritativeDrain(generation: Int) -> Bool {
        self.generation == generation && !completionConsumed
    }

    mutating func reset(generation: Int? = nil) {
        guard generation == nil || self.generation == generation else { return }
        self = StopAcknowledgementLifecycle()
    }
}

enum SurfaceMotionPolicy {
    static let maximumDuration: TimeInterval = 0.28

    static func animationProgress(
        elapsed: TimeInterval
    ) -> CGFloat {
        let linear = min(max(elapsed / maximumDuration, 0), 1)
        return CGFloat(1 - pow(1 - linear, 2))
    }

    static func interpolatedValue(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * min(max(progress, 0), 1)
    }
}

enum OrbAudioLevelPolicy {
    static func normalizedRMS(_ channels: [[Float]]) -> CGFloat {
        var sumOfSquares: Double = 0
        var sampleCount = 0
        for channel in channels {
            for sample in channel {
                let clamped = max(-1, min(1, sample))
                sumOfSquares += Double(clamped * clamped)
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let floorDB = -52.0
        let ceilingDB = -12.0
        let linear = min(
            1,
            max(0, (decibels - floorDB) / (ceilingDB - floorDB))
        )
        return CGFloat(pow(linear, 0.72))
    }

    static func smoothed(current: CGFloat, target: CGFloat) -> CGFloat {
        let response: CGFloat = target > current ? 0.60 : 0.18
        return current + (target - current) * response
    }

    static func scale(for level: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        return 1 + min(max(level, 0), 1) * 0.14
    }
}

struct OrbSpectralAccent {
    let hue: CGFloat
    let center: CGPoint
    let radius: CGFloat
}

enum VoiceOrbVisualPolicy {
    static let lightPoint = CGPoint(x: 0.36, y: 0.74)
    static let nativeGlassOpacity: CGFloat = 0.08
    static let fallbackMaterialOpacity: CGFloat = 0.06
    static let spectralSaturation: CGFloat = 0.98
    static let spectralCenterAlpha: CGFloat = 0.88
    static let spectralSecondaryAlpha: CGFloat = 0.24
    static let edgeVignetteAlpha: CGFloat = 0.36
    static let idleFlowOpacity: CGFloat = 0.34
    static let activeFlowOpacity: CGFloat = 0.50
    static let maximumFlowOpacity: CGFloat = 0.88
    static let flowRotationDuration: TimeInterval = 16
    static let flowDriftDurations: [TimeInterval] = [6.8, 8.6, 10.4]
    static let spectralAccents: [OrbSpectralAccent] = [
        OrbSpectralAccent(
            hue: 0.98,
            center: CGPoint(x: 0.18, y: 0.66),
            radius: 0.48
        ),
        OrbSpectralAccent(
            hue: 0.08,
            center: CGPoint(x: 0.34, y: 0.84),
            radius: 0.43
        ),
        OrbSpectralAccent(
            hue: 0.16,
            center: CGPoint(x: 0.72, y: 0.80),
            radius: 0.41
        ),
        OrbSpectralAccent(
            hue: 0.35,
            center: CGPoint(x: 0.84, y: 0.56),
            radius: 0.47
        ),
        OrbSpectralAccent(
            hue: 0.52,
            center: CGPoint(x: 0.72, y: 0.24),
            radius: 0.50
        ),
        OrbSpectralAccent(
            hue: 0.65,
            center: CGPoint(x: 0.40, y: 0.16),
            radius: 0.47
        ),
        OrbSpectralAccent(
            hue: 0.84,
            center: CGPoint(x: 0.14, y: 0.34),
            radius: 0.46
        ),
    ]
}

enum OrbReplyDirection: CaseIterable, Hashable {
    case upperLeft
    case upperCenter
    case upperRight
    case lowerRight
    case lowerCenter
    case lowerLeft
}

struct OrbReplyLayout {
    let direction: OrbReplyDirection
    let frame: CGRect
}

struct OrbReplyAppearance: Equatable {
    let glassOpacity: CGFloat
    let tintWhite: CGFloat
    let tintAlpha: CGFloat
    let fallbackWhite: CGFloat
    let fallbackAlpha: CGFloat
    let textWhite: CGFloat
    let textAlpha: CGFloat
    let borderWhite: CGFloat
    let borderAlpha: CGFloat
}

enum OrbReplyAppearancePolicy {
    static func resolve(
        isDark: Bool,
        reduceTransparency: Bool = false
    ) -> OrbReplyAppearance {
        if isDark {
            return OrbReplyAppearance(
                glassOpacity: 0.42,
                tintWhite: 0,
                tintAlpha: 0.16,
                fallbackWhite: 0.055,
                fallbackAlpha: reduceTransparency ? 0.96 : 0.22,
                textWhite: 1,
                textAlpha: 0.94,
                borderWhite: 1,
                borderAlpha: 0.30
            )
        }
        return OrbReplyAppearance(
            glassOpacity: 0.68,
            tintWhite: 1,
            tintAlpha: 0.40,
            fallbackWhite: 0.98,
            fallbackAlpha: reduceTransparency ? 0.96 : 0.52,
            textWhite: 0.04,
            textAlpha: 0.92,
            borderWhite: 0,
            borderAlpha: 0.26
        )
    }
}

enum OrbReplyPlacementPolicy {
    static let gap: CGFloat = 12
    static let screenInset: CGFloat = 8
    static let minimumWidth: CGFloat = 260
    static let maximumWidth: CGFloat = 380
    static let minimumHeight: CGFloat = 88
    static let maximumHeight: CGFloat = 280
    static let cornerRadius: CGFloat = 20

    static func direction(
        orbFrame: CGRect,
        visibleFrame: CGRect
    ) -> OrbReplyDirection {
        let horizontalPosition = (
            orbFrame.midX - visibleFrame.minX
        ) / max(visibleFrame.width, 1)
        let orbIsUpper = orbFrame.midY >= visibleFrame.midY
        if horizontalPosition < 1.0 / 3.0 {
            return orbIsUpper ? .lowerRight : .upperRight
        }
        if horizontalPosition > 2.0 / 3.0 {
            return orbIsUpper ? .lowerLeft : .upperLeft
        }
        return orbIsUpper ? .lowerCenter : .upperCenter
    }

    static func layout(
        orbFrame: CGRect,
        requestedSize: CGSize,
        visibleFrame: CGRect
    ) -> OrbReplyLayout {
        let direction = direction(
            orbFrame: orbFrame,
            visibleFrame: visibleFrame
        )
        let availableWidth = max(
            1,
            visibleFrame.width - screenInset * 2
        )
        let availableHeight = max(
            1,
            visibleFrame.height - screenInset * 2
        )
        let size = CGSize(
            width: min(
                availableWidth,
                min(max(requestedSize.width, minimumWidth), maximumWidth)
            ),
            height: min(
                availableHeight,
                min(max(requestedSize.height, minimumHeight), maximumHeight)
            )
        )
        let x: CGFloat
        let y: CGFloat
        switch direction {
        case .upperLeft:
            x = orbFrame.maxX - size.width
            y = orbFrame.maxY + gap
        case .upperCenter:
            x = orbFrame.midX - size.width / 2
            y = orbFrame.maxY + gap
        case .upperRight:
            x = orbFrame.minX
            y = orbFrame.maxY + gap
        case .lowerRight:
            x = orbFrame.minX
            y = orbFrame.minY - gap - size.height
        case .lowerCenter:
            x = orbFrame.midX - size.width / 2
            y = orbFrame.minY - gap - size.height
        case .lowerLeft:
            x = orbFrame.maxX - size.width
            y = orbFrame.minY - gap - size.height
        }
        let insetFrame = visibleFrame.insetBy(
            dx: screenInset,
            dy: screenInset
        )
        let clampedX = min(
            max(x, insetFrame.minX),
            max(insetFrame.minX, insetFrame.maxX - size.width)
        )
        let clampedY = min(
            max(y, insetFrame.minY),
            max(insetFrame.minY, insetFrame.maxY - size.height)
        )
        return OrbReplyLayout(
            direction: direction,
            frame: CGRect(
                origin: CGPoint(x: clampedX, y: clampedY),
                size: size
            )
        )
    }
}

enum WakeRecognitionBackendPolicy {
    static func usesModernAnalyzer(
        preferenceEnabled: Bool,
        platformSupportsAnalyzer: Bool,
        requestedLocaleCount: Int,
        availableLocaleCount: Int
    ) -> Bool {
        preferenceEnabled
            && platformSupportsAnalyzer
            && requestedLocaleCount > 0
            && availableLocaleCount == requestedLocaleCount
    }
}

enum RealtimeHostEventPolicy {
    static func shouldAccept(
        type: String,
        generation: Int?,
        activeGeneration: Int?,
        stoppingGenerations: Set<Int>
    ) -> Bool {
        guard let generation else { return false }
        if type == "error", stoppingGenerations.contains(generation) {
            return false
        }
        if type == "terminal" {
            return generation == activeGeneration
                || stoppingGenerations.contains(generation)
        }
        return generation == activeGeneration
    }
}

struct RealtimeStartupRetryState {
    static let retryDelay: TimeInterval = 0.35

    private let maximumTransportAttempts: Int
    private(set) var generation: Int?
    private(set) var transportAttempts = 0
    private(set) var listeningReady = false
    private(set) var retryReserved = false

    init(maximumTransportAttempts: Int = 3) {
        self.maximumTransportAttempts = max(1, maximumTransportAttempts)
    }

    mutating func begin(generation: Int) {
        self.generation = generation
        transportAttempts = 0
        listeningReady = false
        retryReserved = false
    }

    mutating func registerTransportAttempt(
        generation: Int,
        isRetry: Bool
    ) -> Bool {
        guard self.generation == generation,
              !listeningReady,
              transportAttempts < maximumTransportAttempts else {
            return false
        }
        if isRetry {
            guard retryReserved else { return false }
        } else {
            guard transportAttempts == 0, !retryReserved else { return false }
        }
        retryReserved = false
        transportAttempts += 1
        return true
    }

    mutating func reserveRetry(generation: Int) -> Bool {
        guard self.generation == generation,
              !listeningReady,
              !retryReserved,
              transportAttempts > 0,
              transportAttempts < maximumTransportAttempts else {
            return false
        }
        retryReserved = true
        return true
    }

    func hasReservedRetry(generation: Int) -> Bool {
        self.generation == generation && retryReserved && !listeningReady
    }

    mutating func markListeningReady(generation: Int) -> Bool {
        guard self.generation == generation,
              transportAttempts > 0 else {
            return false
        }
        listeningReady = true
        retryReserved = false
        return true
    }

    mutating func cancel(generation: Int? = nil) {
        guard generation == nil || self.generation == generation else { return }
        self.generation = nil
        transportAttempts = 0
        listeningReady = false
        retryReserved = false
    }
}

struct AudioStartCancellationState {
    private(set) var cancelledGenerations = Set<Int>()

    mutating func requestStart(generation: Int) {
        cancelledGenerations.remove(generation)
        prune(around: generation)
    }

    mutating func requestStop(generation: Int) {
        cancelledGenerations.insert(generation)
        prune(around: generation)
    }

    func isCancelled(generation: Int) -> Bool {
        cancelledGenerations.contains(generation)
    }

    private mutating func prune(around generation: Int) {
        cancelledGenerations = Set(
            cancelledGenerations.filter { $0 >= generation - 16 }
        )
    }
}

struct ExternalAudioPlaybackSnapshot: Equatable {
    let processLabels: Set<String>
    let isAvailable: Bool

    init(
        processLabels: Set<String>,
        isAvailable: Bool = true
    ) {
        self.processLabels = processLabels
        self.isAvailable = isAvailable
    }

    var isPlaying: Bool {
        isAvailable && !processLabels.isEmpty
    }

    func sharesOutputProcess(with other: Self) -> Bool {
        !processLabels.isDisjoint(with: other.processLabels)
    }
}

enum AssistantPlaybackOverlapDecision: Equatable {
    case none
    case pause
    case resume
}

struct AssistantPlaybackOverlapPolicy {
    private(set) var isPaused = false
    private var continuouslyActiveBaseline = Set<String>()
    private var interferingProcesses = Set<String>()
    private var consecutiveClearSamples = 0

    mutating func begin(
        with snapshot: ExternalAudioPlaybackSnapshot
    ) {
        isPaused = false
        continuouslyActiveBaseline = snapshot.isAvailable
            ? snapshot.processLabels
            : []
        interferingProcesses.removeAll()
        consecutiveClearSamples = 0
    }

    mutating func observe(
        _ snapshot: ExternalAudioPlaybackSnapshot,
        clearSamplesRequired: Int = 2
    ) -> AssistantPlaybackOverlapDecision {
        guard snapshot.isAvailable else {
            guard isPaused else { return .none }
            reset()
            return .resume
        }
        continuouslyActiveBaseline.formIntersection(
            snapshot.processLabels
        )
        let newlyActive = snapshot.processLabels.subtracting(
            continuouslyActiveBaseline
        )
        if !newlyActive.isEmpty {
            interferingProcesses.formUnion(newlyActive)
            consecutiveClearSamples = 0
            if !isPaused {
                isPaused = true
                return .pause
            }
            return .none
        }
        guard isPaused else { return .none }
        interferingProcesses.formIntersection(snapshot.processLabels)
        guard interferingProcesses.isEmpty else {
            consecutiveClearSamples = 0
            return .none
        }
        consecutiveClearSamples += 1
        guard consecutiveClearSamples >= max(1, clearSamplesRequired) else {
            return .none
        }
        isPaused = false
        continuouslyActiveBaseline = snapshot.processLabels
        consecutiveClearSamples = 0
        return .resume
    }

    mutating func reset() {
        isPaused = false
        continuouslyActiveBaseline.removeAll()
        interferingProcesses.removeAll()
        consecutiveClearSamples = 0
    }
}

enum ConversationSpeaker: Equatable {
    case user
    case assistant
}

enum ConversationDeliveryState: String, Equatable {
    case pending
    case applied
    case failed
    case expired
    case superseded

    var isTerminal: Bool { self != .pending }
}

struct ConversationEntry: Equatable {
    let speaker: ConversationSpeaker
    var text: String
    let deliveryID: String?
    var deliveryState: ConversationDeliveryState?

    init(
        speaker: ConversationSpeaker,
        text: String,
        deliveryID: String? = nil,
        deliveryState: ConversationDeliveryState? = nil
    ) {
        self.speaker = speaker
        self.text = text
        self.deliveryID = deliveryID
        self.deliveryState = deliveryState
    }
}

struct ConversationTranscriptState {
    private(set) var history: [ConversationEntry] = []
    private(set) var draft: ConversationEntry?
    private var finalizedDeliveryIDs = Set<String>()
    private var finalizedDeliveryOrder: [String] = []
    private let maximumRememberedDeliveryIDs = 64

    mutating func updateDraft(
        speaker: ConversationSpeaker,
        text: String,
        limit: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearDraft(speaker: speaker)
            return
        }
        if draft?.speaker == speaker {
            draft?.text = trimmed
            return
        }
        sealDraft(limit: limit)
        draft = ConversationEntry(speaker: speaker, text: trimmed)
    }

    mutating func finalize(
        speaker: ConversationSpeaker,
        text: String,
        deliveryID: String? = nil,
        deliveryState: ConversationDeliveryState? = nil,
        limit: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedDeliveryID = deliveryID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedDeliveryID.isEmpty,
           finalizedDeliveryIDs.contains(normalizedDeliveryID) {
            return
        }
        let finalizedEntry = ConversationEntry(
            speaker: speaker,
            text: trimmed,
            deliveryID: normalizedDeliveryID.isEmpty
                ? nil
                : normalizedDeliveryID,
            deliveryState: deliveryState
        )
        if draft?.speaker == speaker {
            draft = nil
        } else {
            sealDraft(limit: limit)
        }
        append(finalizedEntry, limit: limit)
        rememberFinalizedDeliveryID(normalizedDeliveryID)
    }

    @discardableResult
    mutating func transitionDeliveryState(
        deliveryID: String,
        to nextState: ConversationDeliveryState
    ) -> Bool {
        let normalizedDeliveryID = deliveryID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDeliveryID.isEmpty,
              let index = history.lastIndex(where: {
                  $0.deliveryID == normalizedDeliveryID
              }) else {
            return false
        }
        let currentState = history[index].deliveryState
        guard currentState != nextState,
              currentState == nil || currentState == .pending,
              currentState?.isTerminal != true else {
            return false
        }
        history[index].deliveryState = nextState
        return true
    }

    mutating func sealDraftAtSessionBoundary(limit: Int) {
        sealDraft(limit: limit)
    }

    mutating func clearDraft(speaker: ConversationSpeaker) {
        guard draft?.speaker == speaker else { return }
        draft = nil
    }

    mutating func clearAllDrafts() {
        draft = nil
    }

    private mutating func sealDraft(limit: Int) {
        guard let draft else { return }
        self.draft = nil
        append(draft, limit: limit)
    }

    private mutating func append(
        _ entry: ConversationEntry,
        limit: Int
    ) {
        history.append(entry)
        let boundedLimit = max(1, limit)
        if history.count > boundedLimit {
            history.removeFirst(history.count - boundedLimit)
        }
    }

    private mutating func rememberFinalizedDeliveryID(_ deliveryID: String) {
        guard !deliveryID.isEmpty,
              finalizedDeliveryIDs.insert(deliveryID).inserted else {
            return
        }
        finalizedDeliveryOrder.append(deliveryID)
        if finalizedDeliveryOrder.count > maximumRememberedDeliveryIDs {
            let removalCount =
                finalizedDeliveryOrder.count - maximumRememberedDeliveryIDs
            let removed = Array(
                finalizedDeliveryOrder.prefix(removalCount)
            )
            finalizedDeliveryOrder.removeFirst(removalCount)
            finalizedDeliveryIDs.subtract(removed)
        }
    }
}

struct WakeAnalyzerCircuitBreaker {
    static let baseCooldown: TimeInterval = 15
    static let maximumCooldown: TimeInterval = 120

    private(set) var isOpen = false
    private(set) var failureStage = ""
    private(set) var failureCount = 0
    private(set) var retryNotBefore: TimeInterval = 0

    @discardableResult
    mutating func open(
        stage: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let changed = !isOpen
        isOpen = true
        failureCount += 1
        if failureStage.isEmpty {
            failureStage = stage
        }
        let exponent = min(max(0, failureCount - 1), 3)
        let cooldown = min(
            Self.maximumCooldown,
            Self.baseCooldown * pow(2, Double(exponent))
        )
        retryNotBefore = now + cooldown
        return changed
    }

    func blocksAttempt(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        isOpen && now < retryNotBefore
    }

    func remainingCooldown(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard isOpen else { return nil }
        return max(0, retryNotBefore - now)
    }

    @discardableResult
    mutating func close() -> Bool {
        let changed = isOpen
        isOpen = false
        failureStage = ""
        failureCount = 0
        retryNotBefore = 0
        return changed
    }
}

struct ExternalAudioOutputConfirmation {
    static let sustainedSampleRequirement = 6
    private(set) var consecutiveSamples = 0
    private var previous = ExternalAudioPlaybackSnapshot(processLabels: [])

    mutating func observe(
        _ snapshot: ExternalAudioPlaybackSnapshot,
        requiredSamples: Int = Self.sustainedSampleRequirement
    ) -> Bool {
        guard snapshot.isAvailable else {
            return false
        }
        guard snapshot.isPlaying else {
            reset()
            return false
        }
        consecutiveSamples = previous.sharesOutputProcess(with: snapshot)
            ? consecutiveSamples + 1
            : 1
        previous = snapshot
        return consecutiveSamples >= max(1, requiredSamples)
    }

    mutating func reset() {
        consecutiveSamples = 0
        previous = ExternalAudioPlaybackSnapshot(processLabels: [])
    }
}

enum WakeCaptureAdmissionDecision: Equatable {
    case start
}

struct WakeCaptureAdmission {
    private(set) var mediaLatched = false
    private(set) var stableIdleSamples = 0

    mutating func observe(
        _ snapshot: ExternalAudioPlaybackSnapshot,
        requiredIdleSamples _: Int = 1,
        now _: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> WakeCaptureAdmissionDecision {
        _ = snapshot
        mediaLatched = false
        stableIdleSamples = 0
        return .start
    }
}

enum ExternalMediaTurnBoundaryPolicy {
    static func beginsNewUserTurn(
        userActivityObserved: Bool,
        assistantFinalObserved: Bool,
        finalPlaybackDrained: Bool,
        mediaConfirmed: Bool,
        assistantOutputActive: Bool
    ) -> Bool {
        !userActivityObserved
            || assistantFinalObserved
            || finalPlaybackDrained
            || mediaConfirmed
            || assistantOutputActive
    }
}

enum RealtimePlaybackLeaseTerminalReason: String, Equatable {
    case callback
    case watchdog
    case interrupted
    case cancelled
    case transportFailure = "transport_failure"
}

struct RealtimePlaybackLeaseTicket: Equatable, Hashable {
    let generation: Int
    let playbackEpoch: Int
    let ticketID: UInt64
    let responseID: String
    let frameCount: Int
    let expectedEnd: TimeInterval
    let hardDeadline: TimeInterval
}

struct RealtimePlaybackLeaseTerminalization: Equatable {
    let generation: Int
    let responseID: String
    let reason: RealtimePlaybackLeaseTerminalReason
    let releasedBufferCount: Int
    let releasedFrameCount: Int
}

enum RealtimePlaybackLeaseReconciliation: Equatable {
    case pending
    case rearm(deadline: TimeInterval)
    case completed(RealtimePlaybackLeaseTerminalization?)
    case ignored

    var terminalization: RealtimePlaybackLeaseTerminalization? {
        guard case let .completed(terminalization) = self else {
            return nil
        }
        return terminalization
    }

    var consumedTicket: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

struct RealtimePlaybackLeaseReconciler {
    static let sampleRate = 24_000.0
    static let watchdogGrace: TimeInterval = 0.35
    static let watchdogHardGrace: TimeInterval = 2.0
    static let pausedPollInterval: TimeInterval = 0.25

    private struct ResponseLease {
        var tickets: [UInt64: RealtimePlaybackLeaseTicket] = [:]
        var serverCompleted = false
        var usedWatchdog = false
    }

    private(set) var generation = 0
    private(set) var playbackEpoch = 0
    private(set) var pendingBufferCount = 0
    private(set) var queuedFrameCount = 0
    private var nextTicketID: UInt64 = 0
    private var estimatedPlayerQueueTail: TimeInterval = 0
    private var leasesByResponseID: [String: ResponseLease] = [:]
    private var responseIDByTicketID: [UInt64: String] = [:]
    private var terminalizedResponseIDs = Set<String>()

    mutating func reset(generation: Int, playbackEpoch: Int) {
        self.generation = generation
        self.playbackEpoch = playbackEpoch
        pendingBufferCount = 0
        queuedFrameCount = 0
        nextTicketID = 0
        estimatedPlayerQueueTail = 0
        leasesByResponseID.removeAll()
        responseIDByTicketID.removeAll()
        terminalizedResponseIDs.removeAll()
    }

    mutating func admit(
        generation: Int,
        playbackEpoch: Int,
        responseID: String,
        frameCount: Int,
        now: TimeInterval
    ) -> RealtimePlaybackLeaseTicket? {
        let normalizedResponseID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard generation == self.generation,
              playbackEpoch == self.playbackEpoch,
              !normalizedResponseID.isEmpty,
              frameCount > 0,
              !terminalizedResponseIDs.contains(normalizedResponseID) else {
            return nil
        }
        nextTicketID &+= 1
        let scheduledStart = max(now, estimatedPlayerQueueTail)
        let expectedEnd = scheduledStart
            + TimeInterval(frameCount) / Self.sampleRate
        estimatedPlayerQueueTail = expectedEnd
        let ticket = RealtimePlaybackLeaseTicket(
            generation: generation,
            playbackEpoch: playbackEpoch,
            ticketID: nextTicketID,
            responseID: normalizedResponseID,
            frameCount: frameCount,
            expectedEnd: expectedEnd + Self.watchdogGrace,
            hardDeadline: expectedEnd + Self.watchdogHardGrace
        )
        var lease = leasesByResponseID[normalizedResponseID]
            ?? ResponseLease()
        lease.tickets[ticket.ticketID] = ticket
        leasesByResponseID[normalizedResponseID] = lease
        responseIDByTicketID[ticket.ticketID] = normalizedResponseID
        pendingBufferCount += 1
        queuedFrameCount += frameCount
        return ticket
    }

    mutating func markResponseCompleted(
        generation: Int,
        responseID: String
    ) -> RealtimePlaybackLeaseTerminalization? {
        guard generation == self.generation,
              !terminalizedResponseIDs.contains(responseID),
              var lease = leasesByResponseID[responseID] else {
            return nil
        }
        lease.serverCompleted = true
        leasesByResponseID[responseID] = lease
        guard lease.tickets.isEmpty else { return nil }
        return terminalizeResponse(
            responseID: responseID,
            reason: lease.usedWatchdog ? .watchdog : .callback
        )
    }

    mutating func complete(
        _ ticket: RealtimePlaybackLeaseTicket,
        reason: RealtimePlaybackLeaseTerminalReason
    ) -> RealtimePlaybackLeaseTerminalization? {
        completeResult(ticket, reason: reason).terminalization
    }

    mutating func completeResult(
        _ ticket: RealtimePlaybackLeaseTicket,
        reason: RealtimePlaybackLeaseTerminalReason
    ) -> RealtimePlaybackLeaseReconciliation {
        guard owns(ticket),
              var lease = leasesByResponseID[ticket.responseID],
              lease.tickets.removeValue(forKey: ticket.ticketID) != nil else {
            return .ignored
        }
        responseIDByTicketID.removeValue(forKey: ticket.ticketID)
        pendingBufferCount = max(0, pendingBufferCount - 1)
        queuedFrameCount = max(0, queuedFrameCount - ticket.frameCount)
        if reason == .watchdog {
            lease.usedWatchdog = true
        }
        leasesByResponseID[ticket.responseID] = lease
        guard lease.serverCompleted, lease.tickets.isEmpty else {
            return .completed(nil)
        }
        return .completed(
            terminalizeResponse(
                responseID: ticket.responseID,
                reason: lease.usedWatchdog ? .watchdog : reason
            )
        )
    }

    mutating func reconcile(
        _ ticket: RealtimePlaybackLeaseTicket,
        now: TimeInterval,
        playerIsPlaying: Bool,
        renderedThroughTicket: Bool,
        intentionallyPaused: Bool
    ) -> RealtimePlaybackLeaseReconciliation {
        guard owns(ticket),
              let currentTicket = leasesByResponseID[ticket.responseID]?
                .tickets[ticket.ticketID] else {
            return .ignored
        }
        guard now >= currentTicket.expectedEnd else { return .pending }
        if intentionallyPaused {
            let extensionDuration = max(
                Self.pausedPollInterval,
                now - currentTicket.expectedEnd + Self.pausedPollInterval
            )
            guard shiftTicketDeadlines(
                currentTicket,
                by: extensionDuration
            ) != nil else {
                return .ignored
            }
            return .rearm(deadline: now + Self.pausedPollInterval)
        }
        guard !playerIsPlaying
                || renderedThroughTicket
                || now >= currentTicket.hardDeadline else {
            return .rearm(deadline: currentTicket.hardDeadline)
        }
        return completeResult(currentTicket, reason: .watchdog)
    }

    mutating func cancelAll(
        generation: Int,
        playbackEpoch: Int,
        reason: RealtimePlaybackLeaseTerminalReason
    ) -> [RealtimePlaybackLeaseTerminalization] {
        guard generation == self.generation,
              playbackEpoch == self.playbackEpoch else {
            return []
        }
        return leasesByResponseID.keys.sorted().compactMap { responseID in
            terminalizeResponse(responseID: responseID, reason: reason)
        }
    }

    private func owns(_ ticket: RealtimePlaybackLeaseTicket) -> Bool {
        ticket.generation == generation
            && ticket.playbackEpoch == playbackEpoch
            && responseIDByTicketID[ticket.ticketID] == ticket.responseID
            && !terminalizedResponseIDs.contains(ticket.responseID)
    }

    @discardableResult
    private mutating func shiftTicketDeadlines(
        _ ticket: RealtimePlaybackLeaseTicket,
        by duration: TimeInterval
    ) -> RealtimePlaybackLeaseTicket? {
        guard var lease = leasesByResponseID[ticket.responseID],
              lease.tickets[ticket.ticketID] == ticket else {
            return nil
        }
        let shifted = RealtimePlaybackLeaseTicket(
            generation: ticket.generation,
            playbackEpoch: ticket.playbackEpoch,
            ticketID: ticket.ticketID,
            responseID: ticket.responseID,
            frameCount: ticket.frameCount,
            expectedEnd: ticket.expectedEnd + duration,
            hardDeadline: ticket.hardDeadline + duration
        )
        lease.tickets[ticket.ticketID] = shifted
        leasesByResponseID[ticket.responseID] = lease
        return shifted
    }

    private mutating func terminalizeResponse(
        responseID: String,
        reason: RealtimePlaybackLeaseTerminalReason
    ) -> RealtimePlaybackLeaseTerminalization? {
        guard terminalizedResponseIDs.insert(responseID).inserted,
              let lease = leasesByResponseID.removeValue(forKey: responseID) else {
            return nil
        }
        let releasedTickets = Array(lease.tickets.values)
        for ticket in releasedTickets {
            responseIDByTicketID.removeValue(forKey: ticket.ticketID)
        }
        let releasedFrames = releasedTickets.reduce(0) {
            $0 + $1.frameCount
        }
        pendingBufferCount = max(
            0,
            pendingBufferCount - releasedTickets.count
        )
        queuedFrameCount = max(0, queuedFrameCount - releasedFrames)
        return RealtimePlaybackLeaseTerminalization(
            generation: generation,
            responseID: responseID,
            reason: reason,
            releasedBufferCount: releasedTickets.count,
            releasedFrameCount: releasedFrames
        )
    }
}

struct AssistantOutputLifecycle {
    private(set) var generation = 0
    private(set) var pendingNativeResponseIDs = Set<String>()
    private(set) var pendingLocalSpeechCount = 0
    private(set) var realtimeQueueLeaseActive = false

    var isActive: Bool {
        !pendingNativeResponseIDs.isEmpty
            || pendingLocalSpeechCount > 0
            || realtimeQueueLeaseActive
    }

    mutating func reset(generation: Int) {
        self.generation = generation
        pendingNativeResponseIDs.removeAll()
        pendingLocalSpeechCount = 0
        realtimeQueueLeaseActive = false
    }

    @discardableResult
    mutating func registerNativeFinal(
        generation: Int,
        responseID: String
    ) -> Bool {
        guard generation == self.generation else { return false }
        let trimmed = responseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pendingNativeResponseIDs.insert(trimmed)
        return true
    }

    @discardableResult
    mutating func finishNativePlayback(
        generation: Int,
        responseID: String
    ) -> Bool {
        guard generation == self.generation,
              pendingNativeResponseIDs.remove(responseID) != nil else {
            return false
        }
        return !isActive
    }

    mutating func beginLocalSpeech(generation: Int) {
        guard generation == self.generation else { return }
        pendingLocalSpeechCount += 1
    }

    @discardableResult
    mutating func finishLocalSpeech(generation: Int) -> Bool {
        guard generation == self.generation,
              pendingLocalSpeechCount > 0 else {
            return false
        }
        pendingLocalSpeechCount -= 1
        return !isActive
    }

    @discardableResult
    mutating func setRealtimeQueueLease(
        generation: Int,
        active: Bool
    ) -> Bool {
        guard generation == self.generation else { return false }
        realtimeQueueLeaseActive = active
        return !isActive
    }

    mutating func cancelAll(generation: Int) {
        guard generation == self.generation else { return }
        pendingNativeResponseIDs.removeAll()
        pendingLocalSpeechCount = 0
        realtimeQueueLeaseActive = false
    }
}

enum VoiceIdleTimeoutPolicy {
    static func shouldArm(
        phase: VoiceSurfacePhase,
        activeCodex: Bool,
        assistantOutputActive: Bool
    ) -> Bool {
        phase == .listening
            && !activeCodex
            && !assistantOutputActive
    }
}

enum WakeMonitoringResumePolicy {
    static let activationDelay: TimeInterval = 0.35

    static func shouldStart(
        voiceSessionActive: Bool,
        externalAudioPlaying _: Bool,
        assistantOutputActive: Bool
    ) -> Bool {
        !voiceSessionActive
            && !assistantOutputActive
    }
}

struct CodexRequestLease: Equatable {
    let generation: Int
    let requestID: String
    fileprivate let sequence: UInt64
}

struct CodexRequestLeaseState {
    private(set) var active: CodexRequestLease?
    private var nextSequence: UInt64 = 0

    @discardableResult
    mutating func begin(
        generation: Int,
        requestID: String
    ) -> CodexRequestLease {
        nextSequence &+= 1
        let lease = CodexRequestLease(
            generation: generation,
            requestID: requestID,
            sequence: nextSequence
        )
        active = lease
        return lease
    }

    func matches(_ lease: CodexRequestLease) -> Bool {
        active == lease
    }

    @discardableResult
    mutating func cancel(
        generation: Int,
        requestID: String
    ) -> CodexRequestLease? {
        guard let active,
              active.generation == generation,
              active.requestID == requestID else {
            return nil
        }
        self.active = nil
        return active
    }

    @discardableResult
    mutating func complete(_ lease: CodexRequestLease) -> Bool {
        guard matches(lease) else { return false }
        active = nil
        return true
    }
}

struct ExpandedVoiceControlsState: Equatable {
    let transportEnabled: Bool
    let transportSymbolName: String
    let microphoneSymbolName: String
}

enum ExpandedVoiceControlsPolicy {
    static func resolve(
        voiceSessionActive: Bool,
        microphoneInputEnabled: Bool
    ) -> ExpandedVoiceControlsState {
        ExpandedVoiceControlsState(
            transportEnabled: voiceSessionActive || microphoneInputEnabled,
            transportSymbolName: voiceSessionActive
                ? "stop.fill"
                : "play.fill",
            microphoneSymbolName: microphoneInputEnabled
                ? "mic.fill"
                : "mic.slash.fill"
        )
    }
}

struct MicrophoneInputTransition: Equatable {
    let targetEnabled: Bool
    let shouldPauseWakeMonitoring: Bool
    let shouldResumeWakeMonitoring: Bool
    let preservesVoiceSession: Bool
    let preservesPlayback: Bool
    let preservesCodexWork: Bool
}

enum MicrophoneInputControlPolicy {
    static func transition(
        from enabled: Bool,
        voiceSessionActive: Bool
    ) -> MicrophoneInputTransition {
        let targetEnabled = !enabled
        return MicrophoneInputTransition(
            targetEnabled: targetEnabled,
            shouldPauseWakeMonitoring: !targetEnabled,
            shouldResumeWakeMonitoring:
                targetEnabled && !voiceSessionActive,
            preservesVoiceSession: true,
            preservesPlayback: true,
            preservesCodexWork: true
        )
    }
}

struct CodexProfileSelectionResolution: Equatable {
    let resolvedModelID: String
    let serviceTierSelection: CodexServiceTierSelection
    let inheritedServiceTierIsPriority: Bool
    let isServiceTierResolved: Bool
    let isModelSupported: Bool
    let isReasoningEffortSupported: Bool
    let isFastModeSupported: Bool

    var isSupported: Bool {
        isModelSupported
            && isReasoningEffortSupported
            && isServiceTierResolved
            && isFastModeSupported
    }

    var serviceTier: String? {
        isServiceTierResolved
            && isFastModeSupported
            && (
                serviceTierSelection == .priority
                    || (
                        serviceTierSelection == .inherit
                            && inheritedServiceTierIsPriority
                    )
            )
            ? "priority"
            : nil
    }
}

enum CodexProfileSelectionPolicy {
    static func resolve(
        model: String,
        reasoningEffort: String,
        serviceTierSelection: CodexServiceTierSelection,
        effectiveModel: String,
        effectiveServiceTier: String,
        capabilities: [CodexModelCapability]
    ) -> CodexProfileSelectionResolution {
        let requestedModel = model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolvedModelID = requestedModel == "inherit"
            ? effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : requestedModel
        let capability = capabilities.first { $0.id == resolvedModelID }
        let isModelSupported = capability != nil
        let isReasoningEffortSupported = reasoningEffort == "inherit"
            || capability?.supportedReasoningEfforts.contains(
                reasoningEffort
            ) == true
        let normalizedEffectiveServiceTier = effectiveServiceTier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let inheritedServiceTierIsPriority =
            normalizedEffectiveServiceTier == "priority"
        let isInheritedServiceTierKnown = [
            "default",
            "priority",
            "standard",
        ].contains(normalizedEffectiveServiceTier)
        let isServiceTierResolved = serviceTierSelection != .inherit
            || isInheritedServiceTierKnown
        let requiresPriorityCapability = serviceTierSelection == .priority
            || (
                serviceTierSelection == .inherit
                    && inheritedServiceTierIsPriority
            )
        let isFastModeSupported = !requiresPriorityCapability
            || capability?.serviceTierIDs.contains("priority") == true
        return CodexProfileSelectionResolution(
            resolvedModelID: resolvedModelID,
            serviceTierSelection: serviceTierSelection,
            inheritedServiceTierIsPriority:
                inheritedServiceTierIsPriority,
            isServiceTierResolved: isServiceTierResolved,
            isModelSupported: isModelSupported,
            isReasoningEffortSupported: isReasoningEffortSupported,
            isFastModeSupported: isFastModeSupported
        )
    }
}

enum SettingsSaveImpactPolicy {
    static func requiresOverlayRebuild(
        previous: AppSettings,
        updated: AppSettings
    ) -> Bool {
        var normalizedPrevious = previous
        normalizedPrevious.codexModel = updated.codexModel
        normalizedPrevious.codexReasoningEffort =
            updated.codexReasoningEffort
        normalizedPrevious.codexServiceTierSelection =
            updated.codexServiceTierSelection
        return normalizedPrevious != updated
    }
}

enum WakeAudioHandoffPolicy {
    static let retiredEngineReleaseDelay: TimeInterval = 0.08
    static let postReleaseSettleDelay: TimeInterval = 0.18
}

enum RealtimePlaybackActivityPolicy {
    static func isActive(
        scheduledPlaybackBuffers: Int,
        playbackProvisionallyPaused: Bool
    ) -> Bool {
        scheduledPlaybackBuffers > 0 || playbackProvisionallyPaused
    }
}

enum WakeAnalyzerStartStage: String {
    case assetReservation = "asset-reservation"
    case analysisContext = "analysis-context"
    case analyzerPrepare = "analyzer-prepare"
    case audioEngineStart = "audio-engine-start"
}

enum WakeAnalyzerRetryPolicy {
    static let retryDelay: TimeInterval = 1.2

    static func shouldRetry(
        stage: WakeAnalyzerStartStage,
        priorAttempts: Int
    ) -> Bool {
        stage == .audioEngineStart && priorAttempts < 1
    }
}

struct VoiceSurfaceReducer {
    private(set) var generation = 0
    private(set) var phase: VoiceSurfacePhase = .dormantWake

    mutating func begin() -> Int {
        guard !phase.isSessionActive else { return generation }
        generation += 1
        phase = .starting
        return generation
    }

    @discardableResult
    mutating func apply(
        generation incomingGeneration: Int,
        phase incomingPhase: VoiceSurfacePhase
    ) -> Bool {
        guard incomingGeneration == generation,
              phase != .stopping,
              incomingPhase != phase else {
            return false
        }
        phase = incomingPhase
        return true
    }

    mutating func requestStop() {
        guard phase.isSessionActive else { return }
        phase = .stopping
    }

    func canFinishStop(
        generation incomingGeneration: Int,
        terminalAcknowledgementPending: Bool
    ) -> Bool {
        incomingGeneration == generation
            && phase == .stopping
            && !terminalAcknowledgementPending
    }

    func canRecoverFromTransientError(
        generation incomingGeneration: Int,
        terminalAcknowledgementPending: Bool
    ) -> Bool {
        incomingGeneration == generation
            && !(phase == .stopping && terminalAcknowledgementPending)
    }

    mutating func finishStop() {
        phase = .dormantWake
    }
}

enum VoiceSurfaceCollapsePolicy {
    static func shouldCollapseAfterStop(renderedText: String) -> Bool {
        renderedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

enum VoiceSurfaceRestartPolicy {
    static func shouldStabilizeExpandedConversation(
        answerTargetVisible: Bool,
        answerCardHidden: Bool,
        answerAnimationInFlight: Bool,
        hasConversation: Bool
    ) -> Bool {
        hasConversation
            && (
                answerTargetVisible
                || !answerCardHidden
                || answerAnimationInFlight
            )
    }
}

struct WakePhraseMatch: Equatable {
    let command: String
}

struct RecognitionLocaleEvidence: Equatable {
    let laneIndex: Int
    let localeIdentifier: String
    let confidence: Float?
    let isFinal: Bool
}

enum SpokenLocaleSelectionReason: String, Equatable {
    case explicitUserOverride = "explicit_user_override"
    case reliableLaneEvidence = "reliable_lane_evidence"
    case activationWakeLocale = "activation_wake_locale"
    case configuredPrimary = "configured_primary"
    case clarificationRequired = "clarification_required"
}

struct SpokenLocaleSelectionDecision: Equatable {
    let localeIdentifier: String?
    let reason: SpokenLocaleSelectionReason
    let laneIndex: Int?
    let confidence: Float?
    let isFinal: Bool?
}

enum SpokenLocaleSelectionPolicy {
    static let reliableConfidenceThreshold: Float = 0.55

    static func resolve(
        explicitOverrideIdentifier: String?,
        laneEvidence: [RecognitionLocaleEvidence],
        activationWakeLocaleIdentifier: String,
        configuredPrimaryLocaleIdentifier: String,
        configuredSupportedLocaleIdentifiers: [String]
    ) -> SpokenLocaleSelectionDecision {
        let supported = normalizedUnique(
            configuredSupportedLocaleIdentifiers
        )
        if let explicit = configuredMatch(
            explicitOverrideIdentifier,
            in: supported
        ) {
            return SpokenLocaleSelectionDecision(
                localeIdentifier: explicit,
                reason: .explicitUserOverride,
                laneIndex: nil,
                confidence: nil,
                isFinal: nil
            )
        }

        let reliable = laneEvidence.compactMap { evidence -> (
            evidence: RecognitionLocaleEvidence,
            locale: String
        )? in
            guard evidence.isFinal,
                  let confidence = evidence.confidence,
                  confidence.isFinite,
                  confidence >= reliableConfidenceThreshold,
                  let locale = configuredMatch(
                    evidence.localeIdentifier,
                    in: supported
                  ) else {
                return nil
            }
            return (evidence, locale)
        }.sorted {
            let left = $0.evidence.confidence ?? 0
            let right = $1.evidence.confidence ?? 0
            if left != right { return left > right }
            return $0.evidence.laneIndex < $1.evidence.laneIndex
        }.first
        if let reliable {
            return SpokenLocaleSelectionDecision(
                localeIdentifier: reliable.locale,
                reason: .reliableLaneEvidence,
                laneIndex: reliable.evidence.laneIndex,
                confidence: reliable.evidence.confidence,
                isFinal: reliable.evidence.isFinal
            )
        }

        if let wake = configuredMatch(
            activationWakeLocaleIdentifier,
            in: supported
        ) {
            return SpokenLocaleSelectionDecision(
                localeIdentifier: wake,
                reason: .activationWakeLocale,
                laneIndex: nil,
                confidence: nil,
                isFinal: nil
            )
        }
        if let primary = configuredMatch(
            configuredPrimaryLocaleIdentifier,
            in: supported
        ) {
            return SpokenLocaleSelectionDecision(
                localeIdentifier: primary,
                reason: .configuredPrimary,
                laneIndex: nil,
                confidence: nil,
                isFinal: nil
            )
        }
        return SpokenLocaleSelectionDecision(
            localeIdentifier: nil,
            reason: .clarificationRequired,
            laneIndex: nil,
            confidence: nil,
            isFinal: nil
        )
    }

    private static func normalizedUnique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty,
                  !result.contains(where: {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                  }) else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private static func configuredMatch(
        _ candidate: String?,
        in supported: [String]
    ) -> String? {
        let normalized = (candidate ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        if let exact = supported.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        guard let candidateBase = localeLanguageBase(normalized) else {
            return nil
        }
        return supported.first(where: {
            localeLanguageBase($0) == candidateBase
        })
    }

    private static func localeLanguageBase(_ identifier: String) -> String? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard let base = normalized.split(separator: "-", maxSplits: 1)
            .first,
              base.count >= 2,
              base.count <= 8,
              base.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        return base.lowercased()
    }
}

struct WakeActivationContext: Equatable {
    let activationID: String
    let commandText: String
    let recognizedUtteranceText: String
    let wakeLocaleIdentifier: String
    let spokenLocaleIdentifier: String
    let spokenLocaleSelectionReason: SpokenLocaleSelectionReason
    let spokenLocaleLaneIndex: Int?
    let spokenLocaleConfidence: Float?
    let spokenLocaleIsFinal: Bool?
    let handoffTicketID: String?
}

enum WakeRealtimePrefillPolicy {
    static func prefill(command: String) -> String {
        command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}

enum WakeDisplayTranscriptPolicy {
    static func visibleText(recognizedText: String) -> String {
        recognizedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}

struct SpeechAnalyzerWakeTranscriptReducer {
    struct Emission: Equatable {
        let transcript: String
        let segmentCount: Int
        let audioEndSeconds: TimeInterval
    }

    private struct Segment: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private var segments: [Segment] = []
    private var fallbackPosition: TimeInterval = 0

    mutating func ingest(
        text rawText: String,
        start rawStart: TimeInterval,
        end rawEnd: TimeInterval,
        phrases: [String]
    ) -> Emission? {
        let text = rawText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let range = normalizedRange(start: rawStart, end: rawEnd)

        if segments.isEmpty {
            guard WakePhrasePolicy.match(
                text,
                phrases: phrases
            ) != nil else {
                return nil
            }
            segments = [
                Segment(start: range.start, end: range.end, text: text)
            ]
            return emission()
        }

        segments.removeAll {
            Self.rangesOverlap(
                lhsStart: $0.start,
                lhsEnd: $0.end,
                rhsStart: range.start,
                rhsEnd: range.end
            )
        }
        if !text.isEmpty {
            segments.append(
                Segment(start: range.start, end: range.end, text: text)
            )
        }
        segments.sort {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }

        guard let current = emission(),
              WakePhrasePolicy.match(
                  current.transcript,
                  phrases: phrases
              ) != nil else {
            segments.removeAll()
            guard WakePhrasePolicy.match(
                text,
                phrases: phrases
            ) != nil else {
                return nil
            }
            segments = [
                Segment(start: range.start, end: range.end, text: text)
            ]
            return emission()
        }
        return current
    }

    mutating func reset() {
        segments.removeAll()
        fallbackPosition = 0
    }

    private mutating func normalizedRange(
        start rawStart: TimeInterval,
        end rawEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        if rawStart.isFinite,
           rawEnd.isFinite,
           rawStart >= 0,
           rawEnd >= rawStart {
            fallbackPosition = max(fallbackPosition, rawEnd)
            return (rawStart, rawEnd)
        }
        let start = fallbackPosition
        fallbackPosition += 0.001
        return (start, fallbackPosition)
    }

    private func emission() -> Emission? {
        let transcript = segments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !transcript.isEmpty else { return nil }
        return Emission(
            transcript: transcript,
            segmentCount: segments.count,
            audioEndSeconds: segments.map(\.end).max() ?? 0
        )
    }

    private static func rangesOverlap(
        lhsStart: TimeInterval,
        lhsEnd: TimeInterval,
        rhsStart: TimeInterval,
        rhsEnd: TimeInterval
    ) -> Bool {
        if lhsStart == rhsStart { return true }
        return lhsStart < rhsEnd && rhsStart < lhsEnd
    }
}

enum WakePhraseCapturePolicy {
    static let partialSettlementGrace: TimeInterval = 1.05
    static let finalizedWakeOnlyGrace: TimeInterval = 1.05
    static let finalizedCommandGrace: TimeInterval = 0.16
    static let partialCommandGrace: TimeInterval = 0.35

    static func activationDelay(
        for match: WakePhraseMatch,
        isFinal: Bool
    ) -> TimeInterval {
        if match.command.isEmpty {
            return isFinal
                ? finalizedWakeOnlyGrace
                : partialSettlementGrace
        }
        return isFinal
            ? finalizedCommandGrace
            : partialCommandGrace
    }

    static func preferred(
        _ lhs: WakePhraseMatch,
        over rhs: WakePhraseMatch
    ) -> Bool {
        if lhs.command.isEmpty != rhs.command.isEmpty {
            return !lhs.command.isEmpty
        }
        return lhs.command.count > rhs.command.count
    }
}

struct WakePhraseCommitmentRevision {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    mutating func invalidate() {
        value &+= 1
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

enum WakeTranscriptCandidatePolicy {
    static let maximumCandidates = 8

    static func preferredWakeTranscript(
        transcripts: [String],
        phrases: [String]
    ) -> String {
        let bounded = Array(transcripts.prefix(maximumCandidates))
        return bounded.first(where: {
            WakePhrasePolicy.match($0, phrases: phrases) != nil
        }) ?? bounded.first ?? ""
    }
}

enum WakeAnalyzerSessionPolicy {
    static let maximumContinuousDuration: TimeInterval = 2 * 60

    static func shouldRotate(
        startedAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        now - startedAt >= maximumContinuousDuration
    }
}

enum WakeAnalyzerInputPolicy {
    static let bufferCapacity = 256
    static let droppedInputRestartThreshold = 8

    static func shouldRestart(afterDroppedInputCount count: Int) -> Bool {
        count >= droppedInputRestartThreshold
    }
}

struct WakeAnalyzerInputTimeline {
    private(set) var nextFramePosition: Int64 = 0

    mutating func consume(frameCount: Int) -> Int64 {
        let startFrame = nextFramePosition
        nextFramePosition += Int64(max(0, frameCount))
        return startFrame
    }
}

struct WakeAudioFrameSpan: Equatable {
    let startFrame: Int64
    let endFrame: Int64
}

struct WakeAudioHandoffTicket: Equatable {
    let id: String
    let recognizedThroughFrame: Int64
}

enum WakeAudioHandoffReplay: Equatable {
    case ready(Data)
    case truncated
    case unavailable
}

struct WakeAudioRearmChunk: Equatable {
    let span: WakeAudioFrameSpan
    let data: Data
}

enum WakeAudioRearmReplay: Equatable {
    case ready(WakeAudioRearmChunk)
    case truncated
}

struct WakeAudioHandoffKey: Equatable {
    let ticketID: String
    let generation: Int
}

struct WakeAudioHandoffReplayBinding: Equatable {
    let key: WakeAudioHandoffKey
    let ordinal: Int
    let byteCount: Int
    let isLast: Bool
}

struct WakeAudioHandoffReplayOutcome: Equatable {
    enum Status: String {
        case sent = "client_send_completed"
        case noTail = "no_tail"
    }

    let key: WakeAudioHandoffKey
    let status: Status
    let byteCount: Int
    let chunkCount: Int
}

struct WakeAudioHandoffReplayLifecycle {
    enum Phase: String, Equatable {
        case idle
        case claimed
        case preparing
        case draining
        case sent
        case noTail = "no_tail"
        case failed
        case cancelled
    }

    enum CaptureDisposition: Equatable {
        case ordinary
        case committedJournal
        case protectedLiveBuffer
    }

    private(set) var phase: Phase = .idle
    private(set) var key: WakeAudioHandoffKey?
    private(set) var totalByteCount = 0
    private(set) var acceptedByteCount = 0
    private(set) var acceptedChunkCount = 0
    private(set) var completedByteCount = 0
    private(set) var completedChunkCount = 0
    private(set) var outcome: WakeAudioHandoffReplayOutcome?

    var captureDisposition: CaptureDisposition {
        switch phase {
        case .claimed, .preparing:
            return .committedJournal
        case .draining:
            return .protectedLiveBuffer
        case .idle, .sent, .noTail, .failed, .cancelled:
            return .ordinary
        }
    }

    var requiresProtectedContinuity: Bool {
        switch phase {
        case .claimed, .preparing, .draining:
            return true
        case .idle, .sent, .noTail, .failed, .cancelled:
            return false
        }
    }

    var shouldBufferInboundEvents: Bool {
        requiresProtectedContinuity
    }

    mutating func claim(ticketID: String, generation: Int) -> Bool {
        guard phase == .idle,
              !ticketID.isEmpty,
              generation > 0 else {
            return false
        }
        phase = .claimed
        key = WakeAudioHandoffKey(
            ticketID: ticketID,
            generation: generation
        )
        return true
    }

    mutating func beginPreparing(
        ticketID: String,
        generation: Int
    ) -> Bool {
        guard phase == .claimed,
              key == WakeAudioHandoffKey(
                  ticketID: ticketID,
                  generation: generation
              ) else {
            return false
        }
        phase = .preparing
        return true
    }

    mutating func beginDraining(
        ticketID: String,
        generation: Int,
        byteCount: Int
    ) -> WakeAudioHandoffReplayOutcome? {
        let expectedKey = WakeAudioHandoffKey(
            ticketID: ticketID,
            generation: generation
        )
        guard phase == .preparing,
              key == expectedKey,
              byteCount >= 0 else {
            return nil
        }
        totalByteCount = byteCount
        acceptedByteCount = 0
        acceptedChunkCount = 0
        completedByteCount = 0
        completedChunkCount = 0
        if byteCount == 0 {
            phase = .noTail
            let resolved = WakeAudioHandoffReplayOutcome(
                key: expectedKey,
                status: .noTail,
                byteCount: 0,
                chunkCount: 0
            )
            outcome = resolved
            return resolved
        }
        phase = .draining
        return nil
    }

    func proposedBinding(byteCount: Int) -> WakeAudioHandoffReplayBinding? {
        guard phase == .draining,
              let key,
              byteCount > 0,
              acceptedByteCount + byteCount <= totalByteCount else {
            return nil
        }
        return WakeAudioHandoffReplayBinding(
            key: key,
            ordinal: acceptedChunkCount,
            byteCount: byteCount,
            isLast: acceptedByteCount + byteCount == totalByteCount
        )
    }

    mutating func recordAccepted(
        _ binding: WakeAudioHandoffReplayBinding
    ) -> Bool {
        guard phase == .draining,
              binding.key == key,
              binding.ordinal == acceptedChunkCount,
              binding.byteCount > 0,
              acceptedByteCount + binding.byteCount <= totalByteCount,
              binding.isLast
                == (
                    acceptedByteCount + binding.byteCount
                        == totalByteCount
                ) else {
            return false
        }
        acceptedByteCount += binding.byteCount
        acceptedChunkCount += 1
        return true
    }

    mutating func recordCompleted(
        _ binding: WakeAudioHandoffReplayBinding
    ) -> WakeAudioHandoffReplayOutcome? {
        guard phase == .draining,
              binding.key == key,
              binding.ordinal == completedChunkCount,
              binding.ordinal < acceptedChunkCount,
              binding.byteCount > 0,
              completedByteCount + binding.byteCount
                <= acceptedByteCount else {
            return nil
        }
        completedByteCount += binding.byteCount
        completedChunkCount += 1
        guard binding.isLast,
              completedByteCount == totalByteCount,
              completedByteCount == acceptedByteCount,
              completedChunkCount == acceptedChunkCount,
              let key else {
            return nil
        }
        phase = .sent
        let resolved = WakeAudioHandoffReplayOutcome(
            key: key,
            status: .sent,
            byteCount: completedByteCount,
            chunkCount: completedChunkCount
        )
        outcome = resolved
        return resolved
    }

    mutating func fail() {
        guard requiresProtectedContinuity else { return }
        phase = .failed
        outcome = nil
    }

    mutating func cancel() {
        guard phase != .idle else { return }
        phase = .cancelled
        outcome = nil
    }

    mutating func reset() {
        self = Self()
    }
}

struct WakeAudioHandoffJournal {
    static let sampleRate: Int64 = 24_000
    static let bytesPerFrame = MemoryLayout<Int16>.size
    static let rollingFrameCapacity = sampleRate * 6
    static let committedByteCapacity = 1_048_576

    private struct Record {
        var startFrame: Int64
        var data: Data

        var endFrame: Int64 {
            startFrame
                + Int64(data.count / WakeAudioHandoffJournal.bytesPerFrame)
        }
    }

    private var records: [Record] = []
    private(set) var nextFrame: Int64 = 0
    private var ticket: WakeAudioHandoffTicket?
    private var claimedGeneration: Int?
    private var truncated = false

    var hasCommittedHandoff: Bool {
        ticket != nil
    }

    mutating func beginWake() {
        records.removeAll(keepingCapacity: true)
        nextFrame = 0
        ticket = nil
        claimedGeneration = nil
        truncated = false
    }

    @discardableResult
    mutating func append(pcm rawPCM: Data) -> WakeAudioFrameSpan {
        let usableByteCount =
            rawPCM.count - rawPCM.count % Self.bytesPerFrame
        let pcm = rawPCM.prefix(usableByteCount)
        let span = WakeAudioFrameSpan(
            startFrame: nextFrame,
            endFrame:
                nextFrame + Int64(usableByteCount / Self.bytesPerFrame)
        )
        guard !pcm.isEmpty else { return span }
        records.append(
            Record(
                startFrame: span.startFrame,
                data: Data(pcm)
            )
        )
        nextFrame = span.endFrame
        if let ticket {
            let retainedBytes = max(
                0,
                Int(nextFrame - ticket.recognizedThroughFrame)
                    * Self.bytesPerFrame
            )
            if retainedBytes > Self.committedByteCapacity {
                truncated = true
            }
        } else {
            trimBefore(
                max(0, nextFrame - Self.rollingFrameCapacity)
            )
        }
        return span
    }

    mutating func commit(
        recognizedThroughFrame: Int64,
        ticketID: String = UUID().uuidString
    ) -> WakeAudioHandoffTicket {
        let earliestFrame = records.first?.startFrame ?? nextFrame
        let boundaryWasAlreadyTrimmed =
            recognizedThroughFrame < earliestFrame
        let boundary = min(
            nextFrame,
            max(earliestFrame, recognizedThroughFrame)
        )
        let resolved = WakeAudioHandoffTicket(
            id: ticketID,
            recognizedThroughFrame: boundary
        )
        ticket = resolved
        claimedGeneration = nil
        truncated = boundaryWasAlreadyTrimmed
        trimBefore(boundary)
        return resolved
    }

    mutating func claim(
        ticketID: String,
        generation: Int
    ) -> Bool {
        guard ticket?.id == ticketID,
              claimedGeneration == nil else {
            return false
        }
        claimedGeneration = generation
        return true
    }

    mutating func replay(
        ticketID: String,
        generation: Int
    ) -> WakeAudioHandoffReplay {
        guard let ticket,
              ticket.id == ticketID,
              claimedGeneration == generation else {
            return .unavailable
        }
        guard !truncated else { return .truncated }
        var result = Data()
        for record in records {
            guard record.endFrame > ticket.recognizedThroughFrame else {
                continue
            }
            let startFrame = max(
                record.startFrame,
                ticket.recognizedThroughFrame
            )
            let byteOffset =
                Int(startFrame - record.startFrame) * Self.bytesPerFrame
            result.append(record.data.dropFirst(byteOffset))
        }
        return .ready(result)
    }

    func replay(fromFrame requestedFrame: Int64) -> WakeAudioRearmReplay {
        let earliestFrame = records.first?.startFrame ?? nextFrame
        guard requestedFrame >= earliestFrame,
              requestedFrame <= nextFrame else {
            return .truncated
        }
        var result = Data()
        for record in records where record.endFrame > requestedFrame {
            let startFrame = max(record.startFrame, requestedFrame)
            let byteOffset =
                Int(startFrame - record.startFrame) * Self.bytesPerFrame
            result.append(record.data.dropFirst(byteOffset))
        }
        return .ready(
            WakeAudioRearmChunk(
                span: WakeAudioFrameSpan(
                    startFrame: requestedFrame,
                    endFrame: nextFrame
                ),
                data: result
            )
        )
    }

    mutating func finish(ticketID: String, generation: Int) {
        guard ticket?.id == ticketID,
              claimedGeneration == generation else {
            return
        }
        beginWake()
    }

    mutating func rollbackCommittedHandoffForRearm() -> Int64? {
        guard let ticket else { return nil }
        let boundary = ticket.recognizedThroughFrame
        self.ticket = nil
        claimedGeneration = nil
        truncated = false
        return boundary
    }

    mutating func cancel(ticketID: String? = nil) {
        if let ticketID, ticket?.id != ticketID {
            return
        }
        beginWake()
    }

    private mutating func trimBefore(_ cutoffFrame: Int64) {
        while let first = records.first,
              first.endFrame <= cutoffFrame {
            records.removeFirst()
        }
        guard !records.isEmpty,
              records[0].startFrame < cutoffFrame else {
            return
        }
        let byteOffset =
            Int(cutoffFrame - records[0].startFrame) * Self.bytesPerFrame
        records[0].data = Data(records[0].data.dropFirst(byteOffset))
        records[0].startFrame = cutoffFrame
    }
}

struct WakeAudioReplayPump {
    static let controlQueueReserve = 16

    private var bytes = Data()
    private var readOffset = 0

    var pendingByteCount: Int {
        max(0, bytes.count - readOffset)
    }

    var hasPendingBytes: Bool {
        pendingByteCount > 0
    }

    mutating func append(_ value: Data) {
        guard !value.isEmpty else { return }
        compactIfUseful()
        bytes.append(value)
    }

    func peek(maximumByteCount: Int) -> Data? {
        let count = min(
            max(0, maximumByteCount),
            pendingByteCount
        )
        guard count > 0 else { return nil }
        return Data(bytes[readOffset..<(readOffset + count)])
    }

    @discardableResult
    mutating func consumeAccepted(byteCount: Int) -> Bool {
        guard byteCount > 0,
              byteCount <= pendingByteCount else {
            return false
        }
        readOffset += byteCount
        compactIfUseful()
        return true
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: false)
        readOffset = 0
    }

    private mutating func compactIfUseful() {
        guard readOffset > 0,
              readOffset >= 65_536
                || readOffset * 2 >= bytes.count else {
            return
        }
        bytes = Data(bytes.dropFirst(readOffset))
        readOffset = 0
    }
}

struct CanonicalUserTurnDisplayRegistry {
    private var generation: Int?
    private var payloads: [String: String] = [:]
    private var order: [String] = []
    private let maximumRememberedTurns = 128

    mutating func begin(generation: Int) {
        self.generation = generation
        payloads.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    mutating func accept(
        generation: Int,
        turnID: String,
        text: String
    ) -> Bool {
        guard self.generation == generation else { return false }
        let id = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !value.isEmpty else { return false }
        if payloads[id] != nil { return false }
        payloads[id] = value
        order.append(id)
        while order.count > maximumRememberedTurns {
            payloads.removeValue(forKey: order.removeFirst())
        }
        return true
    }

    func isFinalized(generation: Int, turnID: String) -> Bool {
        self.generation == generation && payloads[turnID] != nil
    }
}

enum WakeAnalyzerRuntimeRecoveryPolicy {
    static let baseDelay: TimeInterval = 0.15
    static let maximumDelay: TimeInterval = 2
    static let maximumTrackedFailures = 8

    static func retryDelay(consecutiveFailures: Int) -> TimeInterval {
        let boundedFailures = min(
            max(1, consecutiveFailures),
            maximumTrackedFailures
        )
        return min(
            maximumDelay,
            baseDelay * pow(2, Double(boundedFailures - 1))
        )
    }
}

enum WakePhrasePolicy {
    static func match(_ transcript: String) -> WakePhraseMatch? {
        match(transcript, phrases: SettingsStore.defaultWakePhrases)
    }

    static func match(
        _ transcript: String,
        phrases rawPhrases: [String]
    ) -> WakePhraseMatch? {
        let phrases = SettingsStore.normalizedWakePhrases(rawPhrases)
        let range = NSRange(
            transcript.startIndex..<transcript.endIndex,
            in: transcript
        )
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            guard let expression = try? NSRegularExpression(
                pattern:
                    #"^\s*(?:"# + pattern(for: phrase)
                    + #")(?=$|[\s\p{P}])"#,
                options: [.caseInsensitive]
            ),
            let match = expression.firstMatch(
                in: transcript,
                range: range
            ),
            let swiftRange = Range(match.range, in: transcript) else {
                continue
            }
            let suffix = String(transcript[swiftRange.upperBound...])
            let separators = CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
            return WakePhraseMatch(
                command: suffix.trimmingCharacters(in: separators)
            )
        }
        return nil
    }

    private static func pattern(for phrase: String) -> String {
        return phrase
            .filter { !$0.isWhitespace }
            .map {
                NSRegularExpression.escapedPattern(for: String($0))
            }
            .joined(separator: #"[\s\p{P}]*"#)
    }
}
