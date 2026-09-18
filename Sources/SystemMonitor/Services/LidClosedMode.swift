import Foundation
import Combine
import AppKit

/// Keep-Awake sessions. The mechanism is `pmset disablesleep` (so the Mac keeps
/// running with the lid shut), optionally ended by a timer or a condition.
///
/// Setting it requires root; the app routes through the privileged helper
/// (no password once it's running), falling back to an admin prompt.
enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case indefinite = "Indefinitely"
    case minutes30 = "30 minutes"
    case hour1 = "1 hour"
    case hours2 = "2 hours"
    case whileCharging = "While charging"
    case untilBattery = "Until 80% battery"

    var id: String { rawValue }

    var duration: TimeInterval? {
        switch self {
        case .minutes30: return 30 * 60
        case .hour1: return 60 * 60
        case .hours2: return 2 * 60 * 60
        default: return nil
        }
    }
}

final class LidClosedMode: ObservableObject {
    static let shared = LidClosedMode()

    @Published private(set) var enabled: Bool = false
    @Published var mode: KeepAwakeMode = .indefinite {
        didSet { restartMonitorIfNeeded() }
    }
    @Published private(set) var statusText: String?
    @Published var lastError: String?

    private var endDate: Date?
    private var timer: Timer?

    private init() {}

    func refresh() {
        enabled = Self.readDisablesleep()
        if !enabled { statusText = nil }
    }

    func setEnabled(_ on: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Prefer the root helper: once it's running, toggling needs no password.
            if FanRootBridge.shared.setLidSleepDisabled(on) {
                DispatchQueue.main.async { self.finishSet(on, error: nil) }
                return
            }
            let script = "do shell script \"pmset disablesleep \(on ? 1 : 0)\" with administrator privileges"
            self.runAdminScript(script) { ok, error in
                DispatchQueue.main.async {
                    self.finishSet(on, error: ok ? nil : Self.friendlyError(error))
                }
            }
        }
    }

    private func finishSet(_ on: Bool, error: String?) {
        lastError = error
        enabled = error == nil ? Self.readDisablesleep() : false
        if enabled { startMonitor() } else { stopMonitor() }
    }

    // MARK: - Session monitor

    private func restartMonitorIfNeeded() {
        guard enabled else { return }
        startMonitor()
    }

    private func startMonitor() {
        stopMonitor()
        endDate = mode.duration.map { Date().addingTimeInterval($0) }
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func stopMonitor() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        statusText = nil
    }

    private func evaluate() {
        guard enabled else { return }
        switch mode {
        case .indefinite:
            statusText = nil
        case .minutes30, .hour1, .hours2:
            guard let endDate else { return }
            let remaining = endDate.timeIntervalSinceNow
            if remaining <= 0 {
                setEnabled(false)
            } else {
                statusText = "Ends in \(Self.format(remaining))"
            }
        case .whileCharging:
            if BatteryInfo.snapshot().externalPower != true {
                setEnabled(false)
            } else {
                statusText = "Stops when unplugged"
            }
        case .untilBattery:
            if let percent = BatteryInfo.snapshot().percent, percent >= 80 {
                setEnabled(false)
            } else {
                statusText = "Stops at 80%"
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    // MARK: - Internals

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
