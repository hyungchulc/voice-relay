import Foundation

struct CodexModelOption: Equatable {
    let id: String
    let displayName: String
    let supportedReasoningEfforts: [String]
}

struct CodexConnectionSnapshot {
    let accountDescription: String
    let models: [CodexModelOption]
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
}

enum CodexAppServerError: LocalizedError {
    case executableUnavailable(String)
    case processLaunch(String)
    case processExited(String)
    case invalidResponse(String)
    case requestFailed(String)
    case requestTimedOut(String)
    case busy
    case noAssistantMessage

    var errorDescription: String? {
        switch self {
        case let .executableUnavailable(path):
            return "Codex 실행 파일을 찾을 수 없어: \(path)"
        case let .processLaunch(message):
            return "Codex를 시작하지 못했어: \(message)"
        case let .processExited(message):
            return "Codex 연결이 종료됐어: \(message)"
        case let .invalidResponse(message):
            return "Codex 응답 형식이 올바르지 않아: \(message)"
        case let .requestFailed(message):
            return message
        case let .requestTimedOut(method):
            return "\(method) 응답 시간이 초과됐어"
        case .busy:
            return "이미 다른 Codex 요청을 처리하고 있어"
        case .noAssistantMessage:
            return "Codex가 표시할 답변을 반환하지 않았어"
        }
    }
}

final class CodexAppServerClient {
    typealias JSONDictionary = [String: Any]

    private struct PendingRequest {
        let method: String
        let completion: (Result<Any, Error>) -> Void
        let timeout: DispatchWorkItem
    }

    private struct ActiveTurn {
        let id: String
        let threadID: String
        let completion: (Result<String, Error>) -> Void
        let onDelta: ((String) -> Void)?
        var deltaByItemID: [String: String]
        var finalMessages: [String]
    }

    private let executablePath: String
    private let queue = DispatchQueue(label: "com.hyungchulc.voice-relay.codex-app-server")
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var initialized = false
    private var initializingCallbacks: [(Result<Void, Error>) -> Void] = []
    private var activeThreadID = ""
    private var activeTurn: ActiveTurn?
    private var turnRequestReserved = false
    private var turnCancellationRequested = false
    private var pendingInterruptCallbacks: [(Result<Void, Error>) -> Void] = []
    private var bufferedTurnNotifications: [(String, JSONDictionary)] = []

    var onApprovalRequest: ((String, JSONDictionary, @escaping (Bool) -> Void) -> Void)?
    var onThreadCreated: ((String) -> Void)?

    init(executablePath: String) {
        self.executablePath = SettingsStore.normalizedExecutablePath(executablePath)
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true {
                self.process?.terminate()
            }
            self.resetProcessState(
                error: CodexAppServerError.processExited("앱이 연결을 닫았어")
            )
        }
    }

    func inspect(completion: @escaping (Result<CodexConnectionSnapshot, Error>) -> Void) {
        ensureInitialized { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                self.request(method: "account/read", params: [:]) { accountResult in
                    self.request(method: "model/list", params: ["limit": 100]) { modelResult in
                        switch (accountResult, modelResult) {
                        case let (.success(accountValue), .success(modelValue)):
                            completion(.success(CodexConnectionSnapshot(
                                accountDescription: Self.accountDescription(accountValue),
                                models: Self.parseModels(modelValue)
                            )))
                        case let (.failure(error), _):
                            completion(.failure(error))
                        case let (_, .failure(error)):
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    func startLogin(completion: @escaping (Result<URL?, Error>) -> Void) {
        ensureInitialized { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                self.request(
                    method: "account/login/start",
                    params: ["type": "chatgpt"]
                ) { response in
                    completion(response.map { value in
                        guard let object = value as? JSONDictionary else { return nil }
                        let rawURL = object["authUrl"] as? String
                            ?? object["url"] as? String
                        return rawURL.flatMap(URL.init(string:))
                    })
                }
            }
        }
    }

    func ask(
        _ text: String,
        options: CodexTurnOptions,
        onDelta: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            completion(.failure(CodexAppServerError.invalidResponse("빈 요청")))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.turnRequestReserved, self.activeTurn == nil else {
                completion(.failure(CodexAppServerError.busy))
                return
            }
            self.turnRequestReserved = true
            self.turnCancellationRequested = false
            self.ensureInitialized { result in
                switch result {
                case let .failure(error):
                    self.finishReservedTurnBeforeStart()
                    completion(.failure(error))
                case .success:
                    self.ensureThread(options: options) { threadResult in
                        switch threadResult {
                        case let .failure(error):
                            self.finishReservedTurnBeforeStart()
                            completion(.failure(error))
                        case let .success(threadID):
                            self.startTurn(
                                prompt: prompt,
                                threadID: threadID,
                                options: options,
                                onDelta: onDelta,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }
    }

    func interruptActiveTurn(
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.turnRequestReserved || self.activeTurn != nil else {
                completion(.success(()))
                return
            }
            self.turnCancellationRequested = true
            guard let turn = self.activeTurn else {
                self.pendingInterruptCallbacks.append(completion)
                return
            }
            self.sendInterrupt(for: turn, completion: completion)
        }
    }

    private func ensureInitialized(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.initialized {
                completion(.success(()))
                return
            }
            self.initializingCallbacks.append(completion)
            guard self.initializingCallbacks.count == 1 else { return }
            do {
                try self.startProcessIfNeeded()
            } catch {
                self.finishInitialization(.failure(error))
                return
            }
            self.request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "voice_relay",
                        "title": "Voice Relay",
                        "version": "1.0.0",
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false,
                    ],
                ]
            ) { result in
                switch result {
                case let .failure(error):
                    self.finishInitialization(.failure(error))
                case .success:
                    self.notify(method: "initialized", params: [:])
                    self.initialized = true
                    self.finishInitialization(.success(()))
                }
            }
        }
    }

    private func finishInitialization(_ result: Result<Void, Error>) {
        let callbacks = initializingCallbacks
        initializingCallbacks.removeAll()
        callbacks.forEach { $0(result) }
    }

    private func startProcessIfNeeded() throws {
        if process?.isRunning == true { return }
        let launch = try Self.resolveExecutable(executablePath)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = launch.executable
        process.arguments = launch.arguments + ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                guard let self, self.process === process else { return }
                let detail = self.stderrTail.isEmpty
                    ? "exit \(process.terminationStatus)"
                    : self.stderrTail
                self.resetProcessState(error: CodexAppServerError.processExited(detail))
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeStdout(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4_000))
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.processLaunch(error.localizedDescription)
        }
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
    }

    private static func resolveExecutable(_ rawPath: String) throws -> (
        executable: URL,
        arguments: [String]
    ) {
        let path = SettingsStore.normalizedExecutablePath(rawPath)
        if path.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw CodexAppServerError.executableUnavailable(path)
            }
            return (URL(fileURLWithPath: path), [])
        }
        guard path == "codex" else {
            throw CodexAppServerError.executableUnavailable(path)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["codex"])
    }

    private func ensureThread(
        options: CodexTurnOptions,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let preferred = options.preferredThreadID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            if activeThreadID == preferred {
                completion(.success(preferred))
                return
            }
            request(
                method: "thread/resume",
                params: threadParams(options: options).merging([
                    "threadId": preferred,
                ]) { _, new in new }
            ) { [weak self] result in
                switch result {
                case let .failure(error):
                    completion(.failure(error))
                case .success:
                    self?.finishThreadSelection(
                        threadID: preferred,
                        title: options.preferredThreadTitle,
                        wasCreated: false,
                        completion: completion
                    )
                }
            }
            return
        }

        if !activeThreadID.isEmpty {
            completion(.success(activeThreadID))
            return
        }

        var params = threadParams(options: options)
        params["threadSource"] = "app"
        request(method: "thread/start", params: params) { [weak self] result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(value):
                guard let object = value as? JSONDictionary,
                      let thread = object["thread"] as? JSONDictionary,
                      let threadID = thread["id"] as? String,
                      !threadID.isEmpty else {
                    completion(.failure(
                        CodexAppServerError.invalidResponse("thread/start에 task ID가 없어")
                    ))
                    return
                }
                self?.finishThreadSelection(
                    threadID: threadID,
                    title: options.preferredThreadTitle,
                    wasCreated: true,
                    completion: completion
                )
            }
        }
    }

    private func finishThreadSelection(
        threadID: String,
        title: String,
        wasCreated: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        activeThreadID = threadID
        if wasCreated {
            onThreadCreated?(threadID)
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            completion(.success(threadID))
            return
        }
        request(
            method: "thread/name/set",
            params: [
                "threadId": threadID,
                "name": String(name.prefix(160)),
            ]
        ) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                completion(.success(threadID))
            }
        }
    }

    private func threadParams(options: CodexTurnOptions) -> JSONDictionary {
        var params: JSONDictionary = [
            "approvalPolicy": options.approvalPolicy,
            "sandbox": options.sandbox,
        ]
        if !options.workspacePath.isEmpty {
            params["cwd"] = options.workspacePath
        }
        if options.model != "inherit" {
            params["model"] = options.model
        }
        return params
    }

    private func startTurn(
        prompt: String,
        threadID: String,
        options: CodexTurnOptions,
        onDelta: ((String) -> Void)?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var params: JSONDictionary = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": prompt,
                "text_elements": [],
            ]],
            "approvalPolicy": options.approvalPolicy,
        ]
        if !options.workspacePath.isEmpty {
            params["cwd"] = options.workspacePath
        }
        if options.model != "inherit" {
            params["model"] = options.model
        }
        if options.reasoningEffort != "inherit" {
            params["effort"] = options.reasoningEffort
        }
        if let additionalContext = options.additionalContext, !additionalContext.isEmpty {
            params["additionalContext"] = additionalContext
        }

        request(method: "turn/start", params: params, timeout: 60) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.finishReservedTurnBeforeStart()
                completion(.failure(error))
            case let .success(value):
                guard let object = value as? JSONDictionary,
                      let turn = object["turn"] as? JSONDictionary,
                      let turnID = turn["id"] as? String,
                      !turnID.isEmpty else {
                    self.finishReservedTurnBeforeStart()
                    completion(.failure(
                        CodexAppServerError.invalidResponse("turn/start에 turn ID가 없어")
                    ))
                    return
                }
                self.activeTurn = ActiveTurn(
                    id: turnID,
                    threadID: threadID,
                    completion: completion,
                    onDelta: onDelta,
                    deltaByItemID: [:],
                    finalMessages: []
                )
                self.replayBufferedTurnNotifications()
                if self.turnCancellationRequested,
                   let activeTurn = self.activeTurn {
                    let callbacks = self.pendingInterruptCallbacks
                    self.pendingInterruptCallbacks.removeAll()
                    self.sendInterrupt(for: activeTurn) { result in
                        callbacks.forEach { $0(result) }
                    }
                }
            }
        }
    }

    private func sendInterrupt(
        for turn: ActiveTurn,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        request(
            method: "turn/interrupt",
            params: [
                "threadId": turn.threadID,
                "turnId": turn.id,
            ]
        ) { result in
            completion(result.map { _ in () })
        }
    }

    private func finishReservedTurnBeforeStart() {
        turnRequestReserved = false
        turnCancellationRequested = false
        let callbacks = pendingInterruptCallbacks
        pendingInterruptCallbacks.removeAll()
        callbacks.forEach { $0(.success(())) }
    }

    private func request(
        method: String,
        params: JSONDictionary,
        timeout: TimeInterval = 30,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = self.nextRequestID
            self.nextRequestID += 1
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: id) else { return }
                request.completion(.failure(CodexAppServerError.requestTimedOut(method)))
            }
            self.pending[id] = PendingRequest(
                method: method,
                completion: completion,
                timeout: timeoutItem
            )
            do {
                try self.writeJSON([
                    "id": id,
                    "method": method,
                    "params": params,
                ])
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            } catch {
                self.pending.removeValue(forKey: id)
                timeoutItem.cancel()
                completion(.failure(error))
            }
        }
    }

    private func notify(method: String, params: JSONDictionary) {
        try? writeJSON([
            "method": method,
            "params": params,
        ])
    }

    private func writeJSON(_ object: JSONDictionary) throws {
        guard let standardInput else {
            throw CodexAppServerError.processExited("stdin이 닫혀 있어")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try standardInput.write(contentsOf: data)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONDictionary else {
                continue
            }
            handleMessage(object)
        }
    }

    private func handleMessage(_ message: JSONDictionary) {
        if let id = Self.integerID(message["id"]),
           message["method"] == nil {
            guard let pendingRequest = pending.removeValue(forKey: id) else { return }
            pendingRequest.timeout.cancel()
            if let error = message["error"] as? JSONDictionary {
                let detail = error["message"] as? String
                    ?? String(describing: error)
                pendingRequest.completion(.failure(
                    CodexAppServerError.requestFailed(detail)
                ))
            } else {
                pendingRequest.completion(.success(message["result"] ?? NSNull()))
            }
            return
        }

        guard let method = message["method"] as? String,
              let params = message["params"] as? JSONDictionary else {
            return
        }
        if let id = Self.integerID(message["id"]) {
            handleServerRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func handleServerRequest(id: Int, method: String, params: JSONDictionary) {
        guard [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
        ].contains(method) else {
            try? writeJSON([
                "id": id,
                "error": [
                    "code": -32601,
                    "message": "Unsupported app-server request",
                ],
            ])
            return
        }

        let respond: (Bool) -> Void = { [weak self] accepted in
            self?.queue.async {
                try? self?.writeJSON([
                    "id": id,
                    "result": Self.approvalResult(
                        method: method,
                        params: params,
                        accepted: accepted
                    ),
                ])
            }
        }
        guard let onApprovalRequest else {
            respond(false)
            return
        }
        DispatchQueue.main.async {
            onApprovalRequest(method, params, respond)
        }
    }

    static func approvalResult(
        method: String,
        params: JSONDictionary,
        accepted: Bool
    ) -> JSONDictionary {
        if method == "item/permissions/requestApproval" {
            let requested = params["permissions"] as? JSONDictionary ?? [:]
            return [
                "permissions": accepted ? requested : [:],
                "scope": "turn",
            ]
        }
        return [
            "decision": accepted ? "accept" : "decline",
        ]
    }

    private func handleNotification(method: String, params: JSONDictionary) {
        guard var turn = activeTurn else {
            if method.hasPrefix("item/") || method.hasPrefix("turn/") {
                bufferedTurnNotifications.append((method, params))
                if bufferedTurnNotifications.count > 200 {
                    bufferedTurnNotifications.removeFirst(
                        bufferedTurnNotifications.count - 200
                    )
                }
            }
            return
        }
        guard
              Self.notificationMatches(
                  params: params,
                  threadID: turn.threadID,
                  turnID: turn.id
              ) else {
            return
        }

        switch method {
        case "item/agentMessage/delta":
            let itemID = params["itemId"] as? String ?? "stream"
            let delta = params["delta"] as? String ?? ""
            guard !delta.isEmpty else { return }
            turn.deltaByItemID[itemID, default: ""] += delta
            activeTurn = turn
            turn.onDelta?(delta)
        case "item/completed":
            guard let item = params["item"] as? JSONDictionary,
                  item["type"] as? String == "agentMessage" else {
                return
            }
            let itemID = item["id"] as? String ?? ""
            let text = (item["text"] as? String)
                ?? turn.deltaByItemID[itemID]
                ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let phase = item["phase"] as? String
                if phase == "final_answer" {
                    turn.finalMessages.append(text)
                } else if turn.finalMessages.isEmpty {
                    turn.deltaByItemID[itemID] = text
                }
            }
            activeTurn = turn
        case "turn/completed":
            let status: String
            let turnObject: JSONDictionary?
            if let nested = params["turn"] as? JSONDictionary {
                turnObject = nested
                status = nested["status"] as? String ?? "completed"
            } else {
                turnObject = nil
                status = params["status"] as? String ?? "completed"
            }
            activeTurn = nil
            turnRequestReserved = false
            turnCancellationRequested = false
            if status == "failed" || status == "interrupted" {
                let errorObject = turnObject?["error"] as? JSONDictionary
                let message = errorObject?["message"] as? String
                    ?? "Codex turn이 \(status) 상태로 끝났어"
                turn.completion(.failure(CodexAppServerError.requestFailed(message)))
                return
            }
            let combined = (
                turn.finalMessages.isEmpty
                    ? turn.deltaByItemID.values.map { $0 }
                    : turn.finalMessages
            )
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if combined.isEmpty {
                turn.completion(.failure(CodexAppServerError.noAssistantMessage))
            } else {
                turn.completion(.success(combined))
            }
        default:
            break
        }
    }

    private func replayBufferedTurnNotifications() {
        let notifications = bufferedTurnNotifications
        bufferedTurnNotifications.removeAll(keepingCapacity: true)
        for (method, params) in notifications {
            handleNotification(method: method, params: params)
        }
    }

    private static func notificationMatches(
        params: JSONDictionary,
        threadID: String,
        turnID: String
    ) -> Bool {
        if let candidateThread = params["threadId"] as? String,
           candidateThread != threadID {
            return false
        }
        if let candidateTurn = params["turnId"] as? String {
            return candidateTurn == turnID
        }
        if let nestedTurn = params["turn"] as? JSONDictionary,
           let candidateTurn = nestedTurn["id"] as? String {
            return candidateTurn == turnID
        }
        return true
    }

    private func resetProcessState(error: Error) {
        process = nil
        standardInput = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        initialized = false
        activeThreadID = ""
        turnRequestReserved = false
        turnCancellationRequested = false
        bufferedTurnNotifications.removeAll(keepingCapacity: false)

        let interruptCallbacks = pendingInterruptCallbacks
        pendingInterruptCallbacks.removeAll()
        interruptCallbacks.forEach { $0(.success(())) }

        let pendingRequests = pending.values
        pending.removeAll()
        for request in pendingRequests {
            request.timeout.cancel()
            request.completion(.failure(error))
        }
        if let activeTurn {
            self.activeTurn = nil
            activeTurn.completion(.failure(error))
        }
        if !initializingCallbacks.isEmpty {
            finishInitialization(.failure(error))
        }
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func accountDescription(_ value: Any) -> String {
        guard let object = value as? JSONDictionary else { return "연결됨" }
        if let account = object["account"] as? JSONDictionary {
            return account["email"] as? String
                ?? account["type"] as? String
                ?? "ChatGPT 계정 연결됨"
        }
        if object["requiresOpenaiAuth"] as? Bool == true {
            return "로그인 필요"
        }
        return "Codex 연결됨"
    }

    private static func parseModels(_ value: Any) -> [CodexModelOption] {
        guard let object = value as? JSONDictionary,
              let data = object["data"] as? [JSONDictionary] else {
            return []
        }
        return data.compactMap { model in
            guard let id = model["id"] as? String
                    ?? model["model"] as? String
                    ?? model["slug"] as? String,
                  !id.isEmpty else {
                return nil
            }
            let displayName = model["displayName"] as? String
                ?? model["name"] as? String
                ?? id
            let efforts = (model["supportedReasoningEfforts"] as? [Any] ?? [])
                .compactMap { entry -> String? in
                    if let raw = entry as? String { return raw }
                    return (entry as? JSONDictionary)?["reasoningEffort"] as? String
                }
            return CodexModelOption(
                id: id,
                displayName: displayName,
                supportedReasoningEfforts: Array(Set(efforts)).sorted()
            )
        }
    }
}
