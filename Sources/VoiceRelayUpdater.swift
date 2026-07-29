import Cocoa
import Sparkle

struct VoiceRelayReleaseIdentity {
    let shortVersion: String
    let build: String
    let releaseTag: String
    let channel: String

    init(bundle: Bundle = .main) {
        shortVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0.0.0"
        build =
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "0"
        releaseTag =
            bundle.object(forInfoDictionaryKey: "VoiceRelayReleaseTag")
                as? String ?? ""
        channel =
            bundle.object(forInfoDictionaryKey: "VoiceRelayDistributionChannel")
                as? String ?? "development"
    }

    var displayVersion: String {
        if releaseTag.hasPrefix("v") {
            return String(releaseTag.dropFirst())
        }
        return releaseTag.isEmpty ? shortVersion : releaseTag
    }

    var canCheckForUpdates: Bool {
        !releaseTag.isEmpty
    }
}

@MainActor
final class VoiceRelayUpdateController {
    static let shared = VoiceRelayUpdateController()

    private let standardController: SPUStandardUpdaterController

    private init() {
        standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        standardController.updater.automaticallyChecksForUpdates = false
        standardController.updater.automaticallyDownloadsUpdates = false
    }

    func checkForUpdates(_ sender: Any?) {
        standardController.checkForUpdates(sender)
    }
}
