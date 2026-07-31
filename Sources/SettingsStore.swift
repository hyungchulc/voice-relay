import Darwin
import Foundation
import OSLog

enum VoiceRelayDiagnostics {
    private static let logger = Logger(
        subsystem: "com.hyungchulc.voice-relay",
        category: "flow"
    )
    static let transcriptLoggingKey =
        "voiceRelay.diagnostics.logTranscripts"

    static var logsTranscriptContent: Bool {
        UserDefaults.standard.bool(forKey: transcriptLoggingKey)
    }

    static func flow(
        _ stage: String,
        generation: Int? = nil,
        fields: [String: String] = [:],
        transcriptFields: [String: String] = [:]
    ) {
        let entry = rendered(
            stage,
            generation: generation,
            fields: fields,
            transcriptFields: transcriptFields,
            includeTranscriptContent: logsTranscriptContent
        )
        logger.notice("Voice Relay flow \(entry, privacy: .public)")
    }

    static func rendered(
        _ stage: String,
        generation: Int? = nil,
        fields: [String: String] = [:],
        transcriptFields: [String: String] = [:],
        includeTranscriptContent: Bool
    ) -> String {
        var parts = ["stage=\(stage)"]
        if let generation {
            parts.append("generation=\(generation)")
        }
        for key in fields.keys.sorted() {
            guard !isSensitiveField(key) else {
                parts.append("\(key)=redacted")
                continue
            }
            parts.append(
                "\(key)=\(singleLine(redactingSecrets(fields[key] ?? "")))"
            )
        }
        if includeTranscriptContent {
            for key in transcriptFields.keys.sorted() {
                guard !isSensitiveField(key) else {
                    parts.append("\(key)=redacted")
                    continue
                }
                parts.append(
                    "\(key)=\(quoted(redactingSecrets(transcriptFields[key] ?? "")))"
                )
            }
        } else if !transcriptFields.isEmpty {
            parts.append("content=redacted")
        }
        return parts.joined(separator: " ")
    }

    static func safe(_ value: String) -> String {
        singleLine(redactingSecrets(value))
    }

    private static func isSensitiveField(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter(\.isLetter)
        return normalized.contains("authorization")
            || normalized.contains("credential")
            || normalized.contains("secret")
            || normalized.contains("token")
            || normalized.contains("apikey")
    }

    private static func redactingSecrets(_ value: String) -> String {
        var redacted = value
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]+"#,
            #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)openai-insecure-api-key\.[A-Za-z0-9._-]+"#,
            #"(?i)(api[_-]?key|authorization|credential|token)\s*[:=]\s*["']?[^\s"',}]+"#,
            #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else {
                continue
            }
            let range = NSRange(
                redacted.startIndex..<redacted.endIndex,
                in: redacted
            )
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return redacted
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func quoted(_ value: String) -> String {
        let escaped = singleLine(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct AppSettings: Equatable {
    var productName: String
    var assistantName: String
    var userDisplayName: String
    var appDisplayLanguage: String
    var appearanceMode: String
    var overlayAnchor: OverlayAnchor
    var animateSurface: Bool
    var hoverStartsVoice: Bool
    var hoverStartDelay: Double
    var collapseDelay: Double
    var wakePhraseEnabled: Bool
    var wakePhrases: [String]
    var showRecentHistory: Bool
    var recentTurnLimit: Int
    var autoSpeak: Bool
    var speechLocale: String
    var additionalSpeechLocales: [String]
    var preferModernSpeechAnalyzer: Bool
    var voiceIdleTimeoutMinutes: Int
    var returnGreetingEnabled: Bool
    var returnGreetingMinutes: Int

    var codexExecutablePath: String
    var codexWorkspacePath: String
    var codexThreadID: String
    var codexThreadSource: String
    var codexThreadTitle: String
    var codexModel: String
    var codexReasoningEffort: String
    var codexFastMode: Bool
    var codexSandbox: String
    var codexApprovalPolicy: String

    var includeAuthorityPack: Bool
    var authorityPackRoot: String
    var authorityPackFingerprint: String
    var includeAdditionalContextProviders: Bool
    var additionalContextProvidersRoot: String

    var realtimeModel: String
    var realtimeVoice: String
    var realtimeSpeechRate: Double
    var realtimeReasoningEffort: String
    var realtimeInstructions: String

    var secondarySpeechLocale: String {
        get { additionalSpeechLocales.first ?? "" }
        set {
            if newValue.isEmpty {
                additionalSpeechLocales = Array(additionalSpeechLocales.dropFirst())
            } else if additionalSpeechLocales.isEmpty {
                additionalSpeechLocales = [newValue]
            } else {
                additionalSpeechLocales[0] = newValue
            }
        }
    }

    static var defaults: AppSettings {
        return AppSettings(
            productName: "Voice Relay",
            assistantName: "Relay",
            userDisplayName: "",
            appDisplayLanguage: AppDisplayLanguage.system.rawValue,
            appearanceMode: AppAppearanceMode.system.rawValue,
            overlayAnchor: .automatic,
            animateSurface: true,
            hoverStartsVoice: false,
            hoverStartDelay: 0.16,
            collapseDelay: 0.25,
            wakePhraseEnabled: true,
            wakePhrases: SettingsStore.defaultWakePhrases,
            showRecentHistory: true,
            recentTurnLimit: 8,
            autoSpeak: false,
            speechLocale: "system",
            additionalSpeechLocales: [],
            preferModernSpeechAnalyzer: true,
            voiceIdleTimeoutMinutes: 5,
            returnGreetingEnabled: true,
            returnGreetingMinutes: 30,
            codexExecutablePath: SettingsStore.detectCodexExecutable() ?? "codex",
            codexWorkspacePath: SettingsStore.defaultCodexWorkspaceURL.path,
            codexThreadID: "",
            codexThreadSource: "",
            codexThreadTitle: "",
            codexModel: "inherit",
            codexReasoningEffort: "inherit",
            codexFastMode: false,
            codexSandbox: "inherit",
            codexApprovalPolicy: "inherit",
            includeAuthorityPack: false,
            authorityPackRoot: "",
            authorityPackFingerprint: "",
            includeAdditionalContextProviders: false,
            additionalContextProvidersRoot: "",
            realtimeModel: "gpt-realtime-2.1",
            realtimeVoice: "marin",
            realtimeSpeechRate: 1.0,
            realtimeReasoningEffort: "high",
            realtimeInstructions: SettingsStore.defaultRealtimeInstructions
        )
    }
}

final class SettingsStore {
    static let shared = SettingsStore()
    static let settingsDidChange = Notification.Name("VoiceRelaySettingsDidChange")

    static let authorityPackFiles = [
        "AGENTS.md",
        "SOUL.md",
        "USER.md",
        "SOURCE_RULES.md",
        "TOOLS.md",
        "IDENTITY.md",
        "WORKFLOW_AUTO.md",
    ]
    static let defaultWakePhrases = ["Relay", "Hey Relay"]
    static let supportedRealtimeVoices = [
        "marin",
        "cedar",
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "sage",
        "shimmer",
        "verse",
    ]
    static let currentSchemaVersion = 20
    private static let legacyDefaultRealtimeInstructionFingerprints:
        Set<UInt64> = [
            0x01a7718371a87c1c,
            0x054d9a4fca5b5e96,
        ]
    static var defaultCodexWorkspaceURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Voice Relay", isDirectory: true)
        .appendingPathComponent("Workspace", isDirectory: true)
    }
    static let defaultRealtimeInstructions = """
    # Role and Objective
    You are the product's low-latency conversational voice layer.

    # Language and Voice
    Respond in the user's language. Match the user's conversational register. Keep spoken replies natural, concise, and free of internal implementation details.

    # Semantic Routing
    For every completed user turn, call the provided route tool immediately without speaking first. Decide from the complete utterance and active conversation. Follow the non-editable routing contract supplied by the application instead of a phrase list.

    # Delivery
    After the route tool returns, follow the application's response instruction for that action. Do not reveal private reasoning, routing mechanics, tools, or hidden context.
    """
    static func resolvedSpeechLocaleIdentifier(
        _ identifier: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == "system" else {
            return trimmed
        }
        return preferredLanguages.first ?? Locale.current.identifier
    }

    static func resolvedSpeechLocaleIdentifiers(
        _ identifiers: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var seen = Set<String>()
        return Array(
            identifiers.enumerated().compactMap { index, rawIdentifier in
                let trimmed = rawIdentifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard index == 0 || !trimmed.isEmpty else { return nil }
                let resolved = resolvedSpeechLocaleIdentifier(
                    trimmed,
                    preferredLanguages: preferredLanguages
                )
                guard !resolved.isEmpty, seen.insert(resolved).inserted else {
                    return nil
                }
                return resolved
            }.prefix(4)
        )
    }

    static func realtimeLanguageHint(
        _ identifier: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let resolved = resolvedSpeechLocaleIdentifier(
            identifier,
            preferredLanguages: preferredLanguages
        )
        let primary = resolved
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased() ?? ""
        guard primary.count == 2,
              primary.unicodeScalars.allSatisfy({
                  CharacterSet.letters.contains($0)
              }) else {
            return ""
        }
        return primary
    }

    private enum Key {
        static let schemaVersion = "voiceRelay.settings.schemaVersion"
        static let onboardingCompleted = "voiceRelay.onboarding.completed"
        static let completedFirstVoiceGreeting = "voiceRelay.voice.completedFirstGreeting"
        static let codexAppConnectionCompleted =
            "voiceRelay.codex.appConnection.completed"
        static let productName = "voiceRelay.identity.productName"
        static let assistantName = "voiceRelay.identity.assistantName"
        static let userDisplayName = "voiceRelay.identity.userDisplayName"
        static let appDisplayLanguage = "voiceRelay.appearance.language"
        static let appearanceMode = "voiceRelay.appearance.mode"
        static let overlayAnchor = "voiceRelay.surface.anchor"
        static let animateSurface = "voiceRelay.surface.animate"
        static let hoverStartsVoice = "voiceRelay.voice.hoverStarts"
        static let hoverStartDelay = "voiceRelay.voice.hoverStartDelay"
        static let collapseDelay = "voiceRelay.surface.collapseDelay"
        static let wakePhraseEnabled = "voiceRelay.voice.wakePhraseEnabled"
        static let wakePhrases = "voiceRelay.voice.wakePhrases"
        static let showRecentHistory = "voiceRelay.surface.showRecentHistory"
        static let recentTurnLimit = "voiceRelay.surface.recentTurnLimit"
        static let autoSpeak = "voiceRelay.voice.autoSpeak"
        static let speechLocale = "voiceRelay.voice.speechLocale"
        static let secondarySpeechLocale = "voiceRelay.voice.secondarySpeechLocale"
        static let additionalSpeechLocales = "voiceRelay.voice.additionalSpeechLocales"
        static let preferModernSpeechAnalyzer =
            "voiceRelay.voice.preferModernSpeechAnalyzer"
        static let voiceIdleTimeoutMinutes = "voiceRelay.voice.idleTimeoutMinutes"
        static let returnGreetingEnabled = "voiceRelay.presence.returnGreetingEnabled"
        static let returnGreetingMinutes = "voiceRelay.presence.returnGreetingMinutes"
        static let codexExecutablePath = "voiceRelay.codex.executablePath"
        static let codexWorkspacePath = "voiceRelay.codex.workspacePath"
        static let codexThreadID = "voiceRelay.codex.threadID"
        static let codexThreadManaged = "voiceRelay.codex.threadManaged"
        static let codexThreadSource = "voiceRelay.codex.threadSource"
        static let codexThreadTitle = "voiceRelay.codex.threadTitle"
        static let codexModel = "voiceRelay.codex.model"
        static let codexReasoningEffort = "voiceRelay.codex.reasoningEffort"
        static let codexFastMode = "voiceRelay.codex.fastMode"
        static let codexSandbox = "voiceRelay.codex.sandbox"
        static let codexApprovalPolicy = "voiceRelay.codex.approvalPolicy"
        static let includeAuthorityPack = "voiceRelay.injection.enabled"
        static let authorityPackRoot = "voiceRelay.injection.authorityRoot"
        static let authorityPackFingerprint = "voiceRelay.injection.fingerprint"
        static let includeAdditionalContextProviders =
            "voiceRelay.additionalContext.enabled"
        static let additionalContextProvidersRoot =
            "voiceRelay.additionalContext.providersRoot"
        static let realtimeModel = "voiceRelay.voice.realtimeModel"
        static let realtimeVoice = "voiceRelay.voice.realtimeVoice"
        static let realtimeSpeechRate =
            "voiceRelay.voice.realtimeSpeechRate"
        static let realtimeReasoningEffort = "voiceRelay.voice.realtimeReasoningEffort"
        static let realtimeInstructions = "voiceRelay.voice.realtimeInstructions"
    }

    private struct ThreadBinding {
        let threadID: String
        let source: String
    }

    enum ThreadBindingSaveIntent {
        case preserveCurrent
        case applyDraft
    }

    private let defaults: UserDefaults
    private let threadBindingLockURL: URL

    init(
        defaults: UserDefaults = .standard,
        threadBindingLockURL: URL? = nil
    ) {
        self.defaults = defaults
        try? FileManager.default.createDirectory(
            at: Self.defaultCodexWorkspaceURL,
            withIntermediateDirectories: true
        )
        self.threadBindingLockURL = threadBindingLockURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("Voice Relay", isDirectory: true)
            .appendingPathComponent("thread-binding.lock", isDirectory: false)
    }

    func load() -> AppSettings {
        let storedSchemaVersion = defaults.integer(forKey: Key.schemaVersion)
        if storedSchemaVersion < Self.currentSchemaVersion,
           let storedRealtimeInstructions =
            defaults.string(forKey: Key.realtimeInstructions),
           Self.isLegacyDefaultRealtimeInstructions(
            storedRealtimeInstructions
           ) {
            defaults.set(
                Self.defaultRealtimeInstructions,
                forKey: Key.realtimeInstructions
            )
        }
        if storedSchemaVersion < Self.currentSchemaVersion {
            defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
        }
        migrateAuthorityFingerprintIfNeeded()
        let fallback = AppSettings.defaults
        let realtimeInstructions = Self.normalizedRealtimeInstructions(
            defaults.string(forKey: Key.realtimeInstructions)
                ?? fallback.realtimeInstructions
        )
        let binding = (try? withThreadBindingLock {
            readThreadBindingUnlocked(fallback: fallback)
        }) ?? ThreadBinding(
            threadID: "",
            source: ""
        )
        return AppSettings(
            productName: Self.normalizedDisplayName(
                defaults.string(forKey: Key.productName) ?? fallback.productName,
                fallback: fallback.productName
            ),
            assistantName: Self.normalizedDisplayName(
                defaults.string(forKey: Key.assistantName) ?? fallback.assistantName,
                fallback: fallback.assistantName
            ),
            userDisplayName: Self.normalizedDisplayName(
                defaults.string(forKey: Key.userDisplayName)
                    ?? fallback.userDisplayName,
                fallback: fallback.userDisplayName
            ),
            appDisplayLanguage: AppDisplayLanguage.parse(
                defaults.string(forKey: Key.appDisplayLanguage)
                    ?? fallback.appDisplayLanguage
            ).rawValue,
            appearanceMode: AppAppearanceMode.parse(
                defaults.string(forKey: Key.appearanceMode)
                    ?? fallback.appearanceMode
            ).rawValue,
            overlayAnchor: OverlayAnchor.parse(defaults.string(forKey: Key.overlayAnchor)),
            animateSurface: boolValue(forKey: Key.animateSurface, fallback: fallback.animateSurface),
            hoverStartsVoice: storedSchemaVersion >= 9
                ? boolValue(forKey: Key.hoverStartsVoice, fallback: fallback.hoverStartsVoice)
                : false,
            hoverStartDelay: Self.clampedHoverStartDelay(
                numberValue(forKey: Key.hoverStartDelay, fallback: fallback.hoverStartDelay)
            ),
            collapseDelay: Self.clampedCollapseDelay(
                numberValue(forKey: Key.collapseDelay, fallback: fallback.collapseDelay)
            ),
            wakePhraseEnabled: boolValue(forKey: Key.wakePhraseEnabled, fallback: fallback.wakePhraseEnabled),
            wakePhrases: Self.normalizedWakePhrases(
                defaults.stringArray(forKey: Key.wakePhrases) ?? fallback.wakePhrases
            ),
            showRecentHistory: boolValue(forKey: Key.showRecentHistory, fallback: fallback.showRecentHistory),
            recentTurnLimit: Self.clampedRecentTurnLimit(
                defaults.object(forKey: Key.recentTurnLimit) as? Int ?? fallback.recentTurnLimit
            ),
            autoSpeak: boolValue(forKey: Key.autoSpeak, fallback: fallback.autoSpeak),
            speechLocale: nonEmpty(defaults.string(forKey: Key.speechLocale)) ?? fallback.speechLocale,
            additionalSpeechLocales: Self.normalizedAdditionalSpeechLocales(
                defaults.stringArray(forKey: Key.additionalSpeechLocales)
                    ?? [defaults.string(forKey: Key.secondarySpeechLocale) ?? ""],
                primary: defaults.string(forKey: Key.speechLocale)
                    ?? fallback.speechLocale
            ),
            preferModernSpeechAnalyzer: boolValue(
                forKey: Key.preferModernSpeechAnalyzer,
                fallback: fallback.preferModernSpeechAnalyzer
            ),
            voiceIdleTimeoutMinutes: Self.clampedVoiceIdleTimeoutMinutes(
                defaults.object(forKey: Key.voiceIdleTimeoutMinutes) as? Int
                    ?? fallback.voiceIdleTimeoutMinutes
            ),
            returnGreetingEnabled: boolValue(
                forKey: Key.returnGreetingEnabled,
                fallback: fallback.returnGreetingEnabled
            ),
            returnGreetingMinutes: Self.clampedReturnGreetingMinutes(
                defaults.object(forKey: Key.returnGreetingMinutes) as? Int
                    ?? fallback.returnGreetingMinutes
            ),
            codexExecutablePath: Self.normalizedExecutablePath(
                defaults.string(forKey: Key.codexExecutablePath) ?? fallback.codexExecutablePath
            ),
            codexWorkspacePath: Self.normalizedLocalPath(
                defaults.string(forKey: Key.codexWorkspacePath) ?? fallback.codexWorkspacePath
            ),
            codexThreadID: binding.threadID,
            codexThreadSource: binding.source,
            codexThreadTitle: nonEmpty(defaults.string(forKey: Key.codexThreadTitle)) ?? "",
            codexModel: Self.normalizedCodexModel(
                defaults.string(forKey: Key.codexModel) ?? fallback.codexModel
            ),
            codexReasoningEffort: Self.normalizedCodexReasoningEffort(
                defaults.string(forKey: Key.codexReasoningEffort) ?? fallback.codexReasoningEffort
            ),
            codexFastMode: boolValue(
                forKey: Key.codexFastMode,
                fallback: fallback.codexFastMode
            ),
            codexSandbox: Self.normalizedCodexSandbox(
                defaults.string(forKey: Key.codexSandbox) ?? fallback.codexSandbox
            ),
            codexApprovalPolicy: Self.normalizedCodexApprovalPolicy(
                defaults.string(forKey: Key.codexApprovalPolicy) ?? fallback.codexApprovalPolicy
            ),
            includeAuthorityPack: boolValue(
                forKey: Key.includeAuthorityPack,
                fallback: fallback.includeAuthorityPack
            ),
            authorityPackRoot: Self.normalizedLocalPath(
                defaults.string(forKey: Key.authorityPackRoot)
                    ?? fallback.authorityPackRoot
            ),
            authorityPackFingerprint:
                defaults.string(forKey: Key.authorityPackFingerprint)
                    ?? fallback.authorityPackFingerprint,
            includeAdditionalContextProviders: boolValue(
                forKey: Key.includeAdditionalContextProviders,
                fallback: fallback.includeAdditionalContextProviders
            ),
            additionalContextProvidersRoot: Self.normalizedLocalPath(
                defaults.string(forKey: Key.additionalContextProvidersRoot)
                    ?? fallback.additionalContextProvidersRoot
            ),
            realtimeModel: Self.normalizedRealtimeModel(
                defaults.string(forKey: Key.realtimeModel) ?? fallback.realtimeModel
            ),
            realtimeVoice: Self.normalizedRealtimeVoice(
                defaults.string(forKey: Key.realtimeVoice) ?? fallback.realtimeVoice
            ),
            realtimeSpeechRate: Self.clampedRealtimeSpeechRate(
                defaults.object(forKey: Key.realtimeSpeechRate) == nil
                    ? fallback.realtimeSpeechRate
                    : defaults.double(forKey: Key.realtimeSpeechRate)
            ),
            realtimeReasoningEffort: Self.normalizedRealtimeReasoningEffort(
                defaults.string(forKey: Key.realtimeReasoningEffort)
                    ?? fallback.realtimeReasoningEffort
            ),
            realtimeInstructions: Self.normalizedRealtimeInstructions(
                realtimeInstructions
            )
        )
    }

    func save(
        _ settings: AppSettings,
        threadBindingIntent: ThreadBindingSaveIntent
    ) throws {
        let workspace = try Self.validatedCodexWorkspacePath(settings.codexWorkspacePath)
        let authorityPackRoot = Self.normalizedLocalPath(settings.authorityPackRoot)
        let authorityPackFingerprint = settings.includeAuthorityPack
            ? try AuthorityPackComposer.fingerprint(from: authorityPackRoot)
            : ""
        let requestedAdditionalContextProvidersRoot =
            Self.normalizedLocalPath(settings.additionalContextProvidersRoot)
        let additionalContextProvidersRoot =
            settings.includeAdditionalContextProviders
                ? try Self.validatedAdditionalContextProvidersRoot(
                    requestedAdditionalContextProvidersRoot
                )
                : requestedAdditionalContextProvidersRoot
        let authorityChanged =
            settings.includeAuthorityPack
                != boolValue(
                    forKey: Key.includeAuthorityPack,
                    fallback: false
                )
            || authorityPackRoot
                != Self.normalizedLocalPath(
                    defaults.string(forKey: Key.authorityPackRoot) ?? ""
                )
            || authorityPackFingerprint
                != (defaults.string(forKey: Key.authorityPackFingerprint) ?? "")
        let additionalContextProvidersChanged =
            settings.includeAdditionalContextProviders
                != boolValue(
                    forKey: Key.includeAdditionalContextProviders,
                    fallback: false
                )
            || additionalContextProvidersRoot
                != Self.normalizedLocalPath(
                    defaults.string(
                        forKey: Key.additionalContextProvidersRoot
                    ) ?? ""
                )

        let realtimeInstructions = settings.realtimeInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !realtimeInstructions.isEmpty,
              realtimeInstructions.utf8.count <= 16_000,
              !realtimeInstructions.contains("\0") else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Realtime prompt must be non-empty text no larger than 16 KB."
                ]
            )
        }

        if threadBindingIntent == .applyDraft {
            let rawThreadID = settings.codexThreadID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var threadID = Self.normalizedThreadID(settings.codexThreadID)
            guard rawThreadID.isEmpty || !threadID.isEmpty else {
                throw NSError(
                    domain: "VoiceRelay.Settings",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The Codex Session ID format is invalid"
                    ]
                )
            }
            var threadSource = threadID.isEmpty
                ? ""
                : Self.normalizedThreadSource(settings.codexThreadSource)
            guard threadID.isEmpty || !threadSource.isEmpty else {
                throw NSError(
                    domain: "VoiceRelay.Settings",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The Codex Session ID source is unavailable"
                    ]
                )
            }
            if (authorityChanged || additionalContextProvidersChanged),
               !threadID.isEmpty {
                if threadSource == "user" {
                    throw NSError(
                        domain: "VoiceRelay.Settings",
                        code: 7,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Authority Pack or Additional Context settings changed. Clear the existing Session ID and save to create a new dedicated session."
                        ]
                    )
                }
                threadID = ""
                threadSource = ""
            }
            try withThreadBindingLock {
                defaults.set(threadID, forKey: Key.codexThreadID)
                defaults.set(threadSource, forKey: Key.codexThreadSource)
                defaults.set(
                    threadSource == "app",
                    forKey: Key.codexThreadManaged
                )
                try persistThreadBindingUnlocked()
            }
        }

        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
        defaults.set(
            Self.normalizedDisplayName(
                settings.productName,
                fallback: AppSettings.defaults.productName
            ),
            forKey: Key.productName
        )
        defaults.set(
            Self.normalizedDisplayName(
                settings.assistantName,
                fallback: AppSettings.defaults.assistantName
            ),
            forKey: Key.assistantName
        )
        defaults.set(
            Self.normalizedDisplayName(
                settings.userDisplayName,
                fallback: AppSettings.defaults.userDisplayName
            ),
            forKey: Key.userDisplayName
        )
        defaults.set(
            AppDisplayLanguage.parse(settings.appDisplayLanguage).rawValue,
            forKey: Key.appDisplayLanguage
        )
        defaults.set(
            AppAppearanceMode.parse(settings.appearanceMode).rawValue,
            forKey: Key.appearanceMode
        )
        defaults.set(settings.overlayAnchor.rawValue, forKey: Key.overlayAnchor)
        defaults.set(settings.animateSurface, forKey: Key.animateSurface)
        defaults.set(settings.hoverStartsVoice, forKey: Key.hoverStartsVoice)
        defaults.set(Self.clampedHoverStartDelay(settings.hoverStartDelay), forKey: Key.hoverStartDelay)
        defaults.set(Self.clampedCollapseDelay(settings.collapseDelay), forKey: Key.collapseDelay)
        defaults.set(settings.wakePhraseEnabled, forKey: Key.wakePhraseEnabled)
        defaults.set(Self.normalizedWakePhrases(settings.wakePhrases), forKey: Key.wakePhrases)
        defaults.set(settings.showRecentHistory, forKey: Key.showRecentHistory)
        defaults.set(Self.clampedRecentTurnLimit(settings.recentTurnLimit), forKey: Key.recentTurnLimit)
        defaults.set(settings.autoSpeak, forKey: Key.autoSpeak)
        defaults.set(nonEmpty(settings.speechLocale) ?? AppSettings.defaults.speechLocale, forKey: Key.speechLocale)
        let additionalSpeechLocales = Self.normalizedAdditionalSpeechLocales(
            settings.additionalSpeechLocales,
            primary: settings.speechLocale
        )
        defaults.set(
            additionalSpeechLocales,
            forKey: Key.additionalSpeechLocales
        )
        defaults.set(
            additionalSpeechLocales.first ?? "",
            forKey: Key.secondarySpeechLocale
        )
        defaults.set(
            settings.preferModernSpeechAnalyzer,
            forKey: Key.preferModernSpeechAnalyzer
        )
        defaults.set(
            Self.clampedVoiceIdleTimeoutMinutes(settings.voiceIdleTimeoutMinutes),
            forKey: Key.voiceIdleTimeoutMinutes
        )
        defaults.set(settings.returnGreetingEnabled, forKey: Key.returnGreetingEnabled)
        defaults.set(
            Self.clampedReturnGreetingMinutes(settings.returnGreetingMinutes),
            forKey: Key.returnGreetingMinutes
        )
        defaults.set(Self.normalizedExecutablePath(settings.codexExecutablePath), forKey: Key.codexExecutablePath)
        defaults.set(workspace, forKey: Key.codexWorkspacePath)
        defaults.set(nonEmpty(settings.codexThreadTitle) ?? "", forKey: Key.codexThreadTitle)
        defaults.set(Self.normalizedCodexModel(settings.codexModel), forKey: Key.codexModel)
        defaults.set(
            Self.normalizedCodexReasoningEffort(settings.codexReasoningEffort),
            forKey: Key.codexReasoningEffort
        )
        defaults.set(settings.codexFastMode, forKey: Key.codexFastMode)
        defaults.set(Self.normalizedCodexSandbox(settings.codexSandbox), forKey: Key.codexSandbox)
        defaults.set(
            Self.normalizedCodexApprovalPolicy(settings.codexApprovalPolicy),
            forKey: Key.codexApprovalPolicy
        )
        defaults.set(settings.includeAuthorityPack, forKey: Key.includeAuthorityPack)
        defaults.set(authorityPackRoot, forKey: Key.authorityPackRoot)
        defaults.set(
            authorityPackFingerprint,
            forKey: Key.authorityPackFingerprint
        )
        defaults.set(
            settings.includeAdditionalContextProviders,
            forKey: Key.includeAdditionalContextProviders
        )
        defaults.set(
            additionalContextProvidersRoot,
            forKey: Key.additionalContextProvidersRoot
        )
        defaults.set(Self.normalizedRealtimeModel(settings.realtimeModel), forKey: Key.realtimeModel)
        defaults.set(Self.normalizedRealtimeVoice(settings.realtimeVoice), forKey: Key.realtimeVoice)
        defaults.set(
            Self.clampedRealtimeSpeechRate(settings.realtimeSpeechRate),
            forKey: Key.realtimeSpeechRate
        )
        defaults.set(
            Self.normalizedRealtimeReasoningEffort(settings.realtimeReasoningEffort),
            forKey: Key.realtimeReasoningEffort
        )
        defaults.set(
            Self.normalizedRealtimeInstructions(realtimeInstructions),
            forKey: Key.realtimeInstructions
        )

        NotificationCenter.default.post(name: Self.settingsDidChange, object: self)
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    var completedFirstVoiceGreeting: Bool {
        get {
            if defaults.object(forKey: Key.completedFirstVoiceGreeting) != nil {
                return defaults.bool(forKey: Key.completedFirstVoiceGreeting)
            }
            return onboardingCompleted
        }
        set { defaults.set(newValue, forKey: Key.completedFirstVoiceGreeting) }
    }

    var codexAppConnectionCompleted: Bool {
        get { defaults.bool(forKey: Key.codexAppConnectionCompleted) }
        set { defaults.set(newValue, forKey: Key.codexAppConnectionCompleted) }
    }

    func resetToDefaults() throws {
        var reset = AppSettings.defaults
        reset.includeAuthorityPack = false
        reset.authorityPackRoot = ""
        reset.authorityPackFingerprint = ""
        reset.includeAdditionalContextProviders = false
        reset.additionalContextProvidersRoot = ""
        reset.codexThreadID = ""
        reset.codexThreadSource = ""
        reset.codexThreadTitle = ""
        try save(
            reset,
            threadBindingIntent: .applyDraft
        )
        onboardingCompleted = false
        codexAppConnectionCompleted = false
        completedFirstVoiceGreeting = false
    }

    func setManagedCodexThreadID(_ rawThreadID: String) throws {
        let threadID = Self.normalizedThreadID(rawThreadID)
        try withThreadBindingLock {
            defaults.set(threadID, forKey: Key.codexThreadID)
            defaults.set(threadID.isEmpty ? "" : "app", forKey: Key.codexThreadSource)
            defaults.set(!threadID.isEmpty, forKey: Key.codexThreadManaged)
            try persistThreadBindingUnlocked()
        }
        NotificationCenter.default.post(name: Self.settingsDidChange, object: self)
    }

    private func readThreadBindingUnlocked(fallback: AppSettings) -> ThreadBinding {
        let source = Self.normalizedThreadSource(
            defaults.string(forKey: Key.codexThreadSource)
                ?? (defaults.bool(forKey: Key.codexThreadManaged) ? "app" : "")
        )
        let threadID = source.isEmpty
            ? ""
            : Self.normalizedThreadID(defaults.string(forKey: Key.codexThreadID) ?? "")
        return ThreadBinding(
            threadID: threadID,
            source: threadID.isEmpty ? "" : source
        )
    }

    private func persistThreadBindingUnlocked() throws {
        guard defaults.synchronize() else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The Codex task binding could not be verified after saving"]
            )
        }
    }

    private func withThreadBindingLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: threadBindingLockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = threadBindingLockURL.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The Codex task binding lock could not be opened"]
            )
        }
        defer { Darwin.close(descriptor) }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) != -1 else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The Codex task binding lock could not be acquired"]
            )
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        _ = defaults.synchronize()
        return try body()
    }

    static func detectCodexExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path,
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func isValidAuthorityPackRoot(_ rawPath: String) -> Bool {
        AuthorityPackComposer.isValidRoot(rawPath)
    }

    static func validatedAdditionalContextProvidersRoot(
        _ rawPath: String
    ) throws -> String {
        let normalized = normalizedLocalPath(rawPath)
        let canonical = URL(fileURLWithPath: normalized, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var isDirectory: ObjCBool = false
        guard !canonical.isEmpty,
              FileManager.default.fileExists(
                atPath: canonical,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Additional Context Providers folder is invalid"
                ]
            )
        }
        return canonical
    }

    private func migrateAuthorityFingerprintIfNeeded() {
        guard defaults.bool(forKey: Key.includeAuthorityPack),
              defaults.string(forKey: Key.authorityPackFingerprint) == nil else {
            return
        }
        let root = defaults.string(forKey: Key.authorityPackRoot) ?? ""
        guard let fingerprint = try? AuthorityPackComposer.fingerprint(from: root) else {
            return
        }
        defaults.set(fingerprint, forKey: Key.authorityPackFingerprint)
    }

    static func clampedRecentTurnLimit(_ value: Int) -> Int {
        min(max(value, 2), 12)
    }

    static func clampedHoverStartDelay(_ value: Double) -> Double {
        min(max(value, 0.0), 1.5)
    }

    static func clampedCollapseDelay(_ value: Double) -> Double {
        min(max(value, 0.0), 2.0)
    }

    static func clampedVoiceIdleTimeoutMinutes(_ value: Int) -> Int {
        min(max(value, 1), 60)
    }

    static func clampedReturnGreetingMinutes(_ value: Int) -> Int {
        min(max(value, 5), 180)
    }

    static func normalizedExecutablePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1024 else {
            return "codex"
        }
        return trimmed
    }

    static func normalizedLocalPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains("\0") else {
            return ""
        }
        return NSString(string: trimmed).expandingTildeInPath
    }

    static func validatedCodexWorkspacePath(_ value: String) throws -> String {
        let path = normalizedLocalPath(value)
        guard !path.isEmpty else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a Codex workspace"]
            )
        }
        guard NSString(string: path).isAbsolutePath else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Codex workspace must be an absolute path"]
            )
        }
        try validateDirectory(path: path, label: "Codex workspace")
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    static func normalizedThreadID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return ""
        }
        return trimmed
    }

    static func normalizedThreadSource(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["app", "user"].contains(normalized) ? normalized : ""
    }

    private static func validatedUUIDThreadID(_ value: String, label: String) throws -> String {
        let threadID = normalizedThreadID(value)
        guard !threadID.isEmpty, UUID(uuidString: threadID) != nil else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The \(label) Codex Session ID is invalid"]
            )
        }
        return threadID
    }

    static func normalizedCodexModel(_ value: String) -> String {
        normalizedIdentifier(value, fallback: "inherit")
    }

    static func normalizedCodexReasoningEffort(_ value: String) -> String {
        normalizedChoice(
            value,
            allowed: ["inherit", "low", "medium", "high", "xhigh", "max", "ultra"],
            fallback: "inherit"
        )
    }

    static func normalizedCodexSandbox(_ value: String) -> String {
        normalizedChoice(
            value,
            allowed: ["inherit", "read-only", "workspace-write", "danger-full-access"],
            fallback: "inherit"
        )
    }

    static func normalizedCodexApprovalPolicy(_ value: String) -> String {
        normalizedChoice(
            value,
            allowed: ["inherit", "untrusted", "on-request", "never"],
            fallback: "inherit"
        )
    }

    static func normalizedRealtimeModel(_ value: String) -> String {
        normalizedIdentifier(value, fallback: AppSettings.defaults.realtimeModel)
    }

    static func normalizedRealtimeVoice(_ value: String) -> String {
        normalizedChoice(
            value,
            allowed: Set(supportedRealtimeVoices),
            fallback: AppSettings.defaults.realtimeVoice
        )
    }

    static func clampedRealtimeSpeechRate(_ value: Double) -> Double {
        guard value.isFinite else {
            return AppSettings.defaults.realtimeSpeechRate
        }
        return min(1.5, max(0.25, value))
    }

    static func normalizedRealtimeReasoningEffort(_ value: String) -> String {
        normalizedChoice(
            value,
            allowed: ["low", "medium", "high", "xhigh"],
            fallback: AppSettings.defaults.realtimeReasoningEffort
        )
    }

    static func normalizedWakePhrases(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in values {
            let phrase = rawValue
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !phrase.isEmpty, phrase.count <= 32 else { continue }
            let key = phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            result.append(phrase)
            if result.count == 8 { break }
        }
        return result.isEmpty ? defaultWakePhrases : result
    }

    static func normalizedDisplayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 48,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return fallback
        }
        return trimmed
    }

    static func normalizedSecondarySpeechLocale(
        _ value: String,
        primary: String
    ) -> String {
        normalizedAdditionalSpeechLocales([value], primary: primary).first ?? ""
    }

    static func normalizedAdditionalSpeechLocales(
        _ values: [String],
        primary: String
    ) -> [String] {
        let normalizedPrimary = normalizedIdentifier(primary, fallback: "")
            .lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = normalizedIdentifier(
                value.trimmingCharacters(in: .whitespacesAndNewlines),
                fallback: ""
            )
            let key = normalized.lowercased()
            guard !normalized.isEmpty,
                  key != "none",
                  key != "system",
                  key != normalizedPrimary,
                  seen.insert(key).inserted else {
                continue
            }
            result.append(normalized)
            if result.count == 3 { break }
        }
        return result
    }

    static func normalizedRealtimeInstructions(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 16_000,
              !trimmed.contains("\0") else {
            return defaultRealtimeInstructions
        }
        return trimmed
    }

    static func realtimeInstructionsFingerprint(_ value: String) -> UInt64 {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .utf8
            .reduce(UInt64(0xcbf29ce484222325)) { fingerprint, byte in
                (fingerprint ^ UInt64(byte))
                    &* UInt64(0x100000001b3)
            }
    }

    static func isLegacyDefaultRealtimeInstructions(_ value: String) -> Bool {
        isLegacyDefaultRealtimeInstructionsFingerprint(
            realtimeInstructionsFingerprint(value)
        )
    }

    static func isLegacyDefaultRealtimeInstructionsFingerprint(
        _ fingerprint: UInt64
    ) -> Bool {
        legacyDefaultRealtimeInstructionFingerprints.contains(fingerprint)
    }

    private static func validateDirectory(path: String, label: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "VoiceRelay.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The \(label) folder could not be found"]
            )
        }
    }

    private func boolValue(forKey key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private func numberValue(forKey key: String, fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedIdentifier(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 160,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || CharacterSet(charactersIn: "._-/").contains(scalar)
              }) else {
            return fallback
        }
        return trimmed
    }

    private static func normalizedChoice(
        _ value: String,
        allowed: Set<String>,
        fallback: String
    ) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(normalized) ? normalized : fallback
    }

}
