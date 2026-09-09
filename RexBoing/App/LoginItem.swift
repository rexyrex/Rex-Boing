import Foundation
import ServiceManagement
import os

/// Launch-at-login, via the modern `SMAppService` registration.
enum LoginItem {
    private static let log = Logger(subsystem: "com.rexyrex.Zoomies", category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registered, but switched off by the user in System Settings — the one
    /// state the app cannot leave on its own. The toggle in Settings would
    /// otherwise just snap back off with no explanation.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Applies the requested state and returns the effective state. Registration
    /// can fail or require approval, and the preference UI must not claim the
    /// item is enabled when ServiceManagement says otherwise.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    // Registered, but the user switched it off in System
                    // Settings. Registering again throws; the only place the
                    // state can change is System Settings, so go there.
                    SMAppService.openSystemSettingsLoginItems()
                default:
                    // Re-registering an already-registered service throws, so
                    // only act when the current state actually differs.
                    try SMAppService.mainApp.register()
                }
            } else {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    try SMAppService.mainApp.unregister()
                default:
                    break
                }
            }
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
