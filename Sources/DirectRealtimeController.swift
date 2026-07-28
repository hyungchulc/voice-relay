import Foundation
import OSLog
import WebKit

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class DirectRealtimeController: NSObject {
    private static let logger = Logger(
        subsystem: "com.hyungchulc.voice-relay",
        category: "RealtimeReducer"
    )

    private let model: String
    private let voice: String
    private let reasoningEffort: String
    private let instructions: String
    private let language: String
    private let additionalLanguages: [String]
    private let productName: String
    private let assistantName: String
    private let wakePhrases: [String]
    private let contentController = WKUserContentController()
    private let configuration = WKWebViewConfiguration()
    private let transport = NativeRealtimeAudioTransport()
    private var webView: WKWebView?
    private var isReady = false
    private var isShutdown = false
    private var pendingStart: (
        generation: Int,
        prefill: String?,
        shouldGreet: Bool,
        reason: String
    )?
    private var activeGeneration: Int?
    private var stoppingGenerations = Set<Int>()
    private var startupRetryState = RealtimeStartupRetryState()
    private var startupRetryWorkItem: DispatchWorkItem?
    private let trustedOrigin = "https://voice-relay.local"

    var onEvent: (([String: Any]) -> Void)?
    var onInputLevel: ((CGFloat) -> Void)?
    var onCodexRequest: ((String, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onCodexSteer: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onCredentialRequest: ((@escaping (Result<String, Error>) -> Void) -> Void)?
    var onSDPOffer: ((String, @escaping (Result<String, Error>) -> Void) -> Void)?

    init(
        model: String,
        voice: String,
        reasoningEffort: String,
        instructions: String,
        language: String,
        additionalLanguages: [String],
        productName: String,
        assistantName: String,
        wakePhrases: [String]
    ) {
        self.model = model
        self.voice = voice
        self.reasoningEffort = reasoningEffort
        self.instructions = instructions
        self.language = language
        self.additionalLanguages = additionalLanguages
        self.productName = productName
        self.assistantName = assistantName
        self.wakePhrases = wakePhrases
        super.init()
        transport.onSocketOpen = { [weak self] generation in
            guard let self, self.activeGeneration == generation else { return }
            self.evaluate(
                method: "transportOpened",
                payload: ["generation": generation]
            )
        }
        transport.onListeningReady = { [weak self] generation in
            guard let self, self.activeGeneration == generation else { return }
            _ = self.startupRetryState.markListeningReady(generation: generation)
            self.startupRetryWorkItem?.cancel()
            self.startupRetryWorkItem = nil
            self.evaluate(
                method: "transportReady",
                payload: ["generation": generation]
            )
        }
        transport.onEvent = { [weak self] generation, event in
            guard let self, self.activeGeneration == generation else { return }
            self.evaluate(
                method: "receiveRealtimeEvent",
                payload: [
                    "generation": generation,
                    "event": event,
                ]
            )
        }
        transport.onInputLevel = { [weak self] generation, level in
            guard let self, self.activeGeneration == generation else { return }
            self.onInputLevel?(level)
        }
        transport.onPlaybackDrained = { [weak self] generation, responseID in
            guard let self, self.activeGeneration == generation else { return }
            self.evaluate(
                method: "playbackDrained",
                payload: [
                    "generation": generation,
                    "responseId": responseID,
                ]
            )
        }
        transport.onDiagnostic = { snapshot in
            Self.logger.notice(
                "Native Realtime stage=\(snapshot.stage, privacy: .public) generation=\(snapshot.generation) captured=\(snapshot.capturedChunks) sent=\(snapshot.sentChunks) received=\(snapshot.receivedChunks) rendered=\(snapshot.renderedChunks) dropped=\(snapshot.droppedCaptureChunks) echo_suppressed=\(snapshot.suppressedEchoChunks) voice_processing=\(snapshot.voiceProcessingEnabled ? "on" : "off", privacy: .public)"
            )
        }
        transport.onError = { [weak self] generation, message in
            guard let self, self.activeGeneration == generation else { return }
            self.handleTransportFailure(
                generation: generation,
                message: message
            )
        }
    }

    func attach(to hostView: NSView) {
        guard webView == nil else { return }

        configuration.userContentController = contentController
        contentController.add(
            WeakScriptMessageHandler(target: self),
            name: "voiceRelay"
        )

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.alphaValue = 0.01
        webView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            webView.topAnchor.constraint(equalTo: hostView.topAnchor),
            webView.widthAnchor.constraint(equalToConstant: 1),
            webView.heightAnchor.constraint(equalToConstant: 1),
        ])
        self.webView = webView
        webView.loadHTMLString(Self.runtimeHTML, baseURL: URL(string: trustedOrigin))
    }

    func start(
        generation: Int,
        prefill: String? = nil,
        shouldGreet: Bool = true,
        reason: String = "manual"
    ) {
        if let previousGeneration = activeGeneration,
           previousGeneration != generation {
            VoiceRelayDiagnostics.flow(
                "realtime_transport_stop_requested",
                generation: previousGeneration,
                fields: ["reason": "generation_replaced"]
            )
            transport.stop(
                generation: previousGeneration,
                reason: "generation_replaced"
            )
        }
        VoiceRelayDiagnostics.flow(
            "realtime_host_start_requested",
            generation: generation,
            fields: [
                "greet": String(shouldGreet),
                "reason": reason,
            ],
            transcriptFields: ["prefill": prefill ?? ""]
        )
        pendingStart = (
            generation,
            prefill,
            shouldGreet,
            reason
        )
        stoppingGenerations.remove(generation)
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
        startupRetryState.begin(generation: generation)
        activeGeneration = generation
        emitState("starting", generation: generation)
        flushPendingStartIfReady()
    }

    func stop(
        generation: Int,
        reason: String = "host_stop"
    ) {
        VoiceRelayDiagnostics.flow(
            "realtime_host_stop_requested",
            generation: generation,
            fields: ["reason": reason]
        )
        pendingStart = nil
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
        startupRetryState.cancel(generation: generation)
        stoppingGenerations.insert(generation)
        stoppingGenerations = Set(
            stoppingGenerations.filter { $0 >= generation - 8 }
        )
        activeGeneration = nil
        transport.stop(
            generation: generation,
            reason: reason
        )
        evaluate(
            method: "stop",
            payload: [
                "generation": generation,
                "reason": reason,
            ]
        )
    }

    func speakCodexCommentary(
        _ text: String,
        messageID: String,
        generation: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard generation == activeGeneration, !trimmed.isEmpty else { return }
        evaluate(
            method: "speakCodexCommentary",
            payload: [
                "generation": generation,
                "messageId": messageID,
                "text": trimmed,
            ]
        )
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        pendingStart = nil
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
        startupRetryState.cancel()
        if let generation = activeGeneration {
            VoiceRelayDiagnostics.flow(
                "realtime_host_stop_requested",
                generation: generation,
                fields: ["reason": "controller_shutdown"]
            )
            transport.stop(
                generation: generation,
                reason: "controller_shutdown"
            )
            evaluate(
                method: "stop",
                payload: [
                    "generation": generation,
                    "reason": "controller_shutdown",
                ]
            )
        }
        transport.shutdown()
        activeGeneration = nil
        stoppingGenerations.removeAll()
        isReady = false
        contentController.removeScriptMessageHandler(forName: "voiceRelay")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func flushPendingStartIfReady() {
        guard isReady, let pendingStart else {
            return
        }
        self.pendingStart = nil
        evaluate(
            method: "start",
            payload: [
                "generation": pendingStart.generation,
                "prefill": pendingStart.prefill ?? "",
                "model": model,
                "voice": voice,
                "reasoningEffort": reasoningEffort,
                "instructions": instructions,
                "language": language,
                "additionalLanguages": additionalLanguages,
                "productName": productName,
                "assistantName": assistantName,
                "wakePhrases": wakePhrases,
                "shouldGreet": pendingStart.shouldGreet,
                "activationReason": pendingStart.reason,
            ]
        )
    }

    private func evaluate(method: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView?.evaluateJavaScript("window.VoiceRelayNativeVoice?.\(method)(\(json));")
    }

    private func emitState(_ phase: String, generation: Int) {
        onEvent?([
            "type": "state",
            "phase": phase,
            "generation": generation,
        ])
    }

    private func acceptRuntimeReadySignal() {
        guard !isReady else {
            VoiceRelayDiagnostics.flow(
                "realtime_runtime_protocol_violation",
                fields: [
                    "reason": "duplicate_script_ready",
                    "source": "script_message",
                ]
            )
            return
        }
        isReady = true
        onEvent?(["type": "ready"])
        flushPendingStartIfReady()
    }

    private static func originString(for url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else {
            return ""
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

}

extension DirectRealtimeController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "voiceRelay",
              message.frameInfo.isMainFrame,
              Self.originString(for: message.frameInfo.request.url) == trustedOrigin,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              Self.allowedEventTypes.contains(type) else {
            return
        }
        if type == "ready" {
            acceptRuntimeReadySignal()
            return
        }
        if type == "credentialRequest" {
            handleCredentialRequest(body)
            return
        }
        if type == "realtimeSend" {
            handleRealtimeSend(body)
            return
        }
        if type == "playbackInterrupt",
           let generation = (body["generation"] as? NSNumber)?.intValue,
           generation == activeGeneration {
            transport.interruptPlayback(generation: generation)
            return
        }
        if type == "playbackResume",
           let generation = (body["generation"] as? NSNumber)?.intValue,
           generation == activeGeneration {
            transport.resumePlayback(generation: generation)
            return
        }
        if type == "codexRequest" {
            handleCodexRequest(body)
            return
        }
        if type == "codexSteer" {
            handleCodexSteer(body)
            return
        }
        if type == "diagnostic" {
            let stage = body["stage"] as? String ?? "unknown"
            let generation =
                (body["generation"] as? NSNumber)?.intValue
            let peer = body["peer"] as? String ?? "-"
            let ice = body["ice"] as? String ?? "-"
            let channel = body["channel"] as? String ?? "-"
            let shape = body["shape"] as? String ?? "-"
            let kind = body["kind"] as? String ?? "-"
            let code = body["code"] as? String ?? "-"
            let errorType = body["errorType"] as? String ?? "-"
            let eventID = body["eventID"] as? String ?? "-"
            Self.logger.notice(
                "Realtime diagnostic stage=\(stage, privacy: .public) peer=\(peer, privacy: .public) ice=\(ice, privacy: .public) channel=\(channel, privacy: .public) shape=\(shape, privacy: .public) kind=\(kind, privacy: .public) code=\(code, privacy: .public) error_type=\(errorType, privacy: .public) event_id=\(eventID, privacy: .public)"
            )
            var fields: [String: String] = [:]
            for key in [
                "callID",
                "channel",
                "code",
                "errorType",
                "eventID",
                "ice",
                "itemID",
                "kind",
                "peer",
                "reason",
                "responseID",
                "shape",
                "source",
                "status",
                "turnID",
            ] {
                if let value = body[key] as? String, !value.isEmpty {
                    fields[key] = value
                }
            }
            var transcriptFields: [String: String] = [:]
            for key in ["assistantText", "text", "userText"] {
                if let value = body[key] as? String, !value.isEmpty {
                    transcriptFields[key] = value
                }
            }
            VoiceRelayDiagnostics.flow(
                stage,
                generation: generation,
                fields: fields,
                transcriptFields: transcriptFields
            )
            return
        }
        let eventGeneration = (body["generation"] as? NSNumber)?.intValue
        guard RealtimeHostEventPolicy.shouldAccept(
            type: type,
            generation: eventGeneration,
            activeGeneration: activeGeneration,
            stoppingGenerations: stoppingGenerations
        ) else {
            return
        }
        if type == "terminal", let eventGeneration {
            stoppingGenerations.remove(eventGeneration)
        }
        onEvent?(body)
    }

    private func handleCredentialRequest(_ body: [String: Any]) {
        guard let generation = (body["generation"] as? NSNumber)?.intValue,
              generation == activeGeneration else {
            return
        }
        requestCredentialAndStartTransport(
            generation: generation,
            isRetry: false
        )
    }

    private func requestCredentialAndStartTransport(
        generation: Int,
        isRetry: Bool
    ) {
        guard generation == activeGeneration else { return }
        VoiceRelayDiagnostics.flow(
            "credential_request_started",
            generation: generation,
            fields: [
                "attempt": isRetry ? "retry" : "initial",
                "reason": "realtime_transport_start",
            ]
        )
        guard let credentialProvider = onCredentialRequest
            ?? onSDPOffer.map({ legacy in
                { completion in legacy("", completion) }
            }) else {
            startupRetryState.cancel(generation: generation)
            VoiceRelayDiagnostics.flow(
                "credential_request_failed",
                generation: generation,
                fields: [
                    "reason": "provider_unavailable",
                    "status": "terminal",
                ]
            )
            onEvent?([
                "type": "error",
                "generation": generation,
                "message": "The Voice credential connection is not ready",
            ])
            return
        }
        credentialProvider { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.activeGeneration == generation else { return }
                switch result {
                case let .success(encodedCredential):
                    guard let credential = self.decodeCredentialEnvelope(
                        encodedCredential
                    ) else {
                        self.startupRetryState.cancel(generation: generation)
                        VoiceRelayDiagnostics.flow(
                            "credential_request_failed",
                            generation: generation,
                            fields: [
                                "reason": "invalid_envelope",
                                "status": "terminal",
                            ]
                        )
                        self.onEvent?([
                            "type": "error",
                            "generation": generation,
                            "message": "The temporary Voice credential is invalid",
                        ])
                        return
                    }
                    guard self.startupRetryState.registerTransportAttempt(
                        generation: generation,
                        isRetry: isRetry
                    ) else {
                        VoiceRelayDiagnostics.flow(
                            "credential_result_ignored",
                            generation: generation,
                            fields: [
                                "reason": "stale_or_duplicate_attempt",
                            ]
                        )
                        return
                    }
                    VoiceRelayDiagnostics.flow(
                        "credential_request_completed",
                        generation: generation,
                        fields: [
                            "attempt": isRetry ? "retry" : "initial",
                            "model": credential.model,
                            "status": "success",
                        ]
                    )
                    self.transport.start(
                        generation: generation,
                        model: credential.model,
                        ephemeralCredential: credential.value
                    )
                case let .failure(error):
                    self.startupRetryState.cancel(generation: generation)
                    VoiceRelayDiagnostics.flow(
                        "credential_request_failed",
                        generation: generation,
                        fields: [
                            "error_code": String((error as NSError).code),
                            "error_domain": (error as NSError).domain,
                            "status": "terminal",
                        ]
                    )
                    self.onEvent?([
                        "type": "error",
                        "generation": generation,
                        "message": error.localizedDescription,
                    ])
                }
            }
        }
    }

    private func handleTransportFailure(
        generation: Int,
        message: String
    ) {
        guard generation == activeGeneration else { return }
        if startupRetryState.reserveRetry(generation: generation) {
            VoiceRelayDiagnostics.flow(
                "realtime_startup_retry_scheduled",
                generation: generation,
                fields: [
                    "delay_ms": String(
                        Int(RealtimeStartupRetryState.retryDelay * 1_000)
                    ),
                    "reason": message,
                ]
            )
            NSLog(
                "Voice Relay Realtime startup retry generation=%d after=%@",
                generation,
                message
            )
            startupRetryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activeGeneration == generation,
                      self.startupRetryState.hasReservedRetry(
                        generation: generation
                      ) else {
                    return
                }
                self.startupRetryWorkItem = nil
                VoiceRelayDiagnostics.flow(
                    "realtime_startup_retry_started",
                    generation: generation,
                    fields: ["reason": "pre_ready_transport_failure"]
                )
                self.requestCredentialAndStartTransport(
                    generation: generation,
                    isRetry: true
                )
            }
            startupRetryWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + RealtimeStartupRetryState.retryDelay,
                execute: workItem
            )
            return
        }
        if startupRetryState.hasReservedRetry(generation: generation) {
            VoiceRelayDiagnostics.flow(
                "realtime_transport_failure_deduplicated",
                generation: generation,
                fields: ["reason": message]
            )
            return
        }
        VoiceRelayDiagnostics.flow(
            "realtime_transport_failure_terminal",
            generation: generation,
            fields: ["reason": message]
        )
        onEvent?([
            "type": "error",
            "generation": generation,
            "message": message,
        ])
    }

    private func decodeCredentialEnvelope(
        _ encoded: String
    ) -> (value: String, model: String)? {
        guard let data = encoded.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let value = envelope["clientSecret"] as? String,
              !value.isEmpty else {
            return encoded.isEmpty ? nil : (encoded, model)
        }
        if let expiresAt = (envelope["expiresAt"] as? NSNumber)?.doubleValue,
           expiresAt > 0,
           expiresAt <= Date().timeIntervalSince1970 + 5 {
            return nil
        }
        let credentialModel = (envelope["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            value,
            credentialModel?.isEmpty == false ? credentialModel! : model
        )
    }

    private func handleRealtimeSend(_ body: [String: Any]) {
        guard let generation = (body["generation"] as? NSNumber)?.intValue,
              generation == activeGeneration,
              let eventJSON = body["eventJSON"] as? String,
              eventJSON.utf8.count <= 262_144 else {
            return
        }
        transport.send(jsonEvent: eventJSON, generation: generation)
    }

    private func handleCodexRequest(_ body: [String: Any]) {
        guard let generation = (body["generation"] as? NSNumber)?.intValue,
              generation == activeGeneration,
              let callID = body["callId"] as? String,
              let text = body["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        NSLog(
            "Voice Relay Codex bridge accepted request generation=%d call_id=%@ text=%@",
            generation,
            callID,
            VoiceRelayDiagnostics.logsTranscriptContent
                ? text
                : "<redacted>"
        )
        VoiceRelayDiagnostics.flow(
            "codex_bridge_request_accepted",
            generation: generation,
            fields: ["callID": callID],
            transcriptFields: ["text": text]
        )
        guard let onCodexRequest else {
            NSLog(
                "Voice Relay Codex bridge unavailable generation=%d",
                generation
            )
            evaluate(
                method: "resolveCodex",
                payload: [
                    "generation": generation,
                    "callId": callID,
                    "error": "The Codex direct connector is not ready",
                ]
            )
            return
        }
        onCodexRequest(text) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.activeGeneration == generation else { return }
                switch result {
                case let .success(output):
                    NSLog(
                        "Voice Relay Codex bridge completed generation=%d call_id=%@ result=success",
                        generation,
                        callID
                    )
                    VoiceRelayDiagnostics.flow(
                        "codex_bridge_request_completed",
                        generation: generation,
                        fields: [
                            "callID": callID,
                            "status": "success",
                        ],
                        transcriptFields: ["assistantText": output]
                    )
                    self.evaluate(
                        method: "resolveCodex",
                        payload: [
                            "generation": generation,
                            "callId": callID,
                            "output": output,
                        ]
                    )
                case let .failure(error):
                    NSLog(
                        "Voice Relay Codex bridge completed generation=%d call_id=%@ result=failure error=%@",
                        generation,
                        callID,
                        error.localizedDescription
                    )
                    VoiceRelayDiagnostics.flow(
                        "codex_bridge_request_completed",
                        generation: generation,
                        fields: [
                            "callID": callID,
                            "status": "failure",
                        ],
                        transcriptFields: [
                            "assistantText": error.localizedDescription
                        ]
                    )
                    self.evaluate(
                        method: "resolveCodex",
                        payload: [
                            "generation": generation,
                            "callId": callID,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
        }
    }

    private func handleCodexSteer(_ body: [String: Any]) {
        guard let generation = (body["generation"] as? NSNumber)?.intValue,
              generation == activeGeneration,
              let text = body["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let onCodexSteer else {
            evaluate(
                method: "resolveCodexSteer",
                payload: [
                    "generation": generation,
                    "error": "The Codex steering connection is not ready",
                ]
            )
            return
        }
        onCodexSteer(text) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.activeGeneration == generation else { return }
                switch result {
                case .success:
                    self.evaluate(
                        method: "resolveCodexSteer",
                        payload: [
                            "generation": generation,
                            "accepted": true,
                        ]
                    )
                case let .failure(error):
                    self.evaluate(
                        method: "resolveCodexSteer",
                        payload: [
                            "generation": generation,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
        }
    }

    private static let allowedEventTypes: Set<String> = [
        "ready",
        "state",
        "userTranscriptPartial",
        "userTranscript",
        "assistantProgress",
        "assistantPartial",
        "assistantFinal",
        "assistantPlaybackDrained",
        "codexHandoff",
        "codexRequest",
        "codexSteer",
        "stopIntent",
        "stopAcknowledgementDrained",
        "credentialRequest",
        "realtimeSend",
        "playbackInterrupt",
        "playbackResume",
        "terminal",
        "turnError",
        "error",
        "diagnostic",
    ]
}

extension DirectRealtimeController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if url?.scheme == "about"
            || Self.originString(for: url) == trustedOrigin {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("Boolean(window.VoiceRelayNativeVoice?.start)") { [weak self] result, _ in
            guard let self, (result as? Bool) == true else { return }
            VoiceRelayDiagnostics.flow(
                "realtime_runtime_navigation_verified",
                fields: [
                    "ready_signal_received": String(self.isReady),
                    "source": "navigation_probe",
                ]
            )
        }
    }
}

private extension DirectRealtimeController {
    static let runtimeHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Voice Relay Realtime</title>
    </head>
    <body>
    <script>
    (() => {
      const native = window.webkit?.messageHandlers?.voiceRelay;
      const send = payload => native?.postMessage(payload);
      let session = null;
      let activeStartGeneration = 0;
      const handoffAcknowledgementCursor = { ko: 0, en: 0 };

      function state(phase, generation) {
        if (
          session
          && session.generation === generation
          && session.lastReportedPhase === phase
        ) {
          return;
        }
        if (session && session.generation === generation) {
          session.lastReportedPhase = phase;
        }
        send({ type: "state", phase, generation });
      }

      function diagnostic(stage, generation, extra = {}) {
        send({
          type: "diagnostic",
          stage,
          generation,
          ...extra
        });
      }

      function closeSession(generation, emitTerminal = true) {
        const current = session;
        session = null;
        if (current) {
          try { clearTimeout(current.draftFlushTimer); } catch (_) {}
        }
        if (emitTerminal) send({ type: "terminal", generation });
      }

      function dataSend(payload) {
        if (!session?.transportOpen) return false;
        send({
          type: "realtimeSend",
          generation: session.generation,
          eventJSON: JSON.stringify(payload)
        });
        return true;
      }

      function nextClientEventId(kind) {
        if (!session) return "";
        session.clientEventSequence += 1;
        return `voice-relay-${kind}-${session.generation}-${session.clientEventSequence}`;
      }

      function cancelActiveResponseForBargeIn() {
        if (!session || session.lifecycle !== "active"
            || session.responseCancelPending
            || !session.activeResponseId) {
          return false;
        }
        const eventId = nextClientEventId("cancel");
        diagnostic("response_cancel_requested", session.generation, {
          eventID: eventId,
          reason: "admitted_barge_in",
          responseID: session.activeResponseId,
          turnID: String(session.activeUserTurn?.id || "")
        });
        session.responseCancelPending = true;
        session.expectedCancelEventIds.add(eventId);
        const sent = dataSend({
          type: "response.cancel",
          event_id: eventId,
          response_id: session.activeResponseId
        });
        if (!sent) {
          session.responseCancelPending = false;
          session.expectedCancelEventIds.delete(eventId);
          return false;
        }
        resetAssistantDraft();
        return true;
      }

      function finishInterruptedPlaybackForBargeIn() {
        if (!session) return;
        const responseIds = Array.from(session.audioResponseIds);
        if (responseIds.length === 0) {
          processNextAcceptedTurn();
          return;
        }
        const responseId = String(responseIds.at(-1) || "");
        for (const interruptedId of responseIds) {
          const playedText = String(
            session.assistantPlaybackTextByResponseId.get(interruptedId) || ""
          ).trim();
          if (playedText) {
            session.recentAssistantPlaybackTexts.push({
              text: playedText,
              expiresAt: Date.now() + 8_000
            });
          }
          session.audioResponseIds.delete(interruptedId);
          session.finalAudioResponseIds.delete(interruptedId);
          session.assistantPlaybackTextByResponseId.delete(interruptedId);
        }
        pruneRecentAssistantPlaybackTexts();
        if (!session.activeResponseId && session.codexSpeechInFlight) {
          finishActiveCodexSpeech(responseId);
        } else {
          processNextAcceptedTurn();
        }
      }

      function recoverFromRealtimeServerError(event, generation) {
        const error = event?.error || {};
        const causalEventId = String(error.event_id || "");
        const responseId = String(session?.activeResponseId || "");
        if (causalEventId.startsWith("voice-relay-truncate-")) {
          diagnostic("truncate_rejected", generation, {
            code: String(error.code || ""),
            errorType: String(error.type || ""),
            eventID: causalEventId
          });
          return;
        }
        diagnostic("server_error", generation, {
          code: String(error.code || ""),
          errorType: String(error.type || ""),
          eventID: causalEventId
        });

        if (responseId) {
          session.codexSpeechResponseKinds.delete(responseId);
          session.progressResponseIds.delete(responseId);
          session.transientAssistantTranscripts.delete(responseId);
        }
        session.activeResponseId = "";
        session.responseCancelPending = false;
        session.expectedCancelEventIds.clear();

        if (session.codexSpeechInFlight) {
          finishActiveCodexSpeech(responseId);
        }
        if (session.codexInFlight) {
          state("thinking", generation);
          return;
        }

        session.pendingCalls.clear();
        session.awaitingFinal = false;
        resetAssistantDraft();
        send({
          type: "turnError",
          generation,
          code: String(error.code || "")
        });
        completeAcceptedTurn();
      }

      function responseText(response) {
        const output = Array.isArray(response?.output) ? response.output : [];
        const hasFunctionCall = output.some(item => item?.type === "function_call");
        if (hasFunctionCall) return "";
        const preferred = output.filter(item =>
          item?.phase === "final_answer" || !item?.phase
        );
        const source = preferred.length > 0 ? preferred : output;
        const pieces = [];
        for (const item of source) {
          for (const content of Array.isArray(item?.content) ? item.content : []) {
            const text = String(content?.transcript || content?.text || "").trim();
            if (text) pieces.push(text);
          }
        }
        return pieces.join("\n").trim();
      }

      function flushAssistantDraft() {
        if (!session) return;
        try { clearTimeout(session.draftFlushTimer); } catch (_) {}
        session.draftFlushTimer = null;
        const value = String(session.currentAssistantTranscript || "").trim();
        if (!value || value === session.lastReportedAssistantDraft) return;
        session.lastReportedAssistantDraft = value;
        send({
          type: "assistantPartial",
          generation: session.generation,
          text: value
        });
      }

      function queueAssistantDraft(delta, responseId = "") {
        const normalizedResponseId = String(responseId || "");
        const speechKind = activeCodexSpeechKind(normalizedResponseId);
        if (!session
            || isTransientCodexSpeechKind(speechKind)
            || session.progressResponseIds.has(normalizedResponseId)
            || session.stopAcknowledgementResponseIds.has(normalizedResponseId)) {
          return;
        }
        const value = String(delta || "");
        if (!value) return;
        session.currentAssistantTranscript += value;
        if (session.draftFlushTimer) return;
        session.draftFlushTimer = setTimeout(flushAssistantDraft, 80);
      }

      function publishTransientAssistantDraft(delta, responseId = "") {
        if (!session) return;
        const normalizedResponseId = String(responseId || "");
        const speechKind = activeCodexSpeechKind(normalizedResponseId);
        if (!isTransientCodexSpeechKind(speechKind)
            && !session.progressResponseIds.has(normalizedResponseId)) {
          return;
        }
        const current = String(
          session.transientAssistantTranscripts.get(normalizedResponseId) || ""
        );
        const value = `${current}${String(delta || "")}`.trim();
        if (!value) return;
        session.transientAssistantTranscripts.set(normalizedResponseId, value);
        if (speechKind === "codex_commentary") {
          return;
        }
        send({
          type: "assistantProgress",
          generation: session.generation,
          responseId: normalizedResponseId,
          kind: speechKind,
          text: value
        });
      }

      function rememberAssistantPlaybackText(
        responseId,
        text,
        replace = false
      ) {
        if (!session) return;
        const normalizedResponseId = String(
          responseId || session.activeResponseId || ""
        );
        const value = String(text || "");
        if (!normalizedResponseId || !value) return;
        const previous = String(
          session.assistantPlaybackTextByResponseId.get(
            normalizedResponseId
          ) || ""
        );
        session.assistantPlaybackTextByResponseId.set(
          normalizedResponseId,
          replace ? value : `${previous}${value}`
        );
      }

      function normalizedEchoText(text) {
        return String(text || "")
          .normalize("NFKC")
          .toLocaleLowerCase()
          .replace(/[^\p{L}\p{N}]+/gu, "");
      }

      function echoBigramSimilarity(lhs, rhs) {
        if (lhs === rhs) return 1;
        if (lhs.length < 2 || rhs.length < 2) return 0;
        const counts = new Map();
        for (let index = 0; index < lhs.length - 1; index += 1) {
          const gram = lhs.slice(index, index + 2);
          counts.set(gram, (counts.get(gram) || 0) + 1);
        }
        let overlap = 0;
        for (let index = 0; index < rhs.length - 1; index += 1) {
          const gram = rhs.slice(index, index + 2);
          const count = counts.get(gram) || 0;
          if (count <= 0) continue;
          overlap += 1;
          counts.set(gram, count - 1);
        }
        return (2 * overlap) / (lhs.length + rhs.length - 2);
      }

      function pruneRecentAssistantPlaybackTexts() {
        if (!session) return;
        const now = Date.now();
        session.recentAssistantPlaybackTexts =
          session.recentAssistantPlaybackTexts.filter(
            item => Number(item.expiresAt || 0) > now
          );
      }

      function rememberAcceptedUserTurn(text) {
        if (!session) return;
        const normalized = normalizedEchoText(text);
        if (!normalized) return;
        session.primaryUserTurnKey = normalized;
        session.primaryUserTurnGuardUntil =
          Number.POSITIVE_INFINITY;
        session.recentAcceptedUserTurns.push(normalized);
        if (session.recentAcceptedUserTurns.length > 8) {
          session.recentAcceptedUserTurns.shift();
        }
      }

      function protectCompletedPrimaryUserTurn() {
        if (!session || !session.primaryUserTurnKey) return;
        session.primaryUserTurnGuardUntil = Math.max(
          Number(session.primaryUserTurnGuardUntil || 0),
          Date.now() + 6_000
        );
      }

      function isRepeatedPrimaryUserTurn(text) {
        if (!session || !session.primaryUserTurnKey) return false;
        const normalized = normalizedEchoText(text);
        if (!normalized
            || normalized !== session.primaryUserTurnKey) {
          return false;
        }
        const primaryTurnIsActive =
          session.routeInFlight
          || session.codexInFlight
          || session.controlRouteInFlight
          || session.codexSpeechInFlight
          || Boolean(session.activeResponseId)
          || session.audioResponseIds.size > 0
          || session.finalAudioResponseIds.size > 0;
        return primaryTurnIsActive
          || Date.now()
            <= Number(session.primaryUserTurnGuardUntil || 0);
      }

      function isRepeatedUserTurnDuringActiveRequest(text) {
        if (!session) return false;
        if (isRepeatedPrimaryUserTurn(text)) return true;
        pruneRecentAssistantPlaybackTexts();
        const requestOrPlaybackIsActive =
          session.routeInFlight
          || session.codexInFlight
          || session.audioResponseIds.size > 0
          || session.assistantPlaybackTextByResponseId.size > 0
          || session.recentAssistantPlaybackTexts.length > 0;
        if (!requestOrPlaybackIsActive) return false;
        const normalized = normalizedEchoText(text);
        return Boolean(
          normalized
          && session.recentAcceptedUserTurns.includes(normalized)
        );
      }

      function registerCompletedUserAudioItem(event) {
        if (!session) return false;
        const itemId = String(
          event?.item_id || event?.item?.id || ""
        ).trim();
        if (!itemId) return false;
        if (session.completedUserAudioItemIds.has(itemId)) {
          return true;
        }
        session.completedUserAudioItemIds.add(itemId);
        if (session.completedUserAudioItemIds.size > 64) {
          const oldest = session.completedUserAudioItemIds.values()
            .next().value;
          if (oldest) session.completedUserAudioItemIds.delete(oldest);
        }
        return false;
      }

      function suppressRepeatedUserAudioTurn(
        generation,
        stage,
        text = "",
        extra = {}
      ) {
        diagnostic(stage, generation, {
          ...extra,
          text: String(text || "")
        });
        send({
          type: "playbackResume",
          generation: session.generation
        });
        send({
          type: "userTranscriptPartial",
          generation: session.generation,
          text: ""
        });
      }

      function isLikelyAssistantPlaybackEcho(text) {
        if (!session) return false;
        const candidate = normalizedEchoText(text);
        if (!candidate) return false;
        pruneRecentAssistantPlaybackTexts();
        const activeSources = [
          ...session.assistantPlaybackTextByResponseId.values()
        ];
        if (activeSources.some(sourceText =>
          normalizedEchoText(sourceText) === candidate
        )) {
          return true;
        }
        if (candidate.length < 4) return false;
        const sources = [
          ...activeSources,
          ...session.recentAssistantPlaybackTexts.map(item => item.text)
        ];
        return sources.some(sourceText => {
          const source = normalizedEchoText(sourceText);
          if (source.length < 4) return false;
          const shorter = Math.min(candidate.length, source.length);
          const longer = Math.max(candidate.length, source.length);
          const containment =
            (candidate.includes(source) || source.includes(candidate))
            && shorter >= 5
            && shorter / longer >= 0.42;
          return containment
            || echoBigramSimilarity(candidate, source) >= 0.72;
        });
      }

      function emitAssistantFinalOnce(text, responseId = "") {
        const value = String(text || "").trim();
        if (!session || !session.awaitingFinal || !value) return false;
        const key = String(responseId || `text:${value}`);
        if (session.reportedAssistantResponses.has(key)) return false;
        rememberAssistantPlaybackText(key, value, true);
        session.currentAssistantTranscript = value;
        flushAssistantDraft();
        session.reportedAssistantResponses.add(key);
        if (responseId) {
          session.finalAudioResponseIds.add(String(responseId));
        }
        session.awaitingFinal = false;
        session.lastAudioTranscript = "";
        send({
          type: "assistantFinal",
          generation: session.generation,
          responseId: String(responseId || ""),
          text: value
        });
        return true;
      }

      function handoffAcknowledgementLanguage(text) {
        const value = String(text || "");
        if (/[\u3131-\u318e\uac00-\ud7a3]/u.test(value)) return "ko";
        if (/[A-Za-z]/u.test(value)) return "en";
        const configured = String(
          session?.startPayload?.language || ""
        ).toLocaleLowerCase();
        return configured.startsWith("ko") ? "ko" : "en";
      }

      function reserveHandoffAcknowledgement(text) {
        const language = handoffAcknowledgementLanguage(text);
        const variants = language === "ko"
          ? [
              "알겠어, 바로 살펴볼게.",
              "좋아, 맡겨줘.",
              "응, 처리하고 알려줄게.",
              "알겠어, 이어서 알려줄게."
            ]
          : [
              "Got it, I’m on it.",
              "Sure, I’ll look into it.",
              "Okay, I’ll report back shortly.",
              "Understood, leave it with me."
            ];
        const index = handoffAcknowledgementCursor[language] % variants.length;
        handoffAcknowledgementCursor[language] = index + 1;
        return variants[index];
      }

      function handoffProgressInstructions(text) {
        const acknowledgement = reserveHandoffAcknowledgement(text);
        return (
          "Speak exactly this acknowledgement, with no additions or omissions: "
          + JSON.stringify(acknowledgement)
        );
      }

      function isTransientCodexSpeechKind(kind) {
        return new Set([
          "codex_progress",
          "codex_commentary",
          "codex_steer",
          "codex_acknowledgement"
        ]).has(String(kind || ""));
      }

      function activeCodexSpeechKind(responseId = "") {
        const normalizedResponseId = String(responseId || "");
        const responseKind = String(
          session?.codexSpeechResponseKinds?.get(normalizedResponseId) || ""
        );
        if (responseKind) return responseKind;
        if (normalizedResponseId) return "";
        return String(session?.activeCodexSpeech?.kind || "");
      }

      function codexCommentarySpeechDelta(text) {
        if (!session) return "";
        const value = String(text || "").trim();
        if (!value) return "";
        for (const previous of session.spokenCodexCommentaryTexts
          .slice()
          .reverse()) {
          if (value === previous || previous.startsWith(value)) {
            return "";
          }
          if (value.startsWith(previous)) {
            const suffix = value.slice(previous.length).trim();
            session.spokenCodexCommentaryTexts.push(value);
            if (session.spokenCodexCommentaryTexts.length > 8) {
              session.spokenCodexCommentaryTexts.shift();
            }
            return suffix;
          }
        }
        session.spokenCodexCommentaryTexts.push(value);
        if (session.spokenCodexCommentaryTexts.length > 8) {
          session.spokenCodexCommentaryTexts.shift();
        }
        return value;
      }

      function startNextCodexSpeech() {
        if (!session || session.lifecycle !== "active"
            || session.codexSpeechInFlight
            || session.controlRouteInFlight
            || session.activeResponseId
            || session.responseCancelPending
            || session.codexSpeechQueue.length === 0) {
          return;
        }
        const command = session.codexSpeechQueue.shift();
        session.codexSpeechInFlight = true;
        session.activeCodexSpeech = command;
        diagnostic("codex_speech_response_requested", session.generation, {
          reason: command.kind,
          source: command.eventId,
          turnID: String(session.activeUserTurn?.id || "")
        });
        if (command.marksAwaitingFinal) {
          resetAssistantDraft();
          session.awaitingFinal = true;
        }
        const sent = dataSend({
          type: "response.create",
          event_id: command.eventId,
          response: {
            ...(command.detached ? { conversation: "none" } : {}),
            output_modalities: ["audio"],
            tool_choice: "none",
            metadata: {
              voice_relay_kind: command.kind,
              voice_relay_seq: String(command.sequence)
            },
            instructions: command.instructions
          }
        });
        if (!sent) {
          session.codexSpeechInFlight = false;
          session.activeCodexSpeech = null;
          if (command.marksAwaitingFinal) {
            session.awaitingFinal = false;
          }
        }
      }

      function enqueueCodexSpeech(kind, instructions, options = {}) {
        if (!session || session.lifecycle !== "active") return false;
        const command = {
          kind: String(kind || ""),
          instructions: String(instructions || "").trim(),
          marksAwaitingFinal: Boolean(options.marksAwaitingFinal),
          detached: options.detached !== false,
          sequence: ++session.codexSpeechSequence,
          eventId: nextClientEventId("codex-speech")
        };
        if (!command.kind || !command.instructions) return false;
        session.codexSpeechQueue.push(command);
        startNextCodexSpeech();
        return true;
      }

      function finishActiveCodexSpeech(responseId = "") {
        if (!session) return;
        const normalizedResponseId = String(responseId || "");
        if (normalizedResponseId) {
          session.audioResponseIds.delete(normalizedResponseId);
          session.codexSpeechResponseKinds.delete(normalizedResponseId);
          session.progressResponseIds.delete(normalizedResponseId);
          session.transientAssistantTranscripts.delete(normalizedResponseId);
        }
        session.codexSpeechInFlight = false;
        session.activeCodexSpeech = null;
        startNextActiveCodexControlTurn();
        startNextCodexSpeech();
        processNextAcceptedTurn();
      }

      function isMeaningfulSpeechTranscript(text) {
        const value = String(text || "").trim();
        if (!value) return false;
        if (/^[\s\p{P}\p{S}]+$/u.test(value)) return false;
        if (/^[\[(<].*(cough|throat|breath|sigh|noise|기침|헛기침|숨|한숨|목\s*가다듬).*[)\]>]$/iu.test(value)) {
          return false;
        }
        const compact = value
          .toLocaleLowerCase()
          .replace(/[^\p{L}\p{N}]+/gu, "");
        const nonLexical = new Set([
          "ahem", "ah", "eh", "er", "erm", "hm", "hmm", "hmmm", "mm", "mmm",
          "uh", "uhh", "um", "umm", "huh",
          "아", "어", "음", "으음", "흠", "흠흠", "에헴", "크흠", "큼", "응"
        ]);
        if (!compact || nonLexical.has(compact)) return false;
        return /[\p{L}\p{N}]/u.test(compact);
      }

      function resetAssistantDraft() {
        if (!session) return;
        session.awaitingFinal = false;
        session.lastAudioTranscript = "";
        session.currentAssistantTranscript = "";
        session.lastReportedAssistantDraft = "";
        try { clearTimeout(session.draftFlushTimer); } catch (_) {}
        session.draftFlushTimer = null;
      }

      function routeVoiceTurnTool() {
        return {
          type: "function",
          name: "route_voice_turn",
          description:
            "Classify one completed voice turn immediately. Direct chat is only pure social speech that needs no facts or context. Any factual, current-state, personal-context, device-state, external-information, calculation, verification, lookup, analysis, tool, file, app, memory, or source-dependent request must use codex. If a complete reliable answer could take more than about five seconds, use codex. When in doubt, use codex. Do not speak before this tool call.",
          parameters: {
            type: "object",
            properties: {
              kind: {
                type: "string",
                enum: [
                  "stop_session",
                  "local_datetime",
                  "direct_chat",
                  "local_identity",
                  "local_wake",
                  "local_presence",
                  "codex",
                  "clarify",
                  "ignore"
                ]
              }
            },
            required: ["kind"],
            additionalProperties: false
          }
        };
      }

      function normalizeRouteKind(value) {
        const kind = String(value || "");
        const allowed = new Set([
          "stop_session",
          "local_datetime",
          "direct_chat",
          "local_identity",
          "local_wake",
          "local_presence",
          "codex",
          "clarify",
          "ignore"
        ]);
        return allowed.has(kind) ? kind : "codex";
      }

      function requestRouteDecision() {
        return dataSend({
          type: "response.create",
          response: {
            output_modalities: ["text"],
            tools: [routeVoiceTurnTool()],
            tool_choice: "required",
            parallel_tool_calls: false,
            metadata: { voice_relay_kind: "route_classifier" },
            instructions:
              "Call route_voice_turn immediately. Decide semantically from the complete utterance. Direct chat is only pure social speech with no factual or contextual content. Every current, factual, personal-context, device-state, external-information, calculation, verification, lookup, analysis, tool, file, app, memory, or source-dependent request must use codex. When in doubt, use codex. Do not answer or produce audio before the tool call."
          }
        });
      }

      function isAwaitingRouteDecision() {
        return Boolean(
          session
          && session.routeInFlight
          && session.pendingCalls.size === 0
          && !session.awaitingFinal
          && !session.codexInFlight
        );
      }

      function processNextAcceptedTurn() {
        if (!session || session.lifecycle !== "active"
            || session.routeInFlight
            || session.activeResponseId
            || session.responseCancelPending
            || session.codexSpeechInFlight
            || session.audioResponseIds.size > 0
            || session.acceptedTurnQueue.length === 0) {
          return;
        }
        const turn = session.acceptedTurnQueue.shift();
        session.activeUserTurn = turn;
        session.routeInFlight = true;
        session.routeClassifierRetryCount = 0;
        rememberAcceptedUserTurn(turn.text);
        diagnostic("user_turn_started", session.generation, {
          source: turn.inputText ? "prefill" : "realtime_transcript",
          text: turn.text,
          turnID: String(turn.id || "")
        });
        resetAssistantDraft();
        if (turn.inputText) {
          dataSend({
            type: "conversation.item.create",
            item: {
              type: "message",
              role: "user",
              content: [{ type: "input_text", text: turn.text }]
            }
          });
        }
        session.userTurnCount += 1;
        if (!turn.transcriptAlreadyReported
            && !turn.playbackContended) {
          send({
            type: "userTranscript",
            generation: session.generation,
            text: turn.text
          });
          turn.transcriptAlreadyReported = true;
        }
        requestRouteDecision();
        state("thinking", session.generation);
      }

      function acceptUserTurn(
        text,
        inputText = false,
        transcriptAlreadyReported = false,
        playbackContended = false
      ) {
        if (!session || session.lifecycle !== "active") return false;
        const value = String(text || "").trim();
        if (!value) return false;
        if (isRepeatedPrimaryUserTurn(value)) {
          suppressRepeatedUserAudioTurn(
            session.generation,
            "duplicate_user_turn_acceptance_suppressed",
            value
          );
          return false;
        }
        const turnID = `turn-${session.generation}-${++session.turnSequence}`;
        session.acceptedTurnQueue.push({
          id: turnID,
          text: value,
          inputText: Boolean(inputText),
          transcriptAlreadyReported: Boolean(transcriptAlreadyReported),
          playbackContended: Boolean(playbackContended)
        });
        diagnostic("user_turn_queued", session.generation, {
          reason: playbackContended
            ? "playback_contended"
            : "normal",
          source: inputText ? "prefill" : "realtime_transcript",
          text: value,
          turnID
        });
        processNextAcceptedTurn();
        return true;
      }

      function reportActiveUserTurnIfNeeded() {
        const turn = session?.activeUserTurn;
        if (!turn || turn.transcriptAlreadyReported) return;
        send({
          type: "userTranscript",
          generation: session.generation,
          text: turn.text
        });
        turn.transcriptAlreadyReported = true;
      }

      function completeAcceptedTurn() {
        if (!session || session.lifecycle !== "active") return;
        protectCompletedPrimaryUserTurn();
        session.routeInFlight = false;
        session.activeUserTurn = null;
        if (session.acceptedTurnQueue.length > 0) {
          processNextAcceptedTurn();
        } else if (session.finalAudioResponseIds.size === 0) {
          state("listening", session.generation);
        }
      }

      function activeCodexControlTool() {
        return {
          type: "function",
          name: "route_active_codex_turn",
          description:
            "Classify speech received while a Codex task is running. Choose stop_session only for an unambiguous request to stop, cancel, or end the current voice/Codex work. Choose steer_active_codex for an amendment, correction, or additional instruction. Choose acknowledge_only for a conversational receipt, approval, thanks, or acknowledgement that adds no work. Choose clarify only when the meaning cannot be distinguished.",
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                enum: [
                  "stop_session",
                  "steer_active_codex",
                  "acknowledge_only",
                  "clarify"
                ]
              }
            },
            required: ["action"],
            additionalProperties: false
          }
        };
      }

      function speakActiveCodexControlAcknowledgement(instructions) {
        enqueueCodexSpeech(
          "codex_steer",
          String(instructions || "").trim()
        );
      }

      function startNextActiveCodexControlTurn() {
        if (!session || session.lifecycle !== "active"
            || session.controlRouteInFlight
            || session.codexSpeechInFlight
            || session.activeResponseId
            || session.responseCancelPending
            || session.activeCodexControlQueue.length === 0) {
          return;
        }
        const text = session.activeCodexControlQueue.shift();
        session.activeCodexControlText = text;
        session.controlRouteInFlight = true;
        dataSend({
          type: "response.create",
          response: {
            conversation: "none",
            output_modalities: ["text"],
            input: [{
              type: "message",
              role: "user",
              content: [{ type: "input_text", text }]
            }],
            tools: [activeCodexControlTool()],
            tool_choice: "required",
            parallel_tool_calls: false,
            metadata: { voice_relay_kind: "active_codex_control" },
            instructions:
              "Call route_active_codex_turn immediately. Decide semantically from the complete utterance. Do not answer before the tool call, do not use a phrase list, and do not infer a stop from mere discussion of stopping."
          }
        });
      }

      function queueActiveCodexControlTurn(text) {
        if (!session || session.lifecycle !== "active") return false;
        const value = String(text || "").trim();
        if (!value) return false;
        if (isRepeatedPrimaryUserTurn(value)) {
          suppressRepeatedUserAudioTurn(
            session.generation,
            "duplicate_active_control_turn_suppressed"
          );
          return false;
        }
        session.activeCodexControlQueue.push(value);
        startNextActiveCodexControlTurn();
        return true;
      }

      function beginSemanticStop(text) {
        if (!session || session.lifecycle !== "active") return false;
        const value = String(text || "").trim();
        session.lifecycle = "stop_requested";
        session.acceptedTurnQueue.length = 0;
        session.activeCodexControlQueue.length = 0;
        session.codexSpeechQueue.length = 0;
        session.codexSpeechInFlight = false;
        session.activeCodexSpeech = null;
        session.codexSpeechResponseKinds.clear();
        session.activeUserTurn = null;
        session.activeCodexControlText = "";
        session.routeInFlight = false;
        session.controlRouteInFlight = false;
        send({
          type: "stopIntent",
          generation: session.generation,
          text: value
        });
        dataSend({
          type: "response.create",
          response: {
            conversation: "none",
            output_modalities: ["audio"],
            tool_choice: "none",
            metadata: { voice_relay_kind: "semantic_stop" },
            instructions:
              "Give one brief natural confirmation in the user's language that all current voice and Codex work has stopped. Do not add a new topic."
          }
        });
        return true;
      }

      function finishActiveCodexControlTurn(event) {
        if (!session || session.lifecycle !== "active"
            || !session.controlRouteInFlight) return;
        let args = {};
        try { args = JSON.parse(event.arguments || "{}"); } catch (_) {}
        const text = String(session.activeCodexControlText || "").trim();
        const action = String(args.action || "clarify");
        session.controlRouteInFlight = false;
        session.activeCodexControlText = "";

        if (action === "stop_session") {
          beginSemanticStop(text);
          return;
        }

        if (action === "steer_active_codex") {
          if (session.codexInFlight) {
            send({
              type: "codexSteer",
              generation: session.generation,
              text
            });
            speakActiveCodexControlAcknowledgement(
              "Give one brief natural acknowledgement in the user's language that the additional request will be applied now. Do not add facts, advice, or a new topic."
            );
          } else {
            acceptUserTurn(text, false, true);
          }
        } else if (action === "acknowledge_only") {
          enqueueCodexSpeech(
            "codex_acknowledgement",
            "Give one brief natural acknowledgement in the user's language. Do not add work, facts, advice, or a new topic."
          );
        } else {
          speakActiveCodexControlAcknowledgement(
            "Ask one brief clarification question in the user's language: should Voice Relay stop the current task, or add the request to it? Do not add facts or advice."
          );
        }
        startNextActiveCodexControlTurn();
      }

      function localDateTimeResult() {
        const now = new Date();
        const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || "local";
        return {
          iso: now.toISOString(),
          local: new Intl.DateTimeFormat(undefined, {
            dateStyle: "full",
            timeStyle: "long",
            timeZone
          }).format(now),
          timeZone
        };
      }

      function finishRoute(callId, output, instructions) {
        if (!session || session.lifecycle !== "active") return;
        session.pendingCalls.delete(callId);
        dataSend({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify(output)
          }
        });
        dataSend({
          type: "response.create",
          response: {
            tool_choice: "none",
            instructions
          }
        });
        session.awaitingFinal = true;
        state("thinking", session.generation);
      }

      function onRealtimeEvent(event, generation) {
        if (!session || session.generation !== generation) return;
        switch (event.type) {
          case "input_audio_buffer.speech_started":
            session.currentUserTranscript = "";
            diagnostic("vad_speech_started", generation, {
              reason: session.audioResponseIds.size > 0
                ? "during_playback"
                : "microphone_input",
              responseID: String(session.activeResponseId || ""),
              turnID: String(session.activeUserTurn?.id || "")
            });
            if (session.activeResponseId) {
              cancelActiveResponseForBargeIn();
            }
            send({
              type: "userTranscriptPartial",
              generation: session.generation,
              text: ""
            });
            break;
          case "input_audio_buffer.speech_stopped":
            diagnostic("vad_speech_stopped", generation, {
              text: String(session.currentUserTranscript || ""),
              turnID: String(session.activeUserTurn?.id || "")
            });
            break;
          case "conversation.item.input_audio_transcription.delta": {
            const delta = String(event.delta || "");
            if (!delta) break;
            session.currentUserTranscript += delta;
            diagnostic("realtime_transcript_partial", generation, {
              itemID: String(event.item_id || event.item?.id || ""),
              text: session.currentUserTranscript
            });
            send({
              type: "userTranscriptPartial",
              generation: session.generation,
              text: session.currentUserTranscript
            });
            break;
          }
          case "conversation.item.input_audio_transcription.completed": {
            const text = String(event.transcript || "").trim();
            session.currentUserTranscript = "";
            const itemID = String(
              event.item_id || event.item?.id || ""
            ).trim();
            diagnostic("realtime_transcript_completed", generation, {
              itemID,
              text
            });
            if (!isMeaningfulSpeechTranscript(text)) {
              diagnostic("non_meaningful_transcript_suppressed", generation, {
                itemID,
                text
              });
              break;
            }
            if (registerCompletedUserAudioItem(event)) {
              suppressRepeatedUserAudioTurn(
                generation,
                "duplicate_user_audio_item_suppressed",
                text,
                { itemID }
              );
              break;
            }
            if (isRepeatedUserTurnDuringActiveRequest(text)) {
              suppressRepeatedUserAudioTurn(
                generation,
                "replayed_user_turn_suppressed",
                text,
                { itemID }
              );
              break;
            }
            if (isLikelyAssistantPlaybackEcho(text)) {
              suppressRepeatedUserAudioTurn(
                generation,
                "playback_echo_transcript_suppressed",
                text,
                { itemID }
              );
              break;
            }
            pruneRecentAssistantPlaybackTexts();
            const hadBufferedPlayback = session.audioResponseIds.size > 0;
            const hadRecentPlaybackTail =
              session.recentAssistantPlaybackTexts.length > 0;
            const playbackContended =
              hadBufferedPlayback
              || session.finalAudioResponseIds.size > 0
              || session.assistantPlaybackTextByResponseId.size > 0
              || hadRecentPlaybackTail;
            if (playbackContended) {
              diagnostic("playback_contended_transcript_admitted", generation, {
                itemID,
                reason: hadBufferedPlayback
                  ? "buffered_playback"
                  : hadRecentPlaybackTail
                    ? "recent_playback_tail"
                    : "playback_tail",
                text
              });
            }
            if (session.activeResponseId || hadBufferedPlayback) {
              send({
                type: "playbackInterrupt",
                generation: session.generation
              });
            }
            if (session.activeResponseId) {
              cancelActiveResponseForBargeIn();
            }
            if (session.codexInFlight) {
              send({
                type: "userTranscript",
                generation: session.generation,
                text
              });
              queueActiveCodexControlTurn(text);
              if (hadBufferedPlayback) {
                finishInterruptedPlaybackForBargeIn();
              }
              break;
            }
            acceptUserTurn(text, false, false, playbackContended);
            if (hadBufferedPlayback) {
              finishInterruptedPlaybackForBargeIn();
            }
            break;
          }
          case "response.function_call_arguments.done": {
            if (event.name === "route_active_codex_turn") {
              finishActiveCodexControlTurn(event);
              break;
            }
            if (event.name !== "route_voice_turn") break;
            if (!isAwaitingRouteDecision()) break;
            const callId = String(event.call_id || "").trim();
            if (!callId) {
              diagnostic("route_invalid_call", generation);
              break;
            }
            session.lastAudioTranscript = "";
            let args = {};
            try { args = JSON.parse(event.arguments || "{}"); } catch (_) {}
            const text = String(session.activeUserTurn?.text || "").trim();
            if (!text) {
              finishRoute(
                event.call_id,
                { status: "clarify", reason: "missing transcript" },
                "Ask one short clarification question in the user's language."
              );
              break;
            }
            session.pendingCalls.add(callId);
            const kind = normalizeRouteKind(args.kind);
            const activeTurn = session.activeUserTurn;
            diagnostic("route_decision", generation, {
              callID: callId,
              kind,
              reason: activeTurn?.playbackContended
                ? "playback_contended"
                : "normal",
              text,
              turnID: String(activeTurn?.id || "")
            });
            const suppressiblePlaybackKinds = new Set([
              "direct_chat",
              "ignore",
              "local_presence",
              "local_wake"
            ]);
            if (activeTurn?.playbackContended
                && suppressiblePlaybackKinds.has(kind)) {
              session.pendingCalls.delete(callId);
              dataSend({
                type: "conversation.item.create",
                item: {
                  type: "function_call_output",
                  call_id: callId,
                  output: JSON.stringify({
                    status: "suppressed",
                    reason: "probable assistant playback echo"
                  })
                }
              });
              diagnostic(
                "playback_contended_social_turn_suppressed",
                generation,
                {
                  callID: callId,
                  kind,
                  text,
                  turnID: String(activeTurn?.id || "")
                }
              );
              completeAcceptedTurn();
              break;
            }
            reportActiveUserTurnIfNeeded();
            if (kind === "stop_session") {
              session.pendingCalls.delete(callId);
              beginSemanticStop(text);
              break;
            }
            if (kind === "local_datetime") {
              finishRoute(
                callId,
                { status: "ok", request: text, ...localDateTimeResult() },
                "Answer only the user's exact local time, date, or weekday question from the tool result. Use one short sentence in the user's language."
              );
              break;
            }
            if (kind === "direct_chat") {
              finishRoute(
                callId,
                { status: "ok", request: text },
                "Give one brief natural conversational reply to the exact request. This route is only for a greeting, thanks, goodbye, repeat request, conversational receipt, approval, or acknowledgement that adds no work. Do not add facts, advice, or a new topic."
              );
              break;
            }
            if (kind === "local_identity") {
              finishRoute(
                callId,
                {
                  status: "ok",
                  request: text,
                  productName: session.productName,
                  assistantName: session.assistantName
                },
                "Answer the exact identity question from the tool result in one short natural sentence in the user's language. Never invent a different name."
              );
              break;
            }
            if (kind === "local_wake") {
              finishRoute(
                callId,
                {
                  status: "ok",
                  request: text
                },
                "Give one brief natural acknowledgement in the user's language that you are listening. Do not mention Codex, checking, tools, or capabilities."
              );
              break;
            }
            if (kind === "local_presence") {
              finishRoute(
                callId,
                {
                  status: "ok",
                  request: text
                },
                "Give one brief natural acknowledgement in the user's language that you can hear the user. Do not mention Codex, checking, tools, or capabilities."
              );
              break;
            }
            if (kind === "ignore") {
              session.pendingCalls.delete(callId);
              dataSend({
                type: "conversation.item.create",
                item: {
                  type: "function_call_output",
                  call_id: callId,
                  output: JSON.stringify({ status: "ignored" })
                }
              });
              session.awaitingFinal = false;
              completeAcceptedTurn();
              break;
            }
            if (kind === "clarify") {
              finishRoute(
                callId,
                { status: "clarify", request: text },
                "Ask one short clarification question in the user's language. Do not guess."
              );
              break;
            }
            state("thinking", generation);
            session.codexInFlight = true;
            enqueueCodexSpeech(
              "codex_progress",
              handoffProgressInstructions(text)
            );
            send({
              type: "codexRequest",
              generation,
              callId,
              text
            });
            break;
          }
          case "response.output_audio.delta":
          case "response.audio.delta":
            if (isAwaitingRouteDecision()) break;
            if (event.response_id) {
              session.audioResponseIds.add(String(event.response_id));
            }
            state("speaking", generation);
            break;
          case "response.created":
            session.activeResponseId = String(event.response?.id || "");
            session.responseCancelPending = false;
            const responseKind = String(
              event.response?.metadata?.voice_relay_kind || ""
            );
            if (responseKind.startsWith("codex_")) {
              session.codexSpeechResponseKinds.set(
                session.activeResponseId,
                responseKind
              );
            }
            diagnostic("realtime_response_created", generation, {
              responseID: session.activeResponseId,
              source: responseKind || "unclassified",
              turnID: String(session.activeUserTurn?.id || "")
            });
            if (
              event.response?.metadata?.voice_relay_kind === "semantic_stop"
            ) {
              session.stopAcknowledgementResponseIds.add(
                String(event.response.id || "")
              );
              break;
            }
            if (
              isTransientCodexSpeechKind(responseKind)
            ) {
              session.progressResponseIds.add(String(event.response.id || ""));
            }
            break;
          case "response.output_audio_transcript.delta":
          case "response.audio_transcript.delta":
            if (isAwaitingRouteDecision()) break;
            rememberAssistantPlaybackText(
              event.response_id,
              event.delta
            );
            publishTransientAssistantDraft(event.delta, event.response_id);
            queueAssistantDraft(event.delta, event.response_id);
            break;
          case "response.output_audio_transcript.done":
          case "response.audio_transcript.done": {
            if (isAwaitingRouteDecision()) break;
            const responseId = String(event.response_id || "");
            rememberAssistantPlaybackText(
              responseId,
              event.transcript,
              true
            );
            diagnostic("assistant_audio_transcript_completed", generation, {
              assistantText: String(event.transcript || ""),
              responseID: responseId,
              source: activeCodexSpeechKind(responseId)
                || "realtime_direct",
              turnID: String(session.activeUserTurn?.id || "")
            });
            if (isTransientCodexSpeechKind(activeCodexSpeechKind(responseId))
                || session.progressResponseIds.has(responseId)
                || session.stopAcknowledgementResponseIds.has(responseId)) {
              const speechKind = activeCodexSpeechKind(responseId);
              const text = String(
                event.transcript
                  || session.transientAssistantTranscripts.get(responseId)
                  || ""
              ).trim();
              if (text && !session.stopAcknowledgementResponseIds.has(responseId)) {
                session.transientAssistantTranscripts.set(responseId, text);
                if (speechKind !== "codex_commentary") {
                  send({
                    type: "assistantProgress",
                    generation: session.generation,
                    responseId,
                    kind: speechKind,
                    text
                  });
                }
              }
              break;
            }
            const text = String(
              event.transcript || session.currentAssistantTranscript || ""
            ).trim();
            session.lastAudioTranscript = text;
            emitAssistantFinalOnce(
              text,
              responseId || event.item_id || ""
            );
            break;
          }
          case "response.done": {
            const responseId = String(event.response?.id || "");
            const responseKind = activeCodexSpeechKind(responseId)
              || String(event.response?.metadata?.voice_relay_kind || "");
            if (session.stopAcknowledgementResponseIds.has(responseId)) {
              break;
            }
            if (isTransientCodexSpeechKind(responseKind)) {
              if (!responseId || session.activeResponseId === responseId) {
                session.activeResponseId = "";
                session.responseCancelPending = false;
                session.expectedCancelEventIds.clear();
              }
              const responseStatus = String(event.response?.status || "");
              if (!session.audioResponseIds.has(responseId)
                  || (responseStatus && responseStatus !== "completed")) {
                finishActiveCodexSpeech(responseId);
              }
              state("thinking", generation);
              break;
            }
            const text = responseText(event.response)
              || String(session.lastAudioTranscript || "").trim();
            const output = Array.isArray(event.response?.output)
              ? event.response.output
              : [];
            const hasFunctionCall = output.some(item => item?.type === "function_call");
            const phases = Array.from(new Set(
              output.map(item => String(item?.phase || "unphased"))
            ));
            diagnostic("response_done", generation, {
              kind: responseKind || "unclassified",
              shape: phases.join(",") || "empty",
              responseID: responseId,
              status: String(event.response?.status || ""),
              text,
              turnID: String(session.activeUserTurn?.id || "")
            });
            if (responseKind === "route_classifier"
                && isAwaitingRouteDecision()) {
              if (session.routeClassifierRetryCount < 1) {
                session.routeClassifierRetryCount += 1;
                if (!responseId || session.activeResponseId === responseId) {
                  session.activeResponseId = "";
                  session.responseCancelPending = false;
                  session.expectedCancelEventIds.clear();
                }
                requestRouteDecision();
                state("thinking", generation);
                break;
              }
              session.routeClassifierRetryCount = 0;
              send({
                type: "turnError",
                generation,
                code: "route_classifier_failed"
              });
              completeAcceptedTurn();
              if (!responseId || session.activeResponseId === responseId) {
                session.activeResponseId = "";
                session.responseCancelPending = false;
                session.expectedCancelEventIds.clear();
              }
              processNextAcceptedTurn();
              break;
            }
            if (!hasFunctionCall && session.awaitingFinal && text) {
              emitAssistantFinalOnce(text, event.response?.id || "");
            }
            if (!hasFunctionCall && session.routeInFlight
                && session.pendingCalls.size === 0
                && !session.awaitingFinal) {
              completeAcceptedTurn();
            } else if (!session.routeInFlight && session.pendingCalls.size === 0) {
              if (!session.finalAudioResponseIds.has(responseId)) {
                state("listening", generation);
              }
            }
            if (!responseId || session.activeResponseId === responseId) {
              session.activeResponseId = "";
              session.responseCancelPending = false;
              session.expectedCancelEventIds.clear();
            }
            processNextAcceptedTurn();
            if (responseKind === "codex_final") {
              const responseStatus = String(event.response?.status || "");
              if (!session.audioResponseIds.has(responseId)
                  || (responseStatus && responseStatus !== "completed")) {
                finishActiveCodexSpeech(responseId);
              }
            } else {
              startNextActiveCodexControlTurn();
              startNextCodexSpeech();
            }
            break;
          }
          case "error": {
            const causalEventId = String(event.error?.event_id || "");
            if (causalEventId
                && session.expectedCancelEventIds.delete(causalEventId)) {
              const cancelledResponseId = session.activeResponseId;
              session.responseCancelPending = false;
              session.activeResponseId = "";
              if (session.routeInFlight && !session.codexInFlight) {
                session.routeInFlight = false;
                session.activeUserTurn = null;
                session.pendingCalls.clear();
                session.awaitingFinal = false;
              }
              diagnostic(
                "response_cancel_rejected",
                generation,
                { code: String(event.error?.code || "") }
              );
              if (session.codexSpeechInFlight) {
                finishActiveCodexSpeech(cancelledResponseId);
              } else {
                startNextActiveCodexControlTurn();
                startNextCodexSpeech();
                processNextAcceptedTurn();
              }
              break;
            }
            recoverFromRealtimeServerError(event, generation);
            break;
          }
        }
      }

      function start(payload) {
        const generation = Number(payload.generation || 0);
        closeSession(generation, false);
        activeStartGeneration = generation;
        state("starting", generation);
        session = {
          generation,
          lifecycle: "active",
          startPayload: payload,
          transportOpen: false,
          transportReady: false,
          pendingCalls: new Set(),
          reportedAssistantResponses: new Set(),
          finalAudioResponseIds: new Set(),
          audioResponseIds: new Set(),
          assistantPlaybackTextByResponseId: new Map(),
          recentAssistantPlaybackTexts: [],
          recentAcceptedUserTurns: [],
          primaryUserTurnKey: "",
          primaryUserTurnGuardUntil: 0,
          completedUserAudioItemIds: new Set(),
          progressResponseIds: new Set(),
          stopAcknowledgementResponseIds: new Set(),
          expectedCancelEventIds: new Set(),
          clientEventSequence: 0,
          activeResponseId: "",
          responseCancelPending: false,
          codexSpeechQueue: [],
          codexSpeechInFlight: false,
          activeCodexSpeech: null,
          codexSpeechSequence: 0,
          codexSpeechResponseKinds: new Map(),
          transientAssistantTranscripts: new Map(),
          spokenCodexCommentaryIds: new Set(),
          spokenCodexCommentaryTexts: [],
          awaitingFinal: false,
          userTurnCount: 0,
          turnSequence: 0,
          acceptedTurnQueue: [],
          activeUserTurn: null,
          routeInFlight: false,
          routeClassifierRetryCount: 0,
          codexInFlight: false,
          activeCodexControlQueue: [],
          activeCodexControlText: "",
          controlRouteInFlight: false,
          lastAudioTranscript: "",
          currentAssistantTranscript: "",
          currentUserTranscript: "",
          lastReportedAssistantDraft: "",
          lastReportedPhase: "",
          draftFlushTimer: null,
          productName: String(payload.productName || "Voice Relay"),
          assistantName: String(payload.assistantName || "Relay"),
          wakePhrases: Array.isArray(payload.wakePhrases)
            ? payload.wakePhrases.map(value => String(value || "")).filter(Boolean)
            : []
        };
        diagnostic("realtime_session_start_requested", generation, {
          reason: String(payload.activationReason || "manual"),
          text: String(payload.prefill || "")
        });
        diagnostic("credential_requested", generation);
        send({ type: "credentialRequest", generation });
      }

      function transportOpened(payload) {
        const generation = Number(payload.generation || 0);
        if (!session || session.generation !== generation
            || activeStartGeneration !== generation) return;
        session.transportOpen = true;
        diagnostic("transport_open", generation);
        const startPayload = session.startPayload || {};
        const primaryInputLanguage = String(startPayload.language || "")
          .replace(/_/g, "-")
          .split("-")[0]
          .toLocaleLowerCase();
        const acceptedLanguageCodes = [
          startPayload.language,
          ...(Array.isArray(startPayload.additionalLanguages)
            ? startPayload.additionalLanguages
            : [])
        ]
          .map(value => String(value || "").trim())
          .filter(Boolean);
        const configuredLanguageBoundary =
          "\n\n# Configured identity and languages\n" +
          `The configured assistant name is ${JSON.stringify(String(startPayload.assistantName || "Assistant"))}. ` +
          `The configured product name is ${JSON.stringify(String(startPayload.productName || "Voice Assistant"))}. ` +
          `The primary input language is ${JSON.stringify(primaryInputLanguage || "system")}. ` +
          `Also accept these configured languages: ${JSON.stringify(acceptedLanguageCodes)}. ` +
          "Reply in the language actually spoken by the user. " +
          "When a short utterance is ambiguous, prefer the primary input language and never switch scripts from weak evidence.";
        diagnostic("realtime_media_configured", generation, {
          channel: "input_and_output",
          kind: "server_vad",
          reason: "session_update",
          shape:
            "pcm24k;threshold=0.68;prefix_ms=300;silence_ms=1200;create_response=false;interrupt_response=false",
          source: "gpt-4o-mini-transcribe",
          status: String(startPayload.voice || "")
        });
        dataSend({
          type: "session.update",
          session: {
            type: "realtime",
            output_modalities: ["audio"],
            reasoning: { effort: startPayload.reasoningEffort },
            instructions:
              String(startPayload.instructions || "") +
              configuredLanguageBoundary +
              "\n\n# Non-editable routing boundary\n" +
              "For every user turn, call route_voice_turn. " +
              "Use stop_session for an unambiguous request to stop, cancel, or end the current voice or Codex work. " +
              "Use local_datetime only for the current device-local time, date, or weekday. " +
              "Use direct_chat only for pure social speech such as a greeting, thanks, goodbye, repeat request, conversational receipt, approval, or acknowledgement that adds no work. " +
              "Any factual, current-state, personal-context, device-state, external-information, calculation, or verification request must use codex. This applies even when you think the answer is unknown. " +
              "If a complete and reliable answer could take more than about five seconds, or could benefit from lookup, context, analysis, tools, files, apps, memory, or source verification, use codex. When in doubt, use codex. " +
              "Decide semantically from the complete utterance, not from a phrase list. " +
              "Use local_identity for questions about your configured assistant name or this product's configured name. " +
              "Use local_wake only when the complete utterance is just the configured assistant name or a configured wake phrase. " +
              "Use local_presence for a short presence, hearing, or listening check. " +
              "Use clarify only when the user clearly needs one short clarification. " +
              "Use ignore only for non-addressed noise. Use codex for everything else. " +
              "Call the route tool immediately without speaking first. " +
              "After a codex route, the native handoff flow creates the short progress response. " +
              "Never reveal private reasoning.",
            audio: {
              input: {
                format: {
                  type: "audio/pcm",
                  rate: 24000
                },
                transcription: {
                  model: "gpt-4o-mini-transcribe",
                  ...(primaryInputLanguage
                    ? { language: primaryInputLanguage }
                    : {})
                },
                turn_detection: {
                  type: "server_vad",
                  create_response: false,
                  interrupt_response: false,
                  threshold: 0.68,
                  prefix_padding_ms: 300,
                  silence_duration_ms: 1200
                }
              },
              output: {
                format: {
                  type: "audio/pcm",
                  rate: 24000
                },
                voice: startPayload.voice
              }
            },
            tools: [routeVoiceTurnTool()],
            tool_choice: "required"
          }
        });
      }

      function transportReady(payload) {
        const generation = Number(payload.generation || 0);
        if (!session || session.generation !== generation
            || activeStartGeneration !== generation
            || session.transportReady) return;
        session.transportReady = true;
        diagnostic("media_ready", generation);
        const startPayload = session.startPayload || {};
        const prefill = String(startPayload.prefill || "").trim();
        if (prefill) {
          acceptUserTurn(prefill, true);
        } else if (startPayload.shouldGreet) {
          session.awaitingFinal = true;
          dataSend({
            type: "response.create",
            response: {
              tool_choice: "none",
              metadata: {
                voice_relay_kind: "wake_acknowledgement"
              },
              instructions:
                `You are ${session.assistantName} in ${session.productName}. The user just called your configured wake phrase. Give one very brief, natural acknowledgement in ${startPayload.language || "the system language"} that you heard them and are listening, then stop and listen. Choose fresh wording freely instead of using a fixed stock phrase. Do not mention tools, routing, or capabilities.`
            }
          });
          state("speaking", generation);
        } else {
          state("listening", generation);
        }
      }

      function receiveRealtimeEvent(payload) {
        const generation = Number(payload.generation || 0);
        if (!session || session.generation !== generation) return;
        const event = payload.event;
        if (!event || typeof event.type !== "string") return;
        onRealtimeEvent(event, generation);
      }

      function stop(payload) {
        const generation = Number(payload.generation || 0);
        diagnostic("realtime_session_stop_requested", generation, {
          reason: String(payload.reason || "host_stop")
        });
        if (activeStartGeneration === generation) {
          activeStartGeneration = 0;
        }
        closeSession(generation, true);
      }

      function playbackDrained(payload) {
        const generation = Number(payload.generation || 0);
        const responseId = String(payload.responseId || "");
        if (!session || session.generation !== generation || !responseId) {
          return;
        }
        if (session.stopAcknowledgementResponseIds.delete(responseId)) {
          send({
            type: "stopAcknowledgementDrained",
            generation,
            responseId
          });
          return;
        }
        const responseKind = activeCodexSpeechKind(responseId);
        const wasFinal = session.finalAudioResponseIds.delete(responseId);
        const playedText = String(
          session.assistantPlaybackTextByResponseId.get(responseId) || ""
        ).trim();
        session.assistantPlaybackTextByResponseId.delete(responseId);
        if (playedText) {
          session.recentAssistantPlaybackTexts.push({
            text: playedText,
            expiresAt: Date.now() + 8_000
          });
          pruneRecentAssistantPlaybackTexts();
        }
        session.audioResponseIds.delete(responseId);
        diagnostic("assistant_playback_drained", generation, {
          assistantText: playedText,
          responseID: responseId,
          source: responseKind || "realtime_direct",
          status: wasFinal ? "final" : "transient",
          turnID: String(session.activeUserTurn?.id || "")
        });
        if (responseKind.startsWith("codex_")) {
          finishActiveCodexSpeech(responseId);
        }
        processNextAcceptedTurn();
        if (wasFinal) {
          protectCompletedPrimaryUserTurn();
          send({
            type: "assistantPlaybackDrained",
            generation,
            responseId
          });
        }
        if (session.finalAudioResponseIds.size === 0
            && !session.routeInFlight
            && session.pendingCalls.size === 0
            && !session.codexInFlight) {
          state("listening", generation);
        }
      }

      function resolveCodex(payload) {
        if (!session || session.lifecycle !== "active"
            || session.generation !== Number(payload.generation)) return;
        session.codexInFlight = false;
        session.pendingCalls.delete(payload.callId);
        diagnostic("codex_result_received", session.generation, {
          assistantText: String(payload.output || payload.error || ""),
          callID: String(payload.callId || ""),
          status: payload.error ? "failure" : "success",
          turnID: String(session.activeUserTurn?.id || "")
        });
        const output = JSON.stringify(payload.error
          ? { status: "error", message: String(payload.error) }
          : { status: "ok", answer: String(payload.output || "") });
        dataSend({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: payload.callId,
            output
          }
        });
        enqueueCodexSpeech(
          "codex_final",
          "Speak the Codex result faithfully and concisely in the user's language. Do not add unsupported facts. If status is error, give one short friendly retry suggestion without exposing raw diagnostics.",
          {
            marksAwaitingFinal: true,
            detached: false
          }
        );
        state("thinking", session.generation);
      }

      function speakCodexCommentary(payload) {
        const generation = Number(payload.generation || 0);
        const text = String(payload.text || "").trim();
        const messageId = String(payload.messageId || `text:${text}`);
        if (!session || session.lifecycle !== "active"
            || session.generation !== generation
            || !session.codexInFlight
            || !text
            || session.spokenCodexCommentaryIds.has(messageId)) {
          return;
        }
        session.spokenCodexCommentaryIds.add(messageId);
        const speechText = codexCommentarySpeechDelta(text);
        if (!speechText) return;
        diagnostic("codex_commentary_received", generation, {
          assistantText: speechText,
          source: messageId,
          turnID: String(session.activeUserTurn?.id || "")
        });
        enqueueCodexSpeech(
          "codex_commentary",
          `Say exactly this and nothing else: ${JSON.stringify(speechText)}`
        );
      }

      function resolveCodexSteer(payload) {
        if (!session || session.lifecycle !== "active"
            || session.generation !== Number(payload.generation)) return;
        if (!payload.error) return;
        const message = "I couldn't add that instruction to the active Codex task.";
        enqueueCodexSpeech(
          "codex_steer",
          `Say this briefly in the user's current language: ${JSON.stringify(message)}`
        );
        state("thinking", session.generation);
      }

      window.VoiceRelayNativeVoice = {
        start,
        stop,
        transportOpened,
        transportReady,
        receiveRealtimeEvent,
        playbackDrained,
        speakCodexCommentary,
        resolveCodex,
        resolveCodexSteer
      };
      send({ type: "ready" });
    })();
    </script>
    </body>
    </html>
    """#
}
