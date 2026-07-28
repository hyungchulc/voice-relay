import Foundation
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
    private var pendingStart: (generation: Int, prefill: String?, shouldGreet: Bool)?
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
            NSLog(
                "Voice Relay native Realtime stage=%@ generation=%d captured=%d sent=%d received=%d rendered=%d dropped=%d voiceProcessing=%@",
                snapshot.stage,
                snapshot.generation,
                snapshot.capturedChunks,
                snapshot.sentChunks,
                snapshot.receivedChunks,
                snapshot.renderedChunks,
                snapshot.droppedCaptureChunks,
                snapshot.voiceProcessingEnabled ? "on" : "off"
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
        shouldGreet: Bool = true
    ) {
        if let previousGeneration = activeGeneration,
           previousGeneration != generation {
            transport.stop(generation: previousGeneration)
        }
        pendingStart = (generation, prefill, shouldGreet)
        stoppingGenerations.remove(generation)
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
        startupRetryState.begin(generation: generation)
        activeGeneration = generation
        emitState("starting", generation: generation)
        flushPendingStartIfReady()
    }

    func stop(generation: Int) {
        pendingStart = nil
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
        startupRetryState.cancel(generation: generation)
        stoppingGenerations.insert(generation)
        stoppingGenerations = Set(
            stoppingGenerations.filter { $0 >= generation - 8 }
        )
        activeGeneration = nil
        transport.stop(generation: generation)
        evaluate(method: "stop", payload: ["generation": generation])
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
            transport.stop(generation: generation)
            evaluate(method: "stop", payload: ["generation": generation])
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
            isReady = true
            onEvent?(body)
            flushPendingStartIfReady()
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
            let peer = body["peer"] as? String ?? "-"
            let ice = body["ice"] as? String ?? "-"
            let channel = body["channel"] as? String ?? "-"
            let shape = body["shape"] as? String ?? "-"
            NSLog(
                "Voice Relay Realtime diagnostic stage=%@ peer=%@ ice=%@ channel=%@ shape=%@",
                stage,
                peer,
                ice,
                channel,
                shape
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
        guard let credentialProvider = onCredentialRequest
            ?? onSDPOffer.map({ legacy in
                { completion in legacy("", completion) }
            }) else {
            startupRetryState.cancel(generation: generation)
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
                        return
                    }
                    self.transport.start(
                        generation: generation,
                        model: credential.model,
                        ephemeralCredential: credential.value
                    )
                case let .failure(error):
                    self.startupRetryState.cancel(generation: generation)
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
            return
        }
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
        guard let onCodexRequest else {
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
                    self.evaluate(
                        method: "resolveCodex",
                        payload: [
                            "generation": generation,
                            "callId": callID,
                            "output": output,
                        ]
                    )
                case let .failure(error):
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
        "terminal",
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
            self.isReady = true
            self.onEvent?(["type": "ready"])
            self.flushPendingStartIfReady()
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
        send({
          type: "assistantProgress",
          generation: session.generation,
          responseId: normalizedResponseId,
          kind: speechKind,
          text: value
        });
      }

      function emitAssistantFinalOnce(text, responseId = "") {
        const value = String(text || "").trim();
        if (!session || !session.awaitingFinal || !value) return false;
        const key = String(responseId || `text:${value}`);
        if (session.reportedAssistantResponses.has(key)) return false;
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

      function handoffProgressInstructions(text) {
        const request = String(text || "").trim();
        return [
          "Give one brief, natural, non-question handoff acknowledgement in the user's language.",
          "State only that the request is being passed on or checked.",
          "Vary the wording naturally instead of using one stock phrase.",
          "For English, natural variants include 'Let me check' and 'I will look into that.'",
          "Use at most eight words.",
          "Never ask a question or request information from the user.",
          "Do not reference the request's subject or repeat words from it.",
          "Assume all configured private context is already attached.",
          "Do not answer any part of the request.",
          "Do not claim or imply a fact, result, location, user state, knowledge, uncertainty, inability, or missing information.",
          "Do not mention Codex, tools, routing, or private reasoning.",
          `Use only this text to identify the user's language: ${JSON.stringify(request)}`
        ].join(" ");
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
        const responseKind = String(
          session?.codexSpeechResponseKinds?.get(String(responseId || "")) || ""
        );
        if (responseKind) return responseKind;
        return String(session?.activeCodexSpeech?.kind || "");
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
          session.codexSpeechResponseKinds.delete(normalizedResponseId);
          session.progressResponseIds.delete(normalizedResponseId);
          session.transientAssistantTranscripts.delete(normalizedResponseId);
        }
        session.codexSpeechInFlight = false;
        session.activeCodexSpeech = null;
        startNextActiveCodexControlTurn();
        startNextCodexSpeech();
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

      function processNextAcceptedTurn() {
        if (!session || session.lifecycle !== "active"
            || session.routeInFlight
            || session.acceptedTurnQueue.length === 0) {
          return;
        }
        const turn = session.acceptedTurnQueue.shift();
        session.activeUserTurn = turn;
        session.routeInFlight = true;
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
        if (!turn.transcriptAlreadyReported) {
          send({
            type: "userTranscript",
            generation: session.generation,
            text: turn.text
          });
        }
        dataSend({ type: "response.create" });
        state("thinking", session.generation);
      }

      function acceptUserTurn(
        text,
        inputText = false,
        transcriptAlreadyReported = false
      ) {
        if (!session || session.lifecycle !== "active") return;
        session.acceptedTurnQueue.push({
          text: String(text || "").trim(),
          inputText: Boolean(inputText),
          transcriptAlreadyReported: Boolean(transcriptAlreadyReported)
        });
        processNextAcceptedTurn();
      }

      function completeAcceptedTurn() {
        if (!session || session.lifecycle !== "active") return;
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
        if (!session || session.lifecycle !== "active") return;
        session.activeCodexControlQueue.push(String(text || "").trim());
        startNextActiveCodexControlTurn();
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
            cancelActiveResponseForBargeIn();
            send({
              type: "userTranscriptPartial",
              generation: session.generation,
              text: ""
            });
            break;
          case "input_audio_buffer.speech_stopped":
            break;
          case "conversation.item.input_audio_transcription.delta": {
            const delta = String(event.delta || "");
            if (!delta) break;
            session.currentUserTranscript += delta;
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
            if (!isMeaningfulSpeechTranscript(text)) break;
            if (session.codexInFlight) {
              send({
                type: "userTranscript",
                generation: session.generation,
                text
              });
              queueActiveCodexControlTurn(text);
              break;
            }
            acceptUserTurn(text, false);
            break;
          }
          case "response.function_call_arguments.done": {
            if (event.name === "route_active_codex_turn") {
              finishActiveCodexControlTurn(event);
              break;
            }
            if (event.name !== "route_voice_turn") break;
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
            session.pendingCalls.add(event.call_id);
            const kind = String(args.kind || "codex");
            if (kind === "stop_session") {
              session.pendingCalls.delete(event.call_id);
              beginSemanticStop(text);
              break;
            }
            if (kind === "local_datetime") {
              finishRoute(
                event.call_id,
                { status: "ok", request: text, ...localDateTimeResult() },
                "Answer only the user's exact local time, date, or weekday question from the tool result. Use one short sentence in the user's language."
              );
              break;
            }
            if (kind === "direct_chat") {
              finishRoute(
                event.call_id,
                { status: "ok", request: text },
                "Give one brief natural conversational reply to the exact request. This route is only for a greeting, thanks, goodbye, repeat request, conversational receipt, approval, or acknowledgement that adds no work. Do not add facts, advice, or a new topic."
              );
              break;
            }
            if (kind === "local_identity") {
              finishRoute(
                event.call_id,
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
                event.call_id,
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
                event.call_id,
                {
                  status: "ok",
                  request: text
                },
                "Give one brief natural acknowledgement in the user's language that you can hear the user. Do not mention Codex, checking, tools, or capabilities."
              );
              break;
            }
            if (kind === "ignore") {
              session.pendingCalls.delete(event.call_id);
              dataSend({
                type: "conversation.item.create",
                item: {
                  type: "function_call_output",
                  call_id: event.call_id,
                  output: JSON.stringify({ status: "ignored" })
                }
              });
              session.awaitingFinal = false;
              completeAcceptedTurn();
              break;
            }
            if (kind === "clarify") {
              finishRoute(
                event.call_id,
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
              callId: event.call_id,
              text
            });
            break;
          }
          case "response.output_audio.delta":
          case "response.audio.delta":
            state("speaking", generation);
            break;
          case "response.created":
            session.activeResponseId = String(event.response?.id || "");
            session.responseCancelPending = false;
            const responseKind = String(
              event.response?.metadata?.voice_relay_kind
                || session.activeCodexSpeech?.kind
                || ""
            );
            if (responseKind.startsWith("codex_")) {
              session.codexSpeechResponseKinds.set(
                session.activeResponseId,
                responseKind
              );
            }
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
            publishTransientAssistantDraft(event.delta, event.response_id);
            queueAssistantDraft(event.delta, event.response_id);
            break;
          case "response.output_audio_transcript.done":
          case "response.audio_transcript.done": {
            const responseId = String(event.response_id || "");
            if (isTransientCodexSpeechKind(activeCodexSpeechKind(responseId))
                || session.progressResponseIds.has(responseId)
                || session.stopAcknowledgementResponseIds.has(responseId)) {
              const text = String(
                event.transcript
                  || session.transientAssistantTranscripts.get(responseId)
                  || ""
              ).trim();
              if (text && !session.stopAcknowledgementResponseIds.has(responseId)) {
                session.transientAssistantTranscripts.set(responseId, text);
                send({
                  type: "assistantProgress",
                  generation: session.generation,
                  responseId,
                  kind: activeCodexSpeechKind(responseId),
                  text
                });
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
              finishActiveCodexSpeech(responseId);
              state("thinking", generation);
              break;
            }
            const text = responseText(event.response)
              || String(session.lastAudioTranscript || "").trim();
            const output = Array.isArray(event.response?.output)
              ? event.response.output
              : [];
            const hasFunctionCall = output.some(item => item?.type === "function_call");
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
            if (responseKind === "codex_final") {
              finishActiveCodexSpeech(responseId);
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
              }
              break;
            }
            send({
              type: "error",
              generation,
              message: event.error?.message || "Realtime error"
            });
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
          awaitingFinal: false,
          userTurnCount: 0,
          acceptedTurnQueue: [],
          activeUserTurn: null,
          routeInFlight: false,
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
            tools: [{
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
            }],
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
              instructions:
                `You are ${session.assistantName} in ${session.productName}. Give one brief friendly greeting in ${startPayload.language || "the system language"}, then stop and listen. Do not mention tools or capabilities.`
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
        if (!session.finalAudioResponseIds.delete(responseId)) return;
        send({
          type: "assistantPlaybackDrained",
          generation,
          responseId
        });
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
        enqueueCodexSpeech(
          "codex_commentary",
          `Say exactly this and nothing else: ${JSON.stringify(text)}`
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
