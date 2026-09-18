import Foundation
import Combine
import AppKit

/// "Run with lid closed" — toggles `pmset disablesleep` so the MacBook keeps
/// running tasks when the display lid is closed.
///
/// Setting it requires admin rights (one password prompt per toggle, via
/// osascript). Reading the current state needs no privileges.
final class LidClosedMode: ObservableObject {
    static let shared = LidClosedMode()

    @Published private(set) var enabled: Bool = false
    @Published var lastError: String?

    private init() {}

    func refresh() {
        enabled = Self.readDisablesleep()
    }

    func setEnabled(_ on: Bool) {
        let script = "do shell script \"pmset disablesleep \(on ? 1 : 0)\" with administrator privileges"
        runAdminScript(script) { [weak self] ok, error in
            DispatchQueue.main.async {
                if ok {
                    self?.lastError = nil
                    self?.enabled = Self.readDisablesleep()
                } else {
                    self?.lastError = Self.friendlyError(error)
                }
            }
        }
    }

    private static func friendlyError(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return "Could not change the setting. Toggle again and approve the admin prompt."
        }
        let lower = raw.lowercased()
        if lower.contains("user cancelled") || lower.contains("-128") {
            return "Admin authorization was cancelled. Toggle again and enter your password to allow it."
        }
        if lower.contains("not authorized") || lower.contains("-60007") {
            return "Not authorized. Approve the admin prompt to change this setting."
        }
        return raw
    }

    // MARK: - Internals

    private static func readDisablesleep() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        // `pmset -g` reports the live value as `SleepDisabled <0|1>`;
        // `pmset -g custom` does NOT include it, so don't use that.
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard let range = output.range(of: #"SleepDisabled\s+(\d)"#, options: .regularExpression) else {
            return false
        }
        // pmset separates fields with tabs, so split on any whitespace.
        let value = output[range]
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .last ?? "0"
        return value == "1"
    }

    private func runAdminScript(_ script: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    completion(true, nil)
                } else {
                    completion(false, err?.isEmpty == false ? err : nil)
                }
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }
}
