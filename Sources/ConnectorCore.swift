import CryptoKit
import Darwin
import Foundation

enum ConnectorCapability: String, Codable, CaseIterable, Hashable {
    case dailyBrief = "daily_brief"
}

enum ConnectorTrigger: String, Codable, CaseIterable, Hashable {
    case returnEvent = "return"
    case morning
    case manual
}

enum ConnectorPermission: String, Codable, CaseIterable, Hashable {
    case calendarRead = "calendar.read"
    case remindersRead = "reminders.read"
    case locationRead = "location.read"
}

enum ConnectorDataClass: String, Codable, CaseIterable, Hashable {
    case calendarEvents = "calendar_events"
    case reminders
    case location

    var requiredPermission: ConnectorPermission {
        switch self {
        case .calendarEvents: return .calendarRead
        case .reminders: return .remindersRead
        case .location: return .locationRead
        }
    }
}

enum ConnectorRuntimeStatus: String, Codable, Equatable {
    case discovered
    case disabled
    case trustRequired = "trust_required"
    case ready
    case running
    case healthy
    case permissionDenied = "permission_denied"
    case unavailable
    case empty
    case timeout
    case stale
    case error
    case abstained
}

struct ConnectorManifestLimits: Codable, Equatable {
    let timeoutMilliseconds: Int
    let maxOutputBytes: Int
}

struct ConnectorManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let version: String
    let name: String
    let executable: String
    let connectorProtocol: String
    let capabilities: Set<ConnectorCapability>
    let triggers: Set<ConnectorTrigger>
    let dataClasses: Set<ConnectorDataClass>
    let requiredPermissions: Set<ConnectorPermission>
    let readOnly: Bool
    let limits: ConnectorManifestLimits

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case version
        case name
        case executable
        case connectorProtocol = "protocol"
        case capabilities
        case triggers
        case dataClasses
        case requiredPermissions
        case readOnly
        case limits
    }
}

struct ConnectorBinding: Codable, Equatable {
    let manifest: ConnectorManifest
    let manifestURL: URL
    let executableURL: URL
    let manifestSHA256: String
    let executableSHA256: String
    var enabled: Bool
    var approvedPermissions: Set<ConnectorPermission>
    var status: ConnectorRuntimeStatus
    var statusReason: String?
    var statusUpdatedAt: Date

    init(
        manifest: ConnectorManifest,
        manifestURL: URL,
        executableURL: URL,
        manifestSHA256: String,
        executableSHA256: String,
        enabled: Bool,
        approvedPermissions: Set<ConnectorPermission>,
        status: ConnectorRuntimeStatus,
        statusReason: String?,
        statusUpdatedAt: Date
    ) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.executableURL = executableURL
        self.manifestSHA256 = manifestSHA256
        self.executableSHA256 = executableSHA256
        self.enabled = enabled
        self.approvedPermissions = approvedPermissions
        self.status = status
        self.statusReason = statusReason
        self.statusUpdatedAt = statusUpdatedAt
    }
}

enum ConnectorRegistryError: Error, Equatable, CustomStringConvertible {
    case invalidManifest(String)
    case duplicateIdentifier
    case bindingNotFound
    case storageUnavailable
    case unsandboxedAcknowledgementRequired

    var description: String {
        switch self {
        case let .invalidManifest(reason): return reason
        case .duplicateIdentifier: return "A connector with this identifier is already registered."
        case .bindingNotFound: return "The connector binding was not found."
        case .storageUnavailable: return "The connector registry could not be read safely."
        case .unsandboxedAcknowledgementRequired:
            return "Enabling a connector requires acknowledging that its executable runs unsandboxed."
        }
    }
}

private enum ConnectorFileStore {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureParent(of: url)
        let data = try encoder().encode(value)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func withExclusiveLock<T>(for storageURL: URL, body: () throws -> T) throws -> T {
        try ensureParent(of: storageURL)
        let lockURL = storageURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

private enum ConnectorValidation {
    struct LoadedManifest {
        let manifest: ConnectorManifest
        let data: Data
    }

    static let maximumManifestBytes = 64 * 1024
    static let allowedTopLevelKeys: Set<String> = [
        "schemaVersion", "id", "version", "name", "executable", "protocol",
        "capabilities", "triggers", "dataClasses", "requiredPermissions", "readOnly", "limits",
    ]
    static let allowedLimitKeys: Set<String> = ["timeoutMilliseconds", "maxOutputBytes"]

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return digest(of: data)
    }

    static func loadManifest(at manifestURL: URL) throws -> LoadedManifest {
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConnectorRegistryError.invalidManifest("The manifest must be a regular file.")
        }
        let data = try Data(contentsOf: manifestURL)
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw ConnectorRegistryError.invalidManifest("The connector manifest is empty or too large.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorRegistryError.invalidManifest("The connector manifest must be a JSON object.")
        }
        let unknownTopLevel = Set(object.keys).subtracting(allowedTopLevelKeys)
        guard unknownTopLevel.isEmpty else {
            throw ConnectorRegistryError.invalidManifest("The connector manifest contains unsupported fields.")
        }
        guard let limits = object["limits"] as? [String: Any] else {
            throw ConnectorRegistryError.invalidManifest("The connector manifest must declare execution limits.")
        }
        guard Set(limits.keys).subtracting(allowedLimitKeys).isEmpty else {
            throw ConnectorRegistryError.invalidManifest("The connector limits contain unsupported fields.")
        }
        let manifest: ConnectorManifest
        do {
            manifest = try JSONDecoder().decode(ConnectorManifest.self, from: data)
        } catch {
            throw ConnectorRegistryError.invalidManifest("The connector manifest does not match schema version 1.")
        }
        try validate(manifest)
        return LoadedManifest(manifest: manifest, data: data)
    }

    static func validate(_ manifest: ConnectorManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ConnectorRegistryError.invalidManifest("Unsupported connector schema version.")
        }
        let identifierPattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}\.)+[A-Za-z0-9][A-Za-z0-9-]{0,62}$"#
        guard manifest.id.range(of: identifierPattern, options: .regularExpression) != nil else {
            throw ConnectorRegistryError.invalidManifest("The connector identifier must use reverse-DNS form.")
        }
        let versionPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#
        guard manifest.version.range(of: versionPattern, options: .regularExpression) != nil else {
            throw ConnectorRegistryError.invalidManifest("The connector version must use semantic version form.")
        }
        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
            throw ConnectorRegistryError.invalidManifest("The connector name is invalid.")
        }
        guard manifest.connectorProtocol == "voice-relay.connector.v1" else {
            throw ConnectorRegistryError.invalidManifest("Unsupported connector protocol.")
        }
        guard manifest.readOnly else {
            throw ConnectorRegistryError.invalidManifest("Connector v1 permits read-only connectors only.")
        }
        guard !manifest.capabilities.isEmpty, !manifest.triggers.isEmpty else {
            throw ConnectorRegistryError.invalidManifest("The connector must declare capabilities and triggers.")
        }
        let permissionsRequiredByData = Set(
            manifest.dataClasses.map(\.requiredPermission)
        )
        guard permissionsRequiredByData.isSubset(
            of: manifest.requiredPermissions
        ) else {
            throw ConnectorRegistryError.invalidManifest(
                "Every declared data class must declare its matching read permission."
            )
        }
        let executable = manifest.executable
        guard !executable.isEmpty,
              executable == (executable as NSString).lastPathComponent,
              !executable.contains("/"),
              !executable.contains("\\"),
              executable != ".",
              executable != ".." else {
            throw ConnectorRegistryError.invalidManifest("The executable must be a sibling file name.")
        }
        guard (100...30_000).contains(manifest.limits.timeoutMilliseconds) else {
            throw ConnectorRegistryError.invalidManifest("The connector timeout is outside the supported range.")
        }
        guard (256...1_048_576).contains(manifest.limits.maxOutputBytes) else {
            throw ConnectorRegistryError.invalidManifest("The connector output limit is outside the supported range.")
        }
    }

    static func validateExecutable(at executableURL: URL) throws {
        let values = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConnectorRegistryError.invalidManifest("The declared executable must be a regular file.")
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ConnectorRegistryError.invalidManifest("The declared executable is not executable.")
        }
    }
}

final class ConnectorRegistry {
    static let shared = ConnectorRegistry(storageURL: ConnectorRegistry.defaultStorageURL())

    private let storageURL: URL
    private let lock = NSLock()

    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Voice Relay/Connectors/bindings.json")
    }

    @discardableResult
    func addManifest(at manifestURL: URL, now: Date = Date()) throws -> ConnectorBinding {
        let loadedManifest = try ConnectorValidation.loadManifest(at: manifestURL)
        let manifest = loadedManifest.manifest
        let executableURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.executable)
        try ConnectorValidation.validateExecutable(at: executableURL)
        let executableData = try Data(
            contentsOf: executableURL,
            options: .mappedIfSafe
        )
        let binding = ConnectorBinding(
            manifest: manifest,
            manifestURL: manifestURL.standardizedFileURL,
            executableURL: executableURL.standardizedFileURL,
            manifestSHA256: ConnectorValidation.digest(
                of: loadedManifest.data
            ),
            executableSHA256: ConnectorValidation.digest(
                of: executableData
            ),
            enabled: false,
            approvedPermissions: [],
            status: .disabled,
            statusReason: "connector_disabled",
            statusUpdatedAt: now
        )
        return try mutate { bindings in
            guard !bindings.contains(where: { $0.manifest.id == manifest.id }) else {
                throw ConnectorRegistryError.duplicateIdentifier
            }
            bindings.append(binding)
            bindings.sort { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
            return binding
        }
    }

    @discardableResult
    func setEnabled(
        id: String,
        enabled: Bool,
        approvedPermissions: Set<ConnectorPermission> = [],
        acknowledgedUnsandboxedCode: Bool = false,
        now: Date = Date()
    ) throws -> ConnectorBinding {
        if enabled && !acknowledgedUnsandboxedCode {
            throw ConnectorRegistryError.unsandboxedAcknowledgementRequired
        }
        return try mutate { bindings in
            guard let index = bindings.firstIndex(where: { $0.manifest.id == id }) else {
                throw ConnectorRegistryError.bindingNotFound
            }
            var binding = bindings[index]
            if enabled {
                guard FileManager.default.fileExists(atPath: binding.manifestURL.path),
                      FileManager.default.fileExists(atPath: binding.executableURL.path),
                      try ConnectorValidation.digest(of: binding.manifestURL)
                        == binding.manifestSHA256,
                      try ConnectorValidation.digest(of: binding.executableURL)
                        == binding.executableSHA256 else {
                    binding.status = .trustRequired
                    binding.statusReason = "content_digest_changed"
                    binding.statusUpdatedAt = now
                    binding.enabled = false
                    bindings[index] = binding
                    return binding
                }
            }
            binding.enabled = enabled
            binding.approvedPermissions = enabled ? approvedPermissions : []
            binding.statusUpdatedAt = now
            if !enabled {
                binding.status = .disabled
                binding.statusReason = "connector_disabled"
            } else if !binding.manifest.requiredPermissions.isSubset(of: approvedPermissions) {
                binding.status = .permissionDenied
                binding.statusReason = "permission_not_approved"
            } else {
                binding.status = .ready
                binding.statusReason = nil
            }
            bindings[index] = binding
            return binding
        }
    }

    func remove(id: String) throws {
        try mutate { bindings in
            guard let index = bindings.firstIndex(where: { $0.manifest.id == id }) else {
                throw ConnectorRegistryError.bindingNotFound
            }
            bindings.remove(at: index)
        }
    }

    func binding(id: String) -> ConnectorBinding? {
        lock.lock()
        defer { lock.unlock() }
        return loadBindings().first(where: { $0.manifest.id == id })
    }

    func bindings() -> [ConnectorBinding] {
        lock.lock()
        defer { lock.unlock() }
        return loadBindings()
    }

    func discover(capability: ConnectorCapability, trigger: ConnectorTrigger) -> [ConnectorBinding] {
        bindings().filter {
            $0.enabled
                && $0.manifest.capabilities.contains(capability)
                && $0.manifest.triggers.contains(trigger)
        }
    }

    func updateStatus(id: String, status: ConnectorRuntimeStatus, reason: String?, now: Date = Date()) {
        try? mutate { bindings in
            guard let index = bindings.firstIndex(where: { $0.manifest.id == id }) else { return }
            bindings[index].status = status
            bindings[index].statusReason = reason
            bindings[index].statusUpdatedAt = now
        }
    }

    private func loadBindings() -> [ConnectorBinding] {
        guard let data = try? Data(contentsOf: storageURL),
              let bindings = try? ConnectorFileStore.decoder().decode([ConnectorBinding].self, from: data) else {
            return []
        }
        return bindings
    }

    private func loadBindingsForMutation() throws -> [ConnectorBinding] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: storageURL)
            return try ConnectorFileStore.decoder().decode(
                [ConnectorBinding].self,
                from: data
            )
        } catch {
            throw ConnectorRegistryError.storageUnavailable
        }
    }

    private func mutate<T>(_ body: (inout [ConnectorBinding]) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try ConnectorFileStore.withExclusiveLock(for: storageURL) {
            var bindings = try loadBindingsForMutation()
            let result = try body(&bindings)
            try ConnectorFileStore.writeAtomically(bindings, to: storageURL)
            return result
        }
    }
}

enum PresenceEvidence: String, Codable, Equatable {
    case userActivityHeuristic = "user_activity_heuristic"
    case sessionActivated = "session_activated"
    case screenUnlocked = "screen_unlocked"
}

struct ConnectorHostEventEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let eventID: String
    let idempotencyKey: String
    let trigger: ConnectorTrigger
    let occurredAt: Date
    let localDay: String
    let absenceSeconds: TimeInterval?
    let presenceEvidence: PresenceEvidence?

    static func dailyBrief(
        eventID: String,
        trigger: ConnectorTrigger,
        occurredAt: Date,
        localDay: String,
        absenceSeconds: TimeInterval?,
        presenceEvidence: PresenceEvidence?
    ) -> ConnectorHostEventEnvelope {
        let key = trigger == .manual ? "daily-brief:\(localDay):manual:\(eventID)" : "daily-brief:\(localDay)"
        return ConnectorHostEventEnvelope(
            schemaVersion: 1,
            eventID: eventID,
            idempotencyKey: key,
            trigger: trigger,
            occurredAt: occurredAt,
            localDay: localDay,
            absenceSeconds: absenceSeconds,
            presenceEvidence: presenceEvidence
        )
    }

    static func dailyBrief(
        trigger: ConnectorTrigger,
        now: Date,
        localDay: String,
        absenceSeconds: TimeInterval?,
        presenceEvidence: PresenceEvidence?
    ) -> ConnectorHostEventEnvelope {
        dailyBrief(
            eventID: UUID().uuidString,
            trigger: trigger,
            occurredAt: now,
            localDay: localDay,
            absenceSeconds: absenceSeconds,
            presenceEvidence: presenceEvidence
        )
    }
}

struct ConnectorResultItem: Codable, Equatable {
    let text: String
}

enum ConnectorSpeechPolicy {
    static let maximumUTF16Units = 8_000

    static func compose(
        title: String?,
        items: [ConnectorResultItem]
    ) -> String? {
        let trimmedTitle = title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var fragments: [String] = []
        if let trimmedTitle, !trimmedTitle.isEmpty {
            fragments.append(trimmedTitle)
        }
        fragments.append(contentsOf: items.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let speech = fragments.joined(separator: ". ")
        guard !speech.isEmpty,
              speech.utf16.count <= maximumUTF16Units else {
            return nil
        }
        return speech
    }
}

enum AutomaticSpeechKind: String, Equatable {
    case connectorEventBriefing = "connector_event_briefing"
    case presenceReturnGreeting = "presence_return_greeting"
}

struct AutomaticSpeechPlaybackCorrelation {
    private struct Entry {
        let expectedKind: AutomaticSpeechKind
        var responseID: String?
    }

    private var entries: [Int: Entry] = [:]

    mutating func reserve(
        generation: Int,
        expectedKind: AutomaticSpeechKind
    ) {
        entries[generation] = Entry(
            expectedKind: expectedKind,
            responseID: nil
        )
    }

    @discardableResult
    mutating func bindFinal(
        generation: Int,
        responseID: String,
        kind: AutomaticSpeechKind
    ) -> Bool {
        let trimmedResponseID = responseID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedResponseID.isEmpty,
              var entry = entries[generation],
              entry.expectedKind == kind,
              entry.responseID == nil else {
            return false
        }
        entry.responseID = trimmedResponseID
        entries[generation] = entry
        return true
    }

    @discardableResult
    mutating func consumeDrain(
        generation: Int,
        responseID: String
    ) -> Bool {
        guard entries[generation]?.responseID == responseID else {
            return false
        }
        entries.removeValue(forKey: generation)
        return true
    }

    mutating func cancel(generation: Int) {
        entries.removeValue(forKey: generation)
    }
}

enum ConnectorResultDisposition: String, Codable, Equatable {
    case speak
    case noUpdate = "no_update"
    case deferDelivery = "defer"
    case abstain
}

struct ConnectorStructuredResult: Codable, Equatable {
    let schema: String
    let deliveryID: String
    let disposition: ConnectorResultDisposition
    let generatedAt: Date
    let expiresAt: Date
    let title: String?
    let items: [ConnectorResultItem]
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case deliveryID
        case disposition
        case generatedAt
        case expiresAt
        case title
        case items
        case reason
    }
}

struct ConnectorInvocation: Equatable {
    let status: ConnectorRuntimeStatus
    let result: ConnectorStructuredResult?
    let reason: String?
}

final class ConnectorRunner {
    private let maximumItemCount = 24
    private let maximumTextCharacters = 1_000
    private let beforeLaunch: (() -> Void)?

    init(beforeLaunch: (() -> Void)? = nil) {
        self.beforeLaunch = beforeLaunch
    }

    private func materializeVerifiedExecutable(
        _ data: Data
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "voice-relay-connector-run-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let executableURL = directory.appendingPathComponent("connector")
        do {
            try data.write(to: executableURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: executableURL.path
            )
            return executableURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func run(binding: ConnectorBinding, event: ConnectorHostEventEnvelope) -> ConnectorInvocation {
        guard binding.enabled else {
            return ConnectorInvocation(status: .disabled, result: nil, reason: "connector_disabled")
        }
        guard binding.manifest.requiredPermissions.isSubset(of: binding.approvedPermissions) else {
            return ConnectorInvocation(status: .permissionDenied, result: nil, reason: "permission_not_approved")
        }
        guard FileManager.default.fileExists(atPath: binding.executableURL.path),
              FileManager.default.isExecutableFile(atPath: binding.executableURL.path),
              (try? ConnectorValidation.validateExecutable(
                  at: binding.executableURL
              )) != nil else {
            return ConnectorInvocation(status: .unavailable, result: nil, reason: "executable_unavailable")
        }
        let declaredExecutable = binding.manifestURL.deletingLastPathComponent()
            .appendingPathComponent(binding.manifest.executable)
            .standardizedFileURL
        guard declaredExecutable == binding.executableURL.standardizedFileURL else {
            return ConnectorInvocation(status: .trustRequired, result: nil, reason: "binding_path_changed")
        }
        guard let executableData = try? Data(
                  contentsOf: binding.executableURL,
                  options: .mappedIfSafe
              ),
              ConnectorValidation.digest(of: executableData)
                == binding.executableSHA256,
              let manifestData = try? Data(
                  contentsOf: binding.manifestURL,
                  options: .mappedIfSafe
              ),
              ConnectorValidation.digest(of: manifestData)
                == binding.manifestSHA256 else {
            return ConnectorInvocation(status: .trustRequired, result: nil, reason: "content_digest_changed")
        }
        let verifiedExecutableURL: URL
        do {
            verifiedExecutableURL = try materializeVerifiedExecutable(
                executableData
            )
        } catch {
            return ConnectorInvocation(status: .unavailable, result: nil, reason: "execution_failed")
        }
        defer {
            try? FileManager.default.removeItem(
                at: verifiedExecutableURL.deletingLastPathComponent()
            )
        }
        guard let copiedDigest = try? ConnectorValidation.digest(
                  of: verifiedExecutableURL
              ),
              copiedDigest == binding.executableSHA256,
              let manifestDigest = try? ConnectorValidation.digest(of: binding.manifestURL),
              manifestDigest == binding.manifestSHA256 else {
            return ConnectorInvocation(status: .trustRequired, result: nil, reason: "content_digest_changed")
        }

        let eventData: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            eventData = try encoder.encode(event)
        } catch {
            return ConnectorInvocation(status: .error, result: nil, reason: "event_encoding_failed")
        }

        let process = Process()
        process.executableURL = verifiedExecutableURL
        process.arguments = []
        process.currentDirectoryURL = binding.executableURL.deletingLastPathComponent()
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
        ]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        beforeLaunch?()

        var stdoutData = Data()
        var outputExceeded = false
        let maximumOutput = binding.manifest.limits.maxOutputBytes
        let stdoutDescriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        for descriptor in [stdoutDescriptor, stderrDescriptor] {
            let currentFlags = fcntl(descriptor, F_GETFL)
            guard currentFlags >= 0,
                  fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
                return ConnectorInvocation(status: .unavailable, result: nil, reason: "execution_failed")
            }
        }

        func drain(_ descriptor: Int32, capture: Bool) {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(
                    descriptor,
                    &bytes,
                    bytes.count
                )
                if count > 0 {
                    guard capture else { continue }
                    if stdoutData.count + count <= maximumOutput {
                        stdoutData.append(contentsOf: bytes.prefix(count))
                    } else {
                        outputExceeded = true
                    }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return
            }
        }

        func drainPipes() {
            drain(stdoutDescriptor, capture: true)
            drain(stderrDescriptor, capture: false)
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try stdinPipe.fileHandleForWriting.write(contentsOf: eventData)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            return ConnectorInvocation(status: .unavailable, result: nil, reason: "execution_failed")
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(binding.manifest.limits.timeoutMilliseconds) * 1_000_000
        var didTerminate = false
        while true {
            drainPipes()
            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else {
                break
            }
            let remaining = deadline - current
            let waitNanoseconds = min(remaining, 10_000_000)
            if terminated.wait(
                timeout: .now() + .nanoseconds(Int(waitNanoseconds))
            ) == .success {
                didTerminate = true
                break
            }
        }
        drainPipes()
        if !didTerminate {
            kill(-process.processIdentifier, SIGTERM)
            process.terminate()
            if terminated.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                kill(-process.processIdentifier, SIGKILL)
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + .seconds(1))
            }
            drainPipes()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return ConnectorInvocation(status: .timeout, result: nil, reason: "execution_timed_out")
        }
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        let capturedOutput = stdoutData
        let exceeded = outputExceeded
        guard !exceeded else {
            return ConnectorInvocation(status: .error, result: nil, reason: "output_limit_exceeded")
        }
        guard process.terminationStatus == 0 else {
            return ConnectorInvocation(status: .error, result: nil, reason: "connector_failed")
        }
        guard !capturedOutput.isEmpty else {
            return ConnectorInvocation(status: .error, result: nil, reason: "missing_structured_result")
        }

        let result: ConnectorStructuredResult
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try decoder.decode(ConnectorStructuredResult.self, from: capturedOutput)
        } catch {
            return ConnectorInvocation(status: .error, result: nil, reason: "invalid_structured_result")
        }
        guard result.schema == "voice-relay-brief-result-v1",
              result.deliveryID == event.eventID,
              result.items.count <= maximumItemCount,
              result.items.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= maximumTextCharacters }),
              (result.title?.count ?? 0) <= maximumTextCharacters else {
            return ConnectorInvocation(status: .error, result: nil, reason: "invalid_result_contract")
        }
        guard result.expiresAt > event.occurredAt, result.expiresAt > result.generatedAt else {
            return ConnectorInvocation(status: .stale, result: nil, reason: "result_expired")
        }
        switch result.disposition {
        case .speak:
            guard !result.items.isEmpty || !(result.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                return ConnectorInvocation(status: .error, result: nil, reason: "empty_speech_result")
            }
            return ConnectorInvocation(status: .healthy, result: result, reason: nil)
        case .noUpdate:
            guard result.items.isEmpty else {
                return ConnectorInvocation(status: .error, result: nil, reason: "invalid_empty_result")
            }
            return ConnectorInvocation(status: .empty, result: result, reason: "explicit_no_update")
        case .deferDelivery:
            return ConnectorInvocation(status: .abstained, result: result, reason: "connector_deferred")
        case .abstain:
            return ConnectorInvocation(status: .abstained, result: result, reason: "connector_abstained")
        }
    }
}

enum ConnectorDeliveryState: String, Codable, Equatable {
    case reserved
    case prepared
    case presented
    case completed
    case abstained
    case failed
}

struct ConnectorDeliveryRecord: Codable, Equatable {
    let idempotencyKey: String
    let eventID: String
    let trigger: ConnectorTrigger
    var state: ConnectorDeliveryState
    var reason: String?
    var updatedAt: Date
}

enum ConnectorLedgerError: Error, Equatable {
    case missingRecord
    case invalidTransition
    case storageUnavailable
}

final class ConnectorDeliveryLedger {
    static let shared = ConnectorDeliveryLedger(storageURL: ConnectorDeliveryLedger.defaultStorageURL())

    private let storageURL: URL
    private let lock = NSLock()

    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Voice Relay/Connectors/deliveries.json")
    }

    func reserve(event: ConnectorHostEventEnvelope, now: Date = Date()) -> Bool {
        (try? mutate { records in
            guard records[event.idempotencyKey] == nil else { return false }
            records[event.idempotencyKey] = ConnectorDeliveryRecord(
                idempotencyKey: event.idempotencyKey,
                eventID: event.eventID,
                trigger: event.trigger,
                state: .reserved,
                reason: nil,
                updatedAt: now
            )
            return true
        }) ?? false
    }

    func reserve(idempotencyKey: String, eventID: String, at now: Date) -> Bool {
        (try? mutate { records in
            guard records[idempotencyKey] == nil else { return false }
            records[idempotencyKey] = ConnectorDeliveryRecord(
                idempotencyKey: idempotencyKey,
                eventID: eventID,
                trigger: .manual,
                state: .reserved,
                reason: nil,
                updatedAt: now
            )
            return true
        }) ?? false
    }

    func transition(
        key: String,
        to state: ConnectorDeliveryState,
        reason: String? = nil,
        now: Date = Date()
    ) throws {
        try mutate { records in
            guard var record = records[key] else { throw ConnectorLedgerError.missingRecord }
            guard Self.canTransition(from: record.state, to: state) else {
                throw ConnectorLedgerError.invalidTransition
            }
            record.state = state
            record.reason = reason
            record.updatedAt = now
            records[key] = record
        }
    }

    func transition(
        idempotencyKey: String,
        to state: ConnectorDeliveryState,
        reason: String? = nil,
        at now: Date
    ) throws {
        try transition(key: idempotencyKey, to: state, reason: reason, now: now)
    }

    func record(for key: String) -> ConnectorDeliveryRecord? {
        lock.lock()
        defer { lock.unlock() }
        return loadRecords()[key]
    }

    func releaseForRetry(key: String) {
        try? mutate { records in
            guard let state = records[key]?.state,
                  state == .reserved || state == .prepared else { return }
            records.removeValue(forKey: key)
        }
    }

    private static func canTransition(from: ConnectorDeliveryState, to: ConnectorDeliveryState) -> Bool {
        switch (from, to) {
        case (.reserved, .prepared), (.reserved, .abstained), (.reserved, .failed),
             (.prepared, .presented), (.prepared, .failed),
             (.presented, .completed), (.presented, .failed):
            return true
        default:
            return false
        }
    }

    private func loadRecords() -> [String: ConnectorDeliveryRecord] {
        guard let data = try? Data(contentsOf: storageURL),
              let records = try? ConnectorFileStore.decoder().decode([String: ConnectorDeliveryRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func loadRecordsForMutation() throws -> [String: ConnectorDeliveryRecord] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: storageURL)
            return try ConnectorFileStore.decoder().decode(
                [String: ConnectorDeliveryRecord].self,
                from: data
            )
        } catch {
            throw ConnectorLedgerError.storageUnavailable
        }
    }

    private func mutate<T>(_ body: (inout [String: ConnectorDeliveryRecord]) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try ConnectorFileStore.withExclusiveLock(for: storageURL) {
            var records = try loadRecordsForMutation()
            let result = try body(&records)
            try ConnectorFileStore.writeAtomically(records, to: storageURL)
            return result
        }
    }
}

enum ConnectorBriefingAbstention: String, Equatable {
    case noConnector = "no_connector"
    case unavailable = "connector_unavailable"
    case connectorAbstained = "connector_abstained"
    case invalidResult = "invalid_result"
}

struct ConnectorBriefingPresentation: Codable, Equatable {
    let eventID: String
    let idempotencyKey: String
    let trigger: ConnectorTrigger
    let speech: String
}

enum ConnectorBriefingPreparation: Equatable {
    case presentation(ConnectorBriefingPresentation)
    case abstained(ConnectorBriefingAbstention)
    case duplicate
}

final class ConnectorBriefingCoordinator {
    private let registry: ConnectorRegistry
    private let runner: ConnectorRunner
    private let ledger: ConnectorDeliveryLedger

    init(registry: ConnectorRegistry, runner: ConnectorRunner, ledger: ConnectorDeliveryLedger) {
        self.registry = registry
        self.runner = runner
        self.ledger = ledger
    }

    func prepare(event: ConnectorHostEventEnvelope) -> ConnectorBriefingPreparation {
        let bindings = registry.discover(capability: .dailyBrief, trigger: event.trigger)
        guard !bindings.isEmpty else {
            return .abstained(.noConnector)
        }
        guard ledger.reserve(event: event, now: event.occurredAt) else {
            return .duplicate
        }

        var healthyResults: [ConnectorStructuredResult] = []
        var explicitEmptyCount = 0
        var abstainedCount = 0
        var failureCount = 0
        for binding in bindings {
            registry.updateStatus(id: binding.manifest.id, status: .running, reason: nil, now: event.occurredAt)
            let invocation = runner.run(binding: binding, event: event)
            registry.updateStatus(
                id: binding.manifest.id,
                status: invocation.status,
                reason: invocation.reason,
                now: Date()
            )
            switch invocation.status {
            case .healthy:
                if let result = invocation.result { healthyResults.append(result) }
            case .empty:
                explicitEmptyCount += 1
            case .abstained:
                abstainedCount += 1
            default:
                failureCount += 1
            }
        }

        let speech: String
        if !healthyResults.isEmpty {
            let fragments = healthyResults.flatMap { result -> [ConnectorResultItem] in
                var fragments: [ConnectorResultItem] = []
                if let title = result.title {
                    fragments.append(ConnectorResultItem(text: title))
                }
                fragments.append(contentsOf: result.items)
                return fragments
            }
            guard let composed = ConnectorSpeechPolicy.compose(
                title: nil,
                items: fragments
            ) else {
                try? ledger.transition(
                    key: event.idempotencyKey,
                    to: .failed,
                    reason: "speech_limit_exceeded"
                )
                return .abstained(.invalidResult)
            }
            speech = composed
        } else if explicitEmptyCount == bindings.count {
            speech = "Nothing is scheduled."
        } else {
            let reason: ConnectorBriefingAbstention = failureCount > 0 ? .unavailable : .connectorAbstained
            let state: ConnectorDeliveryState = failureCount > 0 ? .failed : .abstained
            try? ledger.transition(key: event.idempotencyKey, to: state, reason: reason.rawValue)
            return .abstained(reason)
        }

        guard !speech.isEmpty else {
            try? ledger.transition(key: event.idempotencyKey, to: .failed, reason: "invalid_result")
            return .abstained(.invalidResult)
        }
        do {
            try ledger.transition(key: event.idempotencyKey, to: .prepared)
        } catch {
            return .abstained(.invalidResult)
        }
        return .presentation(ConnectorBriefingPresentation(
            eventID: event.eventID,
            idempotencyKey: event.idempotencyKey,
            trigger: event.trigger,
            speech: speech
        ))
    }

    func markPresented(_ presentation: ConnectorBriefingPresentation, now: Date = Date()) {
        try? ledger.transition(key: presentation.idempotencyKey, to: .presented, now: now)
    }

    func complete(_ presentation: ConnectorBriefingPresentation, now: Date = Date()) {
        try? ledger.transition(key: presentation.idempotencyKey, to: .completed, now: now)
    }

    func fail(_ presentation: ConnectorBriefingPresentation, reason: String, now: Date = Date()) {
        try? ledger.transition(key: presentation.idempotencyKey, to: .failed, reason: reason, now: now)
    }

    func deferForRetry(_ presentation: ConnectorBriefingPresentation) {
        ledger.releaseForRetry(key: presentation.idempotencyKey)
    }
}
