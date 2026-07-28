import Foundation

struct CodexConnectionSnapshot {
    let accountDescription: String
    let availableModels: [String]
    let effectiveConfig: CodexEffectiveConfig
    let threadID: String
}

struct CodexEffectiveConfig: Equatable {
    let model: String
    let reasoningEffort: String
    let sandbox: String
    let approvalPolicy: String

    var summary: String {
        "\(model) · \(reasoningEffort) · \(sandbox) · \(approvalPolicy)"
    }
}

struct CodexTurnOptions {
    let workspacePath: String
    let preferredThreadID: String
    let preferredThreadTitle: String
    let model: String
    let reasoningEffort: String
    let sandbox: String
    let approvalPolicy: String
    let additionalContext: [String: [String: String]]?
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

struct CodexConnectionResetResult {
    let localStateCleared: Bool
    let localDeviceKeyDeleted: Bool
    let remoteRevocationSupported: Bool
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
        var deliveredCommentaryIDs: Set<String>
        let timeout: DispatchWorkItem
    }

    private let workspacePath: String
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
        workspacePath _: String,
        completion: @escaping (Result<CodexConnectionSnapshot, Error>) -> Void
    ) {
        request(command: "inspect", params: [:], timeout: 60) { result in
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
        if let context = options.additionalContext {
            params["additionalContext"] = context
        }
        if let providersRoot = options.additionalContextProvidersRoot,
           !providersRoot.isEmpty {
            params["additionalContextProvidersRoot"] = providersRoot
        }
        request(
            command: "ask",
            params: params,
            timeout: 10 * 60,
            onCommentary: onCommentary
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
        _ text: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        request(
            command: "steer",
            params: ["text": text],
            timeout: 60
        ) { result in
            completion(result.flatMap { value in
                let status = value["status"] as? String ?? ""
                guard status == "steered"
                        || status == "submitted_pending_ack" else {
                    return .failure(
                        CodexAppRemoteError.invalidResponse(
                            "The additional instruction was not applied to the active Codex task"
                        )
                    )
                }
                return .success(())
            })
        }
    }

    func prepareThread(
        options: CodexTurnOptions,
        completion: @escaping (Result<String, Error>) -> Void = { _ in }
    ) {
        request(
            command: "prepareThread",
            params: [
                "preferredThreadID": options.preferredThreadID,
                "createNewThreadIfUnset": options.preferredThreadID.isEmpty,
                "model": options.model,
                "reasoningEffort": options.reasoningEffort,
            ],
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
        onCommentary: ((CodexCommentary) -> Void)? = nil,
        completion: @escaping (Result<JSONDictionary, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
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
                request.completion(.failure(CodexAppRemoteError.remote(
                    error["code"] as? String ?? "APP_REMOTE_FAILED",
                    error["message"] as? String
                        ?? "Codex/ChatGPT connection failed"
                )))
            } else if let result = object["result"] as? JSONDictionary {
                request.completion(.success(result))
            } else {
                request.completion(.failure(
                    CodexAppRemoteError.invalidResponse(request.command)
                ))
            }
        }
    }

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
        try? standardOutput?.close()
        try? standardError?.close()
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
        }
        resetProcess(
            error: CodexAppRemoteError.processExited(
                "The app closed the connection"
            )
        )
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
        let snapshot = CodexConnectionSnapshot(
            accountDescription: value["accountDescription"] as? String
                ?? "ChatGPT",
            availableModels: value["availableModels"] as? [String] ?? [],
            effectiveConfig: CodexEffectiveConfig(
                model: config["model"] as? String ?? "unknown",
                reasoningEffort: config["reasoningEffort"] as? String ?? "unknown",
                sandbox: config["sandbox"] as? String ?? "unknown",
                approvalPolicy: config["approvalPolicy"] as? String ?? "unknown"
            ),
            threadID: value["threadID"] as? String ?? ""
        )
        return .success(snapshot)
    }
}
