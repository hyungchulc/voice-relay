import AVFoundation
import Foundation

final class NativeRealtimeAudioTransport: NSObject {
    typealias JSONDictionary = [String: Any]

    struct DiagnosticSnapshot {
        let stage: String
        let generation: Int
        let capturedChunks: Int
        let sentChunks: Int
        let receivedChunks: Int
        let renderedChunks: Int
        let droppedCaptureChunks: Int
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
    private var playerNode: AVAudioPlayerNode?
    private var voiceProcessingEnabled = false
    private var captureSlotsInUse = 0
    private let maximumCaptureSlots = 8
    private var pendingPCM = Data()
    private let inputChunkFrames = 720

    private var queuedPlaybackFrames = 0
    private let maximumQueuedPlaybackFrames = 24_000 * 12
    private var scheduledPlaybackBuffers = 0
    private var playbackBuffersByResponseID: [String: Int] = [:]
    private var completedAudioResponseIDs: Set<String> = []
    private var drainedAudioResponseIDs: Set<String> = []
    private var playbackToken = 0
    private var activePlaybackItemID = ""
    private var activePlaybackContentIndex = 0
    private var activePlaybackStartSampleTime: AVAudioFramePosition?
    private var activePlaybackStartedAt: Date?
    private var mediaEpoch = 0

    private var capturedChunks = 0
    private var sentChunks = 0
    private var receivedChunks = 0
    private var renderedChunks = 0
    private var droppedCaptureChunks = 0
    private var lastProgressDiagnosticAt = Date.distantPast
    private var lastReportedDroppedChunks = 0

    func start(
        generation: Int,
        model: String,
        ephemeralCredential: String
    ) {
        stateQueue.async {
            self.stopCurrent(emitClosed: false)
            self.activeGeneration = generation
            self.stopping = false
            self.resetCounters()

            guard !ephemeralCredential.isEmpty else {
                self.fail("The temporary Realtime credential is empty")
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
                self.fail("The Realtime WebSocket URL could not be created")
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
                self.fail("The Realtime WebSocket connection timed out")
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
            self.enqueueOutbound(text: jsonEvent, isAudio: false)
        }
    }

    func stop(generation: Int) {
        stateQueue.async {
            guard self.activeGeneration == generation else { return }
            self.stopCurrent(emitClosed: true)
        }
    }

    func shutdown() {
        stateQueue.sync {
            self.stopCurrent(emitClosed: false)
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
                fail("The Realtime send queue is full")
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
                    self.fail("Realtime send failed · \(error.localizedDescription)")
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
                            "Realtime receive failed · \(error.localizedDescription)"
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
                try startAudio()
            } catch {
                fail("The audio engine could not start · \(error.localizedDescription)")
                return
            }
        }

        var completedAudioResponseID: String?
        if type == "response.output_audio.delta"
            || type == "response.audio.delta" {
            if let encoded = event["delta"] as? String,
               let audio = Data(base64Encoded: encoded),
               !audio.isEmpty {
                let responseID = event["response_id"] as? String ?? ""
                receivedChunks += 1
                enqueuePlayback(
                    audio,
                    responseID: responseID,
                    itemID: event["item_id"] as? String ?? "",
                    contentIndex: (event["content_index"] as? NSNumber)?.intValue
                        ?? 0
                )
                emitDiagnosticIfUseful()
            }
            event.removeValue(forKey: "delta")
        } else if type == "response.done",
                  let response = event["response"] as? JSONDictionary,
                  let responseID = response["id"] as? String,
                  !responseID.isEmpty,
                  playbackBuffersByResponseID[responseID] != nil {
            completedAudioResponseIDs.insert(responseID)
            completedAudioResponseID = responseID
        } else if type == "input_audio_buffer.speech_started" {
            interruptPlaybackForBargeIn()
        }

        emitOnMain {
            self.onEvent?(generation, event)
        }
        if let completedAudioResponseID {
            reportPlaybackDrainedIfReady(
                responseID: completedAudioResponseID
            )
        }
    }

    private func startAudio() throws {
        guard audioEngine == nil else { return }
        guard let generation = activeGeneration else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
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
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
        } catch {
            voiceProcessingEnabled = false
        }
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0,
              captureFormat.channelCount > 0 else {
            throw NSError(
                domain: "VoiceRelay.NativeRealtimeAudioTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The microphone input format is unavailable"]
            )
        }
        let epoch = mediaEpoch
        let bufferFrames = AVAudioFrameCount(
            max(256, min(4_096, Int(captureFormat.sampleRate * 0.04)))
        )
        input.installTap(
            onBus: 0,
            bufferSize: bufferFrames,
            format: captureFormat
        ) { [weak self] buffer, _ in
            self?.capture(
                buffer,
                format: captureFormat,
                generation: generation,
                epoch: epoch
            )
        }
        audioEngine = engine
        playerNode = player
        engine.prepare()
        try engine.start()
        if !voiceProcessingEnabled {
            emitDiagnostic("voice_processing_unavailable")
        }
        emitDiagnostic("audio_started")
    }

    private func capture(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        generation: Int,
        epoch: Int
    ) {
        guard reserveCaptureSlot() else {
            stateQueue.async {
                guard self.activeGeneration == generation,
                      self.mediaEpoch == epoch else {
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
        audioProcessingQueue.async { [weak self] in
            guard let self else { return }
            let inputLevel = OrbAudioLevelPolicy.normalizedRMS(channelSamples)
            let pcm = Self.mixResampleAndEncodePCM16(
                channelSamples,
                sourceRate: sourceRate
            )
            self.stateQueue.async {
                defer { self.releaseCaptureSlot() }
                guard self.sessionUpdated,
                      self.activeGeneration == generation,
                      self.mediaEpoch == epoch,
                      !pcm.isEmpty else {
                    return
                }
                self.emitOnMain {
                    self.onInputLevel?(generation, inputLevel)
                }
                self.capturedChunks += 1
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

    private static func mixResampleAndEncodePCM16(
        _ channels: [[Float]],
        sourceRate: Double
    ) -> Data {
        guard let firstChannel = channels.first,
              !firstChannel.isEmpty,
              sourceRate > 0 else {
            return Data()
        }
        let frameCount = channels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return Data() }
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
        var data = Data(capacity: outputCount * MemoryLayout<Int16>.size)
        for index in 0..<outputCount {
            let position = Double(index) * sourceRate / targetRate
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            let interpolated =
                samples[lower] + ((samples[upper] - samples[lower]) * fraction)
            let clamped = max(-1, min(1, interpolated))
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
            fail("The Realtime audio playback queue is full")
            return
        }
        guard let player = playerNode,
              let buffer = Self.playbackBuffer(from: chunk.data) else {
            return
        }
        if activePlaybackItemID != chunk.itemID {
            activePlaybackItemID = chunk.itemID
            activePlaybackContentIndex = chunk.contentIndex
            activePlaybackStartSampleTime =
                currentPlaybackSampleTime() ?? 0
            activePlaybackStartedAt = Date()
        }
        queuedPlaybackFrames += chunk.frameCount
        scheduledPlaybackBuffers += 1
        if !responseID.isEmpty {
            playbackBuffersByResponseID[responseID, default: 0] += 1
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
        playbackToken += 1
        playerNode?.stop()
        queuedPlaybackFrames = 0
        scheduledPlaybackBuffers = 0
        playbackBuffersByResponseID.removeAll()
        completedAudioResponseIDs.removeAll()
        drainedAudioResponseIDs.removeAll()
        activePlaybackItemID = ""
        activePlaybackStartSampleTime = nil
        activePlaybackStartedAt = nil

        guard let generation = activeGeneration else { return }
        guard !itemID.isEmpty else {
            emitDiagnostic("playback_cancelled")
            return
        }
        let audioEndMS = max(0, Int(Double(renderedFrames) / 24.0))
        enqueueControlEvent([
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": contentIndex,
            "audio_end_ms": audioEndMS,
        ])
        guard activeGeneration == generation else { return }
        emitDiagnostic("playback_truncated")
    }

    private func enqueueControlEvent(_ event: JSONDictionary) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        enqueueOutbound(text: text, isAudio: false)
    }

    private func stopCurrent(emitClosed: Bool) {
        let previousGeneration = activeGeneration
        if let previousGeneration {
            emitOnMain {
                self.onInputLevel?(previousGeneration, 0)
            }
        }
        mediaEpoch &+= 1
        stopping = true
        openTimeout?.cancel()
        openTimeout = nil
        playbackToken += 1
        playerNode?.stop()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        playerNode = nil
        audioEngine = nil
        voiceProcessingEnabled = false
        queuedPlaybackFrames = 0
        scheduledPlaybackBuffers = 0
        playbackBuffersByResponseID.removeAll()
        completedAudioResponseIDs.removeAll()
        drainedAudioResponseIDs.removeAll()
        activePlaybackItemID = ""
        activePlaybackStartSampleTime = nil
        activePlaybackStartedAt = nil
        pendingPCM.removeAll(keepingCapacity: false)

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
        if emitClosed, let previousGeneration {
            emitOnMain {
                self.onClosed?(previousGeneration)
            }
        }
    }

    private func fail(_ message: String) {
        guard let generation = activeGeneration else { return }
        emitDiagnostic("failed")
        stopCurrent(emitClosed: false)
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
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        emitOnMain {
            self.onDiagnostic?(snapshot)
        }
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
                "Realtime WebSocket connection failed · \(error.localizedDescription)"
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
            self.fail("The Realtime WebSocket closed unexpectedly")
        }
    }
}
