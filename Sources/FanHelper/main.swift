import Foundation
import IOKit
import Darwin

// FanHelper — a root-privileged SMC fan controller.
//
// The app launches this binary with admin privileges (via osascript) once;
// it stays alive and serves simple text commands over a unix socket:
//
//   ping              -> "ok"
//   force <id>        -> "ok" | "err"
//   auto  <id>        -> "ok" | "err"
//   target <id> <rpm> -> "ok" | "err"
//   reset             -> "ok" | "err"
//
// Root is required because user-space SMC writes return kIOReturnNotPrivileged.

let socketPath = "/tmp/com.systemmonitor.fanhelper.sock"

// MARK: - SMC wire format (read + write)

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyDataVers {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == kIOReturnSuccess else { return nil }
        conn = c
    }

    deinit { IOServiceClose(conn) }

    private static func keyValue(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func typeName(_ raw: UInt32) -> String {
        String(bytes: [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                       UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)], encoding: .ascii) ?? ""
    }

    func readKey(_ key: String) -> (type: String, data: Data)? {
        var info = SMCKeyData()
        info.key = Self.keyValue(key)
        info.data8 = 9
        var outSize = MemoryLayout<SMCKeyData>.stride
        var out = SMCKeyData()
        guard IOConnectCallStructMethod(conn, 2, &info, MemoryLayout<SMCKeyData>.stride, &out, &outSize) == kIOReturnSuccess else { return nil }
        let size = Int(out.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        let type = Self.typeName(out.keyInfo.dataType)

        var val = SMCKeyData()
        val.key = Self.keyValue(key)
        val.data8 = 5
        val.keyInfo.dataSize = out.keyInfo.dataSize
        outSize = MemoryLayout<SMCKeyData>.stride
        guard IOConnectCallStructMethod(conn, 2, &val, MemoryLayout<SMCKeyData>.stride, &out, &outSize) == kIOReturnSuccess else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Data($0) }
        return (type, bytes.prefix(size))
    }

    func writeKey(_ key: String, data: Data) -> Bool {
        var input = SMCKeyData()
        input.key = Self.keyValue(key)
        input.data8 = 6
        input.keyInfo.dataSize = UInt32(data.count)
        var tuple = input.bytes
        data.withUnsafeBytes { src in
            withUnsafeMutableBytes(of: &tuple) { dst in
                if let s = src.baseAddress, let d = dst.baseAddress {
                    memcpy(d, s, min(data.count, 32))
                }
            }
        }
        input.bytes = tuple
        var out = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &out, &outSize)
        return result == kIOReturnSuccess && out.result == 0x00
    }
}

// MARK: - Fan control logic (runs as root)

final class FanControl {
    private let smc: SMC
    private var modeKeyIsLower: Bool?

    init(_ smc: SMC) { self.smc = smc }

    func fanCount() -> Int {
        guard let (_, data) = smc.readKey("FNum"), let b = data.first else { return 0 }
        return min(Int(b), 8)
    }

    private func modeKey(_ id: Int) -> String {
        if modeKeyIsLower == nil {
            modeKeyIsLower = smc.readKey("F0md") != nil
        }
        return modeKeyIsLower == true ? "F\(id)md" : "F\(id)Md"
    }

    private func readByte(_ key: String) -> UInt8? {
        guard let (_, data) = smc.readKey(key), let b = data.first else { return nil }
        return b
    }

    private func writeWithRetry(_ key: String, _ data: Data, attempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
        for attempt in 0..<attempts {
            if smc.writeKey(key, data: data) { return true }
            if attempt < attempts - 1 { usleep(delayMicros) }
        }
        return false
    }

    private func retryModeWrite(fan id: Int, attempts: Int) -> Bool {
        guard readByte(modeKey(id)) != nil else { return false }
        return writeWithRetry(modeKey(id), Data([1]), attempts: attempts, delayMicros: 100_000)
    }

    private func unlockFanControl(fan id: Int) -> Bool {
        if readByte(modeKey(id)) != nil {
            if writeWithRetry(modeKey(id), Data([1])) { return true }
        }
        guard let ftst = readByte("Ftst") else { return false }
        if ftst == 1 { return retryModeWrite(fan: id, attempts: 20) }
        if !writeWithRetry("Ftst", Data([1]), attempts: 100) { return false }
        usleep(3_000_000)
        return retryModeWrite(fan: id, attempts: 300)
    }

    func force(_ id: Int) -> Bool {
        guard let byte = readByte(modeKey(id)) else { return false }
        if byte == 1 { return true }
        if writeWithRetry(modeKey(id), Data([1])) { return true }
        return unlockFanControl(fan: id)
    }

    func auto(_ id: Int) -> Bool {
        if let byte = readByte(modeKey(id)), byte != 0 {
            if !writeWithRetry(modeKey(id), Data([0])) { return false }
        }
        if let (type, _) = smc.readKey("F\(id)Tg") {
            let data = type == "flt " ? floatLE(0) : Data([0, 0, 0, 0])
            _ = writeWithRetry("F\(id)Tg", data)
        }
        return true
    }

    func target(_ id: Int, rpm: Int) -> Bool {
        if let byte = readByte(modeKey(id)), byte != 1 {
            if !force(id) { return false }
        }
        guard let (type, _) = smc.readKey("F\(id)Tg") else { return false }
        let speed = max(0, min(rpm, 30_000))
        let data: Data
        if type == "flt " {
            data = floatLE(Float(speed))
        } else {
            data = Data([UInt8(speed >> 6), UInt8((speed << 2) ^ ((speed >> 6) << 8)), 0, 0])
        }
        return writeWithRetry("F\(id)Tg", data)
    }

    func reset() -> Bool {
        var ok = true
        if let ftst = readByte("Ftst"), ftst != 0 {
            if !writeWithRetry("Ftst", Data([0])) { ok = false }
        }
        for i in 0..<fanCount() {
            if !auto(i) { ok = false }
        }
        return ok
    }
}

private func floatLE(_ value: Float) -> Data {
    let raw = value.bitPattern.littleEndian
    return Data([UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                 UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF)])
}

// MARK: - Unix socket server

func makeSockaddr(_ path: String) -> sockaddr_un {
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

func sendReply(_ fd: Int32, _ text: String) {
    let data = text + "\n"
    _ = data.withCString { write(fd, $0, strlen($0)) }
}

func setLidSleepDisabled(_ on: Bool) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["disablesleep", on ? "1" : "0"]
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func handleCommand(_ line: String, fan: FanControl) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first else { return "err" }
    switch cmd {
    case "ping":
        return "ok"
    case "force":
        guard parts.count > 1, let id = Int(parts[1]) else { return "err" }
        return fan.force(id) ? "ok" : "err"
    case "auto":
        guard parts.count > 1, let id = Int(parts[1]) else { return "err" }
        return fan.auto(id) ? "ok" : "err"
    case "target":
        guard parts.count > 2, let id = Int(parts[1]), let rpm = Int(parts[2]) else { return "err" }
        return fan.target(id, rpm: rpm) ? "ok" : "err"
    case "reset":
        return fan.reset() ? "ok" : "err"
    case "lidson":
        return setLidSleepDisabled(true) ? "ok" : "err"
    case "lidsoff":
        return setLidSleepDisabled(false) ? "ok" : "err"
    case "quit":
        return "ok"
    default:
        return "err"
    }
}

guard let smc = SMC() else {
    FileHandle.standardError.write("FanHelper: cannot open AppleSMC\n".data(using: .utf8)!)
    exit(1)
}
let fan = FanControl(smc)

if CommandLine.arguments.contains("--once") {
    // One-shot mode used for testing: args after --once.
    let args = CommandLine.arguments.drop(while: { $0 != "--once" }).dropFirst()
    let line = args.joined(separator: " ")
    print(handleCommand(line, fan: fan))
    exit(0)
}

// Socket server mode.
unlink(socketPath)
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var addr = makeSockaddr(socketPath)
let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    FileHandle.standardError.write("FanHelper: bind failed\n".data(using: .utf8)!)
    exit(1)
}
guard listen(fd, 4) == 0 else { exit(1) }
chmod(socketPath, 0o666)

var idleMs: Int32 = 43_200_000 // 12h — stay alive so repeat writes need no password

while true {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, idleMs)
    if ready == 0 {
        break // idle for 300s, exit
    }
    if ready < 0 { break }

    let client = accept(fd, nil, nil)
    guard client >= 0 else { continue }
    // The app writes one newline-delimited command and then waits for a reply.
    // Reply as soon as that command arrives.  Waiting for EOF here creates a
    // deadlock: the client cannot close until it has received our response.
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(client, &buf, buf.count)
    var shouldQuit = false
    if n > 0 {
        let request = String(decoding: buf[0..<n], as: UTF8.self)
        if let newline = request.firstIndex(of: "\n") {
            let line = String(request[..<newline])
            sendReply(client, handleCommand(line, fan: fan))
            shouldQuit = line == "quit"
        } else {
            sendReply(client, "err")
        }
    }
    close(client)
    if shouldQuit { break }
}

close(fd)
unlink(socketPath)
