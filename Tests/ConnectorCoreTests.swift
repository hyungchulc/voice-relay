import CryptoKit
import Foundation

private var failures: [String] = []

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures.append(message)
    }
}

private func writeExecutable(_ body: String, to url: URL) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
    )
}

private func writeManifest(
    to url: URL,
    executable: String,
    identifier: String = "org.example.daily-brief",
    timeoutMilliseconds: Int = 500,
    readOnly: Bool = true,
    dataClasses: [String] = ["calendar_events"],
    requiredPermissions: [String] = ["calendar.read"]
) throws {
    let object: [String: Any] = [
        "schemaVersion": 1,
        "id": identifier,
        "version": "1.0.0",
        "name": "Example Daily Brief",
        "executable": executable,
        "protocol": "voice-relay.connector.v1",
        "capabilities": ["daily_brief"],
        "triggers": ["return", "morning", "manual"],
        "dataClasses": dataClasses,
        "requiredPermissions": requiredPermissions,
        "readOnly": readOnly,
        "limits": [
            "timeoutMilliseconds": timeoutMilliseconds,
            "maxOutputBytes": 32_768,
        ],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
}

private func binding(
    from value: ConnectorBinding,
    executableURL: URL? = nil,
    enabled: Bool = true,
    approvedPermissions: Set<ConnectorPermission> = [.calendarRead]
) -> ConnectorBinding {
    let selectedExecutable = executableURL ?? value.executableURL
    let selectedManifest: ConnectorManifest
    let selectedManifestURL: URL
    let selectedManifestDigest: String
    let selectedExecutableDigest: String
    if selectedExecutable.standardizedFileURL == value.executableURL.standardizedFileURL {
        selectedManifest = value.manifest
        selectedManifestURL = value.manifestURL
        selectedManifestDigest = value.manifestSHA256
        selectedExecutableDigest = value.executableSHA256
    } else if FileManager.default.fileExists(atPath: selectedExecutable.path) {
        selectedManifest = ConnectorManifest(
            schemaVersion: value.manifest.schemaVersion,
            id: value.manifest.id,
            version: value.manifest.version,
            name: value.manifest.name,
            executable: selectedExecutable.lastPathComponent,
            connectorProtocol: value.manifest.connectorProtocol,
            capabilities: value.manifest.capabilities,
            triggers: value.manifest.triggers,
            dataClasses: value.manifest.dataClasses,
            requiredPermissions: value.manifest.requiredPermissions,
            readOnly: value.manifest.readOnly,
            limits: value.manifest.limits
        )
        selectedManifestURL = selectedExecutable.deletingLastPathComponent()
            .appendingPathComponent(".test-\(selectedExecutable.lastPathComponent).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try! encoder.encode(selectedManifest)
        try! manifestData.write(to: selectedManifestURL, options: .atomic)
        selectedManifestDigest = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }.joined()
        selectedExecutableDigest = SHA256.hash(data: try! Data(contentsOf: selectedExecutable))
            .map { String(format: "%02x", $0) }.joined()
    } else {
        selectedManifest = value.manifest
        selectedManifestURL = value.manifestURL
        selectedManifestDigest = value.manifestSHA256
        selectedExecutableDigest = value.executableSHA256
    }
    return ConnectorBinding(
        manifest: selectedManifest,
        manifestURL: selectedManifestURL,
        executableURL: selectedExecutable,
        manifestSHA256: selectedManifestDigest,
        executableSHA256: selectedExecutableDigest,
        enabled: enabled,
        approvedPermissions: approvedPermissions,
        status: value.status,
        statusReason: value.statusReason,
        statusUpdatedAt: value.statusUpdatedAt
    )
}

@main
private enum ConnectorCoreTests {
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "voice-relay-connector-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let markerURL = scratch.appendingPathComponent("executed.marker")
        let contentExecutable = scratch.appendingPathComponent("connector.sh")
        let contentScript =
            """
            #!/bin/sh
            /usr/bin/touch \"\(markerURL.path)\"
            input=\"$(/bin/cat)\"
            delivery_id=\"$(/usr/bin/printf '%s' \"$input\" | /usr/bin/sed -n 's/.*\"eventID\":\"\\([^\"]*\\)\".*/\\1/p')\"
            /usr/bin/printf '{"schema":"voice-relay-brief-result-v1","deliveryID":"%s","disposition":"speak","generatedAt":"2026-08-03T06:00:00Z","expiresAt":"2026-08-03T12:00:00Z","title":"Daily brief","items":[{"text":"Team review at 10:00"}]}' \"$delivery_id\"
            """
        try writeExecutable(
            contentScript,
            to: contentExecutable
        )
        let manifestURL = scratch.appendingPathComponent("connector.json")
        try writeManifest(
            to: manifestURL,
            executable: contentExecutable.lastPathComponent
        )
        let registryURL = scratch.appendingPathComponent("bindings.json")
        let registry = ConnectorRegistry(storageURL: registryURL)
        let added = try registry.addManifest(at: manifestURL)
        expect(!added.enabled, "adding a connector must never enable it")
        expect(
            added.status == .disabled,
            "a newly bound connector must report disabled status"
        )
        expect(
            !FileManager.default.fileExists(atPath: markerURL.path),
            "manifest validation and binding must never execute connector code"
        )
        let enabled = try registry.setEnabled(
            id: added.manifest.id,
            enabled: true,
            approvedPermissions: [.calendarRead],
            acknowledgedUnsandboxedCode: true
        )
        expect(enabled.enabled, "explicit acknowledgement must enable the connector")
        expect(
            !FileManager.default.fileExists(atPath: markerURL.path),
            "enabling a connector must not execute it"
        )
        expect(
            registry.discover(
                capability: .dailyBrief,
                trigger: .returnEvent
            ).map(\.manifest.id) == [added.manifest.id],
            "capability discovery must return only enabled compatible connectors"
        )

        let denied = ConnectorRunner().run(
            binding: binding(
                from: enabled,
                approvedPermissions: []
            ),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .returnEvent,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: 1_900,
                presenceEvidence: .userActivityHeuristic
            )
        )
        expect(
            denied.status == .permissionDenied,
            "missing required permission acknowledgement must fail closed"
        )

        let healthy = ConnectorRunner().run(
            binding: enabled,
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .returnEvent,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: 1_900,
                presenceEvidence: .userActivityHeuristic
            )
        )
        expect(
            healthy.status == .healthy
                && healthy.result?.items.map(\.text)
                    == ["Team review at 10:00"],
            "an enabled trusted connector must return a bounded structured result"
        )
        expect(
            FileManager.default.fileExists(atPath: markerURL.path),
            "connector code must run only when the host explicitly invokes it"
        )
        try writeExecutable(
            contentScript + "\n# changed after trust acknowledgement\n",
            to: contentExecutable
        )
        let changedExecutable = ConnectorRunner().run(
            binding: enabled,
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .manual,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: nil,
                presenceEvidence: nil
            )
        )
        expect(
            changedExecutable.status == .trustRequired,
            "changing executable bytes must invalidate the opt-in trust binding"
        )
        try writeExecutable(contentScript, to: contentExecutable)

        let swappedMarkerURL = scratch.appendingPathComponent("swapped.marker")
        let swapProtected = ConnectorRunner(beforeLaunch: {
            try? writeExecutable(
                "#!/bin/sh\n/usr/bin/touch \"\(swappedMarkerURL.path)\"\nexit 9\n",
                to: contentExecutable
            )
        }).run(
            binding: enabled,
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .manual,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: nil,
                presenceEvidence: nil
            )
        )
        expect(
            swapProtected.status == .healthy,
            "the runner must execute the exact approved bytes even if the source path changes before launch"
        )
        expect(
            !FileManager.default.fileExists(atPath: swappedMarkerURL.path),
            "bytes swapped onto the source path after verification must never execute"
        )
        try writeExecutable(contentScript, to: contentExecutable)

        let unavailableURL = scratch.appendingPathComponent("missing.sh")
        let unavailable = ConnectorRunner().run(
            binding: binding(from: enabled, executableURL: unavailableURL),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .returnEvent,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: 1_900,
                presenceEvidence: .userActivityHeuristic
            )
        )
        expect(
            unavailable.status == .unavailable,
            "a missing executable must be unavailable rather than empty"
        )

        let emptyExecutable = scratch.appendingPathComponent("empty.sh")
        try writeExecutable(
            """
            #!/bin/sh
            input=\"$(/bin/cat)\"
            delivery_id=\"$(/usr/bin/printf '%s' \"$input\" | /usr/bin/sed -n 's/.*\"eventID\":\"\\([^\"]*\\)\".*/\\1/p')\"
            /usr/bin/printf '{"schema":"voice-relay-brief-result-v1","deliveryID":"%s","disposition":"no_update","generatedAt":"2026-08-03T06:00:00Z","expiresAt":"2026-08-03T12:00:00Z","title":"Daily brief","items":[]}' \"$delivery_id\"
            """,
            to: emptyExecutable
        )
        let empty = ConnectorRunner().run(
            binding: binding(from: enabled, executableURL: emptyExecutable),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .morning,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: nil,
                presenceEvidence: nil
            )
        )
        expect(
            empty.status == .empty && empty.result?.items.isEmpty == true,
            "only an explicit empty result may report nothing scheduled"
        )

        let staleExecutable = scratch.appendingPathComponent("stale.sh")
        try writeExecutable(
            """
            #!/bin/sh
            input=\"$(/bin/cat)\"
            delivery_id=\"$(/usr/bin/printf '%s' \"$input\" | /usr/bin/sed -n 's/.*\"eventID\":\"\\([^\"]*\\)\".*/\\1/p')\"
            /usr/bin/printf '{"schema":"voice-relay-brief-result-v1","deliveryID":"%s","disposition":"speak","generatedAt":"2026-08-02T06:00:00Z","expiresAt":"2026-08-02T12:00:00Z","title":"Old","items":[{"text":"old item"}]}' \"$delivery_id\"
            """,
            to: staleExecutable
        )
        let stale = ConnectorRunner().run(
            binding: binding(from: enabled, executableURL: staleExecutable),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .returnEvent,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: 1_900,
                presenceEvidence: .userActivityHeuristic
            )
        )
        expect(
            stale.status == .stale,
            "expired connector data must be stale rather than empty"
        )

        let failingExecutable = scratch.appendingPathComponent("failing.sh")
        try writeExecutable(
            """
            #!/bin/sh
            /bin/cat >/dev/null
            /usr/bin/printf '%s' 'private connector diagnostic' >&2
            exit 7
            """,
            to: failingExecutable
        )
        let failed = ConnectorRunner().run(
            binding: binding(from: enabled, executableURL: failingExecutable),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .returnEvent,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: 1_900,
                presenceEvidence: .userActivityHeuristic
            )
        )
        expect(
            failed.status == .error
                && !String(describing: failed).contains("private connector diagnostic")
                && !String(describing: failed).contains(failingExecutable.path),
            "connector failures must expose only fixed privacy-safe status"
        )

        let timeoutExecutable = scratch.appendingPathComponent("timeout.sh")
        try writeExecutable(
            """
            #!/bin/sh
            /bin/cat >/dev/null
            /bin/sleep 1
            /usr/bin/printf '%s' '{}'
            """,
            to: timeoutExecutable
        )
        let timeoutManifestURL = scratch.appendingPathComponent("timeout.json")
        try writeManifest(
            to: timeoutManifestURL,
            executable: timeoutExecutable.lastPathComponent,
            identifier: "org.example.timeout",
            timeoutMilliseconds: 100
        )
        let timeoutBinding = try registry.addManifest(at: timeoutManifestURL)
        let timeout = ConnectorRunner().run(
            binding: binding(from: timeoutBinding, executableURL: timeoutExecutable),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .manual,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: nil,
                presenceEvidence: nil
            )
        )
        expect(
            timeout.status == .timeout,
            "a bounded connector timeout must not be classified as empty"
        )

        let heldPipeExecutable = scratch.appendingPathComponent("held-pipe.sh")
        try writeExecutable(
            """
            #!/bin/sh
            input="$(/bin/cat)"
            delivery_id="$(/usr/bin/printf '%s' "$input" | /usr/bin/sed -n 's/.*"eventID":"\\([^"]*\\)".*/\\1/p')"
            /bin/sleep 2 &
            /usr/bin/printf '{"schema":"voice-relay-brief-result-v1","deliveryID":"%s","disposition":"speak","generatedAt":"2026-08-03T06:00:00Z","expiresAt":"2026-08-03T12:00:00Z","title":"Bounded","items":[{"text":"ready"}]}' "$delivery_id"
            """,
            to: heldPipeExecutable
        )
        let heldPipeStartedAt = Date()
        let heldPipe = ConnectorRunner().run(
            binding: binding(from: enabled, executableURL: heldPipeExecutable),
            event: ConnectorHostEventEnvelope.dailyBrief(
                trigger: .manual,
                now: Date(timeIntervalSince1970: 1_785_736_800),
                localDay: "2026-08-03",
                absenceSeconds: nil,
                presenceEvidence: nil
            )
        )
        expect(
            heldPipe.status == .healthy,
            "a detached child holding inherited pipes must not invalidate the parent result"
        )
        expect(
            Date().timeIntervalSince(heldPipeStartedAt) < 0.75,
            "a detached child holding stdout must not extend the host execution bound"
        )

        let invalidManifestURL = scratch.appendingPathComponent("invalid.json")
        try writeManifest(
            to: invalidManifestURL,
            executable: contentExecutable.lastPathComponent,
            identifier: "org.example.mutating",
            readOnly: false
        )
        do {
            _ = try registry.addManifest(at: invalidManifestURL)
            failures.append("a mutating connector manifest must be rejected")
        } catch {}

        let missingPermissionManifestURL = scratch.appendingPathComponent(
            "missing-permission.json"
        )
        try writeManifest(
            to: missingPermissionManifestURL,
            executable: contentExecutable.lastPathComponent,
            identifier: "org.example.missing-permission",
            dataClasses: ["calendar_events"],
            requiredPermissions: []
        )
        do {
            _ = try registry.addManifest(at: missingPermissionManifestURL)
            failures.append("a declared data class without its read permission must be rejected")
        } catch {}

        let maximumSpeech = String(repeating: "a", count: 8_000)
        expect(
            ConnectorSpeechPolicy.compose(
                title: nil,
                items: [ConnectorResultItem(text: maximumSpeech)]
            ) == maximumSpeech,
            "exactly 8,000 UTF-16 units must remain admissible for direct briefing speech"
        )
        expect(
            ConnectorSpeechPolicy.compose(
                title: nil,
                items: [ConnectorResultItem(text: maximumSpeech + "b")]
            ) == nil,
            "8,001 UTF-16 units must fail before a delivery reaches prepared state"
        )

        var playbackCorrelation = AutomaticSpeechPlaybackCorrelation()
        playbackCorrelation.reserve(
            generation: 41,
            expectedKind: .connectorEventBriefing
        )
        expect(
            !playbackCorrelation.bindFinal(
                generation: 41,
                responseID: "ordinary-response",
                kind: .presenceReturnGreeting
            ),
            "an unrelated final must not bind an automatic connector delivery"
        )
        expect(
            playbackCorrelation.bindFinal(
                generation: 41,
                responseID: "connector-response",
                kind: .connectorEventBriefing
            ),
            "the expected automatic response kind must bind its exact response ID"
        )
        expect(
            !playbackCorrelation.consumeDrain(
                generation: 41,
                responseID: "ordinary-response"
            ),
            "an unrelated playback drain must not complete automatic delivery"
        )
        expect(
            playbackCorrelation.consumeDrain(
                generation: 41,
                responseID: "connector-response"
            ),
            "only the bound automatic response drain may complete delivery"
        )
        expect(
            !playbackCorrelation.consumeDrain(
                generation: 41,
                responseID: "connector-response"
            ),
            "automatic playback completion must be exact once"
        )

        let ledgerURL = scratch.appendingPathComponent("delivery-ledger.json")
        let ledger = ConnectorDeliveryLedger(storageURL: ledgerURL)
        let event = ConnectorHostEventEnvelope.dailyBrief(
            trigger: .morning,
            now: Date(timeIntervalSince1970: 1_785_736_800),
            localDay: "2026-08-03",
            absenceSeconds: nil,
            presenceEvidence: nil
        )
        expect(
            ledger.reserve(
                idempotencyKey: event.idempotencyKey,
                eventID: event.eventID,
                at: event.occurredAt
            ),
            "the first Daily Brief delivery must reserve atomically"
        )
        try ledger.transition(
            idempotencyKey: event.idempotencyKey,
            to: .prepared,
            reason: "content",
            at: event.occurredAt
        )
        try ledger.transition(
            idempotencyKey: event.idempotencyKey,
            to: .presented,
            reason: "playback_started",
            at: event.occurredAt
        )
        try ledger.transition(
            idempotencyKey: event.idempotencyKey,
            to: .completed,
            reason: "playback_acknowledged",
            at: event.occurredAt
        )
        expect(
            !ConnectorDeliveryLedger(storageURL: ledgerURL).reserve(
                idempotencyKey: event.idempotencyKey,
                eventID: UUID().uuidString,
                at: event.occurredAt.addingTimeInterval(60)
            ),
            "a completed Daily Brief must remain duplicate-suppressed after reload"
        )

        let retryLedgerURL = scratch.appendingPathComponent("retry-ledger.json")
        let retryLedger = ConnectorDeliveryLedger(storageURL: retryLedgerURL)
        let retryEvent = ConnectorHostEventEnvelope.dailyBrief(
            trigger: .returnEvent,
            now: event.occurredAt.addingTimeInterval(120),
            localDay: "2026-08-04",
            absenceSeconds: 1_900,
            presenceEvidence: .userActivityHeuristic
        )
        expect(
            retryLedger.reserve(event: retryEvent),
            "a deferred delivery must first reserve normally"
        )
        try retryLedger.transition(
            key: retryEvent.idempotencyKey,
            to: .prepared
        )
        retryLedger.releaseForRetry(key: retryEvent.idempotencyKey)
        expect(
            ConnectorDeliveryLedger(storageURL: retryLedgerURL)
                .reserve(event: retryEvent),
            "a media-deferred prepared delivery must become retryable without duplicate speech"
        )

        let corruptLedgerURL = scratch.appendingPathComponent("corrupt-ledger.json")
        let corruptLedgerBytes = Data("{not-json".utf8)
        try corruptLedgerBytes.write(to: corruptLedgerURL, options: .atomic)
        expect(
            !ConnectorDeliveryLedger(storageURL: corruptLedgerURL)
                .reserve(event: retryEvent),
            "a corrupted delivery ledger must fail closed instead of permitting duplicate speech"
        )
        let preservedCorruptLedgerBytes = try Data(contentsOf: corruptLedgerURL)
        expect(
            preservedCorruptLedgerBytes == corruptLedgerBytes,
            "a failed-closed ledger read must not overwrite the recovery evidence"
        )

        let corruptRegistryURL = scratch.appendingPathComponent("corrupt-bindings.json")
        let corruptRegistryBytes = Data("[not-json".utf8)
        try corruptRegistryBytes.write(to: corruptRegistryURL, options: .atomic)
        do {
            _ = try ConnectorRegistry(storageURL: corruptRegistryURL)
                .addManifest(at: manifestURL)
            failures.append("a corrupted connector registry must reject mutation")
        } catch {}
        let preservedCorruptRegistryBytes = try Data(contentsOf: corruptRegistryURL)
        expect(
            preservedCorruptRegistryBytes == corruptRegistryBytes,
            "a rejected registry mutation must preserve the corrupted file for recovery"
        )

        let emptyRegistry = ConnectorRegistry(
            storageURL: scratch.appendingPathComponent("empty-bindings.json")
        )
        let coordinator = ConnectorBriefingCoordinator(
            registry: emptyRegistry,
            runner: ConnectorRunner(),
            ledger: ConnectorDeliveryLedger(
                storageURL: scratch.appendingPathComponent("empty-ledger.json")
            )
        )
        let noConnector = coordinator.prepare(event: event)
        expect(
            noConnector == .abstained(.noConnector),
            "no installed connector must abstain without fabricated briefing text"
        )

        try registry.remove(id: added.manifest.id)
        expect(
            registry.binding(id: added.manifest.id) == nil,
            "removing a connector must remove its persisted binding"
        )

        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("Connector core tests passed")
    }
}
