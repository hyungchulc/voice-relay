import Foundation

@main
struct CodexClientSmoke {
    static func main() {
        let settings = AppSettings.defaults
        let client = CodexAppRemoteClient(
            workspacePath: settings.codexWorkspacePath
        )
        let requestedThreadIDs = Array(CommandLine.arguments.dropFirst().prefix(2))
        let preferredThreadID = requestedThreadIDs.first ?? ""
        let switchThreadID = requestedThreadIDs.dropFirst().first ?? ""
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode = 1
        var turnIndex = 0
        var runTurn: (() -> Void)!
        client.onThreadCreated = { threadID in
            fputs("VOICE_RELAY_THREAD_ID=\(threadID)\n", stderr)
        }

        runTurn = {
            let currentThreadID = turnIndex == 0 ? preferredThreadID : switchThreadID
            client.ask(
                "Reply with exactly VOICE_RELAY_REMOTE_OK and no other text. Do not use tools.",
                options: CodexTurnOptions(
                    workspacePath: settings.codexWorkspacePath,
                    preferredThreadID: currentThreadID,
                    preferredThreadTitle: "Voice Relay Remote Smoke",
                    model: "inherit",
                    reasoningEffort: "low",
                    sandbox: "read-only",
                    approvalPolicy: "on-request",
                    additionalContext: nil,
                    additionalContextProvidersRoot: nil
                ),
                completion: { result in
                    switch result {
                    case let .success(reply):
                        print(reply)
                        guard reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            == "VOICE_RELAY_REMOTE_OK" else {
                            exitCode = 2
                            semaphore.signal()
                            return
                        }
                        if turnIndex == 0, !switchThreadID.isEmpty {
                            turnIndex = 1
                            runTurn()
                            return
                        }
                        exitCode = 0
                    case let .failure(error):
                        fputs("FAIL: \(error.localizedDescription)\n", stderr)
                        exitCode = 3
                    }
                    semaphore.signal()
                }
            )
        }
        runTurn()

        if semaphore.wait(timeout: .now() + 180) == .timedOut {
            fputs("FAIL: Codex app Remote smoke test timed out\n", stderr)
            exitCode = 4
        }
        client.shutdown()
        exit(Int32(exitCode))
    }
}
