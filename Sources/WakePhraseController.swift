import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

private struct WakeCaptureCandidate: Equatable {
    let match: WakePhraseMatch
    let isFinal: Bool
    let laneIndex: Int
}

final class WakePhraseController {
    private static let logger = Logger(
        subsystem: "com.hyungchulc.voice-relay",
        category: "WakePhrase"
    )

    private let localeIdentifiers: [String]
    private let recognizers: [SFSpeechRecognizer]
    private let phrases: [String]
    private let preferModernSpeechAnalyzer: Bool
    private let audioEngine = AVAudioEngine()
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    private var completedLaneIndexes = Set<Int>()
    private var restartWorkItem: DispatchWorkItem?
    private var pendingWakeWorkItem: DispatchWorkItem?
    private var pendingWakeCandidate: WakeCaptureCandidate?
    private var wakeCandidates: [Int: WakeCaptureCandidate] = [:]
    private var modernStartTask: Task<Void, Never>?
    private var modernSession: AnyObject?
    private var wantsMonitoring = false
    private var permissionRequestInFlight = false
    private var recognitionGeneration = 0
    private var preferLegacyUntilPause = false
    private var modernTransientRetryCount = 0

    private(set) var isMonitoring = false
    var onWake: ((WakePhraseMatch) -> Void)?
    var onState: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    init(
        localeIdentifiers: [String],
        phrases: [String],
        preferModernSpeechAnalyzer: Bool = true
    ) {
        let resolved = SettingsStore.resolvedSpeechLocaleIdentifiers(
            localeIdentifiers
        )
        self.localeIdentifiers = resolved
        recognizers = resolved.compactMap {
            SFSpeechRecognizer(locale: Locale(identifier: $0))
        }
        self.phrases = SettingsStore.normalizedWakePhrases(phrases)
        self.preferModernSpeechAnalyzer = preferModernSpeechAnalyzer
        Self.logger.info(
            "Wake configuration locales=\(resolved.joined(separator: ","), privacy: .public) phrase_count=\(self.phrases.count)"
        )
    }

    func startMonitoring() {
        if !wantsMonitoring {
            preferLegacyUntilPause = false
            modernTransientRetryCount = 0
        }
        wantsMonitoring = true
        guard !isMonitoring,
              modernStartTask == nil,
              modernSession == nil,
              !permissionRequestInFlight else {
            return
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            startRecognitionIfPossible()
            return
        }
        requestPermissionsAndStart()
    }

    func pause() {
        wantsMonitoring = false
        preferLegacyUntilPause = false
        modernTransientRetryCount = 0
        stopRecognition()
    }

    private func requestPermissionsAndStart() {
        permissionRequestInFlight = true
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    self.permissionRequestInFlight = false
                    self.wantsMonitoring = false
                    self.onError?("웨이크워드 음성 인식 권한이 필요해")
                }
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    guard granted else {
                        self.wantsMonitoring = false
                        self.onError?("웨이크워드 마이크 권한이 필요해")
                        return
                    }
                    self.startRecognitionIfPossible()
                }
            }
        }
    }

    private func startRecognitionIfPossible() {
        guard wantsMonitoring,
              !isMonitoring,
              modernStartTask == nil,
              modernSession == nil else {
            return
        }
        if #available(macOS 26.0, *),
           preferModernSpeechAnalyzer,
           !preferLegacyUntilPause {
            startModernRecognitionIfPossible()
            return
        }
        startLegacyRecognitionIfPossible()
    }

    @available(macOS 26.0, *)
    private func startModernRecognitionIfPossible() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        recognitionGeneration += 1
        let generation = recognitionGeneration
        let requestedLocales = localeIdentifiers.map(Locale.init(identifier:))

        modernStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let installedLocales = await DictationTranscriber.installedLocales
            var selectedLocales: [Locale] = []
            var selectedKeys = Set<String>()
            for requestedLocale in requestedLocales {
                guard !Task.isCancelled,
                      let supportedLocale =
                        await DictationTranscriber.supportedLocale(
                            equivalentTo: requestedLocale
                        ) else {
                    continue
                }
                let supportedKey = Self.localeKey(supportedLocale)
                guard let installedLocale = installedLocales.first(where: {
                    Self.localeKey($0) == supportedKey
                }), selectedKeys.insert(supportedKey).inserted else {
                    continue
                }
                selectedLocales.append(installedLocale)
            }

            self.modernStartTask = nil
            guard self.wantsMonitoring,
                  self.recognitionGeneration == generation else {
                return
            }
            guard WakeRecognitionBackendPolicy.usesModernAnalyzer(
                preferenceEnabled: self.preferModernSpeechAnalyzer,
                platformSupportsAnalyzer: true,
                requestedLocaleCount: requestedLocales.count,
                availableLocaleCount: selectedLocales.count
            ) else {
                self.preferLegacyUntilPause = true
                self.startLegacyRecognitionIfPossible()
                return
            }
            self.launchModernRecognition(
                locales: selectedLocales,
                generation: generation
            )
        }
    }

    @available(macOS 26.0, *)
    private func launchModernRecognition(
        locales: [Locale],
        generation: Int
    ) {
        let session = SpeechAnalyzerWakeSession(
            locales: locales,
            phrases: phrases,
            onTranscript: { [weak self] laneIndex, transcript, isFinal in
                DispatchQueue.main.async {
                    guard let self,
                          self.wantsMonitoring,
                          self.recognitionGeneration == generation else {
                        return
                    }
                    _ = self.handleWakeTranscript(
                        transcript,
                        laneIndex: laneIndex,
                        isFinal: isFinal,
                        generation: generation
                    )
                }
            },
            onFailure: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self,
                          self.wantsMonitoring,
                          self.recognitionGeneration == generation else {
                        return
                    }
                    Self.logger.error(
                        "SpeechAnalyzer runtime failed, using legacy fallback: \(error.localizedDescription, privacy: .public)"
                    )
                    self.preferLegacyUntilPause = true
                    self.stopRecognition()
                    self.wantsMonitoring = true
                    self.scheduleRestart()
                }
            }
        )
        modernSession = session
        session.start { [weak self, weak session] result in
            DispatchQueue.main.async {
                guard let self,
                      let session,
                      self.modernSession === session,
                      self.recognitionGeneration == generation else {
                    return
                }
                switch result {
                case .success:
                    self.modernTransientRetryCount = 0
                    self.isMonitoring = true
                    Self.logger.info(
                        "SpeechAnalyzer active locales=\(locales.map(\.identifier).joined(separator: ","), privacy: .public) phrase_count=\(self.phrases.count)"
                    )
                    self.onState?(true)
                case let .failure(error):
                    if let startError =
                        error as? WakeRecognitionStartError,
                       WakeAnalyzerRetryPolicy.shouldRetry(
                           stage: startError.stage,
                           priorAttempts:
                               self.modernTransientRetryCount
                       ) {
                        self.modernTransientRetryCount += 1
                        Self.logger.notice(
                            "SpeechAnalyzer audio device was still switching, retrying modern recognition once"
                        )
                        self.stopRecognition()
                        self.wantsMonitoring = true
                        self.scheduleRestart(
                            delay: WakeAnalyzerRetryPolicy.retryDelay
                        )
                        return
                    }
                    Self.logger.error(
                        "SpeechAnalyzer start failed, using legacy fallback: \(error.localizedDescription, privacy: .public)"
                    )
                    self.preferLegacyUntilPause = true
                    self.stopRecognition()
                    self.wantsMonitoring = true
                    self.scheduleRestart()
                }
            }
        }
    }

    private func startLegacyRecognitionIfPossible() {
        guard wantsMonitoring, !isMonitoring else { return }
        let availableRecognizers = recognizers.filter {
            $0.isAvailable && $0.supportsOnDeviceRecognition
        }
        guard !availableRecognizers.isEmpty else {
            wantsMonitoring = false
            onError?("선택한 언어는 이 Mac에서 로컬 웨이크워드를 사용할 수 없어")
            return
        }

        restartWorkItem?.cancel()
        recognitionGeneration += 1
        let generation = recognitionGeneration
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        completedLaneIndexes.removeAll()
        requests = availableRecognizers.map { _ in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.contextualStrings = phrases
            return request
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.requests.forEach { $0.append(buffer) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            requests.removeAll()
            wantsMonitoring = false
            onError?("웨이크워드 마이크를 시작하지 못했어")
            return
        }

        isMonitoring = true
        Self.logger.info(
            "Legacy recognizer active locales=\(availableRecognizers.map(\.locale.identifier).joined(separator: ","), privacy: .public) phrase_count=\(self.phrases.count)"
        )
        onState?(true)
        tasks = zip(availableRecognizers, requests).enumerated().map {
            laneIndex, pair in
            let (recognizer, request) = pair
            return recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard generation == self.recognitionGeneration else { return }
                    if let transcript =
                        result?.bestTranscription.formattedString,
                       self.handleWakeTranscript(
                            transcript,
                            laneIndex: laneIndex,
                            isFinal: result?.isFinal == true,
                            generation: generation
                       ) {
                        return
                    }

                    if error != nil || result?.isFinal == true {
                        self.completedLaneIndexes.insert(laneIndex)
                        if self.completedLaneIndexes.count == self.tasks.count {
                            self.stopRecognition()
                            self.wantsMonitoring = true
                            self.scheduleRestart()
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func handleWakeTranscript(
        _ transcript: String,
        laneIndex: Int,
        isFinal: Bool,
        generation: Int
    ) -> Bool {
        guard wantsMonitoring,
              recognitionGeneration == generation else {
            return false
        }
        if let match = WakePhrasePolicy.match(
            transcript,
            phrases: phrases
        ) {
            wakeCandidates[laneIndex] = WakeCaptureCandidate(
                match: match,
                isFinal: isFinal,
                laneIndex: laneIndex
            )
        } else {
            wakeCandidates.removeValue(forKey: laneIndex)
        }

        guard let candidate = wakeCandidates.values.max(by: {
            WakePhraseCapturePolicy.preferred(
                $1.match,
                over: $0.match
            )
        }) else {
            pendingWakeWorkItem?.cancel()
            pendingWakeWorkItem = nil
            pendingWakeCandidate = nil
            return false
        }
        guard candidate != pendingWakeCandidate else { return true }

        pendingWakeWorkItem?.cancel()
        pendingWakeWorkItem = nil
        pendingWakeCandidate = candidate
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.recognitionGeneration == generation else {
                return
            }
            self.wantsMonitoring = false
            Self.logger.notice(
                "Wake matched lane=\(candidate.laneIndex) phrase_count=\(self.phrases.count) final=\(candidate.isFinal) command_tail=\(!candidate.match.command.isEmpty) command_length=\(candidate.match.command.count)"
            )
            self.stopRecognition { [weak self] in
                guard let self, !self.wantsMonitoring else { return }
                self.onWake?(candidate.match)
            }
        }
        pendingWakeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WakePhraseCapturePolicy.activationDelay(
                for: candidate.match,
                isFinal: candidate.isFinal
            ),
            execute: item
        )
        return true
    }

    private func stopRecognition(completion: (() -> Void)? = nil) {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        pendingWakeWorkItem?.cancel()
        pendingWakeWorkItem = nil
        pendingWakeCandidate = nil
        wakeCandidates.removeAll()
        modernStartTask?.cancel()
        modernStartTask = nil
        recognitionGeneration += 1
        let completionGeneration = recognitionGeneration
        let finish = { [weak self] in
            guard let self,
                  self.recognitionGeneration == completionGeneration else {
                return
            }
            completion?()
        }
        requests.forEach { $0.endAudio() }
        tasks.forEach { $0.cancel() }
        requests.removeAll()
        tasks.removeAll()
        completedLaneIndexes.removeAll()
        if isMonitoring {
            isMonitoring = false
            onState?(false)
        }
        if #available(macOS 26.0, *),
           let modernWakeSession =
            modernSession as? SpeechAnalyzerWakeSession {
            modernSession = nil
            modernWakeSession.stop(completion: finish)
        } else {
            modernSession = nil
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            finish()
        }
    }

    private func scheduleRestart(delay: TimeInterval = 0.8) {
        guard wantsMonitoring else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.startRecognitionIfPossible()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private static func localeKey(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

@available(macOS 26.0, *)
private final class SpeechAnalyzerWakeSession {
    private let locales: [Locale]
    private let phrases: [String]
    private let onTranscript: (Int, String, Bool) -> Void
    private let onFailure: (Error) -> Void
    private let audioEngine = AVAudioEngine()
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var reservedLocales: [Locale] = []
    private var stopped = false
    private var stopCompleted = false
    private var stopCompletions: [() -> Void] = []
    private var failureReported = false

    init(
        locales: [Locale],
        phrases: [String],
        onTranscript: @escaping (Int, String, Bool) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.locales = locales
        self.phrases = phrases
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            var startupStage = WakeAnalyzerStartStage.assetReservation
            do {
                var acquiredLocales: [Locale] = []
                for locale in locales {
                    _ = try await AssetInventory.reserve(locale: locale)
                    acquiredLocales.append(locale)
                    if isStopped {
                        for acquiredLocale in acquiredLocales {
                            _ = await AssetInventory.release(
                                reservedLocale: acquiredLocale
                            )
                        }
                        return
                    }
                }
                stateLock.withLock {
                    self.reservedLocales = acquiredLocales
                }
                let transcribers = locales.map {
                    DictationTranscriber(
                        locale: $0,
                        contentHints: [.shortForm, .farField],
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults],
                        attributeOptions: []
                    )
                }
                let modules: [any SpeechModule] = transcribers
                let naturalFormat = audioEngine.inputNode.outputFormat(forBus: 0)
                guard let analysisFormat =
                    await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: modules,
                        considering: naturalFormat
                    ) else {
                    throw WakeRecognitionError.noCompatibleAudioFormat
                }

                let context = AnalysisContext()
                context.contextualStrings[.general] = phrases
                let analyzer = SpeechAnalyzer(
                    modules: modules,
                    options: .init(
                        priority: .high,
                        modelRetention: .lingering
                    )
                )
                startupStage = .analysisContext
                try await analyzer.setContext(context)
                startupStage = .analyzerPrepare
                try await analyzer.prepareToAnalyze(in: analysisFormat)
                guard !isStopped else { return }
                let converter = naturalFormat.isEqual(analysisFormat)
                    ? nil
                    : AVAudioConverter(
                        from: naturalFormat,
                        to: analysisFormat
                    )
                if !naturalFormat.isEqual(analysisFormat),
                   converter == nil {
                    throw WakeRecognitionError.noCompatibleAudioConverter
                }

                let (inputStream, continuation) =
                    AsyncStream<AnalyzerInput>.makeStream(
                        bufferingPolicy: .bufferingNewest(64)
                    )
                let analyzerResultTasks = transcribers.enumerated().map {
                    laneIndex, transcriber in
                    Task { [weak self] in
                        var segments: [ModernTranscriptSegment] = []
                        do {
                            for try await result in transcriber.results {
                                guard let self, !self.isStopped else { return }
                                segments.removeAll {
                                    Self.rangesOverlap(
                                        $0.range,
                                        result.range
                                    )
                                }
                                let text = String(result.text.characters)
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                if !text.isEmpty {
                                    segments.append(
                                        ModernTranscriptSegment(
                                            range: result.range,
                                            text: text
                                        )
                                    )
                                }
                                segments.sort {
                                    CMTimeCompare(
                                        $0.range.start,
                                        $1.range.start
                                    ) < 0
                                }
                                let transcript = segments
                                    .map(\.text)
                                    .joined(separator: " ")
                                self.onTranscript(
                                    laneIndex,
                                    transcript,
                                    result.isFinal
                                )
                            }
                        } catch {
                            self?.reportFailure(error)
                        }
                    }
                }

                let didStart = try self.lifecycleLock.withLock {
                    let ownsLifecycle = self.stateLock.withLock {
                        guard !self.stopped else { return false }
                        self.analyzer = analyzer
                        self.inputContinuation = continuation
                        self.resultTasks = analyzerResultTasks
                        return true
                    }
                    guard ownsLifecycle else { return false }

                    let inputNode = self.audioEngine.inputNode
                    inputNode.removeTap(onBus: 0)
                    inputNode.installTap(
                        onBus: 0,
                        bufferSize: 1024,
                        format: nil
                    ) { [weak self] buffer, _ in
                        guard let self else { return }
                        let analyzerBuffer: AVAudioPCMBuffer
                        let resolvedConverter: AVAudioConverter?
                        if buffer.format.isEqual(analysisFormat) {
                            resolvedConverter = nil
                        } else if buffer.format.isEqual(naturalFormat) {
                            resolvedConverter = converter
                        } else {
                            resolvedConverter = AVAudioConverter(
                                from: buffer.format,
                                to: analysisFormat
                            )
                        }
                        if let resolvedConverter {
                            guard let converted = Self.convert(
                                buffer,
                                using: resolvedConverter,
                                to: analysisFormat
                            ) else {
                                self.reportFailure(
                                    WakeRecognitionError.audioConversionFailed
                                )
                                return
                            }
                            analyzerBuffer = converted
                        } else {
                            analyzerBuffer = buffer
                        }
                        self.inputContinuation?.yield(
                            AnalyzerInput(buffer: analyzerBuffer)
                        )
                    }
                    startupStage = .audioEngineStart
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                    self.analysisTask = Task { [weak self] in
                        do {
                            try await analyzer.start(
                                inputSequence: inputStream
                            )
                        } catch {
                            self?.reportFailure(error)
                        }
                    }
                    return true
                }
                guard didStart else {
                    continuation.finish()
                    analyzerResultTasks.forEach { $0.cancel() }
                    await analyzer.cancelAndFinishNow()
                    return
                }
                completion(.success(()))
            } catch {
                completion(
                    .failure(
                        WakeRecognitionStartError(
                            stage: startupStage,
                            underlying: error
                        )
                    )
                )
            }
        }
    }

    private struct ModernTranscriptSegment {
        let range: CMTimeRange
        let text: String
    }

    private static func rangesOverlap(
        _ lhs: CMTimeRange,
        _ rhs: CMTimeRange
    ) -> Bool {
        if CMTimeCompare(lhs.start, rhs.start) == 0 {
            return true
        }
        let lhsEnd = CMTimeRangeGetEnd(lhs)
        let rhsEnd = CMTimeRangeGetEnd(rhs)
        return CMTimeCompare(lhs.start, rhsEnd) < 0
            && CMTimeCompare(rhs.start, lhsEnd) < 0
    }

    func stop(completion: @escaping () -> Void = {}) {
        stateLock.lock()
        if stopCompleted {
            stateLock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        stopCompletions.append(completion)
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let analyzerToCancel = analyzer
        analyzer = nil
        let localesToRelease = reservedLocales
        reservedLocales.removeAll()
        stateLock.unlock()

        lifecycleLock.withLock {
            inputContinuation?.finish()
            inputContinuation = nil
            analysisTask?.cancel()
            analysisTask = nil
            resultTasks.forEach { $0.cancel() }
            resultTasks.removeAll()
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        Task { [self] in
            if let analyzerToCancel {
                await analyzerToCancel.cancelAndFinishNow()
            }
            for locale in localesToRelease {
                _ = await AssetInventory.release(
                    reservedLocale: locale
                )
            }
            finishStop()
        }
    }

    private func finishStop() {
        stateLock.lock()
        guard !stopCompleted else {
            stateLock.unlock()
            return
        }
        stopCompleted = true
        let completions = stopCompletions
        stopCompletions.removeAll()
        stateLock.unlock()
        DispatchQueue.main.async {
            completions.forEach { $0() }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func reportFailure(_ error: Error) {
        stateLock.lock()
        guard !stopped, !failureReported else {
            stateLock.unlock()
            return
        }
        failureReported = true
        stateLock.unlock()
        onFailure(error)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sampleRateRatio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(
                1,
                ceil(Double(buffer.frameLength) * sampleRateRatio) + 16
            )
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            return nil
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0 else {
            return nil
        }
        return output
    }
}

private enum WakeRecognitionError: LocalizedError {
    case noCompatibleAudioFormat
    case noCompatibleAudioConverter
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            "호출어 인식용 오디오 형식을 준비하지 못했어"
        case .noCompatibleAudioConverter:
            "호출어 인식용 오디오 변환기를 준비하지 못했어"
        case .audioConversionFailed:
            "호출어 인식용 오디오를 변환하지 못했어"
        }
    }
}

private struct WakeRecognitionStartError: LocalizedError {
    let stage: WakeAnalyzerStartStage
    let underlying: Error

    var errorDescription: String? {
        "\(stage.rawValue): \(underlying.localizedDescription)"
    }
}
