import Foundation

/// Bridges fan-control writes to the root-privileged `FanHelper` process.
///
/// The helper is launched once via osascript (`do shell script ... with
/// administrator privileges`), which shows the macOS password prompt. It then
/// stays alive serving commands over a unix socket, so slider changes need no
/// further prompts.
final class FanRootBridge {
    static let shared = FanRootBridge()

    private let socketPath = "/tmp/com.systemmonitor.fanhelper.sock"
    private var launching = false

    private init() {}

    // MARK: - High-level commands

    func isRunning() -> Bool {
        send("ping") != nil
    }

    @discardableResult
    func ensureRunning() -> Bool {
        if isRunning() { return true }
        if launching {
            for _ in 0..<100 where !isRunning() { usleep(100_000) }
            return isRunning()
        }
        launching = true
        defer { launching = false }

        guard let helperPath = helperBinaryPath() else { return false }
        // `do shell script` receives a shell command, not an executable path.
        // Quote the path so bundles stored in folders such as "Default Project"
        // launch correctly instead of being split at the space.
        let command = shellQuoted(helperPath.path)
        let script = "do shell script \"\(command)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            NSLog("FanRootBridge: could not launch helper: \(error)")
            return false
        }

        // Wait for the socket; the user may need time to enter their password.
        for _ in 0..<120 {
            usleep(250_000)
            if isRunning() { return true }
        }
        return false
    }

    func force(_ id: Int) -> Bool {
        guard ensureRunning() else { return false }
        return send("force \(id)") == "ok"
    }

    func auto(_ id: Int) -> Bool {
        guard ensureRunning() else { return false }
        return send("auto \(id)") == "ok"
    }

    func target(_ id: Int, rpm: Int) -> Bool {
        guard ensureRunning() else { return false }
        return send("target \(id) \(rpm)") == "ok"
    }

    func reset() -> Bool {
        guard ensureRunning() else { return false }
        return send("reset") == "ok"
    }

    /// Toggle `pmset disablesleep` via the root helper. No password once the
    /// helper is running (only the initial launch prompts).
    func setLidSleepDisabled(_ on: Bool) -> Bool {
        guard ensureRunning() else { return false }
        return send(on ? "lidson" : "lidsoff") == "ok"
    }

    // MARK: - Socket I/O

    private func helperBinaryPath() -> URL? {
        let args = CommandLine.arguments
        let processDir = args.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        var candidates: [URL] = []
        if let dir = processDir {
            candidates.append(dir.appendingPathComponent("FanHelper"))
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("FanHelper"))
        }
        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func send(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = makeSockaddr(socketPath)
        var connected = false
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connected = connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return nil }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let data = (command + "\n").data(using: .utf8) ?? Data()
        data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSockaddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let len = min(bytes.count, 104)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: len) { dst in
                dst.update(from: bytes, count: len)
            }
        }
        return addr
    }
}
