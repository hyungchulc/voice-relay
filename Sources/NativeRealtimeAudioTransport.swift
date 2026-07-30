import AVFoundation
import CoreAudio
import Foundation
import OSLog

private enum AudioLifecycleError: Error {
    case startCancelled
}

final class NativeRealtimeAudioTransport: NSObject, WakeAudioBufferSource {
    typealias JSONDictionary = [String: Any]

    private static let logger = Logger(
        subsystem: "com.hyungchulc.voice-relay",
        category: "NativeRealtimeAudio"
    )

    struct DiagnosticSnapshot {
        let stage: String
        let generation: Int
        let capturedChunks: Int
        let sentChunks: Int
        let receivedChunks: Int
        let renderedChunks: Int
        let droppedCaptureChunks: Int
        let suppressedEchoChunks: Int
        let voiceProcessingEnabled: Bool
    }

    var onSocketOpen: ((Int) -> Void)?
    var onListeningReady: ((Int) -> Void)?
    var onEvent: ((Int, JSONDictionary) -> Void)?
    var onInputLevel: ((Int, CGFloat) -> Void)?
    var onPlaybackDrained: ((Int, String) -> Void)?
    var onDiagnostic: ((DiagnosticSnapshot) -> Void)?
    var onError: ((Int, String) -> Void)?
    var onClosed: ((Int) -> Void)?

    private struct OutboundMessage {
        let text: String
        let isAudio: Bool
    }

    private struct PlaybackChunk {
        let data: Data
        let responseID: String
        let itemID: String
        let contentIndex: Int

        var frameCount: Int {
            data.count / MemoryLayout<Int16>.size
        }
    }

    private let stateQueue = DispatchQueue(
        label: "VoiceRelay.NativeRealtimeAudioTransport.state"
    )
    private let audioProcessingQueue = DispatchQueue(
        label: "VoiceRelay.NativeRealtimeAudioTransport.capture",
        qos: .userInitiated
    )
    private let captureLock = NSLock()
    private let lifecycleSignalLock = NSLock()
    private var audioStartCancellation = AudioStartCancellationState()
    private var captureRoutingEpoch = AudioCaptureRoutingEpoch()
    private var captureTimingHealth = AudioCaptureTimingHealth()

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var activeGeneration: Int?
    private var socketOpen = false
    private var sessionUpdated = false
    private var listeningReadyReported = false
    private var stopping = false
    private var openTimeout: DispatchWorkItem?

    private var outboundQueue: [OutboundMessage] = []
    private var sendInFlight = false
    private let maximumOutboundMessages = 96

    private var audioEngine: AVAudioEngine?
    private var retiredAudioEngines: [AVAudioEngine] = []
    private var playerNode: AVAudioPlayerNode?
    private var wakeAudioConsumer: ((AVAudioPCMBuffer) -> Void)?
    private var wakeAudioFailureHandler: (() -> Void)?
    private var wakeAudioHealthWorkItem: DispatchWorkItem?
    private var wakeAudioHealthToken: UInt64 = 0
    private var wakeDeliveredChunks = 0
    private let wakeAudioHealthInterval: TimeInterval = 1.0
    private var voiceProcessingEnabled = false
    private var captureTapInstalled = false
    private var playbackReferenceTapInstalled = false
    private var audioConfigurationObserver: NSObjectProtocol?
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioRecoveryStableWorkItem: DispatchWorkItem?
    private var audioRecoveryAttempts = 0
    private let maximumAudioRecoveryAttempts = 3
    private var audioConfigurationRecoveryPolicy =
        AudioConfigurationRecoveryPolicy()
    private var audioConfigurationRecoveryNotBefore: TimeInterval = 0
    private let audioConfigurationStartupGrace: TimeInterval = 2.0
    private var audioRecoveryStableCapturedBaseline = 0
    private var audioRecoveryStableRenderedBaseline = 0
    private var captureSlotsInUse = 0
    private let maximumCaptureSlots = 8
    private var pendingPCM = Data()
    private var pendingBargeInPCM = Data()
    private let inputChunkFrames = 720
    private let maximumBargeInPrerollBytes =
        Int(RealtimeEchoAdmissionPolicy.sampleRate * 0.65)
            * MemoryLayout<Int16>.size

    private var queuedPlaybackFrames = 0
    private let maximumQueuedPlaybackFrames = 24_000 * 120
    private var scheduledPlaybackBuffers = 0
    private var playbackBuffersByResponseID: [String: Int] = [:]
    private var completedAudioResponseIDs: Set<String> = []
    private var drainedAudioResponseIDs: Set<String> = []
    private var discardedAudioResponseIDs: Set<String> = []
    private var truncatableResponseIDs: Set<String> = []
    private var backpressureReportedResponseIDs: Set<String> = []
    private var playbackToken = 0
    private var provisionalPauseToken = 0
    private var playbackProvisionallyPaused = false
    private let systemMediaPlaybackDetector =
        SystemMediaPlaybackDetector()
    private var playbackOverlapPolicy =
        AssistantPlaybackOverlapPolicy()
    private var playbackOverlapWorkItem: DispatchWorkItem?
    private var playbackExternallyPaused = false
    private var activePlaybackResponseID = ""
    private var activePlaybackItemID = ""
    private var activePlaybackContentIndex = 0
    private var activePlaybackCanTruncate = false
    private var activePlaybackStartSampleTime: AVAudioFramePosition?
    private var activePlaybackStartedAt: Date?
    private var activePlaybackScheduledFrames = 0
    private var controlEventSequence: UInt64 = 0
    private var mediaEpoch = 0
    private var audioAdmissionPolicy = RealtimeAudioAdmissionPolicy()
    private var pendingAudioPreemptionPolicy =
        RealtimePendingAudioPreemptionPolicy()
    private var echoAdmissionPolicy = RealtimeEchoAdmissionPolicy()

    private var capturedChunks = 0
    private var sentChunks = 0
    private var receivedChunks = 0
    private var renderedChunks = 0
    private var droppedCaptureChunks = 0
    private var suppressedEchoChunks = 0
    private var lastProgressDiagnosticAt = Date.distantPast
    private var lastReportedDroppedChunks = 0
    private var lastCaptureClassification = ""

    func start(
        generation: Int,
        model: String,
        ephemeralCredential: String
    ) {
        markStartRequested(generation: generation)
        stateQueue.async {
            guard !self.isStartCancelled(generation: generation) else {
                self.emitOnMain {
                    self.onClosed?(generation)
                }
                return
            }
            VoiceRelayDiagnostics.flow(
                "realtime_transport_start_requested",
                generation: generation,
                fields: [
                    "audio_route": "macos_system_default",
                    "credential_present": String(!ephemeralCredential.isEmpty),
                    "model": model,
                    "reason": "realtime_session",
                ]
            )
            if self.activeGeneration != generation {
                let hasPriorTransport =
                    self.activeGeneration != nil
                    || self.webSocketTask != nil
                    || self.urlSession != nil
                    || self.socketOpen
                    || self.sessionUpdated
                if hasPriorTransport {
                    self.stopCurrent(
                        emitClosed: false,
                        reason: "generation_replaced",
                        preserveCaptureForWake: true
                    )
                }
                self.advanceCaptureRoutingEpoch()
                self.cancelWakeAudioHealthCheck()
                self.wakeAudioConsumer = nil
                self.wakeAudioFailureHandler = nil
                self.activeGeneration = generation
                self.resetCounters()
            }
            self.stopping = false

            guard !ephemeralCredential.isEmpty else {
                self.fail(
                    "The temporary Realtime credential is empty",
                    stage: "credential"
                )
                return
            }

            var components = URLComponents()
            components.scheme = "wss"
            components.host = "api.openai.com"
            components.path = "/v1/realtime"
            components.queryItems = [
                URLQueryItem(name: "model", value: model),
            ]
            guard let url = components.url else {
                self.fail(
                    "The Realtime WebSocket URL could not be created",
                    stage: "websocket_url"
                )
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(
                "realtime, openai-insecure-api-key.\(ephemeralCredential)",
                forHTTPHeaderField: "Sec-WebSocket-Protocol"
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            let task = session.webSocketTask(with: request)
            self.urlSession = session
            self.webSocketTask = task
            self.emitDiagnostic("socket_connecting")
            task.resume()

            let timeout = DispatchWorkItem { [weak self, weak task] in
                guard let self,
                      let task,
                      self.webSocketTask === task,
                      !self.socketOpen else {
                    return
                }
                self.fail(
                    "The Realtime WebSocket connection timed out",
                    stage: "websocket_open_timeout"
                )
            }
            self.openTimeout = timeout
            self.stateQueue.asyncAfter(deadline: .now() + 20, execute: timeout)
        }
    }

    func send(jsonEvent: String, generation: Int) {
        stateQueue.async {
            guard self.activeGeneration == generation,
                  self.socketOpen,
                  jsonEvent.utf8.count <= 262_144,
                  let data = jsonEvent.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data)
                    as? JSONDictionary,
                  event["type"] is String else {
                return
            }
            if Self.isOutboundAudioResponseCreate(event),
               let eventID = event["event_id"] as? String {
                self.pendingAudioPreemptionPolicy
                    .registerOutboundAudioResponseCreate(
                        eventID: eventID
                    )
            }
            self.enqueueOutbound(text: jsonEvent, isAudio: false)
        }
    }

    private static func isOutboundAudioResponseCreate(
        _ event: JSONDictionary
    ) -> Bool {
        guard event["type"] as? String == "response.create",
              let response = event["response"] as? JSONDictionary else {
            return false
        }
        let metadata = response["metadata"] as? JSONDictionary
        let responseKind =
            metadata?["voice_relay_kind"] as? String ?? ""
        if responseKind == "route_classifier"
            || responseKind == "active_codex_control" {
            return false
        }
        if let modalities = response["output_modalities"] as? [String] {
            return modalities.contains("audio")
        }
        return true
    }

    func stop(
        generation: Int,
        reason: String = "host_stop",
        preserveCaptureForWake: Bool = true
    ) {
        markStopRequested(generation: generation)
        stateQueue.async {
            guard self.activeGeneration == generation else {
                self.emitOnMain {
                    self.onClosed?(generation)
                }
                return
            }
            self.stopCurrent(
                emitClosed: true,
                reason: reason,
                preserveCaptureForWake: preserveCaptureForWake
            )
        }
    }

    func interruptPlayback(generation: Int) {
        stateQueue.async {
            guard self.activeGeneration == generation,
                  !self.stopping else {
                return
            }
            self.interruptPlaybackForBargeIn()
        }
    }

    func resumePlayback(generation: Int) {
        stateQueue.async {
            guard self.activeGeneration == generation,
                  !self.stopping else {
                return
            }
            self.resumeProvisionallyPausedPlayback()
        }
    }

    func shutdown() {
        stateQueue.sync {
            self.stopCurrent(
                emitClosed: false,
                reason: "transport_shutdown",
                preserveCaptureForWake: false
            )
        }
    }

    var wakeAudioFormat: AVAudioFormat? {
        stateQueue.sync {
            guard activeGeneration == nil,
                  audioEngine != nil,
                  voiceProcessingEnabled else {
                return nil
            }
            return AVAudioFormat(
                standardFormatWithSampleRate: 24_000,
                channels: 1
            )
        }
    }

    @discardableResult
    func beginWakeAudioDelivery(
        _ handler: @escaping (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        stateQueue.sync {
            audioRecoveryWorkItem?.cancel()
            audioRecoveryWorkItem = nil
            audioConfigurationRecoveryPolicy.invalidate()
            audioRecoveryStableWorkItem?.cancel()
            audioRecoveryStableWorkItem = nil
            guard activeGeneration == nil,
                  let audioEngine,
                  voiceProcessingEnabled else {
                return false
            }
            advanceCaptureRoutingEpoch()
            wakeAudioConsumer = handler
            wakeAudioFailureHandler = onFailure
            if !audioEngine.isRunning {
                do {
                    try restartFullDuplexEngineInPlace(
                        engine: audioEngine,
                        generation: nil
                    )
                } catch {
                    wakeAudioConsumer = nil
                    wakeAudioFailureHandler = nil
                    releaseAudioEngine(
                        generation: nil,
                        reason: "wake_audio_bind_recovery_failed"
                    )
                    return false
                }
            }
            observeAudioConfigurationChanges(for: audioEngine)
            scheduleWakeAudioHealthCheck(
                engine: audioEngine,
                capturedBaseline: wakeDeliveredChunks,
                reason: "initial_binding"
            )
            return true
        }
    }

    func endWakeAudioDelivery() {
        stateQueue.sync {
            audioRecoveryWorkItem?.cancel()
            audioRecoveryWorkItem = nil
            audioConfigurationRecoveryPolicy.invalidate()
            audioRecoveryStableWorkItem?.cancel()
            audioRecoveryStableWorkItem = nil
            advanceCaptureRoutingEpoch()
            cancelWakeAudioHealthCheck()
            wakeAudioConsumer = nil
            wakeAudioFailureHandler = nil
        }
    }

    private func enqueueOutbound(text: String, isAudio: Bool) {
        guard socketOpen, webSocketTask != nil else { return }
        if outboundQueue.count >= maximumOutboundMessages {
            if isAudio {
                droppedCaptureChunks += 1
                emitDiagnosticIfUseful()
                return
            }
            if let audioIndex = outboundQueue.firstIndex(where: \.isAudio) {
                outboundQueue.remove(at: audioIndex)
                droppedCaptureChunks += 1
            } else {
                fail(
                    "The Realtime send queue is full",
                    stage: "send_queue"
                )
                return
            }
        }
        let outbound = OutboundMessage(text: text, isAudio: isAudio)
        if isAudio {
            outboundQueue.append(outbound)
        } else {
            let startIndex = sendInFlight ? 1 : 0
            let insertionIndex = outboundQueue[startIndex...]
                .firstIndex(where: \.isAudio)
                ?? outboundQueue.endIndex
            outboundQueue.insert(outbound, at: insertionIndex)
        }
        pumpOutbound()
    }

    private func pumpOutbound() {
        guard !sendInFlight,
              let task = webSocketTask,
              let generation = activeGeneration,
              let message = outboundQueue.first else {
            return
        }
        sendInFlight = true
        task.send(.string(message.text)) { [weak self, weak task] error in
            guard let self else { return }
            self.stateQueue.async {
                guard let task,
                      self.webSocketTask === task,
                      self.activeGeneration == generation else {
                    return
                }
                self.sendInFlight = false
                if !self.outboundQueue.isEmpty {
                    self.outboundQueue.removeFirst()
                }
                if let error {
                    self.fail(
                        "Realtime send failed · \(error.localizedDescription)",
                        stage: "websocket_send"
                    )
                    return
                }
                if message.isAudio {
                    self.sentChunks += 1
                    if !self.listeningReadyReported,
                       self.sessionUpdated,
                       self.sentChunks > 0 {
                        self.listeningReadyReported = true
                        self.emitDiagnostic("listening_ready")
                        self.emitOnMain {
                            self.onListeningReady?(generation)
                        }
                    } else {
                        self.emitDiagnosticIfUseful()
                    }
                }
                self.pumpOutbound()
            }
        }
    }

    private func receiveNext() {
        guard let task = webSocketTask, let generation = activeGeneration else {
            return
        }
        task.receive { [weak self, weak task] result in
            guard let self else { return }
            self.stateQueue.async {
                guard let task,
                      self.webSocketTask === task,
                      self.activeGeneration == generation else {
                    return
                }
                switch result {
                case let .success(message):
                    self.handle(message, generation: generation)
                    self.receiveNext()
                case let .failure(error):
                    if !self.stopping {
                        self.fail(
                            "Realtime receive failed · \(error.localizedDescription)",
                            stage: "websocket_receive"
                        )
                    }
                }
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message,
        generation: Int
    ) {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(value):
            data = value
        @unknown default:
            return
        }
        guard var event = try? JSONSerialization.jsonObject(with: data)
                as? JSONDictionary,
              let type = event["type"] as? String else {
            return
        }

        if type == "session.updated", !sessionUpdated {
            sessionUpdated = true
            emitDiagnostic("session_updated")
            do {
                try startAudio(reason: "session_updated")
            } catch AudioLifecycleError.startCancelled {
                emitDiagnostic("audio_start_cancelled")
                return
            } catch {
                fail(
                    "The audio engine could not start · \(error.localizedDescription)",
                    stage: "audio_start"
                )
                return
            }
        }

        if type == "error",
           let error = event["error"] as? JSONDictionary,
           let eventID = error["event_id"] as? String {
            pendingAudioPreemptionPolicy
                .rejectOutboundAudioResponseCreate(
                    eventID: eventID
                )
        }

        if type == "response.created",
           let response = event["response"] as? JSONDictionary {
            let metadata = response["metadata"] as? JSONDictionary
            let responseID = response["id"] as? String ?? ""
            let responseKind =
                metadata?["voice_relay_kind"] as? String ?? ""
            let isAudioResponse = audioAdmissionPolicy.register(
                responseID: responseID,
                responseKind: responseKind
            )
            if isAudioResponse,
               pendingAudioPreemptionPolicy.registerCreatedAudioResponse() {
                audioAdmissionPolicy.suppressAudioResponse(
                    responseID: responseID
                )
                if !responseID.isEmpty {
                    discardedAudioResponseIDs.insert(responseID)
                }
                emitDiagnostic("preempted_audio_response_suppressed")
            }
            let detachedSpeechKinds: Set<String> = [
                "codex_progress",
                "codex_commentary",
                "codex_steer",
                "codex_acknowledgement",
                "semantic_stop",
            ]
            if !responseID.isEmpty,
               !detachedSpeechKinds.contains(responseKind) {
                truncatableResponseIDs.insert(responseID)
            }
        }

        let shouldForwardInputEvent =
            echoAdmissionPolicy.shouldForwardServerEvent(
                type: type,
                playbackActive: RealtimePlaybackActivityPolicy.isActive(
                    scheduledPlaybackBuffers: scheduledPlaybackBuffers,
                    playbackProvisionallyPaused:
                        playbackProvisionallyPaused
                ),
                now: ProcessInfo.processInfo.systemUptime
            )
        var completedAudioResponseID: String?
        if type == "response.output_audio.delta"
            || type == "response.audio.delta" {
            let responseID = event["response_id"] as? String ?? ""
            if discardedAudioResponseIDs.contains(responseID) {
                event.removeValue(forKey: "delta")
            } else if let encoded = event["delta"] as? String,
               let audio = Data(base64Encoded: encoded),
               !audio.isEmpty {
                if audioAdmissionPolicy.shouldAdmit(responseID: responseID) {
                    receivedChunks += 1
                    enqueuePlayback(
                        audio,
                        responseID: responseID,
                        itemID: event["item_id"] as? String ?? "",
                        contentIndex: (event["content_index"] as? NSNumber)?.intValue
                            ?? 0
                    )
                    emitDiagnosticIfUseful()
                } else if audioAdmissionPolicy.shouldReportSuppression(
                    responseID: responseID
                ) {
                    emitDiagnostic("classifier_audio_suppressed")
                }
            }
            event.removeValue(forKey: "delta")
        } else if type == "response.done",
                  let response = event["response"] as? JSONDictionary,
                  let responseID = response["id"] as? String,
                  !responseID.isEmpty,
                  discardedAudioResponseIDs.contains(responseID) {
            discardedAudioResponseIDs.remove(responseID)
            if backpressureReportedResponseIDs.remove(responseID) != nil,
               playbackBuffersByResponseID[responseID] != nil {
                completedAudioResponseIDs.insert(responseID)
                completedAudioResponseID = responseID
            }
        } else if type == "response.done",
                  let response = event["response"] as? JSONDictionary,
                  let responseID = response["id"] as? String,
                  !responseID.isEmpty,
                  playbackBuffersByResponseID[responseID] != nil {
            completedAudioResponseIDs.insert(responseID)
            completedAudioResponseID = responseID
        } else if type == "input_audio_buffer.speech_started" {
            if shouldForwardInputEvent {
                discardedAudioResponseIDs.formUnion(
                    audioAdmissionPolicy.suppressActiveAudioResponses()
                )
                pendingAudioPreemptionPolicy.admitUserSpeech()
                interruptPlaybackForBargeIn()
            } else {
                emitDiagnostic("unadmitted_playback_turn_suppressed")
            }
        }
        if type == "response.done",
           let response = event["response"] as? JSONDictionary {
            let responseID = response["id"] as? String ?? ""
            audioAdmissionPolicy.finish(responseID: responseID)
        }

        if shouldForwardInputEvent {
            emitOnMain {
                self.onEvent?(generation, event)
            }
        }
        if let completedAudioResponseID {
            reportPlaybackDrainedIfReady(
                responseID: completedAudioResponseID
            )
        }
    }

    private func startAudio(reason: String) throws {
        guard let generation = activeGeneration else { return }
        guard !isStartCancelled(generation: generation) else {
            throw AudioLifecycleError.startCancelled
        }
        if let audioEngine,
           voiceProcessingEnabled {
            guard audioEngine.inputNode.isVoiceProcessingEnabled,
                  audioEngine.outputNode.isVoiceProcessingEnabled,
                  captureTapInstalled,
                  playbackReferenceTapInstalled else {
                releaseAudioEngine(
                    generation: generation,
                    reason: "persistent_capture_invalid_before_reuse"
                )
                throw NSError(
                    domain: "VoiceRelay.NativeRealtimeAudioTransport",
                    code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The persistent audio graph is no longer reusable"
                    ]
                )
            }
            wakeAudioConsumer = nil
            wakeAudioFailureHandler = nil
            let captureWasRunning = audioEngine.isRunning
            if !captureWasRunning {
                try restartFullDuplexEngineInPlace(
                    engine: audioEngine,
                    generation: generation
                )
            }
            audioConfigurationRecoveryNotBefore =
                ProcessInfo.processInfo.systemUptime
                    + audioConfigurationStartupGrace
            observeAudioConfigurationChanges(for: audioEngine)
            emitDiagnostic("audio_reused")
            VoiceRelayDiagnostics.flow(
                "microphone_started",
                generation: generation,
                fields: [
                    "backend": "realtime_native_audio",
                    "reason": captureWasRunning
                        ? "persistent_capture_reused"
                        : "persistent_capture_restarted",
                    "voice_processing": "true",
                ]
            )
            return
        }
        VoiceRelayDiagnostics.flow(
            "microphone_open_requested",
            generation: generation,
            fields: [
                "backend": "realtime_native_audio",
                "input_selection": "macos_system_default",
                "output_selection": "macos_system_default",
                "reason": reason,
            ]
        )
        try installDefaultFullDuplexEngine(generation: generation)
    }

    private func installDefaultFullDuplexEngine(
        generation: Int
    ) throws {
        guard !isStartCancelled(generation: generation) else {
            throw AudioLifecycleError.startCancelled
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        VoiceRelayDiagnostics.flow(
            "audio_route_resolved",
            generation: generation,
            fields: [
                "input": Self.defaultAudioDeviceName(
                    selector: kAudioHardwarePropertyDefaultInputDevice
                ),
                "input_selection": "macos_system_default",
                "output": Self.defaultAudioDeviceName(
                    selector: kAudioHardwarePropertyDefaultOutputDevice
                ),
                "output_selection": "macos_system_default",
            ]
        )
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: 24_000,
            channels: 1
        ) else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The 24 kHz playback format could not be created"]
            )
        }
        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: playbackFormat
        )

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        guard input.isVoiceProcessingEnabled,
              engine.outputNode.isVoiceProcessingEnabled else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "System echo cancellation did not bind both audio directions"
                ]
            )
        }
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        voiceProcessingEnabled = true
        VoiceRelayDiagnostics.flow(
            "voice_processing_activated",
            generation: generation,
            fields: [
                "advanced_ducking": "false",
                "echo_cancellation": "system_output_reference_plus_software_guard",
                "input": String(input.isVoiceProcessingEnabled),
                "other_audio_policy": "minimum_without_activity_ducking",
                "output_reference": "software_mixer_tap",
            ]
        )
        emitDiagnostic("system_voice_processing_enabled")
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0,
              captureFormat.channelCount > 0 else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The microphone input format is unavailable"]
            )
        }
        VoiceRelayDiagnostics.flow(
            "microphone_capture_configured",
            generation: generation,
            fields: [
                "channels": String(captureFormat.channelCount),
                "format": String(describing: captureFormat.commonFormat),
                "sample_rate": String(format: "%.0f", captureFormat.sampleRate),
                "source": "macos_system_default_input",
            ]
        )
        VoiceRelayDiagnostics.flow(
            "speaker_playback_configured",
            generation: generation,
            fields: [
                "channels": String(playbackFormat.channelCount),
                "format": String(describing: playbackFormat.commonFormat),
                "sample_rate": String(format: "%.0f", playbackFormat.sampleRate),
                "sink": "macos_system_default_output",
            ]
        )
        installCaptureTap(
            on: input,
            format: captureFormat
        )
        try installPlaybackReferenceTap(
            on: engine.mainMixerNode
        )
        guard !isStartCancelled(generation: generation) else {
            input.removeTap(onBus: 0)
            captureTapInstalled = false
            engine.mainMixerNode.removeTap(onBus: 0)
            playbackReferenceTapInstalled = false
            throw AudioLifecycleError.startCancelled
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            captureTapInstalled = false
            engine.mainMixerNode.removeTap(onBus: 0)
            playbackReferenceTapInstalled = false
            engine.stop()
            voiceProcessingEnabled = false
            throw error
        }
        guard !isStartCancelled(generation: generation) else {
            input.removeTap(onBus: 0)
            captureTapInstalled = false
            engine.mainMixerNode.removeTap(onBus: 0)
            playbackReferenceTapInstalled = false
            engine.stop()
            throw AudioLifecycleError.startCancelled
        }
        audioEngine = engine
        playerNode = player
        audioConfigurationRecoveryNotBefore =
            ProcessInfo.processInfo.systemUptime
                + audioConfigurationStartupGrace
        observeAudioConfigurationChanges(for: engine)
        scheduleAudioRecoveryStableReset(
            engine: engine,
            generation: generation
        )
        emitDiagnostic("audio_started")
        VoiceRelayDiagnostics.flow(
            "microphone_started",
            generation: generation,
            fields: [
                "backend": "realtime_native_audio",
                "reason": "realtime_session_ready",
                "voice_processing": String(voiceProcessingEnabled),
            ]
        )
    }

    private func releaseAudioEngine(
        generation: Int?,
        reason: String,
        completion: (() -> Void)? = nil
    ) {
        let hadActiveCapture =
            audioEngine != nil
            || voiceProcessingEnabled
            || playbackReferenceTapInstalled
        if hadActiveCapture {
            VoiceRelayDiagnostics.flow(
                "microphone_stop_requested",
                generation: generation,
                fields: [
                    "backend": "realtime_native_audio",
                    "capture_active": String(audioEngine?.isRunning == true),
                    "reason": reason,
                ]
            )
        } else if generation != nil {
            VoiceRelayDiagnostics.flow(
                "microphone_stop_noop",
                generation: generation,
                fields: [
                    "backend": "realtime_native_audio",
                    "reason": reason,
                ]
            )
        }
        mediaEpoch &+= 1
        advanceCaptureRoutingEpoch()
        cancelWakeAudioHealthCheck()
        provisionalPauseToken &+= 1
        playbackProvisionallyPaused = false
        pendingPCM.removeAll(keepingCapacity: false)
        pendingBargeInPCM.removeAll(keepingCapacity: false)
        echoAdmissionPolicy.reset()
        removeAudioConfigurationObserver()
        playerNode?.stop()
        let engineToRetire = audioEngine
        if let engine = engineToRetire {
            engine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
            if playbackReferenceTapInstalled {
                engine.mainMixerNode.removeTap(onBus: 0)
            }
            engine.stop()
            engine.reset()
        }
        playbackReferenceTapInstalled = false
        playerNode = nil
        audioEngine = nil
        voiceProcessingEnabled = false
        lastCaptureClassification = ""
        if hadActiveCapture {
            VoiceRelayDiagnostics.flow(
                "microphone_stopped",
                generation: generation,
                fields: [
                    "backend": "realtime_native_audio",
                    "reason": reason,
                ]
            )
        }
        if let engineToRetire {
            retireAudioEngine(
                engineToRetire,
                completion: completion
            )
        } else if let completion {
            stateQueue.async(execute: completion)
        }
    }

    private func retireAudioEngine(
        _ engine: AVAudioEngine,
        completion: (() -> Void)? = nil
    ) {
        retiredAudioEngines.append(engine)
        stateQueue.asyncAfter(deadline: .now() + 0.08) { [weak self, weak engine] in
            guard let self else {
                completion?()
                return
            }
            if let engine {
                self.retiredAudioEngines.removeAll { $0 === engine }
            } else {
                self.retiredAudioEngines.removeAll()
            }
            self.stateQueue.asyncAfter(deadline: .now() + 0.18) {
                completion?()
            }
        }
    }

    private func installCaptureTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat
    ) {
        let epoch = mediaEpoch
        let bufferFrames = AVAudioFrameCount(
            max(256, min(4_096, Int(format.sampleRate * 0.04)))
        )
        input.installTap(
            onBus: 0,
            bufferSize: bufferFrames,
            format: format
        ) { [weak self] buffer, time in
            guard let self else { return }
            let routingToken = self.currentCaptureRoutingToken()
            self.capture(
                buffer,
                format: format,
                time: time,
                epoch: epoch,
                routingToken: routingToken,
                bufferHostTime: time.isHostTimeValid ? time.hostTime : nil
            )
        }
        captureTapInstalled = true
    }

    private func installPlaybackReferenceTap(
        on mixer: AVAudioMixerNode
    ) throws {
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The playback reference is unavailable"
                ]
            )
        }
        let epoch = mediaEpoch
        let bufferFrames = AVAudioFrameCount(
            max(256, min(4_096, Int(format.sampleRate * 0.04)))
        )
        mixer.installTap(
            onBus: 0,
            bufferSize: bufferFrames,
            format: format
        ) { [weak self] buffer, time in
            guard let self else { return }
            let routingToken = self.currentCaptureRoutingToken()
            self.capturePlaybackReference(
                buffer,
                format: format,
                time: time,
                epoch: epoch,
                routingToken: routingToken,
                bufferHostTime: time.isHostTimeValid ? time.hostTime : nil
            )
        }
        playbackReferenceTapInstalled = true
    }

    private func observeAudioConfigurationChanges(
        for engine: AVAudioEngine
    ) {
        removeAudioConfigurationObserver()
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.stateQueue.async {
                guard self.audioEngine === engine else {
                    return
                }
                let owner = PersistentAudioCaptureOwnerPolicy.resolve(
                    activeGeneration: self.activeGeneration,
                    realtimeStopping: self.stopping,
                    wakeConsumerBound: self.wakeAudioConsumer != nil
                )
                switch owner {
                case let .realtime(generation):
                    self.scheduleAudioRecovery(
                        engine: engine,
                        generation: generation
                    )
                case .wake:
                    self.scheduleWakeAudioRecovery(engine: engine)
                case .none:
                    break
                }
            }
        }
    }

    private func scheduleWakeAudioRecovery(engine: AVAudioEngine) {
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        audioConfigurationRecoveryPolicy.invalidate()
        audioRecoveryStableWorkItem?.cancel()
        audioRecoveryStableWorkItem = nil
        cancelWakeAudioHealthCheck()
        VoiceRelayDiagnostics.flow(
            "wake_audio_route_change_detected",
            generation: nil,
            fields: [
                "reason": "av_audio_engine_configuration_change",
            ]
        )
        let plan = audioConfigurationRecoveryPolicy.registerChange(
            now: ProcessInfo.processInfo.systemUptime,
            recoveryNotBefore: audioConfigurationRecoveryNotBefore
        )
        let capturedBaseline = wakeDeliveredChunks
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            guard self.audioConfigurationRecoveryPolicy.isCurrent(
                token: plan.token
            ),
            self.audioEngine === engine,
            self.activeGeneration == nil,
            self.wakeAudioConsumer != nil else {
                return
            }
            self.audioRecoveryWorkItem = nil
            if engine.isRunning,
               engine.inputNode.isVoiceProcessingEnabled,
               engine.outputNode.isVoiceProcessingEnabled,
               self.wakeDeliveredChunks > capturedBaseline {
                VoiceRelayDiagnostics.flow(
                    "wake_audio_route_change_settled",
                    generation: nil,
                    fields: ["recovery": "not_needed"]
                )
                self.scheduleWakeAudioHealthCheck(
                    engine: engine,
                    capturedBaseline: self.wakeDeliveredChunks,
                    reason: "route_settled"
                )
                return
            }
            do {
                try self.restartFullDuplexEngineInPlace(
                    engine: engine,
                    generation: nil
                )
                VoiceRelayDiagnostics.flow(
                    "wake_audio_recovery_completed",
                    generation: nil,
                    fields: ["strategy": "in_place"]
                )
                self.scheduleWakeAudioHealthCheck(
                    engine: engine,
                    capturedBaseline: self.wakeDeliveredChunks,
                    reason: "route_recovery"
                )
            } catch {
                self.failWakeAudioSource(
                    engine: engine,
                    reason: "route_recovery_failed"
                )
            }
        }
        audioRecoveryWorkItem = workItem
        stateQueue.asyncAfter(
            deadline: .now() + plan.delay,
            execute: workItem
        )
    }

    private func scheduleWakeAudioHealthCheck(
        engine: AVAudioEngine,
        capturedBaseline: Int,
        reason: String
    ) {
        cancelWakeAudioHealthCheck()
        let healthToken = wakeAudioHealthToken
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.stateQueue.async {
                guard self.wakeAudioHealthWorkItem != nil,
                      self.wakeAudioHealthToken == healthToken,
                      self.audioEngine === engine,
                      self.activeGeneration == nil,
                      self.wakeAudioConsumer != nil else {
                    return
                }
                self.wakeAudioHealthWorkItem = nil
                guard engine.isRunning,
                      engine.inputNode.isVoiceProcessingEnabled,
                      engine.outputNode.isVoiceProcessingEnabled,
                      self.wakeDeliveredChunks > capturedBaseline else {
                    self.failWakeAudioSource(
                        engine: engine,
                        reason: "\(reason)_capture_stalled"
                    )
                    return
                }
                VoiceRelayDiagnostics.flow(
                    "wake_audio_source_healthy",
                    generation: nil,
                    fields: ["reason": reason]
                )
            }
        }
        wakeAudioHealthWorkItem = workItem
        stateQueue.asyncAfter(
            deadline: .now() + wakeAudioHealthInterval,
            execute: workItem
        )
    }

    private func cancelWakeAudioHealthCheck() {
        wakeAudioHealthWorkItem?.cancel()
        wakeAudioHealthWorkItem = nil
        wakeAudioHealthToken &+= 1
    }

    private func failWakeAudioSource(
        engine: AVAudioEngine,
        reason: String
    ) {
        guard audioEngine === engine,
              activeGeneration == nil,
              wakeAudioConsumer != nil else {
            return
        }
        let failureHandler = wakeAudioFailureHandler
        advanceCaptureRoutingEpoch()
        cancelWakeAudioHealthCheck()
        wakeAudioConsumer = nil
        wakeAudioFailureHandler = nil
        VoiceRelayDiagnostics.flow(
            "wake_audio_source_failed",
            generation: nil,
            fields: ["reason": reason]
        )
        releaseAudioEngine(
            generation: nil,
            reason: "wake_audio_source_\(reason)",
            completion: {
                if let failureHandler {
                    self.emitOnMain(failureHandler)
                }
            }
        )
    }

    private func scheduleAudioRecovery(
        engine: AVAudioEngine,
        generation: Int
    ) {
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        audioConfigurationRecoveryPolicy.invalidate()
        audioRecoveryStableWorkItem?.cancel()
        audioRecoveryStableWorkItem = nil
        emitDiagnostic("audio_configuration_changed")
        VoiceRelayDiagnostics.flow(
            "audio_route_change_detected",
            generation: generation,
            fields: [
                "attempt": String(audioRecoveryAttempts),
                "reason": "av_audio_engine_configuration_change",
            ]
        )
        if scheduledPlaybackBuffers > 0 {
            emitDiagnostic("playback_cancelled_for_audio_recovery")
            interruptPlaybackForBargeIn()
        }
        let plan = audioConfigurationRecoveryPolicy.registerChange(
            now: ProcessInfo.processInfo.systemUptime,
            recoveryNotBefore: audioConfigurationRecoveryNotBefore
        )
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            guard self.audioConfigurationRecoveryPolicy.isCurrent(
                token: plan.token
            ),
            self.audioEngine === engine,
            self.activeGeneration == generation,
            !self.stopping else {
                return
            }
            self.audioRecoveryWorkItem = nil
            self.settleOrRebuildAudio(
                engine: engine,
                generation: generation
            )
        }
        audioRecoveryWorkItem = workItem
        stateQueue.asyncAfter(
            deadline: .now() + plan.delay,
            execute: workItem
        )
    }

    private func settleOrRebuildAudio(
        engine: AVAudioEngine,
        generation: Int
    ) {
        if engine.isRunning,
           engine.inputNode.isVoiceProcessingEnabled,
           engine.outputNode.isVoiceProcessingEnabled {
            emitDiagnostic("audio_configuration_settled")
            VoiceRelayDiagnostics.flow(
                "audio_route_change_settled",
                generation: generation,
                fields: [
                    "microphone_running": "true",
                    "rebuild": "false",
                ]
            )
            scheduleAudioRecoveryStableReset(
                engine: engine,
                generation: generation
            )
            return
        }

        guard audioRecoveryAttempts < maximumAudioRecoveryAttempts else {
            fail(
                "The system audio route changed and audio capture could not restart",
                stage: "audio_recovery_exhausted"
            )
            return
        }
        audioRecoveryAttempts += 1
        VoiceRelayDiagnostics.flow(
            "audio_recovery_started",
            generation: generation,
            fields: [
                "attempt": String(audioRecoveryAttempts),
                "strategy": "in_place_then_rebuild",
            ]
        )
        do {
            try restartFullDuplexEngineInPlace(
                engine: engine,
                generation: generation
            )
            emitDiagnostic("audio_recovered_in_place")
            VoiceRelayDiagnostics.flow(
                "audio_recovery_completed",
                generation: generation,
                fields: [
                    "attempt": String(audioRecoveryAttempts),
                    "strategy": "in_place",
                ]
            )
        } catch {
            Self.logger.error(
                "Realtime audio in-place recovery failed generation=\(generation) error_domain=\((error as NSError).domain, privacy: .public) error_code=\((error as NSError).code)"
            )
            rebuildDefaultFullDuplexEngine(generation: generation)
        }
    }

    private func restartFullDuplexEngineInPlace(
        engine: AVAudioEngine,
        generation: Int?
    ) throws {
        let input = engine.inputNode
        if let generation,
           isStartCancelled(generation: generation) {
            throw AudioLifecycleError.startCancelled
        }
        guard input.isVoiceProcessingEnabled,
              engine.outputNode.isVoiceProcessingEnabled else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "System echo cancellation lost its output reference"
                ]
            )
        }

        mediaEpoch &+= 1
        advanceCaptureRoutingEpoch()
        cancelWakeAudioHealthCheck()
        input.removeTap(onBus: 0)
        captureTapInstalled = false
        if playbackReferenceTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            playbackReferenceTapInstalled = false
        }
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0,
              captureFormat.channelCount > 0 else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The recovered microphone format is unavailable"
                ]
            )
        }
        installCaptureTap(
            on: input,
            format: captureFormat
        )
        try installPlaybackReferenceTap(
            on: engine.mainMixerNode
        )
        engine.prepare()
        try engine.start()
        if let generation,
           isStartCancelled(generation: generation) {
            input.removeTap(onBus: 0)
            captureTapInstalled = false
            engine.mainMixerNode.removeTap(onBus: 0)
            playbackReferenceTapInstalled = false
            engine.stop()
            throw AudioLifecycleError.startCancelled
        }
        if scheduledPlaybackBuffers > 0,
           !playbackProvisionallyPaused,
           let playerNode,
           !playerNode.isPlaying {
            playerNode.play()
        }
        audioConfigurationRecoveryNotBefore =
            ProcessInfo.processInfo.systemUptime
                + audioConfigurationStartupGrace
        if let generation {
            scheduleAudioRecoveryStableReset(
                engine: engine,
                generation: generation
            )
        }
    }

    private func rebuildDefaultFullDuplexEngine(generation: Int) {
        guard audioRecoveryAttempts <= maximumAudioRecoveryAttempts else {
            fail(
                "The system audio route changed and audio capture could not restart",
                stage: "audio_recovery_exhausted"
            )
            return
        }
        if audioEngine != nil {
            releaseAudioEngine(
                generation: generation,
                reason: "audio_route_rebuild",
                completion: { [weak self] in
                    guard let self,
                          self.activeGeneration == generation,
                          !self.stopping,
                          !self.isStartCancelled(generation: generation) else {
                        return
                    }
                    self.startRebuiltFullDuplexEngine(
                        generation: generation
                    )
                }
            )
            return
        }
        startRebuiltFullDuplexEngine(generation: generation)
    }

    private func startRebuiltFullDuplexEngine(generation: Int) {
        guard activeGeneration == generation,
              !stopping,
              !isStartCancelled(generation: generation) else {
            return
        }
        do {
            try installDefaultFullDuplexEngine(generation: generation)
            emitDiagnostic("audio_recovered")
            VoiceRelayDiagnostics.flow(
                "audio_recovery_completed",
                generation: generation,
                fields: [
                    "attempt": String(audioRecoveryAttempts),
                    "strategy": "full_rebuild",
                ]
            )
        } catch {
            Self.logger.error(
                "Realtime audio retry failed generation=\(generation) attempt=\(self.audioRecoveryAttempts) error_domain=\((error as NSError).domain, privacy: .public) error_code=\((error as NSError).code)"
            )
            guard audioRecoveryAttempts < maximumAudioRecoveryAttempts else {
                fail(
                    "The system audio route changed and audio capture could not restart",
                    stage: "audio_recovery_exhausted"
                )
                return
            }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stateQueue.async {
                    guard self.audioRecoveryWorkItem != nil,
                          self.audioEngine == nil,
                          self.activeGeneration == generation,
                          !self.stopping else {
                        return
                    }
                    self.audioRecoveryWorkItem = nil
                    self.audioRecoveryAttempts += 1
                    self.rebuildDefaultFullDuplexEngine(
                        generation: generation
                    )
                }
            }
            audioRecoveryWorkItem = workItem
            stateQueue.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        }
    }

    private func scheduleAudioRecoveryStableReset(
        engine: AVAudioEngine,
        generation: Int
    ) {
        audioRecoveryStableWorkItem?.cancel()
        audioRecoveryStableCapturedBaseline = capturedChunks
        audioRecoveryStableRenderedBaseline = renderedChunks
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.stateQueue.async {
                guard self.audioRecoveryStableWorkItem != nil,
                      self.audioEngine === engine,
                      self.activeGeneration == generation,
                      !self.stopping else {
                    return
                }
                guard self.sessionUpdated else {
                    self.scheduleAudioRecoveryStableReset(
                        engine: engine,
                        generation: generation
                    )
                    return
                }
                let mediaProgressed =
                    self.capturedChunks
                        > self.audioRecoveryStableCapturedBaseline
                    || self.renderedChunks
                        > self.audioRecoveryStableRenderedBaseline
                guard engine.isRunning, mediaProgressed else {
                    self.audioRecoveryStableWorkItem = nil
                    self.emitDiagnostic("audio_recovery_unstable")
                    if engine.isRunning {
                        engine.stop()
                    }
                    self.settleOrRebuildAudio(
                        engine: engine,
                        generation: generation
                    )
                    return
                }
                self.audioRecoveryStableWorkItem = nil
                self.audioRecoveryAttempts = 0
                self.emitDiagnostic("audio_recovery_stable")
            }
        }
        audioRecoveryStableWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func removeAudioConfigurationObserver() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(
                audioConfigurationObserver
            )
        }
        audioConfigurationObserver = nil
    }

    private func capture(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        time: AVAudioTime,
        epoch: Int,
        routingToken: AudioCaptureRoutingToken,
        bufferHostTime: UInt64?
    ) {
        guard reserveCaptureSlot() else {
            stateQueue.async {
                guard self.mediaEpoch == epoch,
                      self.acceptsCaptureRouting(
                          routingToken,
                          bufferHostTime: bufferHostTime
                      ) else {
                    return
                }
                self.droppedCaptureChunks += 1
                self.emitDiagnosticIfUseful()
            }
            return
        }
        guard let channels = buffer.floatChannelData else {
            releaseCaptureSlot()
            return
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            releaseCaptureSlot()
            return
        }
        var channelSamples: [[Float]] = []
        channelSamples.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            channelSamples.append(
                Array(
                    UnsafeBufferPointer(
                        start: channels[channel],
                        count: frameCount
                    )
                )
            )
        }
        let sourceRate = format.sampleRate
        let startTime = Self.monotonicSeconds(for: time)
        audioProcessingQueue.async { [weak self] in
            guard let self else { return }
            let inputLevel = OrbAudioLevelPolicy.normalizedRMS(channelSamples)
            let samples = Self.mixAndResample(
                channelSamples,
                sourceRate: sourceRate
            )
            self.stateQueue.async {
                defer { self.releaseCaptureSlot() }
                guard self.mediaEpoch == epoch,
                      self.isCurrentCaptureRoutingToken(routingToken) else {
                    return
                }
                guard let bufferHostTime else {
                    if self.captureTimingHealth.record(
                        timestampAvailable: false
                    ) {
                        self.handleUnavailableCaptureTiming()
                    }
                    return
                }
                _ = self.captureTimingHealth.record(timestampAvailable: true)
                guard self.acceptsCaptureRouting(
                    routingToken,
                    bufferHostTime: bufferHostTime
                ), !samples.isEmpty else {
                    return
                }
                if let wakeAudioConsumer = self.wakeAudioConsumer,
                   let wakeBuffer = Self.wakeAudioBuffer(from: samples) {
                    self.wakeDeliveredChunks += 1
                    wakeAudioConsumer(wakeBuffer)
                }
                guard self.sessionUpdated,
                      let generation = self.activeGeneration,
                      !self.stopping else {
                    return
                }
                self.emitOnMain {
                    self.onInputLevel?(generation, inputLevel)
                }
                self.capturedChunks += 1
                if self.playbackExternallyPaused {
                    self.echoAdmissionPolicy.cancelProvisionalSpeech()
                    self.pendingBargeInPCM.removeAll(
                        keepingCapacity: true
                    )
                    self.suppressedEchoChunks += 1
                    self.reportCaptureClassificationIfChanged(
                        .echoOnly,
                        correlation: 0,
                        generation: generation
                    )
                    self.emitDiagnosticIfUseful()
                    return
                }
                let filtered = self.echoAdmissionPolicy.filterCapture(
                    samples,
                    startTime: startTime,
                    playbackActive:
                        RealtimePlaybackActivityPolicy.isActive(
                            scheduledPlaybackBuffers:
                                self.scheduledPlaybackBuffers,
                            playbackProvisionallyPaused:
                                self.playbackProvisionallyPaused
                        ),
                    playbackProvisionallyPaused:
                        self.playbackProvisionallyPaused
                )
                self.reportCaptureClassificationIfChanged(
                    filtered.classification,
                    correlation: filtered.correlation,
                    generation: generation
                )
                if filtered.classification == .echoOnly {
                    if !self.echoAdmissionPolicy
                        .shouldRetainPendingSpeechCandidate(
                            at: startTime
                        ) {
                        self.pendingBargeInPCM.removeAll(keepingCapacity: true)
                    }
                    self.suppressedEchoChunks += 1
                    self.emitDiagnosticIfUseful()
                    return
                }
                if filtered.classification == .uncertainSpeech {
                    self.appendBargeInPreroll(
                        Self.encodePCM16(filtered.samples)
                    )
                    return
                }
                let pcm = Self.encodePCM16(filtered.samples)
                guard !pcm.isEmpty else { return }
                if filtered.classification == .residualSpeech,
                   !self.pendingBargeInPCM.isEmpty {
                    self.pendingPCM.append(self.pendingBargeInPCM)
                    self.pendingBargeInPCM.removeAll(keepingCapacity: true)
                } else if filtered.classification == .noPlaybackReference {
                    self.pendingBargeInPCM.removeAll(keepingCapacity: true)
                }
                self.pendingPCM.append(pcm)
                let bytesPerChunk =
                    self.inputChunkFrames * MemoryLayout<Int16>.size
                while self.pendingPCM.count >= bytesPerChunk {
                    let chunk = self.pendingPCM.prefix(bytesPerChunk)
                    self.pendingPCM.removeFirst(bytesPerChunk)
                    let event: JSONDictionary = [
                        "type": "input_audio_buffer.append",
                        "audio": Data(chunk).base64EncodedString(),
                    ]
                    guard let data = try? JSONSerialization.data(
                        withJSONObject: event
                    ), let text = String(data: data, encoding: .utf8) else {
                        continue
                    }
                    self.enqueueOutbound(text: text, isAudio: true)
                }
                self.emitDiagnosticIfUseful()
            }
        }
    }

    private func capturePlaybackReference(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        time: AVAudioTime,
        epoch: Int,
        routingToken: AudioCaptureRoutingToken,
        bufferHostTime: UInt64?
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }
        var channelSamples: [[Float]] = []
        channelSamples.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            channelSamples.append(
                Array(
                    UnsafeBufferPointer(
                        start: channels[channel],
                        count: frameCount
                    )
                )
            )
        }
        let sourceRate = format.sampleRate
        let startTime = Self.monotonicSeconds(for: time)
        audioProcessingQueue.async { [weak self] in
            guard let self else { return }
            let samples = Self.mixAndResample(
                channelSamples,
                sourceRate: sourceRate
            )
            self.stateQueue.async {
                guard self.activeGeneration != nil,
                      self.mediaEpoch == epoch,
                      self.acceptsCaptureRouting(
                          routingToken,
                          bufferHostTime: bufferHostTime
                      ),
                      !samples.isEmpty else {
                    return
                }
                if Self.audioRMS(samples) >= 0.001 {
                    self.echoAdmissionPolicy.markPlaybackActive(
                        at: startTime
                    )
                }
                self.echoAdmissionPolicy.appendPlaybackReference(
                    samples,
                    startTime: startTime
                )
            }
        }
    }

    private func appendBargeInPreroll(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        pendingBargeInPCM.append(pcm)
        if pendingBargeInPCM.count > maximumBargeInPrerollBytes {
            pendingBargeInPCM.removeFirst(
                pendingBargeInPCM.count - maximumBargeInPrerollBytes
            )
        }
    }

    private static func mixAndResample(
        _ channels: [[Float]],
        sourceRate: Double
    ) -> [Float] {
        guard let firstChannel = channels.first,
              !firstChannel.isEmpty,
              sourceRate > 0 else {
            return []
        }
        let frameCount = channels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in channels {
                sum += channel[frame]
            }
            samples[frame] = sum / Float(channels.count)
        }
        let targetRate = 24_000.0
        let outputCount = max(
            1,
            Int((Double(samples.count) * targetRate / sourceRate).rounded())
        )
        var output = [Float]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * sourceRate / targetRate
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            let interpolated =
                samples[lower] + ((samples[upper] - samples[lower]) * fraction)
            output.append(max(-1, min(1, interpolated)))
        }
        return output
    }

    private static func encodePCM16(_ samples: [Float]) -> Data {
        var data = Data(
            capacity: samples.count * MemoryLayout<Int16>.size
        )
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = clamped < 0
                ? clamped * 32_768
                : clamped * Float(Int16.max)
            var littleEndian = Int16(scaled.rounded()).littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static func audioRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) {
            $0 + Double($1 * $1)
        }
        return Float(sqrt(energy / Double(samples.count)))
    }

    private static func monotonicSeconds(for time: AVAudioTime) -> TimeInterval {
        if time.isHostTimeValid {
            return AVAudioTime.seconds(forHostTime: time.hostTime)
        }
        return ProcessInfo.processInfo.systemUptime
    }

    private func reserveCaptureSlot() -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard captureSlotsInUse < maximumCaptureSlots else { return false }
        captureSlotsInUse += 1
        return true
    }

    private func releaseCaptureSlot() {
        captureLock.lock()
        captureSlotsInUse = max(0, captureSlotsInUse - 1)
        captureLock.unlock()
    }

    private func enqueuePlayback(
        _ data: Data,
        responseID: String,
        itemID: String,
        contentIndex: Int
    ) {
        let chunk = PlaybackChunk(
            data: data,
            responseID: responseID,
            itemID: itemID,
            contentIndex: contentIndex
        )
        guard chunk.frameCount > 0 else { return }
        if queuedPlaybackFrames + chunk.frameCount
            > maximumQueuedPlaybackFrames {
            if !responseID.isEmpty {
                discardedAudioResponseIDs.insert(responseID)
                if backpressureReportedResponseIDs.insert(responseID).inserted {
                    emitDiagnostic("playback_backpressure_drop")
                }
            }
            return
        }
        guard let player = playerNode,
              let buffer = Self.playbackBuffer(from: chunk.data) else {
            return
        }
        let firstChunkForResponse =
            !responseID.isEmpty
                && playbackBuffersByResponseID[responseID] == nil
        if firstChunkForResponse, let generation = activeGeneration {
            VoiceRelayDiagnostics.flow(
                "assistant_playback_queued",
                generation: generation,
                fields: [
                    "itemID": itemID,
                    "responseID": responseID,
                    "source": "realtime_audio",
                ]
            )
        }
        if !chunk.responseID.isEmpty {
            activePlaybackResponseID = chunk.responseID
        }
        if activePlaybackItemID != chunk.itemID {
            activePlaybackItemID = chunk.itemID
            activePlaybackContentIndex = chunk.contentIndex
            activePlaybackCanTruncate =
                truncatableResponseIDs.contains(chunk.responseID)
            activePlaybackStartSampleTime =
                currentPlaybackSampleTime() ?? 0
            activePlaybackStartedAt = Date()
            activePlaybackScheduledFrames = 0
        }
        activePlaybackScheduledFrames += chunk.frameCount
        queuedPlaybackFrames += chunk.frameCount
        scheduledPlaybackBuffers += 1
        if !responseID.isEmpty {
            playbackBuffersByResponseID[responseID, default: 0] += 1
        }
        if firstChunkForResponse {
            beginPlaybackOverlapMonitoring()
        }
        let token = playbackToken
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                guard token == self.playbackToken else { return }
                self.queuedPlaybackFrames = max(
                    0,
                    self.queuedPlaybackFrames - chunk.frameCount
                )
                self.scheduledPlaybackBuffers = max(
                    0,
                    self.scheduledPlaybackBuffers - 1
                )
                if self.scheduledPlaybackBuffers == 0 {
                    self.echoAdmissionPolicy.markPlaybackEnded(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                }
                if !chunk.responseID.isEmpty {
                    self.playbackBuffersByResponseID[chunk.responseID] = max(
                        0,
                        (self.playbackBuffersByResponseID[chunk.responseID] ?? 1) - 1
                    )
                    self.reportPlaybackDrainedIfReady(
                        responseID: chunk.responseID
                    )
                }
                self.renderedChunks += 1
                self.emitDiagnosticIfUseful()
            }
        }
        if !player.isPlaying {
            player.play()
            if let generation = activeGeneration {
                VoiceRelayDiagnostics.flow(
                    "assistant_playback_started",
                    generation: generation,
                    fields: [
                        "responseID": responseID,
                        "reason": firstChunkForResponse
                            ? "response_audio_received"
                            : "queue_resumed",
                    ]
                )
            }
        }
    }

    private func reportPlaybackDrainedIfReady(responseID: String) {
        guard let generation = activeGeneration,
              completedAudioResponseIDs.contains(responseID),
              playbackBuffersByResponseID[responseID] == 0,
              drainedAudioResponseIDs.insert(responseID).inserted else {
            return
        }
        completedAudioResponseIDs.remove(responseID)
        playbackBuffersByResponseID.removeValue(forKey: responseID)
        truncatableResponseIDs.remove(responseID)
        if activePlaybackResponseID == responseID {
            activePlaybackResponseID = ""
        }
        endPlaybackOverlapMonitoring()
        VoiceRelayDiagnostics.flow(
            "assistant_playback_drained_native",
            generation: generation,
            fields: ["responseID": responseID]
        )
        emitOnMain {
            self.onPlaybackDrained?(generation, responseID)
        }
    }

    private func currentPlaybackSampleTime() -> AVAudioFramePosition? {
        guard let player = playerNode,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime) else {
            return nil
        }
        return playerTime.sampleTime
    }

    private static func playbackBuffer(
        from data: Data
    ) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: 24_000,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destination = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                let offset = frame * 2
                let bits = UInt16(raw[offset])
                    | (UInt16(raw[offset + 1]) << 8)
                let sample = Int16(bitPattern: bits)
                destination[frame] = Float(sample) / 32_768
            }
        }
        return buffer
    }

    private static func wakeAudioBuffer(
        from samples: [Float]
    ) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: 24_000,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let destination = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        destination.update(from: samples, count: samples.count)
        return buffer
    }

    private func provisionallyPausePlaybackForBargeIn() {
        guard scheduledPlaybackBuffers > 0,
              !playbackProvisionallyPaused,
              let player = playerNode,
              player.isPlaying else {
            return
        }
        playbackProvisionallyPaused = true
        provisionalPauseToken &+= 1
        let token = provisionalPauseToken
        player.pause()
        emitDiagnostic("playback_provisionally_paused")
        if let generation = activeGeneration {
            VoiceRelayDiagnostics.flow(
                "assistant_playback_paused",
                generation: generation,
                fields: [
                    "reason": "possible_human_barge_in",
                    "responseID": activePlaybackResponseID,
                ]
            )
        }
        stateQueue.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self,
                  self.provisionalPauseToken == token else {
                return
            }
            self.resumeProvisionallyPausedPlayback()
        }
    }

    private func resumeProvisionallyPausedPlayback() {
        guard playbackProvisionallyPaused else { return }
        provisionalPauseToken &+= 1
        playbackProvisionallyPaused = false
        pendingBargeInPCM.removeAll(keepingCapacity: true)
        echoAdmissionPolicy.cancelProvisionalSpeech()
        guard scheduledPlaybackBuffers > 0,
              !playbackExternallyPaused,
              let player = playerNode else {
            return
        }
        player.play()
        emitDiagnostic("playback_resumed_after_echo")
        if let generation = activeGeneration {
            VoiceRelayDiagnostics.flow(
                "assistant_playback_resumed",
                generation: generation,
                fields: [
                    "reason": "provisional_speech_was_echo",
                    "responseID": activePlaybackResponseID,
                ]
            )
        }
    }

    private func interruptPlaybackForBargeIn() {
        guard scheduledPlaybackBuffers > 0 else { return }
        let renderedFrames: Int
        if let start = activePlaybackStartSampleTime,
           let current = currentPlaybackSampleTime() {
            renderedFrames = max(0, Int(current - start))
        } else if let started = activePlaybackStartedAt {
            renderedFrames = max(
                0,
                Int(Date().timeIntervalSince(started) * 24_000)
            )
        } else {
            renderedFrames = 0
        }
        let itemID = activePlaybackItemID
        let contentIndex = activePlaybackContentIndex
        let canTruncate = activePlaybackCanTruncate
        let scheduledFrames = activePlaybackScheduledFrames
        let interruptedResponseID = activePlaybackResponseID
        discardedAudioResponseIDs.formUnion(
            playbackBuffersByResponseID.keys
        )
        if !activePlaybackResponseID.isEmpty {
            discardedAudioResponseIDs.insert(activePlaybackResponseID)
        }
        playbackToken += 1
        provisionalPauseToken &+= 1
        playbackProvisionallyPaused = false
        endPlaybackOverlapMonitoring()
        pendingBargeInPCM.removeAll(keepingCapacity: true)
        playerNode?.stop()
        queuedPlaybackFrames = 0
        scheduledPlaybackBuffers = 0
        playbackBuffersByResponseID.removeAll()
        completedAudioResponseIDs.removeAll()
        drainedAudioResponseIDs.removeAll()
        activePlaybackResponseID = ""
        activePlaybackItemID = ""
        activePlaybackContentIndex = 0
        activePlaybackCanTruncate = false
        activePlaybackStartSampleTime = nil
        activePlaybackStartedAt = nil
        activePlaybackScheduledFrames = 0
        echoAdmissionPolicy.markPlaybackEnded(
            at: ProcessInfo.processInfo.systemUptime
        )

        guard let generation = activeGeneration else { return }
        VoiceRelayDiagnostics.flow(
            "assistant_playback_interrupted",
            generation: generation,
            fields: [
                "reason": "admitted_human_barge_in",
                "responseID": interruptedResponseID,
            ]
        )
        guard canTruncate, !itemID.isEmpty, scheduledFrames > 0 else {
            emitDiagnostic("playback_cancelled")
            return
        }
        let boundedRenderedFrames = min(
            max(0, renderedFrames),
            scheduledFrames
        )
        let audioEndMS = max(
            0,
            Int(Double(boundedRenderedFrames) / 24.0)
        )
        controlEventSequence &+= 1
        enqueueControlEvent([
            "event_id":
                "voice-relay-truncate-\(generation)-\(controlEventSequence)",
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": max(0, contentIndex),
            "audio_end_ms": audioEndMS,
        ])
        guard activeGeneration == generation else { return }
        emitDiagnostic("playback_truncated")
    }

    private func beginPlaybackOverlapMonitoring() {
        playbackOverlapWorkItem?.cancel()
        playbackOverlapWorkItem = nil
        playbackOverlapPolicy.begin(
            with: systemMediaPlaybackDetector.snapshot()
        )
        playbackExternallyPaused = false
        schedulePlaybackOverlapSample()
    }

    private func schedulePlaybackOverlapSample() {
        guard activeGeneration != nil,
              !stopping,
              !activePlaybackResponseID.isEmpty else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard self.playbackOverlapWorkItem != nil,
                      self.activeGeneration != nil,
                      !self.stopping,
                      !self.activePlaybackResponseID.isEmpty else {
                    return
                }
                self.playbackOverlapWorkItem = nil
                let snapshot =
                    self.systemMediaPlaybackDetector.snapshot()
                switch self.playbackOverlapPolicy.observe(snapshot) {
                case .pause:
                    self.playbackExternallyPaused = true
                    if self.playerNode?.isPlaying == true {
                        self.playerNode?.pause()
                    }
                    VoiceRelayDiagnostics.flow(
                        "assistant_playback_yielded",
                        generation: self.activeGeneration,
                        fields: [
                            "process_count":
                                String(snapshot.processLabels.count),
                            "reason":
                                "new_external_output_overlap",
                            "responseID":
                                self.activePlaybackResponseID,
                        ]
                    )
                case .resume:
                    self.playbackExternallyPaused = false
                    if self.scheduledPlaybackBuffers > 0,
                       !self.playbackProvisionallyPaused,
                       self.playerNode?.isPlaying == false {
                        self.playerNode?.play()
                    }
                    VoiceRelayDiagnostics.flow(
                        "assistant_playback_resumed",
                        generation: self.activeGeneration,
                        fields: [
                            "reason":
                                "external_output_overlap_ended",
                            "responseID":
                                self.activePlaybackResponseID,
                        ]
                    )
                case .none:
                    break
                }
                self.schedulePlaybackOverlapSample()
            }
        }
        playbackOverlapWorkItem = workItem
        stateQueue.asyncAfter(
            deadline: .now() + 0.10,
            execute: workItem
        )
    }

    private func endPlaybackOverlapMonitoring() {
        playbackOverlapWorkItem?.cancel()
        playbackOverlapWorkItem = nil
        playbackOverlapPolicy.reset()
        playbackExternallyPaused = false
    }

    private func enqueueControlEvent(_ event: JSONDictionary) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        enqueueOutbound(text: text, isAudio: false)
    }

    private func stopCurrent(
        emitClosed: Bool,
        reason: String,
        preserveCaptureForWake: Bool = false
    ) {
        let previousGeneration = activeGeneration
        if let previousGeneration {
            markStopRequested(generation: previousGeneration)
        }
        advanceCaptureRoutingEpoch()
        let hadActiveTransport =
            previousGeneration != nil
            || webSocketTask != nil
            || urlSession != nil
            || audioEngine != nil
            || socketOpen
            || sessionUpdated
        if hadActiveTransport {
            VoiceRelayDiagnostics.flow(
                "realtime_transport_stop_requested",
                generation: previousGeneration,
                fields: [
                    "emit_closed": String(emitClosed),
                    "reason": reason,
                ]
            )
        }
        if let previousGeneration {
            emitOnMain {
                self.onInputLevel?(previousGeneration, 0)
            }
        }
        let keepsCaptureRunning =
            preserveCaptureForWake
            && audioEngine?.isRunning == true
            && voiceProcessingEnabled
        if !keepsCaptureRunning {
            mediaEpoch &+= 1
        }
        stopping = true
        openTimeout?.cancel()
        openTimeout = nil
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        audioConfigurationRecoveryPolicy.invalidate()
        audioRecoveryStableWorkItem?.cancel()
        audioRecoveryStableWorkItem = nil
        audioRecoveryAttempts = 0
        playbackToken += 1
        provisionalPauseToken &+= 1
        playbackProvisionallyPaused = false
        endPlaybackOverlapMonitoring()
        let closeAfterAudioTransition = { [weak self] in
            guard let self,
                  emitClosed,
                  let previousGeneration else {
                return
            }
            self.emitOnMain {
                self.onClosed?(previousGeneration)
            }
        }
        if keepsCaptureRunning {
            playerNode?.stop()
            wakeAudioConsumer = nil
            wakeAudioFailureHandler = nil
            VoiceRelayDiagnostics.flow(
                "microphone_capture_preserved",
                generation: previousGeneration,
                fields: [
                    "backend": "realtime_native_audio",
                    "next": "local_wake_analysis",
                    "reason": reason,
                ]
            )
            closeAfterAudioTransition()
        } else {
            wakeAudioConsumer = nil
            wakeAudioFailureHandler = nil
            releaseAudioEngine(
                generation: previousGeneration,
                reason: reason,
                completion: closeAfterAudioTransition
            )
        }
        queuedPlaybackFrames = 0
        scheduledPlaybackBuffers = 0
        playbackBuffersByResponseID.removeAll()
        completedAudioResponseIDs.removeAll()
        drainedAudioResponseIDs.removeAll()
        discardedAudioResponseIDs.removeAll()
        truncatableResponseIDs.removeAll()
        backpressureReportedResponseIDs.removeAll()
        activePlaybackResponseID = ""
        activePlaybackItemID = ""
        activePlaybackContentIndex = 0
        activePlaybackCanTruncate = false
        activePlaybackStartSampleTime = nil
        activePlaybackStartedAt = nil
        activePlaybackScheduledFrames = 0
        audioAdmissionPolicy.reset()
        pendingAudioPreemptionPolicy.reset()
        echoAdmissionPolicy.reset()
        pendingPCM.removeAll(keepingCapacity: false)
        pendingBargeInPCM.removeAll(keepingCapacity: false)

        outboundQueue.removeAll(keepingCapacity: false)
        sendInFlight = false
        socketOpen = false
        sessionUpdated = false
        listeningReadyReported = false
        let task = webSocketTask
        webSocketTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        let session = urlSession
        urlSession = nil
        session?.invalidateAndCancel()
        activeGeneration = nil
        if hadActiveTransport {
            VoiceRelayDiagnostics.flow(
                "realtime_transport_stopped",
                generation: previousGeneration,
                fields: ["reason": reason]
            )
        }
    }

    private func markStartRequested(generation: Int) {
        lifecycleSignalLock.withLock {
            audioStartCancellation.requestStart(generation: generation)
        }
    }

    private func markStopRequested(generation: Int) {
        lifecycleSignalLock.withLock {
            audioStartCancellation.requestStop(generation: generation)
        }
    }

    private func isStartCancelled(generation: Int) -> Bool {
        lifecycleSignalLock.withLock {
            audioStartCancellation.isCancelled(generation: generation)
        }
    }

    private func currentCaptureRoutingToken() -> AudioCaptureRoutingToken {
        lifecycleSignalLock.withLock {
            captureRoutingEpoch.token
        }
    }

    private func acceptsCaptureRouting(
        _ token: AudioCaptureRoutingToken,
        bufferHostTime: UInt64?
    ) -> Bool {
        lifecycleSignalLock.withLock {
            captureRoutingEpoch.accepts(
                token,
                bufferHostTime: bufferHostTime
            )
        }
    }

    private func isCurrentCaptureRoutingToken(
        _ token: AudioCaptureRoutingToken
    ) -> Bool {
        lifecycleSignalLock.withLock {
            captureRoutingEpoch.isCurrent(token)
        }
    }

    private func handleUnavailableCaptureTiming() {
        if activeGeneration != nil, !stopping {
            fail(
                "The microphone did not provide safe capture timing",
                stage: "capture_timing_unavailable"
            )
            return
        }
        if activeGeneration == nil,
           wakeAudioConsumer != nil,
           let audioEngine {
            failWakeAudioSource(
                engine: audioEngine,
                reason: "capture_timing_unavailable"
            )
        }
    }

    @discardableResult
    private func advanceCaptureRoutingEpoch() -> AudioCaptureRoutingToken {
        captureTimingHealth.reset()
        return lifecycleSignalLock.withLock {
            captureRoutingEpoch.advance(
                atHostTime: AudioGetCurrentHostTime()
            )
        }
    }

    private func fail(_ message: String, stage: String) {
        guard let generation = activeGeneration else { return }
        let established = listeningReadyReported
        let safeMessage = VoiceRelayDiagnostics.safe(message)
        Self.logger.error(
            "Realtime transport failed stage=\(stage, privacy: .public) generation=\(generation) established=\(established) message=\(safeMessage, privacy: .public)"
        )
        emitDiagnostic("failed_\(stage)")
        stopCurrent(
            emitClosed: false,
            reason: "failure_\(stage)",
            preserveCaptureForWake: false
        )
        emitOnMain {
            self.onError?(generation, message)
        }
    }

    private func resetCounters() {
        capturedChunks = 0
        sentChunks = 0
        receivedChunks = 0
        renderedChunks = 0
        droppedCaptureChunks = 0
        suppressedEchoChunks = 0
        lastCaptureClassification = ""
        lastProgressDiagnosticAt = .distantPast
        lastReportedDroppedChunks = 0
    }

    private func emitDiagnosticIfUseful() {
        let total = capturedChunks + sentChunks + receivedChunks + renderedChunks
        let now = Date()
        let droppedChanged = droppedCaptureChunks != lastReportedDroppedChunks
        if total <= 4
            || droppedChanged
            || now.timeIntervalSince(lastProgressDiagnosticAt) >= 10 {
            lastProgressDiagnosticAt = now
            lastReportedDroppedChunks = droppedCaptureChunks
            emitDiagnostic("media_progress")
        }
    }

    private func emitDiagnostic(_ stage: String) {
        guard let generation = activeGeneration else { return }
        let snapshot = DiagnosticSnapshot(
            stage: stage,
            generation: generation,
            capturedChunks: capturedChunks,
            sentChunks: sentChunks,
            receivedChunks: receivedChunks,
            renderedChunks: renderedChunks,
            droppedCaptureChunks: droppedCaptureChunks,
            suppressedEchoChunks: suppressedEchoChunks,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        emitOnMain {
            self.onDiagnostic?(snapshot)
        }
    }

    private func reportCaptureClassificationIfChanged(
        _ classification: RealtimeEchoFilterResult.Classification,
        correlation: Float,
        generation: Int
    ) {
        let label: String
        switch classification {
        case .noPlaybackReference:
            label = "ordinary_microphone_input"
        case .echoOnly:
            label = "assistant_echo_suppressed"
        case .uncertainSpeech:
            label = "possible_barge_in_waiting"
        case .residualSpeech:
            label = "human_barge_in_admitted"
        }
        guard label != lastCaptureClassification else { return }
        lastCaptureClassification = label
        VoiceRelayDiagnostics.flow(
            "microphone_capture_classification_changed",
            generation: generation,
            fields: [
                "classification": label,
                "correlation": String(format: "%.3f", correlation),
                "playback_active": String(scheduledPlaybackBuffers > 0),
            ]
        )
    }

    private static func defaultAudioDeviceName(
        selector: AudioObjectPropertySelector
    ) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return "system_default_unknown"
        }
        address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(
            MemoryLayout<Unmanaged<CFString>?>.size
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &nameSize,
            &unmanagedName
        ) == noErr,
        let unmanagedName else {
            return "system_default_unknown"
        }
        return unmanagedName.takeUnretainedValue() as String
    }

    private func emitOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

extension NativeRealtimeAudioTransport: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateQueue.async {
            guard let error,
                  self.webSocketTask === task,
                  !self.stopping else {
                return
            }
            self.fail(
                "Realtime WebSocket connection failed · \(error.localizedDescription)",
                stage: "websocket_task"
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        stateQueue.async {
            guard self.webSocketTask === webSocketTask,
                  let generation = self.activeGeneration else {
                return
            }
            self.openTimeout?.cancel()
            self.openTimeout = nil
            self.socketOpen = true
            self.emitDiagnostic("socket_open")
            self.receiveNext()
            self.emitOnMain {
                self.onSocketOpen?(generation)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        stateQueue.async {
            guard self.webSocketTask === webSocketTask,
                  !self.stopping else {
                return
            }
            self.fail(
                "The Realtime WebSocket closed unexpectedly",
                stage: "websocket_close"
            )
        }
    }
}
