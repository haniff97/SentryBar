import SwiftUI
import ServiceManagement

enum MenuBarContent: String, CaseIterable, Identifiable {
    case iconOnly = "Icon only"
    case cpuUsage = "CPU usage"
    case cpuTemp = "CPU temperature"
    case cpuUsageTemp = "CPU usage + temperature"
    case cpuTempFan = "CPU temp + fan"

    var id: String { rawValue }
}

/// App-wide settings, persisted to UserDefaults via @AppStorage.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("pollInterval") var pollInterval: Double = 2.0
    @AppStorage("menuBarContent") var menuBarContent: MenuBarContent = .cpuUsage
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }
    @AppStorage("autoUnlockSeconds") var autoUnlockSeconds: Double = 0
    @AppStorage("escapeComboEnabled") var escapeComboEnabled: Bool = true

    @Published private(set) var launchAtLoginStatus: Bool = false
    @Published private(set) var launchAtLoginError: String?

    /// Reflect the real macOS login-item state (may differ from the toggle).
    func refreshLaunchStatus() {
        guard #available(macOS 13, *) else { return }
        launchAtLoginStatus = SMAppService.mainApp.status == .enabled
    }

    /// SMAppService only works from a bundled .app in /Applications.
    private func updateLaunchAtLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = friendlyLaunchError(error)
        }
        refreshLaunchStatus()
    }

    private func friendlyLaunchError(_ error: Error) -> String {
        let inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
        if !inApplications {
            return "Move SentryBar to /Applications first, then turn this on."
        }
        return "Could not change launch-at-login: \(error.localizedDescription)"
    }
}
