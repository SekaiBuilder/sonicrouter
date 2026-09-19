import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so Settings can offer "Launch at login". Only
/// meaningful when running as a bundled .app: `swift run` has no bundle to
/// register, so the toggle is disabled there.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS put the item on hold until the user approves it in System Settings.
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    init() {
        refresh()
    }

    /// Re-reads the system state; the user may have changed it in System
    /// Settings → Login Items while the app was running.
    func refresh() {
        guard isAvailable else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
