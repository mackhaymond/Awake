import Foundation
import ServiceManagement
import AppKit

/// Launch-at-login via `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItem {

    private(set) var isEnabled: Bool = false

    /// True when registration succeeded but macOS still needs the user to approve
    /// the login item in Settings (status == .requiresApproval). The toggle then
    /// looks "on" but is inert until approved.
    private(set) var needsApproval: Bool = false

    /// Drives the toggle's visual on/off state: a successful registration that is
    /// still pending the user's approval (.requiresApproval) is "on" — the app
    /// WILL launch at login once approved — so the toggle must not snap back off.
    var isOnOrPending: Bool { isEnabled || needsApproval }

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// Register or unregister the login item. On failure (e.g. requires
    /// approval), deep-links the user to the Login Items settings pane.
    func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // Unregister whenever the service still exists. register() commonly
                // leaves the status in .requiresApproval (pending the user's
                // approval), which is a real, removable registration — guarding on
                // == .enabled would skip it and leave a phantom login item that
                // still launches the app at next login. unregister() is valid for
                // .requiresApproval too.
                let status = SMAppService.mainApp.status
                if status != .notRegistered && status != .notFound {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            openSystemSettingsLoginItems()
        }
        refresh()
    }

    func openSystemSettingsLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
