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
        let headerExpanded = phase == .thinking || answerVisible || hovering
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

struct ExternalAudioPlaybackSnapshot: Equatable {
    let processLabels: Set<String>

    var isPlaying: Bool {
        !processLabels.isEmpty
    }

    func sharesOutputProcess(with other: Self) -> Bool {
        !processLabels.isDisjoint(with: other.processLabels)
    }
}

struct ExternalAudioOutputConfirmation {
    private(set) var consecutiveSamples = 0
    private var previous = ExternalAudioPlaybackSnapshot(processLabels: [])

    mutating func observe(
        _ snapshot: ExternalAudioPlaybackSnapshot,
        requiredSamples: Int = 2
    ) -> Bool {
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

enum ExternalMediaVoiceYieldPolicy {
    static func shouldStop(
        mediaConfirmed: Bool,
        finalPlaybackDrained: Bool,
        userActivityObserved: Bool,
        assistantFinalObserved: Bool,
        phase: VoiceSurfacePhase
    ) -> Bool {
        guard mediaConfirmed else { return false }
        if finalPlaybackDrained {
            return true
        }
        return !userActivityObserved
            && !assistantFinalObserved
            && phase == .listening
    }
}

struct AssistantOutputLifecycle {
    private(set) var generation = 0
    private(set) var pendingNativeResponseIDs = Set<String>()
    private(set) var pendingLocalSpeechCount = 0

    var isActive: Bool {
        !pendingNativeResponseIDs.isEmpty || pendingLocalSpeechCount > 0
    }

    mutating func reset(generation: Int) {
        self.generation = generation
        pendingNativeResponseIDs.removeAll()
        pendingLocalSpeechCount = 0
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

    mutating func cancelAll(generation: Int) {
        guard generation == self.generation else { return }
        pendingNativeResponseIDs.removeAll()
        pendingLocalSpeechCount = 0
    }
}

enum WakeMonitoringResumePolicy {
    static let activationDelay: TimeInterval = 1.6

    static func shouldStart(
        voiceSessionActive: Bool,
        externalAudioPlaying: Bool,
        assistantOutputActive: Bool
    ) -> Bool {
        !voiceSessionActive
            && !externalAudioPlaying
            && !assistantOutputActive
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

    mutating func finishStop() {
        phase = .dormantWake
    }
}

struct WakePhraseMatch: Equatable {
    let command: String
}

enum WakePhraseCapturePolicy {
    static let wakeOnlyGrace: TimeInterval = 0.55
    static let commandTailGrace: TimeInterval = 1.05
    static let finalizedGrace: TimeInterval = 0.16

    static func activationDelay(
        for match: WakePhraseMatch,
        isFinal: Bool
    ) -> TimeInterval {
        if isFinal {
            return finalizedGrace
        }
        return match.command.isEmpty ? wakeOnlyGrace : commandTailGrace
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
