import Darwin
import Foundation

enum CodexReasoningEffortOrder {
    private static let semanticRank = Dictionary(
        uniqueKeysWithValues: [
            "none",
            "minimal",
            "low",
            "medium",
            "high",
            "xhigh",
            "max",
            "ultra",
        ].enumerated().map { ($0.element, $0.offset) }
    )

    static func sorted(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let unique = values.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = value.lowercased()
            guard !value.isEmpty, seen.insert(identifier).inserted else {
                return nil
            }
            return value
        }
        return unique.sorted { lhs, rhs in
            let lhsIdentifier = lhs.lowercased()
            let rhsIdentifier = rhs.lowercased()
            let lhsRank = semanticRank[lhsIdentifier]
            let rhsRank = semanticRank[rhsIdentifier]
            switch (lhsRank, rhsRank) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                let insensitive = lhsIdentifier.compare(rhsIdentifier)
                return insensitive == .orderedSame
                    ? lhs < rhs
                    : insensitive == .orderedAscending
            }
        }
    }
}

struct CodexModelCapability: Equatable {
    let id: String
    let displayName: String
    let supportedReasoningEfforts: [String]
    let serviceTierIDs: [String]
}

struct CodexConnectionSnapshot {
    let accountDescription: String
    let models: [CodexModelCapability]
    let effectiveConfig: CodexEffectiveConfig
    let threadID: String

    var availableModels: [String] {
        models.map(\.id)
    }
}

struct CodexEffectiveConfig: Equatable {
    let model: String
    let reasoningEffort: String
    let serviceTier: String
    let sandbox: String
    let approvalPolicy: String

    var summary: String {
        "\(model) · \(reasoningEffort) · \(serviceTier) · \(sandbox) · \(approvalPolicy)"
    }
}

struct CodexTurnOptions {
    let workspacePath: String
    let preferredThreadID: String
    let preferredThreadTitle: String
    let model: String
    let reasoningEffort: String
    let serviceTier: String?
    let sandbox: String
    let approvalPolicy: String
    let additionalContext: [String: [String: String]]?
    let additionalContextProvidersEnabled: Bool
    let additionalContextProvidersRoot: String?
}

struct CodexAppConnectionResult {
    let remoteRPCReady: Bool
    let hostClaimRequired: Bool
    let environmentOnline: Bool
}

struct CodexCommentary: Equatable {
    let messageID: String
    let text: String
}

struct CodexContextOmission: Equatable {
    let source: String
    let reason: String
    let fallback: String
    let providerIndex: Int?
}

struct CodexConnectionResetResult {
    let localStateCleared: Bool
    let localDeviceKeyDeleted: Bool
    let remoteRevocationSupported: Bool
}

struct CodexSteerRequest: Equatable {
    let controlRequestID: String
    let voiceTurnID: String
    let generation: Int
    let text: String
}

struct CodexSteerReceipt: Equatable {
    let controlRequestID: String
    let voiceTurnID: String
    let codexTurnID: String
    let mutationDeadlineEpochMilliseconds: Int64
    let mutationDispatched: Bool

    func isAcceptable(
        nowEpochMilliseconds: Int64 = Int64(
            Date().timeIntervalSince1970 * 1_000
        )
    ) -> Bool {
        mutationDispatched
            && mutationDeadlineEpochMilliseconds > nowEpochMilliseconds
    }
}

struct CodexSteerDeadlineError: LocalizedError {
    let mutationDispatched: Bool?
    let failurePhase: String

    var errorDescription: String? {
        "The additional instruction deadline expired"
    }
}

enum CodexSteerFailureReason: String {
    case noActiveTurn = "no_active_turn"
    case rejected
    case timeout
    case malformedResult = "malformed_result"

    static func classify(_ error: Error) -> Self {
        if let error = error as? CodexAppRemoteError {
            switch error {
            case .requestTimedOut:
                return .timeout
            case .invalidResponse:
                return .malformedResult
            case let .remote(code, _)
                where code == "APP_REMOTE_NO_ACTIVE_TURN":
                return .noActiveTurn
            default:
                return .rejected
            }
        }
        if error is CodexSteerDeadlineError {
            return .timeout
        }
        return .rejected
    }
}

enum CodexSteerDeadline {
    static let mutationBudgetMilliseconds = 10 * 60 * 1_000
    static let deliveryMarginMilliseconds = 5_000
    static let clientRequestTimeout: TimeInterval = Double(
        mutationBudgetMilliseconds + deliveryMarginMilliseconds
    ) / 1_000
}

enum RealtimeCredentialPolicy {
    static let minimumRemainingLifetime: TimeInterval = 30

    static func canReuse(
        expiresAt: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        expiresAt - now >= minimumRemainingLifetime
    }

    static func evictionDelay(
        expiresAt: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> TimeInterval {
        max(0, expiresAt - now - minimumRemainingLifetime)
    }
}

enum CodexAppRemoteError: LocalizedError {
    case helperUnavailable(String)
    case processExited(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case remote(String, String)

    private var copy: AppCopy {
        AppCopy(
            preference: UserDefaults.standard.string(
                forKey: "voiceRelay.appearance.language"
            ) ?? "system"
        )
    }

    var errorDescription: String? {
        switch self {
        case let .helperUnavailable(path):
            return copy.text(
                "The Voice Relay connection helper is unavailable. · \(path)",
                "Voice Relay connection helper was not found. · \(path)"
            )
        case let .processExited(detail):
            return copy.text(
                "The Codex/ChatGPT connection closed. · \(detail)",
                "The Codex/ChatGPT connection closed. · \(detail)"
            )
        case let .requestTimedOut(command):
            return copy.text(
                "The Codex/ChatGPT connection timed out. · \(command)",
                "The Codex/ChatGPT connection timed out. · \(command)"
            )
        case let .invalidResponse(detail):
            return copy.text(
                "The Codex/ChatGPT connection returned an invalid response. · \(detail)",
                "The Codex/ChatGPT connection returned an invalid response. · \(detail)"
            )
        case let .remote(code, message):
            return "\(message) (\(code))"
        }
    }
}

final class CodexAppRemoteClient {
    typealias JSONDictionary = [String: Any]

    var onThreadCreated: ((String) -> Void)?

    private struct PendingRequest {
        let command: String
        let completion: (Result<JSONDictionary, Error>) -> Void
        let onCommentary: ((CodexCommentary) -> Void)?
        let onContextOmission: ((CodexContextOmission) -> Void)?
        var deliveredCommentaryIDs: Set<String>
        let timeout: DispatchWorkItem
    }

    private var workspacePath: String
    private let queue = DispatchQueue(label: "VoiceRelay.CodexAppRemote")
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var pending: [String: PendingRequest] = [:]
    private var shuttingDown = false
    private var cachedRealtimeCredential: (
        encoded: String,
        expiresAt: TimeInterval
    )?
    private var realtimeCredentialEviction: DispatchWorkItem?
    private var realtimeCredentialRequestInFlight = false
    private var pendingRealtimeStarts: [
        (Result<String, Error>) -> Void
    ] = []

    init(workspacePath: String) {
        self.workspacePath = workspacePath
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    deinit {
        stopProcessNow()
    }

    func pair(
        pairingCode: String,
        completion: @escaping (Result<CodexAppConnectionResult, Error>) -> Void
    ) {
        request(
            command: "pair",
            params: ["pairingCode": pairingCode],
            timeout: 12 * 60
        ) { result in
            completion(result.flatMap(Self.parseConnectionResult))
        }
    }

    func health(
        completion: @escaping (Result<CodexAppConnectionResult, Error>) -> Void
    ) {
        request(command: "health", params: [:], timeout: 60) { result in
            completion(result.flatMap(Self.parseConnectionResult))
        }
    }

    func inspect(
        workspacePath: String,
        completion: @escaping (Result<CodexConnectionSnapshot, Error>) -> Void
    ) {
        request(
            command: "inspect",
            params: [:],
            timeout: 60,
            workspacePath: workspacePath
        ) { result in
            completion(result.flatMap(Self.parseConnectionSnapshot))
        }
    }

    func inspectRealtimeAvailability(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        request(command: "voices", params: [:], timeout: 60) { result in
            completion(result.flatMap { value in
                guard let description = value["description"] as? String,
                      !description.isEmpty else {
                    return .failure(
                        CodexAppRemoteError.invalidResponse(
                            "Missing Voice description"
                        )
                    )
                }
                return .success(description)
            })
        }
    }

    func ask(
        _ prompt: String,
        options: CodexTurnOptions,
        onCommentary: ((CodexCommentary) -> Void)? = nil,
        onContextOmission: ((CodexContextOmission) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var params: JSONDictionary = [
            "prompt": prompt,
            "preferredThreadID": options.preferredThreadID,
            "createNewThreadIfUnset": options.preferredThreadID.isEmpty,
            "preferredThreadTitle": options.preferredThreadTitle,
            "model": options.model,
            "reasoningEffort": options.reasoningEffort,
            "sandbox": options.sandbox,
            "approvalPolicy": options.approvalPolicy,
        ]
        params["serviceTier"] = options.serviceTier ?? NSNull()
        if let context = options.additionalContext {
            params["additionalContext"] = context
        }
        params["additionalContextProvidersEnabled"] =
            options.additionalContextProvidersEnabled
        if let providersRoot = options.additionalContextProvidersRoot,
           !providersRoot.isEmpty {
            params["additionalContextProvidersRoot"] = providersRoot
        }
        request(
            command: "ask",
            params: params,
            timeout: 10 * 60,
            workspacePath: options.workspacePath,
            onCommentary: onCommentary,
            onContextOmission: onContextOmission
        ) { [weak self] result in
            completion(result.flatMap { value in
                guard let answer = value["answer"] as? String,
                      !answer.isEmpty else {
                    return .failure(
                        CodexAppRemoteError.invalidResponse(
                            "Missing final response"
                        )
                    )
                }
                if let threadID = value["threadID"] as? String,
                   !threadID.isEmpty,
                   value["wasCreated"] as? Bool == true {
                    self?.onThreadCreated?(threadID)
                }
                return .success(answer)
            })
        }
    }

    func interruptActiveTurn(
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        request(command: "interrupt", params: [:], timeout: 45) { result in
            completion(result.map { _ in () })
        }
    }

    func steerActiveTurn(
        _ steerRequest: CodexSteerRequest,
        completion: @escaping (Result<CodexSteerReceipt, Error>) -> Void
    ) {
        request(
            command: "steer",
            params: [
                "text": steerRequest.text,
                "controlRequestID": steerRequest.controlRequestID,
                "voiceTurnID": steerRequest.voiceTurnID,
                "generation": steerRequest.generation,
                "terminalDeadlineMs":
                    CodexSteerDeadline.mutationBudgetMilliseconds,
            ],
            timeout: CodexSteerDeadline.clientRequestTimeout
        ) { result in
            completion(result.flatMap { value in
                let status = value["status"] as? String ?? ""
                let controlRequestID =
                    value["requestId"] as? String ?? ""
                let voiceTurnID =
                    value["voiceTurnId"] as? String ?? ""
                let codexTurnID =
                    value["turnId"] as? String ?? ""
                let mutationDeadlineEpochMilliseconds =
                    (value["mutationDeadlineEpochMs"] as? NSNumber)?
                        .int64Value ?? 0
                let mutationDispatched =
                    value["mutationDispatched"] as? Bool ?? false
                guard status == "steered",
                      controlRequestID == steerRequest.controlRequestID,
                      voiceTurnID == steerRequest.voiceTurnID,
                      !codexTurnID.isEmpty,
                      mutationDeadlineEpochMilliseconds > 0,
                      mutationDispatched else {
                    return .failure(
                        CodexAppRemoteError.invalidResponse(
                            "The additional instruction was not applied to the active Codex task"
                        )
                    )
                }
                let receipt = CodexSteerReceipt(
                    controlRequestID: controlRequestID,
                    voiceTurnID: voiceTurnID,
                    codexTurnID: codexTurnID,
                    mutationDeadlineEpochMilliseconds:
                        mutationDeadlineEpochMilliseconds,
                    mutationDispatched: mutationDispatched
                )
                guard receipt.isAcceptable() else {
                    return .failure(CodexSteerDeadlineError(
                        mutationDispatched: true,
                        failurePhase: "swift_receipt_expired"
                    ))
                }
                return .success(receipt)
            })
        }
    }

    func prepareThread(
        options: CodexTurnOptions,
        completion: @escaping (Result<String, Error>) -> Void = { _ in }
    ) {
        var params: JSONDictionary = [
            "preferredThreadID": options.preferredThreadID,
            "createNewThreadIfUnset": options.preferredThreadID.isEmpty,
            "model": options.model,
            "reasoningEffort": options.reasoningEffort,
        ]
        params["serviceTier"] = options.serviceTier ?? NSNull()
        request(
            command: "prepareThread",
            params: params,
            timeout: 90
        ) { [weak self] result in
            completion(result.flatMap { value in
                guard let threadID = value["threadID"] as? String,
                      !threadID.isEmpty else {
                    return .failure(
                        CodexAppRemoteError.invalidResponse(
                            "No prepared Voice Relay task is available"
                        )
                    )
                }
                if threadID != options.preferredThreadID {
                    self?.onThreadCreated?(threadID)
                }
                return .success(threadID)
            })
        }
    }

    func startRealtime(
        offerSDP _: String,
        model: String,
        voice: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            if let credential = self.consumeCachedRealtimeCredential() {
                completion(.success(credential))
                return
            }
            self.pendingRealtimeStarts.append(completion)
            self.fetchRealtimeCredentialIfNeeded(model: model, voice: voice)
        }
    }

    func prefetchRealtimeCredential(model: String, voice: String) {
        queue.async {
            if let cached = self.cachedRealtimeCredential,
               RealtimeCredentialPolicy.canReuse(
                   expiresAt: cached.expiresAt
               ) {
                return
            }
            self.clearCachedRealtimeCredential()
            self.fetchRealtimeCredentialIfNeeded(model: model, voice: voice)
        }
    }

    private func fetchRealtimeCredentialIfNeeded(model: String, voice: String) {
        guard !realtimeCredentialRequestInFlight else { return }
        realtimeCredentialRequestInFlight = true
        request(
            command: "realtimeCredential",
            params: [
                "model": model,
                "voice": voice,
            ],
            timeout: 90
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.shuttingDown else { return }
                self.realtimeCredentialRequestInFlight = false
                let parsed = result.flatMap {
                    self.parseRealtimeCredential($0, fallbackModel: model)
                }
                switch parsed {
                case let .success(credential):
                    self.storeCachedRealtimeCredential(credential)
                    if !self.pendingRealtimeStarts.isEmpty,
                       let encoded = self.consumeCachedRealtimeCredential() {
                        let completions = self.pendingRealtimeStarts
                        self.pendingRealtimeStarts.removeAll()
                        completions.forEach { $0(.success(encoded)) }
                    }
                case let .failure(error):
                    let completions = self.pendingRealtimeStarts
                    self.pendingRealtimeStarts.removeAll()
                    completions.forEach { $0(.failure(error)) }
                }
            }
        }
    }

    private func parseRealtimeCredential(
        _ value: JSONDictionary,
        fallbackModel: String
    ) -> Result<(encoded: String, expiresAt: TimeInterval), Error> {
        guard let credential = value["clientSecret"] as? String,
              !credential.isEmpty else {
            return .failure(
                CodexAppRemoteError.invalidResponse(
                    "Missing temporary Voice credential"
                )
            )
        }
        let expiresAt = (value["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        guard RealtimeCredentialPolicy.canReuse(expiresAt: expiresAt) else {
            return .failure(
                CodexAppRemoteError.invalidResponse(
                    "Temporary Voice credential lifetime is too short"
                )
            )
        }
        let envelope: JSONDictionary = [
            "clientSecret": credential,
            "model": value["model"] as? String ?? fallbackModel,
            "expiresAt": expiresAt,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: envelope
        ), let encoded = String(data: data, encoding: .utf8) else {
            return .failure(
                CodexAppRemoteError.invalidResponse(
                    "Could not create the Voice credential envelope"
                )
            )
        }
        return .success((encoded, expiresAt))
    }

    private func consumeCachedRealtimeCredential() -> String? {
        guard let cached = cachedRealtimeCredential,
              RealtimeCredentialPolicy.canReuse(
                expiresAt: cached.expiresAt
              ) else {
            clearCachedRealtimeCredential()
            return nil
        }
        clearCachedRealtimeCredential()
        return cached.encoded
    }

    private func storeCachedRealtimeCredential(
        _ credential: (encoded: String, expiresAt: TimeInterval)
    ) {
        clearCachedRealtimeCredential()
        cachedRealtimeCredential = credential
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.cachedRealtimeCredential?.expiresAt == credential.expiresAt else {
                return
            }
            self.cachedRealtimeCredential = nil
            self.realtimeCredentialEviction = nil
        }
        realtimeCredentialEviction = workItem
        queue.asyncAfter(
            deadline: .now() + RealtimeCredentialPolicy.evictionDelay(
                expiresAt: credential.expiresAt
            ),
            execute: workItem
        )
    }

    private func clearCachedRealtimeCredential() {
        realtimeCredentialEviction?.cancel()
        realtimeCredentialEviction = nil
        cachedRealtimeCredential = nil
    }

    func stopRealtime(
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        request(command: "realtimeStop", params: [:], timeout: 30) { result in
            completion(result.map { _ in () })
        }
    }

    func resetConnection(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        request(command: "reset", params: [:], timeout: 30) { [weak self] result in
            completion(result.map { _ in
                self?.shutdown()
                return ()
            })
        }
    }

    func resetSession(
        completion: @escaping (Result<CodexConnectionResetResult, Error>) -> Void
    ) {
        request(command: "resetSession", params: [:], timeout: 30) { [weak self] result in
            completion(result.flatMap(Self.parseConnectionResetResult))
            self?.shutdown()
        }
    }

    func forgetLocalPairing(
        completion: @escaping (Result<CodexConnectionResetResult, Error>) -> Void
    ) {
        request(command: "forgetPairing", params: [:], timeout: 30) { [weak self] result in
            completion(result.flatMap(Self.parseConnectionResetResult))
            self?.shutdown()
        }
    }

    func shutdown() {
        queue.async {
            self.stopProcessNow()
        }
    }

    func shutdownSynchronously() {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopProcessNow()
            return
        }
        queue.sync {
            self.stopProcessNow()
        }
    }

    private func request(
        command: String,
        params: JSONDictionary,
        timeout: TimeInterval,
        workspacePath requestedWorkspacePath: String? = nil,
        onCommentary: ((CodexCommentary) -> Void)? = nil,
        onContextOmission: ((CodexContextOmission) -> Void)? = nil,
        completion: @escaping (Result<JSONDictionary, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.updateWorkspaceIfNeeded(requestedWorkspacePath)
                try self.startProcessIfNeeded()
            } catch {
                completion(.failure(error))
                return
            }

            let id = UUID().uuidString
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: id) else {
                    return
                }
                request.completion(.failure(CodexAppRemoteError.requestTimedOut(command)))
            }
            self.pending[id] = PendingRequest(
                command: command,
                completion: completion,
                onCommentary: onCommentary,
                onContextOmission: onContextOmission,
                deliveredCommentaryIDs: [],
                timeout: timeoutItem
            )
            self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            guard self.writeLine([
                "id": id,
                "command": command,
                "params": params,
            ]) else {
                timeoutItem.cancel()
                self.pending.removeValue(forKey: id)
                completion(.failure(
                    CodexAppRemoteError.processExited("Failed to write to stdin")
                ))
                return
            }
        }
    }

    private func startProcessIfNeeded() throws {
        if process?.isRunning == true { return }
        shuttingDown = false
        let helper = try helperURL()
        let node = try nodeExecutableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = node
        process.arguments = [helper.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["VOICE_RELAY_WORKSPACE"] = workspacePath
        environment["VOICE_RELAY_STATE_ROOT"] = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Voice Relay", isDirectory: true)
        .appendingPathComponent("Remote", isDirectory: true)
        .path
        process.environment = environment
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                guard let self, self.process === terminated else { return }
                let detail = self.stderrTail.isEmpty
                    ? "exit \(terminated.terminationStatus)"
                    : self.stderrTail
                self.resetProcess(error: CodexAppRemoteError.processExited(detail))
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4_000))
            }
        }
        do {
            try process.run()
        } catch {
            throw CodexAppRemoteError.processExited(error.localizedDescription)
        }
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
    }

    private func updateWorkspaceIfNeeded(_ requestedWorkspacePath: String?) {
        guard let requestedWorkspacePath else { return }
        let normalized = requestedWorkspacePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty, normalized != workspacePath else { return }
        stopProcessNow()
        workspacePath = normalized
    }

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? JSONDictionary else {
                continue
            }
            if object["event"] as? String == "commentary",
               let requestID = object["requestId"] as? String,
               let messageID = object["messageId"] as? String,
               let text = object["text"] as? String {
                guard var request = pending[requestID],
                      !messageID.isEmpty,
                      !text.isEmpty,
                      request.deliveredCommentaryIDs.insert(messageID).inserted else {
                    continue
                }
                pending[requestID] = request
                request.onCommentary?(
                    CodexCommentary(messageID: messageID, text: text)
                )
                continue
            }
            if object["event"] as? String == "contextOmitted",
               let requestID = object["requestId"] as? String,
               let source = object["source"] as? String,
               let reason = object["reason"] as? String,
               let fallback = object["fallback"] as? String,
               let request = pending[requestID],
               request.command == "ask",
               Self.allowedContextOmissionSources.contains(source),
               Self.allowedContextOmissionReasons.contains(reason),
               fallback == "without_optional_context" {
                let rawProviderIndex = (object["providerIndex"] as? NSNumber)?
                    .intValue
                let providerIndex = rawProviderIndex.flatMap {
                    (0..<8).contains($0) ? $0 : nil
                }
                request.onContextOmission?(
                    CodexContextOmission(
                        source: source,
                        reason: reason,
                        fallback: fallback,
                        providerIndex: providerIndex
                    )
                )
                continue
            }
            if object["event"] as? String == "threadBound",
               let threadID = object["threadID"] as? String,
               !threadID.isEmpty {
                onThreadCreated?(threadID)
                continue
            }
            guard let id = object["id"] as? String,
                  let request = pending.removeValue(forKey: id) else {
                continue
            }
            request.timeout.cancel()
            if let error = object["error"] as? JSONDictionary {
                let code =
                    error["code"] as? String ?? "APP_REMOTE_FAILED"
                if request.command == "steer",
                   code == "APP_REMOTE_STEER_DEADLINE_EXPIRED" {
                    request.completion(.failure(
                        CodexSteerDeadlineError(
                            mutationDispatched:
                                error["mutationDispatched"] as? Bool,
                            failurePhase:
                                error["failurePhase"] as? String ?? ""
                        )
                    ))
                } else {
                    request.completion(.failure(CodexAppRemoteError.remote(
                        code,
                        error["message"] as? String
                            ?? "Codex/ChatGPT connection failed"
                    )))
                }
            } else if let result = object["result"] as? JSONDictionary {
                request.completion(.success(result))
            } else {
                request.completion(.failure(
                    CodexAppRemoteError.invalidResponse(request.command)
                ))
            }
        }
    }

    private static let allowedContextOmissionSources: Set<String> = [
        "authority_pack",
        "additional_context",
    ]

    private static let allowedContextOmissionReasons: Set<String> = [
        "authority_shape_invalid",
        "authority_kind_invalid",
        "authority_incomplete",
        "authority_too_large",
        "combined_context_too_large",
        "provider_root_unavailable",
        "provider_configuration_invalid",
        "provider_start_failed",
        "provider_timeout",
        "provider_output_too_large",
        "provider_exit_nonzero",
        "provider_output_empty",
        "provider_output_stale",
        "provider_output_invalid",
        "providers_output_too_large",
    ]

    @discardableResult
    private func writeLine(_ object: JSONDictionary) -> Bool {
        guard let input = standardInput,
              let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else {
            return false
        }
        line.append("\n")
        do {
            try input.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            return false
        }
    }

    private func resetProcess(error: Error) {
        process = nil
        standardInput = nil
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        standardOutput = nil
        standardError = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        let requests = pending.values
        pending.removeAll()
        requests.forEach {
            $0.timeout.cancel()
            $0.completion(.failure(error))
        }
    }

    private func stopProcessNow() {
        guard !shuttingDown || process?.isRunning == true else { return }
        shuttingDown = true
        clearCachedRealtimeCredential()
        realtimeCredentialRequestInFlight = false
        let realtimeStarts = pendingRealtimeStarts
        pendingRealtimeStarts.removeAll()
        realtimeStarts.forEach {
            $0(.failure(
                CodexAppRemoteError.processExited(
                    "The app closed the connection"
                )
            ))
        }
        let activeProcess = process
        activeProcess?.terminationHandler = nil
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        if activeProcess?.isRunning == true {
            _ = writeLine([
                "id": UUID().uuidString,
                "command": "shutdown",
                "params": [:],
            ])
        }
        try? standardInput?.close()
        if let activeProcess, activeProcess.isRunning {
            if !waitForExit(activeProcess, timeout: 0.4) {
                activeProcess.terminate()
            }
            if !waitForExit(activeProcess, timeout: 0.8) {
                Darwin.kill(activeProcess.processIdentifier, SIGKILL)
                activeProcess.waitUntilExit()
            }
        }
        try? standardOutput?.close()
        try? standardError?.close()
        resetProcess(
            error: CodexAppRemoteError.processExited(
                "The app closed the connection"
            )
        )
    }

    private func waitForExit(
        _ activeProcess: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while activeProcess.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !activeProcess.isRunning
    }

    private func helperURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Helpers/voice-relay-app-remote.mjs"),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        throw CodexAppRemoteError.helperUnavailable(
            "Voice Relay.app/Contents/Resources/Helpers/voice-relay-app-remote.mjs"
        )
    }

    private func nodeExecutableURL() throws -> URL {
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexAppRemoteError.helperUnavailable("node")
    }

    private static func parseConnectionResult(
        _ value: JSONDictionary
    ) -> Result<CodexAppConnectionResult, Error> {
        let ready = value["remoteRpcReady"] as? Bool ?? false
        let claimRequired = value["hostClaimRequired"] as? Bool
            ?? ((value["errorCode"] as? String)
                == "REMOTE_CONTROL_ENVIRONMENT_PAIRING_REQUIRED")
        let online = value["environmentOnline"] as? Bool ?? false
        return .success(CodexAppConnectionResult(
            remoteRPCReady: ready,
            hostClaimRequired: claimRequired,
            environmentOnline: online
        ))
    }

    private static func parseConnectionResetResult(
        _ value: JSONDictionary
    ) -> Result<CodexConnectionResetResult, Error> {
        .success(CodexConnectionResetResult(
            localStateCleared: value["localStateCleared"] as? Bool ?? false,
            localDeviceKeyDeleted: value["localDeviceKeyDeleted"] as? Bool ?? false,
            remoteRevocationSupported:
                value["remoteRevocationSupported"] as? Bool ?? false
        ))
    }

    private static func parseConnectionSnapshot(
        _ value: JSONDictionary
    ) -> Result<CodexConnectionSnapshot, Error> {
        guard let config = value["effectiveConfig"] as? JSONDictionary else {
            return .failure(
                CodexAppRemoteError.invalidResponse("Missing configuration")
            )
        }
        let modelObjects = value["models"] as? [JSONDictionary] ?? []
        let models = modelObjects.compactMap { model -> CodexModelCapability? in
            guard let id = model["id"] as? String, !id.isEmpty else {
                return nil
            }
            let efforts = (model["supportedReasoningEfforts"] as? [String] ?? [])
                .filter { !$0.isEmpty }
            let serviceTierIDs = (model["serviceTierIDs"] as? [String] ?? [])
                .filter { !$0.isEmpty }
            return CodexModelCapability(
                id: id,
                displayName: model["displayName"] as? String ?? id,
                supportedReasoningEfforts: CodexReasoningEffortOrder.sorted(
                    efforts
                ),
                serviceTierIDs: Array(Set(serviceTierIDs)).sorted()
            )
        }
        let fallbackModels = (value["availableModels"] as? [String] ?? [])
            .map {
                CodexModelCapability(
                    id: $0,
                    displayName: $0,
                    supportedReasoningEfforts: [],
                    serviceTierIDs: []
                )
            }
        let snapshot = CodexConnectionSnapshot(
            accountDescription: value["accountDescription"] as? String
                ?? "ChatGPT",
            models: models.isEmpty ? fallbackModels : models,
            effectiveConfig: CodexEffectiveConfig(
                model: config["model"] as? String ?? "unknown",
                reasoningEffort: config["reasoningEffort"] as? String ?? "unknown",
                serviceTier: config["serviceTier"] as? String ?? "unknown",
                sandbox: config["sandbox"] as? String ?? "unknown",
                approvalPolicy: config["approvalPolicy"] as? String ?? "unknown"
            ),
            threadID: value["threadID"] as? String ?? ""
        )
        return .success(snapshot)
    }
}
