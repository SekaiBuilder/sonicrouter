import AppKit
import SwiftUI

/// Keeps SonicRouter alive when the main window closes: the app leaves the
/// Dock (accessory mode) but stays fully usable from the menu bar item in the
/// top-right of the screen. Reopening the window restores the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let closing = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard Self.isMainWindow(closing) else { return }
                let mainStillVisible = NSApp.windows.contains { window in
                    window !== closing && Self.isMainWindow(window) && window.isVisible
                }
                if !mainStillVisible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    /// SwiftUI names the `Window(id: "main")` scene's windows "main-AppWindow-…",
    /// which distinguishes them from Settings and the menu bar panel.
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// Restores the Dock icon and brings the app forward. Call before opening
    /// the main window from the menu bar panel.
    static func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SonicRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audioStore = AudioDeviceStore()
    @StateObject private var appStore = ApplicationAudioStore()

    var body: some Scene {
        Window("SonicRouter", id: "main") {
            ContentView()
                .environmentObject(audioStore)
                .environmentObject(appStore)
                .tint(Theme.accent)
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    audioStore.refresh()
                    appStore.refresh()
                    appStore.checkPermission()
                }
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)

        MenuBarExtra("SonicRouter", systemImage: "slider.vertical.3") {
            MenuBarView()
                .environmentObject(audioStore)
                .environmentObject(appStore)
                .tint(Theme.accent)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(audioStore)
                .environmentObject(appStore)
                .tint(Theme.accent)
                .frame(width: 480)
        }
    }
}
