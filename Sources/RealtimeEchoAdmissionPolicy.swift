import Foundation

struct RealtimeEchoFilterResult {
    enum Classification: Equatable {
        case noPlaybackReference
        case echoOnly
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
    private let playbackTailDuration: TimeInterval = 0.8
    private let bargeInPermitDuration: TimeInterval = 2.5

    private var referenceStartTick: Int64?
    private var referenceSamples: [Float] = []
    private var playbackGuardUntil = -Double.greatestFiniteMagnitude
    private var bargeInPermitUntil = -Double.greatestFiniteMagnitude
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
        playbackActive: Bool
    ) -> RealtimeEchoFilterResult {
        guard !input.isEmpty else {
            return RealtimeEchoFilterResult(
                samples: [],
                classification: .noPlaybackReference,
                correlation: 0
            )
        }
        guard playbackActive,
              let referenceStartTick,
              !referenceSamples.isEmpty else {
            return RealtimeEchoFilterResult(
                samples: input,
                classification: .noPlaybackReference,
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
            if Self.rms(input) >= minimumResidualRMS {
                bargeInPermitUntil = max(
                    bargeInPermitUntil,
                    startTime + bargeInPermitDuration
                )
            }
            return RealtimeEchoFilterResult(
                samples: input,
                classification: .noPlaybackReference,
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
            return RealtimeEchoFilterResult(
                samples: [],
                classification: .echoOnly,
                correlation: bestCorrelation
            )
        }

        bargeInPermitUntil = max(
            bargeInPermitUntil,
            startTime + bargeInPermitDuration
        )
        return RealtimeEchoFilterResult(
            samples: residual,
            classification: .residualSpeech,
            correlation: bestCorrelation
        )
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
        playbackGuardUntil = -Double.greatestFiniteMagnitude
        bargeInPermitUntil = -Double.greatestFiniteMagnitude
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
