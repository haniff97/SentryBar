import Foundation

/// The running app's version (from the bundle's Info.plist).
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var display: String { "v\(short)" }

    /// True if semantic version `a` is newer than `b` (e.g. "1.1" > "1.0.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// One entry in the in-app version history shown in Settings.
struct ReleaseNote: Identifiable {
    let version: String
    let date: String
    let highlights: [String]
    var id: String { version }
}

/// Version history. Add new releases at the TOP (newest first).
/// This is the "list v1, v1.1, v2" the Settings screen renders.
enum Changelog {
    static let releases: [ReleaseNote] = [
        ReleaseNote(version: "1.0", date: "Sep 2026", highlights: [
            "System monitoring: CPU, GPU, RAM, battery, fan RPM",
            "Display brightness (hardware for Apple, software overlay for others), remembered per display",
            "Fan control: Manual/Auto, link fans (privileged helper)",
            "Lid Closed Mode — keep running with the lid shut",
            "Keyboard Lock — block all keys while cleaning",
            "Launch at login, menu-bar content options"
        ])
        // Add future releases here, newest first, e.g.:
        // ReleaseNote(version: "1.1", date: "Oct 2026", highlights: ["..."]),
        // ReleaseNote(version: "2.0", date: "Dec 2026", highlights: ["..."]),
    ]
}
