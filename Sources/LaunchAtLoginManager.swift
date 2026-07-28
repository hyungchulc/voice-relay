import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }

    var canChangeRegistration: Bool {
        self != .notFound
    }
}

protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class LaunchAtLoginManager {
    private let service: LaunchAtLoginServicing

    init(service: LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        service.status
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        let current = service.status
        guard current.canChangeRegistration else { return current }

        if enabled {
            if current == .notRegistered {
                try service.register()
            }
        } else if current.isRegistered {
            try service.unregister()
        }
        return service.status
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }
}
