import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

struct WakeAudioChunk {
    let buffer: AVAudioPCMBuffer
    let span: WakeAudioFrameSpan
}

protocol WakeAudioBufferSource: AnyObject {
    var wakeAudioFormat: AVAudioFormat? { get }
    var wakeAudioFrameCursor: Int64 { get }

    @discardableResult
    func prepareWakeAudioCapture() -> Bool

    @discardableResult
    func beginWakeAudioRearm() -> Bool

    @discardableResult
    func beginWakeAudioDelivery(
        _ handler: @escaping (WakeAudioChunk) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool

    func endWakeAudioDelivery()
    func commitWakeAudioHandoff(
        recognizedThroughFrame: Int64
    ) -> WakeAudioHandoffTicket?
    func cancelWakeAudioHandoff()
}

private struct WakeCaptureCandidate: Equatable {
    let match: WakePhraseMatch
    let transcript: String
    let isFinal: Bool
    let laneIndex: Int
    let localeIdentifier: String
    let confidence: Float?
    let recognizedThroughFrame: Int64?
}

final class WakePhraseController {
    private static let logger = Logger(
        subsystem: "com.hyungchulc.voice-relay",
        category: "WakePhrase"
    )

    private let localeIdentifiers: [String]
    private let explicitLocaleIdentifier: String?
    private let recognizers: [SFSpeechRecognizer]
    private let phrases: [String]
    private let preferModernSpeechAnalyzer: Bool
    private let captureAdmission: (String) -> Bool
    private weak var externalAudioSource: WakeAudioBufferSource?
    private var legacyAudioEngine: AVAudioEngine?
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    private var completedLaneIndexes = Set<Int>()
    private var restartWorkItem: DispatchWorkItem?
    private var pendingWakeWorkItem: DispatchWorkItem?
    private var pendingWakeCandidate: WakeCaptureCandidate?
    private var pendingWakeCommitmentRevision =
        WakePhraseCommitmentRevision()
    private var wakeCandidates: [Int: WakeCaptureCandidate] = [:]
    private var modernStartTask: Task<Void, Never>?
    private var modernSession: AnyObject?
    private var modernCircuitProbeWorkItem: DispatchWorkItem?
    private var modernStabilityWorkItem: DispatchWorkItem?
    private var modernRotationWorkItem: DispatchWorkItem?
    private var retiredWakeAudioOwners: [AnyObject] = []
    private var wantsMonitoring = false
    private var permissionRequestInFlight = false
    private var recognitionGeneration = 0
    private var modernAnalyzerCircuit = WakeAnalyzerCircuitBreaker()
    private var modernTransientRetryCount = 0
    private var modernRuntimeRetryCount = 0
    private var captureStarted = false
    private var legacyUsesExternalAudioSource = false
    private var legacyExternalCaptureStartFrame: Int64?

    private(set) var isMonitoring = false
    var onWake: ((WakePhraseMatch, WakeActivationContext) -> Void)?
    var onWakeCandidate: (() -> Void)?
    var onState: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onCaptureDeferred: (() -> Void)?

    init(
        localeIdentifiers: [String],
        phrases: [String],
        explicitLocaleIdentifier: String? = nil,
        preferModernSpeechAnalyzer: Bool = true,
        externalAudioSource: WakeAudioBufferSource? = nil,
        captureAdmission: @escaping (String) -> Bool = { _ in true }
    ) {
        let resolved = SettingsStore.resolvedSpeechLocaleIdentifiers(
            localeIdentifiers
        )
        self.localeIdentifiers = resolved
        self.explicitLocaleIdentifier = explicitLocaleIdentifier
        recognizers = resolved.compactMap {
            SFSpeechRecognizer(locale: Locale(identifier: $0))
        }
        self.phrases = SettingsStore.normalizedWakePhrases(phrases)
        self.preferModernSpeechAnalyzer = preferModernSpeechAnalyzer
        self.externalAudioSource = externalAudioSource
        self.captureAdmission = captureAdmission
        Self.logger.info(
            "Wake configuration locales=\(resolved.joined(separator: ","), privacy: .public) phrase_count=\(self.phrases.count)"
        )
    }

    func startMonitoring(reason: String = "requested") {
        VoiceRelayDiagnostics.flow(
            "wake_monitor_start_requested",
            generation: recognitionGeneration,
            fields: [
                "already_monitoring": String(isMonitoring),
                "microphone_permission":
                    String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
                "phrase_count": String(phrases.count),
                "reason": reason,
                "speech_permission":
                    String(SFSpeechRecognizer.authorizationStatus().rawValue),
            ]
        )
        wantsMonitoring = true
        guard !isMonitoring,
              modernStartTask == nil,
              modernSession == nil,
              !permissionRequestInFlight else {
            VoiceRelayDiagnostics.flow(
                "wake_monitor_start_suppressed",
                generation: recognitionGeneration,
                fields: [
                    "reason": isMonitoring
                        ? "already_monitoring"
                        : "startup_already_in_progress",
                ]
            )
            return
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            startRecognitionIfPossible()
            return
        }
        requestPermissionsAndStart()
    }

    func pause(
        reason: String = "requested",
        cleanupCompletion: (() -> Void)? = nil
    ) {
        let hadPendingOrActiveWork =
            wantsMonitoring
            || isMonitoring
            || restartWorkItem != nil
            || pendingWakeWorkItem != nil
            || pendingWakeCandidate != nil
            || !wakeCandidates.isEmpty
            || modernStartTask != nil
            || modernSession != nil
            || captureStarted
            || legacyAudioEngine?.isRunning == true
            || !requests.isEmpty
            || !tasks.isEmpty
        wantsMonitoring = false
        guard hadPendingOrActiveWork else {
            cleanupCompletion?()
            return
        }
        stopRecognition(
            reason: reason,
            cleanupCompletion: cleanupCompletion
        )
    }

    private func requestPermissionsAndStart() {
        VoiceRelayDiagnostics.flow(
            "wake_permission_request_started",
            generation: recognitionGeneration,
            fields: ["reason": "wake_monitor_start"]
        )
        permissionRequestInFlight = true
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    self.permissionRequestInFlight = false
                    self.wantsMonitoring = false
                    VoiceRelayDiagnostics.flow(
                        "wake_permission_request_completed",
                        generation: self.recognitionGeneration,
                        fields: [
                            "granted": "false",
                            "permission": "speech_recognition",
                        ]
                    )
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
                        VoiceRelayDiagnostics.flow(
                            "wake_permission_request_completed",
                            generation: self.recognitionGeneration,
                            fields: [
                                "granted": "false",
                                "permission": "microphone",
                            ]
                        )
                        self.onError?("웨이크워드 마이크 권한이 필요해")
                        return
                    }
                    VoiceRelayDiagnostics.flow(
                        "wake_permission_request_completed",
                        generation: self.recognitionGeneration,
                        fields: [
                            "granted": "true",
                            "permission": "speech_and_microphone",
                        ]
                    )
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
        guard captureAdmission("backend_selection") else {
            VoiceRelayDiagnostics.flow(
                "wake_microphone_start_deferred",
                generation: recognitionGeneration,
                fields: ["reason": "external_audio_or_detector_unavailable"]
            )
            onCaptureDeferred?()
            return
        }
        let analyzerCircuitBlocksAttempt =
            modernAnalyzerCircuit.blocksAttempt()
        if #available(macOS 26.0, *),
           preferModernSpeechAnalyzer,
           !analyzerCircuitBlocksAttempt {
            VoiceRelayDiagnostics.flow(
                "wake_backend_selected",
                generation: recognitionGeneration,
                fields: [
                    "backend": "speech_analyzer",
                    "reason": modernAnalyzerCircuit.isOpen
                        ? "half_open_probe"
                        : "preferred_and_available",
                ]
            )
            startModernRecognitionIfPossible()
            return
        }
        VoiceRelayDiagnostics.flow(
            "wake_backend_selected",
            generation: recognitionGeneration,
            fields: [
                "backend": "legacy_speech",
                "reason": modernAnalyzerCircuit.isOpen
                    ? "speech_analyzer_circuit_open"
                    : "platform_or_preference",
            ]
        )
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
                VoiceRelayDiagnostics.flow(
                    "wake_backend_fallback",
                    generation: generation,
                    fields: [
                        "from": "speech_analyzer",
                        "reason": "no_supported_installed_locale",
                        "to": "legacy_speech",
                    ]
                )
                self.openModernAnalyzerCircuit(
                    stage: "locale_availability",
                    generation: generation
                )
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
        guard captureAdmission("speech_analyzer_start") else {
            VoiceRelayDiagnostics.flow(
                "wake_microphone_start_deferred",
                generation: generation,
                fields: [
                    "backend": "speech_analyzer",
                    "reason": "external_audio_or_detector_unavailable",
                ]
            )
            onCaptureDeferred?()
            return
        }
        VoiceRelayDiagnostics.flow(
            "wake_microphone_open_requested",
            generation: generation,
            fields: [
                "backend": "speech_analyzer",
                "input": AVCaptureDevice.default(for: .audio)?.localizedName
                    ?? "system_default_unknown",
                "input_selection": "macos_system_default",
                "locale_count": String(locales.count),
                "reason": "wake_monitoring",
            ]
        )
        let session = SpeechAnalyzerWakeSession(
            diagnosticGeneration: generation,
            locales: locales,
            phrases: phrases,
            externalAudioSource: externalAudioSource,
            onTranscript: {
                [weak self] laneIndex,
                localeIdentifier,
                transcript,
                isFinal,
                recognizedThroughFrame in
                DispatchQueue.main.async {
                    guard let self,
                          self.wantsMonitoring,
                          self.recognitionGeneration == generation else {
                        return
                    }
                    self.markModernAnalyzerHealthy(
                        generation: generation,
                        reason: "transcript_received"
                    )
                    _ = self.handleWakeTranscript(
                        transcript,
                        laneIndex: laneIndex,
                        localeIdentifier: localeIdentifier,
                        confidence: nil,
                        isFinal: isFinal,
                        recognizedThroughFrame: recognizedThroughFrame,
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
                        "SpeechAnalyzer runtime failed, restarting modern recognition: \(VoiceRelayDiagnostics.safe(error.localizedDescription), privacy: .public)"
                    )
                    VoiceRelayDiagnostics.flow(
                        "wake_backend_failed",
                        generation: generation,
                        fields: [
                            "backend": "speech_analyzer",
                            "error_code": String((error as NSError).code),
                            "error_domain": (error as NSError).domain,
                            "stage": "runtime",
                        ]
                    )
                    self.modernRuntimeRetryCount = min(
                        self.modernRuntimeRetryCount + 1,
                        WakeAnalyzerRuntimeRecoveryPolicy
                            .maximumTrackedFailures
                    )
                    let retryDelay =
                        WakeAnalyzerRuntimeRecoveryPolicy.retryDelay(
                            consecutiveFailures:
                                self.modernRuntimeRetryCount
                        )
                    self.restartAfterFullCleanup(
                        reason: "speech_analyzer_runtime_failure",
                        delay: retryDelay
                    )
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
                    self.modernCircuitProbeWorkItem?.cancel()
                    self.modernCircuitProbeWorkItem = nil
                    self.isMonitoring = true
                    self.captureStarted = true
                    self.scheduleModernAnalyzerStabilityCheck(
                        generation: generation
                    )
                    self.scheduleModernAnalyzerRotation(
                        generation: generation
                    )
                    VoiceRelayDiagnostics.flow(
                        "wake_microphone_started",
                        generation: generation,
                        fields: [
                            "backend": "speech_analyzer",
                            "input_selection": "macos_system_default",
                            "reason": "wake_monitoring",
                        ]
                    )
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
                        self.restartAfterFullCleanup(
                            reason: "speech_analyzer_start_retry",
                            delay: WakeAnalyzerRetryPolicy.retryDelay
                        )
                        return
                    }
                    Self.logger.error(
                        "SpeechAnalyzer start failed, using legacy fallback: \(VoiceRelayDiagnostics.safe(error.localizedDescription), privacy: .public)"
                    )
                    VoiceRelayDiagnostics.flow(
                        "wake_backend_failed",
                        generation: generation,
                        fields: [
                            "backend": "speech_analyzer",
                            "error_code": String((error as NSError).code),
                            "error_domain": (error as NSError).domain,
                            "stage": "startup",
                        ]
                    )
                    self.openModernAnalyzerCircuit(
                        stage: "startup",
                        generation: generation
                    )
                    self.restartAfterFullCleanup(
                        reason: "speech_analyzer_start_failure"
                    )
                }
            }
        }
    }

    private func startLegacyRecognitionIfPossible() {
        guard wantsMonitoring, !isMonitoring else { return }
        guard captureAdmission("legacy_speech_start") else {
            VoiceRelayDiagnostics.flow(
                "wake_microphone_start_deferred",
                generation: recognitionGeneration,
                fields: [
                    "backend": "legacy_speech",
                    "reason": "external_audio_or_detector_unavailable",
                ]
            )
            onCaptureDeferred?()
            return
        }
        let availableRecognizers = recognizers.filter {
            $0.isAvailable && $0.supportsOnDeviceRecognition
        }
        guard !availableRecognizers.isEmpty else {
            wantsMonitoring = false
            VoiceRelayDiagnostics.flow(
                "wake_backend_failed",
                generation: recognitionGeneration,
                fields: [
                    "backend": "legacy_speech",
                    "reason": "no_on_device_recognizer",
                    "stage": "startup",
                ]
            )
            onError?("선택한 언어는 이 Mac에서 로컬 웨이크워드를 사용할 수 없어")
            return
        }

        restartWorkItem?.cancel()
        recognitionGeneration += 1
        let generation = recognitionGeneration
        VoiceRelayDiagnostics.flow(
            "wake_microphone_open_requested",
            generation: generation,
            fields: [
                "backend": "legacy_speech",
                "input": AVCaptureDevice.default(for: .audio)?.localizedName
                    ?? "system_default_unknown",
                "input_selection": "macos_system_default",
                "locale_count": String(availableRecognizers.count),
                "reason": "wake_monitoring",
            ]
        )
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

        legacyUsesExternalAudioSource = false
        legacyExternalCaptureStartFrame = nil
        _ = externalAudioSource?.prepareWakeAudioCapture()
        let externalCaptureFormat = externalAudioSource?.wakeAudioFormat
        let captureFormat: AVAudioFormat
        if let externalCaptureFormat,
           externalAudioSource?.beginWakeAudioDelivery({
               [weak self] chunk in
               guard let self else { return }
               if self.legacyExternalCaptureStartFrame == nil {
                   self.legacyExternalCaptureStartFrame =
                       chunk.span.startFrame
               }
               self.requests.forEach { $0.append(chunk.buffer) }
           }, onFailure: { [weak self] in
               DispatchQueue.main.async {
                   guard let self,
                         self.wantsMonitoring,
                         self.recognitionGeneration == generation,
                         self.legacyUsesExternalAudioSource else {
                       return
                   }
                   self.restartAfterFullCleanup(
                       reason: "legacy_external_audio_source_failed",
                       delay: 0.15
                   )
               }
           }) == true {
            legacyUsesExternalAudioSource = true
            captureFormat = externalCaptureFormat
        } else {
            let audioEngine = AVAudioEngine()
            legacyAudioEngine = audioEngine
            let inputNode = audioEngine.inputNode
            captureFormat = inputNode.outputFormat(forBus: 0)
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
                audioEngine.stop()
                audioEngine.reset()
                legacyAudioEngine = nil
                requests.removeAll()
                wantsMonitoring = false
                VoiceRelayDiagnostics.flow(
                    "wake_backend_failed",
                    generation: generation,
                    fields: [
                        "backend": "legacy_speech",
                        "error_code": String((error as NSError).code),
                        "error_domain": (error as NSError).domain,
                        "stage": "audio_engine_start",
                    ]
                )
                onError?("웨이크워드 마이크를 시작하지 못했어")
                return
            }
        }
        VoiceRelayDiagnostics.flow(
            "wake_microphone_capture_configured",
            generation: generation,
            fields: [
                "backend": "legacy_speech",
                "channels": String(captureFormat.channelCount),
                "format": String(describing: captureFormat.commonFormat),
                "sample_rate": String(
                    format: "%.0f",
                    captureFormat.sampleRate
                ),
                "source": legacyUsesExternalAudioSource
                    ? "persistent_raw_wake_capture"
                    : "legacy_speech_engine",
            ]
        )

        isMonitoring = true
        captureStarted = true
        VoiceRelayDiagnostics.flow(
            "wake_microphone_started",
            generation: generation,
            fields: [
                "backend": "legacy_speech",
                "input_selection": "macos_system_default",
                "reason": "wake_monitoring",
            ]
        )
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
                    if let transcription = result?.bestTranscription {
                        let transcriptions = result?.transcriptions
                            ?? [transcription]
                        let transcript =
                            WakeTranscriptCandidatePolicy
                                .preferredWakeTranscript(
                                    transcripts: transcriptions.map(
                                        \.formattedString
                                    ),
                                    phrases: self.phrases
                                )
                        let selectedTranscription = transcriptions.first {
                            $0.formattedString == transcript
                        } ?? transcription
                        if self.handleWakeTranscript(
                            transcript,
                            laneIndex: laneIndex,
                            localeIdentifier:
                                recognizer.locale.identifier,
                            confidence: self.legacyConfidence(
                                selectedTranscription
                            ),
                            isFinal: result?.isFinal == true,
                            recognizedThroughFrame:
                                self.legacyRecognizedThroughFrame(
                                    selectedTranscription
                                ),
                            generation: generation
                        ) {
                            return
                        }
                    }

                    if error != nil || result?.isFinal == true {
                        self.completedLaneIndexes.insert(laneIndex)
                        if self.completedLaneIndexes.count == self.tasks.count {
                            self.stopRecognition(
                                reason: "legacy_recognition_cycle_completed"
                            )
                            self.wantsMonitoring = true
                            self.scheduleRestart()
                        }
                    }
                }
            }
        }
        scheduleModernAnalyzerProbeIfNeeded()
    }

    @discardableResult
    private func handleWakeTranscript(
        _ transcript: String,
        laneIndex: Int,
        localeIdentifier: String,
        confidence: Float?,
        isFinal: Bool,
        recognizedThroughFrame: Int64?,
        generation: Int
    ) -> Bool {
        guard wantsMonitoring,
              recognitionGeneration == generation else {
            return false
        }
        VoiceRelayDiagnostics.flow(
            "wake_transcript",
            generation: generation,
            fields: [
                "backend":
                    modernSession == nil ? "legacy_speech" : "speech_analyzer",
                "final": String(isFinal),
                "lane": String(laneIndex),
            ],
            transcriptFields: ["text": transcript]
        )
        let match = WakePhrasePolicy.match(
            transcript,
            phrases: phrases
        )
        VoiceRelayDiagnostics.flow(
            "wake_locale_lane_evaluated",
            generation: generation,
            fields: [
                "backend":
                    modernSession == nil ? "legacy_speech" : "speech_analyzer",
                "confidence": confidence.map { String($0) }
                    ?? "unavailable",
                "final": String(isFinal),
                "lane": String(laneIndex),
                "locale": localeIdentifier,
                "selection_reason": match == nil
                    ? "wake_phrase_not_matched"
                    : "wake_phrase_matched",
            ]
        )
        if let match {
            wakeCandidates[laneIndex] = WakeCaptureCandidate(
                match: match,
                transcript: transcript,
                isFinal: isFinal,
                laneIndex: laneIndex,
                localeIdentifier: localeIdentifier,
                confidence: confidence,
                recognizedThroughFrame: recognizedThroughFrame
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
            pendingWakeCommitmentRevision.invalidate()
            return false
        }
        let candidateChanged = candidate != pendingWakeCandidate
        if !candidateChanged, candidate.isFinal {
            return true
        }
        if candidateChanged {
            onWakeCandidate?()
        }

        pendingWakeWorkItem?.cancel()
        pendingWakeWorkItem = nil
        pendingWakeCandidate = candidate
        let commitmentRevision =
            pendingWakeCommitmentRevision.advance()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.recognitionGeneration == generation,
                  self.pendingWakeCommitmentRevision.isCurrent(
                      commitmentRevision
                  ),
                  self.pendingWakeCandidate == candidate else {
                return
            }
            self.wantsMonitoring = false
            Self.logger.notice(
                "Wake matched lane=\(candidate.laneIndex) phrase_count=\(self.phrases.count) final=\(candidate.isFinal) command_tail=\(!candidate.match.command.isEmpty) command_length=\(candidate.match.command.count)"
            )
            VoiceRelayDiagnostics.flow(
                "wake_accepted",
                generation: generation,
                fields: [
                    "backend":
                        self.modernSession == nil
                            ? "legacy_speech"
                            : "speech_analyzer",
                    "final": String(candidate.isFinal),
                    "lane": String(candidate.laneIndex),
                    "reason": candidate.match.command.isEmpty
                        ? "wake_only"
                        : "wake_with_command",
                ],
                transcriptFields: [
                    "command": candidate.match.command,
                    "text": candidate.transcript,
                ]
            )
            let handoffTicket = candidate.recognizedThroughFrame.flatMap {
                self.externalAudioSource?.commitWakeAudioHandoff(
                    recognizedThroughFrame: $0
                )
            }
            let localeSelection = SpokenLocaleSelectionPolicy.resolve(
                explicitOverrideIdentifier: self.explicitLocaleIdentifier,
                laneEvidence: self.wakeCandidates.values.map {
                    RecognitionLocaleEvidence(
                        laneIndex: $0.laneIndex,
                        localeIdentifier: $0.localeIdentifier,
                        confidence: $0.confidence,
                        isFinal: $0.isFinal
                    )
                },
                activationWakeLocaleIdentifier: candidate.localeIdentifier,
                configuredPrimaryLocaleIdentifier:
                    self.localeIdentifiers.first ?? "",
                configuredSupportedLocaleIdentifiers:
                    self.localeIdentifiers
            )
            VoiceRelayDiagnostics.flow(
                "wake_locale_selected",
                generation: generation,
                fields: [
                    "confidence": localeSelection.confidence.map { String($0) }
                        ?? "unavailable",
                    "final": localeSelection.isFinal.map { String($0) }
                        ?? "unavailable",
                    "lane": localeSelection.laneIndex.map { String($0) }
                        ?? "unavailable",
                    "locale": localeSelection.localeIdentifier
                        ?? "unavailable",
                    "selection_reason": localeSelection.reason.rawValue,
                ]
            )
            let activation = WakeActivationContext(
                activationID: UUID().uuidString,
                commandText: WakeRealtimePrefillPolicy.prefill(
                    command: candidate.match.command
                ),
                recognizedUtteranceText:
                    WakeDisplayTranscriptPolicy.visibleText(
                        recognizedText: candidate.transcript
                ),
                wakeLocaleIdentifier: candidate.localeIdentifier,
                spokenLocaleIdentifier:
                    localeSelection.localeIdentifier ?? "",
                spokenLocaleSelectionReason: localeSelection.reason,
                spokenLocaleLaneIndex: localeSelection.laneIndex,
                spokenLocaleConfidence: localeSelection.confidence,
                spokenLocaleIsFinal: localeSelection.isFinal,
                handoffTicketID: handoffTicket?.id
            )
            self.stopRecognition(
                reason: "wake_handoff",
                completion: { [weak self] in
                    guard let self, !self.wantsMonitoring else { return }
                    VoiceRelayDiagnostics.flow(
                        "wake_cleanup_barrier_released",
                        generation: generation,
                        fields: [
                            "handoff": handoffTicket == nil
                                ? "unavailable"
                                : "committed",
                            "next": "realtime_start",
                        ]
                    )
                    self.onWake?(
                        candidate.match,
                        activation
                    )
                }
            )
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

    private func legacyRecognizedThroughFrame(
        _ transcription: SFTranscription
    ) -> Int64? {
        guard let startFrame = legacyExternalCaptureStartFrame,
              let end = transcription.segments
                .map({ $0.timestamp + $0.duration })
                .max() else {
            return nil
        }
        return startFrame
            + Int64(
                (end * Double(WakeAudioHandoffJournal.sampleRate))
                    .rounded(.up)
            )
    }

    private func legacyConfidence(
        _ transcription: SFTranscription
    ) -> Float? {
        let calibrated = transcription.segments
            .map(\.confidence)
            .filter { $0 > 0 && $0.isFinite }
        guard !calibrated.isEmpty else { return nil }
        return calibrated.reduce(0, +) / Float(calibrated.count)
    }

    private func stopRecognition(
        reason: String,
        completion: (() -> Void)? = nil,
        cleanupCompletion: (() -> Void)? = nil
    ) {
        let stoppedGeneration = recognitionGeneration
        let backend = modernSession == nil
            ? "legacy_speech"
            : "speech_analyzer"
        let hadActiveCapture = captureStarted
        captureStarted = false
        VoiceRelayDiagnostics.flow(
            "wake_monitor_stop_requested",
            generation: stoppedGeneration,
            fields: [
                "backend": backend,
                "capture_active": String(hadActiveCapture),
                "legacy_tasks": String(tasks.count),
                "modern_active": String(modernSession != nil),
                "reason": reason,
            ]
        )
        restartWorkItem?.cancel()
        restartWorkItem = nil
        modernCircuitProbeWorkItem?.cancel()
        modernCircuitProbeWorkItem = nil
        modernStabilityWorkItem?.cancel()
        modernStabilityWorkItem = nil
        modernRotationWorkItem?.cancel()
        modernRotationWorkItem = nil
        pendingWakeWorkItem?.cancel()
        pendingWakeWorkItem = nil
        pendingWakeCandidate = nil
        pendingWakeCommitmentRevision.invalidate()
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
            VoiceRelayDiagnostics.flow(
                "wake_microphone_stopped",
                generation: stoppedGeneration,
                fields: [
                    "backend": backend,
                    "capture_was_active": String(hadActiveCapture),
                    "reason": reason,
                ]
            )
            completion?()
        }
        if legacyUsesExternalAudioSource {
            externalAudioSource?.endWakeAudioDelivery()
            legacyUsesExternalAudioSource = false
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
            modernWakeSession.stop(
                completion: finish,
                cleanupCompletion: { [weak self, modernWakeSession] in
                    guard let self else {
                        cleanupCompletion?()
                        return
                    }
                    self.retireWakeAudioOwner(
                        modernWakeSession,
                        completion: cleanupCompletion
                    )
                }
            )
        } else {
            modernSession = nil
            let audioEngine = legacyAudioEngine
            legacyAudioEngine = nil
            if let audioEngine {
                if audioEngine.isRunning {
                    audioEngine.stop()
                }
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.reset()
            }
            finish()
            if let audioEngine {
                retireWakeAudioOwner(
                    audioEngine,
                    completion: cleanupCompletion
                )
            } else {
                cleanupCompletion?()
            }
        }
    }

    private func openModernAnalyzerCircuit(
        stage: String,
        generation: Int
    ) {
        let changed = modernAnalyzerCircuit.open(stage: stage)
        VoiceRelayDiagnostics.flow(
            "wake_backend_circuit_opened",
            generation: generation,
            fields: [
                "backend": "speech_analyzer",
                "changed": changed ? "true" : "false",
                "fallback": "legacy_speech",
                "stage": stage,
            ]
        )
    }

    private func scheduleRestart(delay: TimeInterval = 0.8) {
        guard wantsMonitoring else { return }
        VoiceRelayDiagnostics.flow(
            "wake_monitor_restart_scheduled",
            generation: recognitionGeneration,
            fields: [
                "delay_ms": String(Int(delay * 1_000)),
                "reason": modernAnalyzerCircuit.isOpen
                    ? "speech_analyzer_circuit_open"
                    : "recognition_cycle",
            ]
        )
        let item = DispatchWorkItem { [weak self] in
            self?.startRecognitionIfPossible()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private func scheduleModernAnalyzerProbeIfNeeded() {
        guard #available(macOS 26.0, *),
              wantsMonitoring,
              preferModernSpeechAnalyzer,
              let delay = modernAnalyzerCircuit.remainingCooldown() else {
            return
        }
        modernCircuitProbeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.modernCircuitProbeWorkItem = nil
            guard self.wantsMonitoring,
                  self.modernAnalyzerCircuit.isOpen,
                  !self.modernAnalyzerCircuit.blocksAttempt() else {
                return
            }
            VoiceRelayDiagnostics.flow(
                "wake_backend_half_open_probe",
                generation: self.recognitionGeneration,
                fields: [
                    "backend": "speech_analyzer",
                    "fallback": "legacy_speech",
                ]
            )
            if self.isMonitoring {
                self.stopRecognition(
                    reason: "speech_analyzer_half_open_probe",
                    cleanupCompletion: { [weak self] in
                        guard let self, self.wantsMonitoring else { return }
                        self.startRecognitionIfPossible()
                    }
                )
            } else {
                self.startRecognitionIfPossible()
            }
        }
        modernCircuitProbeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.05, delay),
            execute: item
        )
    }

    private func scheduleModernAnalyzerStabilityCheck(
        generation: Int
    ) {
        modernStabilityWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.recognitionGeneration == generation,
                  self.modernSession != nil else {
                return
            }
            self.closeModernAnalyzerCircuit(
                generation: generation,
                reason: "stable_runtime"
            )
        }
        modernStabilityWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 30,
            execute: item
        )
    }

    private func scheduleModernAnalyzerRotation(
        generation: Int
    ) {
        modernRotationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.recognitionGeneration == generation,
                  self.modernSession != nil else {
                return
            }
            VoiceRelayDiagnostics.flow(
                "wake_backend_rotation_started",
                generation: generation,
                fields: [
                    "backend": "speech_analyzer",
                    "reason": "bounded_session_lifetime",
                ]
            )
            self.markModernAnalyzerHealthy(
                generation: generation,
                reason: "completed_bounded_session"
            )
            self.restartAfterFullCleanup(
                reason: "speech_analyzer_session_rotation",
                delay: 0.05
            )
        }
        modernRotationWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + WakeAnalyzerSessionPolicy.maximumContinuousDuration,
            execute: item
        )
    }

    private func restartAfterFullCleanup(
        reason: String,
        delay: TimeInterval = 0.8
    ) {
        guard wantsMonitoring else { return }
        let rearmContinuityStarted =
            externalAudioSource?.beginWakeAudioRearm() ?? false
        VoiceRelayDiagnostics.flow(
            "wake_audio_rearm_started",
            generation: recognitionGeneration,
            fields: [
                "reason": reason,
                "status": rearmContinuityStarted
                    ? "buffering"
                    : "unavailable",
            ]
        )
        let expectedGeneration = recognitionGeneration + 1
        stopRecognition(
            reason: reason,
            cleanupCompletion: { [weak self] in
                guard let self,
                      self.wantsMonitoring,
                      self.recognitionGeneration == expectedGeneration else {
                    return
                }
                self.scheduleRestart(delay: delay)
            }
        )
    }

    private func markModernAnalyzerHealthy(
        generation: Int,
        reason: String
    ) {
        modernRuntimeRetryCount = 0
        modernStabilityWorkItem?.cancel()
        modernStabilityWorkItem = nil
        closeModernAnalyzerCircuit(
            generation: generation,
            reason: reason
        )
    }

    private func closeModernAnalyzerCircuit(
        generation: Int,
        reason: String
    ) {
        guard modernAnalyzerCircuit.close() else { return }
        VoiceRelayDiagnostics.flow(
            "wake_backend_circuit_closed",
            generation: generation,
            fields: [
                "backend": "speech_analyzer",
                "reason": reason,
            ]
        )
    }

    private func retireWakeAudioOwner(
        _ owner: AnyObject,
        completion: (() -> Void)?
    ) {
        retiredWakeAudioOwners.append(owner)
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + WakeAudioHandoffPolicy.retiredEngineReleaseDelay
        ) { [weak self, weak owner] in
            guard let self else {
                completion?()
                return
            }
            if let owner {
                self.retiredWakeAudioOwners.removeAll { $0 === owner }
            } else {
                self.retiredWakeAudioOwners.removeAll()
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now()
                    + WakeAudioHandoffPolicy.postReleaseSettleDelay
            ) {
                completion?()
            }
        }
    }

    private static func localeKey(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

@available(macOS 26.0, *)
private final class SpeechAnalyzerWakeSession {
    private let diagnosticGeneration: Int
    private let locales: [Locale]
    private let phrases: [String]
    private weak var externalAudioSource: WakeAudioBufferSource?
    private let onTranscript: (
        Int,
        String,
        String,
        Bool,
        Int64?
    ) -> Void
    private let onFailure: (Error) -> Void
    private let audioEngine = AVAudioEngine()
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var startupTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var reservedLocales: [Locale] = []
    private var audioConfigurationObserver: NSObjectProtocol?
    private var configurationRecoveryNotBefore: TimeInterval = 0
    private var stopped = false
    private var audioReleaseCompleted = false
    private var audioReleaseCompletions: [() -> Void] = []
    private var cleanupCompleted = false
    private var cleanupCompletions: [() -> Void] = []
    private var failureReported = false
    private var usesExternalAudioSource = false
    private var analyzerInputTimeline = WakeAnalyzerInputTimeline()
    private var droppedAnalyzerInputCount = 0
    private var externalCaptureStartFrame: Int64?

    init(
        diagnosticGeneration: Int,
        locales: [Locale],
        phrases: [String],
        externalAudioSource: WakeAudioBufferSource?,
        onTranscript: @escaping (
            Int,
            String,
            String,
            Bool,
            Int64?
        ) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.diagnosticGeneration = diagnosticGeneration
        self.locales = locales
        self.phrases = phrases
        self.externalAudioSource = externalAudioSource
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.markStartupFinished() }
            var startupStage = WakeAnalyzerStartStage.assetReservation
            do {
                for locale in locales {
                    _ = try await AssetInventory.reserve(locale: locale)
                    let accepted = self.stateLock.withLock {
                        guard !self.stopped else { return false }
                        self.reservedLocales.append(locale)
                        return true
                    }
                    if !accepted {
                        _ = await AssetInventory.release(
                            reservedLocale: locale
                        )
                        return
                    }
                }
                let transcribers = locales.map {
                    DictationTranscriber(
                        locale: $0,
                        contentHints: [.shortForm, .farField],
                        transcriptionOptions: [],
                        reportingOptions: [
                            .volatileResults,
                            .frequentFinalization,
                        ],
                        attributeOptions: []
                    )
                }
                let modules: [any SpeechModule] = transcribers
                _ = externalAudioSource?.prepareWakeAudioCapture()
                let externalNaturalFormat =
                    externalAudioSource?.wakeAudioFormat
                let naturalFormat = externalNaturalFormat
                    ?? audioEngine.inputNode.outputFormat(forBus: 0)
                guard let analysisFormat =
                    await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: modules,
                        considering: naturalFormat
                    ) else {
                    throw WakeRecognitionError.noCompatibleAudioFormat
                }
                VoiceRelayDiagnostics.flow(
                    "wake_microphone_capture_configured",
                    generation: diagnosticGeneration,
                    fields: [
                        "analysis_channels":
                            String(analysisFormat.channelCount),
                        "analysis_format":
                            String(describing: analysisFormat.commonFormat),
                        "analysis_sample_rate": String(
                            format: "%.0f",
                            analysisFormat.sampleRate
                        ),
                        "backend": "speech_analyzer",
                        "conversion": String(
                            !naturalFormat.isEqual(analysisFormat)
                        ),
                        "natural_channels":
                            String(naturalFormat.channelCount),
                        "natural_format":
                            String(describing: naturalFormat.commonFormat),
                        "natural_sample_rate": String(
                            format: "%.0f",
                            naturalFormat.sampleRate
                        ),
                    ]
                )

                let context = AnalysisContext()
                context.contextualStrings[.general] = phrases
                let analyzer = SpeechAnalyzer(
                    modules: modules,
                    options: .init(
                        priority: .high,
                        modelRetention: .whileInUse
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
                        bufferingPolicy: .bufferingNewest(
                            WakeAnalyzerInputPolicy.bufferCapacity
                        )
                )
                let analyzerResultTasks = transcribers.enumerated().map {
                    laneIndex, transcriber in
                    Task { [weak self] in
                        var reducer =
                            SpeechAnalyzerWakeTranscriptReducer()
                        do {
                            for try await result in transcriber.results {
                                guard let self, !self.isStopped else { return }
                                let text = String(result.text.characters)
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                let rangeStart = CMTimeGetSeconds(
                                    result.range.start
                                )
                                let rangeEnd = CMTimeGetSeconds(
                                    CMTimeRangeGetEnd(result.range)
                                )
                                let emission = reducer.ingest(
                                    text: text,
                                    start: rangeStart,
                                    end: rangeEnd,
                                    phrases: self.phrases
                                )
                                VoiceRelayDiagnostics.flow(
                                    "wake_transcript_result",
                                    generation: self.diagnosticGeneration,
                                    fields: [
                                        "candidate":
                                            emission == nil
                                                ? "false"
                                                : "true",
                                        "final": String(result.isFinal),
                                        "lane": String(laneIndex),
                                        "range_end_ms":
                                            Self.milliseconds(rangeEnd),
                                        "range_start_ms":
                                            Self.milliseconds(rangeStart),
                                        "scope":
                                            emission == nil
                                                ? "current_result"
                                                : "wake_anchored",
                                        "segment_count":
                                            String(
                                                emission?.segmentCount ?? 0
                                            ),
                                    ]
                                )
                                guard let emission else { continue }
                                let recognizedThroughFrame =
                                    self.stateLock.withLock {
                                        self.externalCaptureStartFrame.map {
                                            $0 + Int64(
                                                (
                                                    emission.audioEndSeconds
                                                        * Double(
                                                            WakeAudioHandoffJournal
                                                                .sampleRate
                                                        )
                                                ).rounded(.up)
                                            )
                                        }
                                    }
                                self.onTranscript(
                                    laneIndex,
                                    self.locales[laneIndex].identifier,
                                    emission.transcript,
                                    result.isFinal,
                                    recognizedThroughFrame
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

                    let consumeBuffer: (
                        AVAudioPCMBuffer,
                        WakeAudioFrameSpan?
                    ) -> Void = {
                        [weak self] buffer, sourceSpan in
                        guard let self else { return }
                        if let sourceSpan {
                            self.stateLock.withLock {
                                if self.externalCaptureStartFrame == nil {
                                    self.externalCaptureStartFrame =
                                        sourceSpan.startFrame
                                }
                            }
                        }
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
                        self.yieldAnalyzerInput(
                            analyzerBuffer,
                            sampleRate: analysisFormat.sampleRate
                        )
                    }
                    let usesExternalAudioSource =
                        self.externalAudioSource?
                            .beginWakeAudioDelivery(
                                { chunk in
                                    consumeBuffer(
                                        chunk.buffer,
                                        chunk.span
                                    )
                                },
                                onFailure: { [weak self] in
                                    self?.reportFailure(
                                        WakeRecognitionError
                                            .audioConfigurationChanged
                                    )
                                }
                            )
                        == true
                    self.usesExternalAudioSource =
                        usesExternalAudioSource
                    if !usesExternalAudioSource {
                        let inputNode = self.audioEngine.inputNode
                        inputNode.removeTap(onBus: 0)
                        inputNode.installTap(
                            onBus: 0,
                            bufferSize: 1024,
                            format: nil
                        ) { buffer, _ in
                            consumeBuffer(buffer, nil)
                        }
                        startupStage = .audioEngineStart
                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                        self.configurationRecoveryNotBefore =
                            ProcessInfo.processInfo.systemUptime + 1.5
                        self.observeAudioConfigurationChanges()
                    }
                    self.analysisTask = Task { [weak self] in
                        do {
                            try await analyzer.start(
                                inputSequence: inputStream
                            )
                        } catch {
                            self?.reportFailure(error)
                        }
                    }
                    VoiceRelayDiagnostics.flow(
                        "wake_audio_source_bound",
                        generation: self.diagnosticGeneration,
                        fields: [
                            "source": usesExternalAudioSource
                                ? "persistent_raw_wake_capture"
                                : "speech_analyzer_engine",
                        ]
                    )
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
        stateLock.withLock {
            startupTask = task
            if stopped {
                task.cancel()
            }
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "unavailable" }
        return String(Int(max(0, seconds * 1_000)))
    }

    func stop(
        completion: @escaping () -> Void = {},
        cleanupCompletion: @escaping () -> Void = {}
    ) {
        stateLock.lock()
        if audioReleaseCompleted {
            let alreadyCleanedUp = cleanupCompleted
            if !alreadyCleanedUp {
                cleanupCompletions.append(cleanupCompletion)
            }
            stateLock.unlock()
            DispatchQueue.main.async(execute: completion)
            if alreadyCleanedUp {
                DispatchQueue.main.async(execute: cleanupCompletion)
            }
            return
        }
        audioReleaseCompletions.append(completion)
        cleanupCompletions.append(cleanupCompletion)
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let startupTaskToAwait = startupTask
        stateLock.unlock()

        let stopStartedAt = ProcessInfo.processInfo.systemUptime
        VoiceRelayDiagnostics.flow(
            "wake_audio_capture_release_started",
            generation: diagnosticGeneration,
            fields: ["backend": "speech_analyzer"]
        )
        lifecycleLock.withLock {
            removeAudioConfigurationObserver()
            let hadExternalAudioSource = usesExternalAudioSource
            if hadExternalAudioSource {
                externalAudioSource?.endWakeAudioDelivery()
                usesExternalAudioSource = false
            }
            inputContinuation?.finish()
            inputContinuation = nil
            analysisTask?.cancel()
            analysisTask = nil
            resultTasks.forEach { $0.cancel() }
            resultTasks.removeAll()
            if !hadExternalAudioSource {
                if audioEngine.isRunning {
                    audioEngine.stop()
                }
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
        VoiceRelayDiagnostics.flow(
            "wake_audio_capture_released",
            generation: diagnosticGeneration,
            fields: [
                "backend": "speech_analyzer",
                "elapsed_ms": Self.elapsedMilliseconds(
                    since: stopStartedAt
                ),
            ]
        )
        finishAudioRelease()
        Task { [self] in
            await startupTaskToAwait?.value
            let cleanupState = stateLock.withLock {
                let analyzerToCancel = analyzer
                analyzer = nil
                let localesToRelease = reservedLocales
                reservedLocales.removeAll()
                return (analyzerToCancel, localesToRelease)
            }
            let analyzerToCancel = cleanupState.0
            let localesToRelease = cleanupState.1
            if let analyzerToCancel {
                await analyzerToCancel.cancelAndFinishNow()
            }
            VoiceRelayDiagnostics.flow(
                "wake_analyzer_cancel_completed",
                generation: diagnosticGeneration,
                fields: [
                    "elapsed_ms": Self.elapsedMilliseconds(
                        since: stopStartedAt
                    )
                ]
            )
            for locale in localesToRelease {
                _ = await AssetInventory.release(
                    reservedLocale: locale
                )
            }
            VoiceRelayDiagnostics.flow(
                "wake_asset_release_completed",
                generation: diagnosticGeneration,
                fields: [
                    "elapsed_ms": Self.elapsedMilliseconds(
                        since: stopStartedAt
                    ),
                    "locale_count": String(localesToRelease.count),
                ]
            )
            finishCleanup(startedAt: stopStartedAt)
        }
    }

    private func markStartupFinished() {
        stateLock.withLock {
            startupTask = nil
        }
    }

    private func observeAudioConfigurationChanges() {
        removeAudioConfigurationObserver()
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            guard let self,
                  ProcessInfo.processInfo.systemUptime
                    >= self.configurationRecoveryNotBefore else {
                return
            }
            self.reportFailure(
                WakeRecognitionError.audioConfigurationChanged
            )
        }
    }

    private func removeAudioConfigurationObserver() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(
                audioConfigurationObserver
            )
        }
        audioConfigurationObserver = nil
    }

    private func finishAudioRelease() {
        stateLock.lock()
        guard !audioReleaseCompleted else {
            stateLock.unlock()
            return
        }
        audioReleaseCompleted = true
        let completions = audioReleaseCompletions
        audioReleaseCompletions.removeAll()
        stateLock.unlock()
        DispatchQueue.main.async {
            completions.forEach { $0() }
        }
    }

    private func finishCleanup(startedAt: TimeInterval) {
        stateLock.lock()
        guard !cleanupCompleted else {
            stateLock.unlock()
            return
        }
        cleanupCompleted = true
        let completions = cleanupCompletions
        cleanupCompletions.removeAll()
        stateLock.unlock()
        VoiceRelayDiagnostics.flow(
            "wake_cleanup_completed",
            generation: diagnosticGeneration,
            fields: [
                "elapsed_ms": Self.elapsedMilliseconds(
                    since: startedAt
                )
            ]
        )
        DispatchQueue.main.async {
            completions.forEach { $0() }
        }
    }

    private static func elapsedMilliseconds(
        since startedAt: TimeInterval
    ) -> String {
        String(
            Int(
                max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - startedAt)
                        * 1_000
                )
            )
        )
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

    private func yieldAnalyzerInput(
        _ buffer: AVAudioPCMBuffer,
        sampleRate: Double
    ) {
        let inputState = stateLock.withLock {
            () -> (
                AsyncStream<AnalyzerInput>.Continuation,
                AVAudioFramePosition
            )? in
            guard !stopped, let inputContinuation else { return nil }
            let startFrame = analyzerInputTimeline.consume(
                frameCount: Int(buffer.frameLength)
            )
            return (inputContinuation, startFrame)
        }
        guard let (continuation, startFrame) = inputState else { return }
        let timeScale = CMTimeScale(
            max(
                1,
                min(
                    Double(Int32.max),
                    sampleRate.rounded()
                )
            )
        )
        let result = continuation.yield(
            AnalyzerInput(
                buffer: buffer,
                bufferStartTime: CMTime(
                    value: CMTimeValue(startFrame),
                    timescale: timeScale
                )
            )
        )
        switch result {
        case .enqueued:
            break
        case .dropped:
            let droppedCount = stateLock.withLock {
                droppedAnalyzerInputCount += 1
                return droppedAnalyzerInputCount
            }
            if droppedCount == 1
                || droppedCount.isMultiple(of: 8) {
                VoiceRelayDiagnostics.flow(
                    "wake_analyzer_input_dropped",
                    generation: diagnosticGeneration,
                    fields: [
                        "drop_count": String(droppedCount),
                        "input_start_frame": String(startFrame),
                    ]
                )
            }
            if WakeAnalyzerInputPolicy.shouldRestart(
                afterDroppedInputCount: droppedCount
            ) {
                reportFailure(
                    WakeRecognitionError.analyzerInputBackpressure
                )
            }
        case .terminated:
            if !isStopped {
                reportFailure(
                    WakeRecognitionError.analyzerInputTerminated
                )
            }
        @unknown default:
            reportFailure(
                WakeRecognitionError.analyzerInputTerminated
            )
        }
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
    case audioConfigurationChanged
    case analyzerInputBackpressure
    case analyzerInputTerminated

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            "호출어 인식용 오디오 형식을 준비하지 못했어"
        case .noCompatibleAudioConverter:
            "호출어 인식용 오디오 변환기를 준비하지 못했어"
        case .audioConversionFailed:
            "호출어 인식용 오디오를 변환하지 못했어"
        case .audioConfigurationChanged:
            "호출어 인식 중 오디오 장치 구성이 바뀌었어"
        case .analyzerInputBackpressure:
            "호출어 인식 입력 처리가 오디오 속도를 따라가지 못했어"
        case .analyzerInputTerminated:
            "호출어 인식 입력 스트림이 예기치 않게 종료됐어"
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
