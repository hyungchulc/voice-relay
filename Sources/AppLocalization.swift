import Foundation

enum AppAppearanceMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    static func parse(_ value: String?) -> AppAppearanceMode {
        AppAppearanceMode(
            rawValue: value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        ) ?? .system
    }

    func resolvesDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system:
            return systemIsDark
        case .light:
            return false
        case .dark:
            return true
        }
    }
}

enum AppDisplayLanguage: String, CaseIterable, Equatable {
    case system
    case english = "en"
    case korean = "ko"

    static func parse(_ value: String?) -> AppDisplayLanguage {
        AppDisplayLanguage(
            rawValue: value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        ) ?? .system
    }

    func resolved(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppDisplayLanguage {
        switch self {
        case .english, .korean:
            return self
        case .system:
            let language = preferredLanguages.first?
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased()
            return language == "ko" ? .korean : .english
        }
    }
}

struct AppCopy {
    let language: AppDisplayLanguage

    init(
        preference: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        language = AppDisplayLanguage.parse(preference)
            .resolved(preferredLanguages: preferredLanguages)
    }

    var isKorean: Bool { language == .korean }

    func text(_ english: String, _ korean: String) -> String {
        isKorean ? korean : english
    }
}

enum ManualPairingCode {
    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.range(
            of: #"^[A-Za-z0-9]{4}-?[A-Za-z0-9]{4}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let compact = trimmed
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        let separator = compact.index(compact.startIndex, offsetBy: 4)
        return "\(compact[..<separator])-\(compact[separator...])"
    }
}
