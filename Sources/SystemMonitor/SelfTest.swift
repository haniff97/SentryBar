import Foundation
import AppKit

/// CLI self-test: sample every reader once and print results, then exit.
/// Run with: `swift run SystemMonitor --test`
func runSelfTest() {
    let machine = SystemInfo()
    print("Machine : \(machine.model) — \(machine.cores) cores, \(machine.memoryGB) GB")
    print()

    let cpu = CPUUsage()
    _ = cpu.sample()
    Thread.sleep(forTimeInterval: 1.0)
    if let c = cpu.sample() {
        print(String(format: "CPU     overall: %.1f%%", c.overall * 100))
        let cores = c.perCore.enumerated()
            .map { String(format: "  c%d: %.0f%%", $0.offset, $0.element * 100) }
            .joined()
        print("CPU     per-core:\(cores)")
    } else {
        print("CPU     unavailable")
    }

    if let m = MemoryInfo.usage() {
        print(String(format: "MEM     %.2f / %.2f GB  (%.0f%%)",
                     m.usedGB, m.totalGB, m.usedFraction * 100))
    } else {
        print("MEM     unavailable")
    }

    let b = BatteryInfo.snapshot()
    print("BAT     \(b.percent.map { "\($0)%" } ?? "n/a")"
        + " | charging=\(b.isCharging.map(String.init) ?? "n/a")"
        + " | ac=\(b.externalPower.map(String.init) ?? "n/a")"
        + " | health=\(b.health.map { "\($0)%" } ?? "n/a")"
        + " | cycles=\(b.cycleCount.map(String.init) ?? "n/a")"
        + " | temp=\(b.temperature.map { String(format: "%.0f°C", $0) } ?? "n/a")")

    SMCHelper.debug = CommandLine.arguments.contains("--debug-smc")
    if let smc = SMCHelper() {
        if CommandLine.arguments.contains("--debug-smc") {
            print("SMC     --- raw probe ---")
            for key in ["FNum", "F0Ac", "F1Ac", "Tp09", "Tp0a", "Tp0b", "Tp0c", "Tp0d", "Tf09", "Tf0a", "Tf0b", "Tf0c", "Tg05", "Tg0c", "Tg0f"] {
                if let (type, data) = smc.readKey(key) {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    print("SMC     \(key): type=\(type) size=\(data.count) hex=\(hex)")
                } else {
                    print("SMC     \(key): nil")
                }
            }
        }
        let count = smc.fanCount()
        let speeds = smc.fanSpeeds()
            .map { String(format: "%.0f rpm", $0) }
            .joined(separator: ", ")
        print("SMC     fans=\(count) [\(speeds.isEmpty ? "none" : speeds)]")
        if let t = smc.cpuTemperature() {
            print(String(format: "SMC     cpuTemp: %.1f°C", t))
        } else {
            print("SMC     cpuTemp: unavailable")
        }
        if let t = smc.gpuTemperature() {
            print(String(format: "SMC     gpuTemp: %.1f°C", t))
        } else {
            print("SMC     gpuTemp: unavailable")
        }
    } else {
        print("SMC     unavailable (not an AppleSMC machine?)")
    }

    print()
    print("FAN CONTROL")
    if let smc = SMCHelper() {
        let fc = FanController(smc: smc)
        let count = fc.fanCount()
        print("  fans=\(count)")
        if count > 0 {
            for i in 0..<count {
                let actual = fc.actualRPM(i).map { String(format: "%.0f", $0) } ?? "n/a"
                let max = fc.maxRPM(i).map { String(format: "%.0f", $0) } ?? "n/a"
                let mode = fc.mode(i).map { "\($0)" } ?? "n/a"
                print("  fan\(i): actual=\(actual) rpm, max=\(max), mode=\(mode) (0=auto 1=forced)")
            }
            // Key availability probe (read-only)
            for key in ["F0md", "F0Md", "Ftst", "F0Tg"] {
                let present = smc.readKey(key) != nil
                print("  key \(key): \(present ? "present" : "absent")")
            }
        }
    } else {
        print("  no SMC")
    }

    print()
    print("LID CLOSED MODE")
    LidClosedMode.shared.refresh()
    print("  disablesleep = \(LidClosedMode.shared.enabled ? 1 : 0) (\(LidClosedMode.shared.enabled ? "lid close keeps running" : "lid close sleeps"))")

    print()
    print("BRIGHTNESS")
    if !BrightnessController.isAvailable {
        print("  CoreDisplay unavailable on this system")
    } else {
        for screen in NSScreen.screens {
            guard let idNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = UInt32(truncating: idNum)
            let current = BrightnessController.getBrightness(displayID: id)
            print("  \(screen.localizedName) (id \(id))\(screen == NSScreen.main ? " [main]" : "")"
                + " brightness=\(current.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")")
        }
    }

    exit(0)
}

/// Applies a software dim to the first non-built-in display for a few seconds.
/// Usage: `swift run SystemMonitor --shade-test 0.5` (0...1, default 0.5)
func runShadeTest() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let level = CommandLine.arguments.last.flatMap(Double.init) ?? 0.5
    let mainID = UInt32(CGMainDisplayID())
    let displayID: UInt32 = NSScreen.screens
        .compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = UInt32(truncating: n)
            return id != mainID ? id : nil
        }
        .first ?? mainID

    print("Applying software dim \(level) to display \(displayID) for 3s…")
    SoftwareBrightness.shared.setBrightness(displayID: displayID, level: level)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        SoftwareBrightness.shared.remove(displayID: displayID)
        exit(0)
    }
    app.run()
}

/// Safe fan-control round-trip: force manual, set target to the current RPM,
/// then restore automatic. Verifies SMC writes work without changing behavior.
func runFanWriteTest() {
    print("FAN WRITE TEST (round-trip, restores to automatic)")
    guard let smc = SMCHelper() else {
        print("no SMC"); exit(1)
    }
    let fc = FanController(smc: smc)
    guard fc.fanCount() > 0 else {
        print("no fans"); exit(1)
    }

    let id = 0
    print("fan0: actual=\(fc.actualRPM(id).map { String(format: "%.0f", $0) } ?? "n/a")"
        + " mode=\(fc.mode(id).map(String.init) ?? "n/a")")

    print("forceMode(fan0) -> \(fc.forceMode(fan: id))")
    print("  mode after force = \(fc.mode(id).map(String.init) ?? "n/a") (1 = forced)")

    if let current = fc.actualRPM(id) {
        let target = Int(current)
        print("setTarget(\(target)) -> \(fc.setTargetRPM(fan: id, rpm: target))")
        Thread.sleep(forTimeInterval: 1.0)
        print("  actual after set = \(fc.actualRPM(id).map { String(format: "%.0f", $0) } ?? "n/a")")
    }

    print("setAutomatic(fan0) -> \(fc.setAutomatic(fan: id))")
    print("  mode after reset = \(fc.mode(id).map(String.init) ?? "n/a") (0 = auto)")
    exit(0)
}

struct SystemInfo {
    let model: String
    let cores: Int
    let memoryGB: Double

    init() {
        model = Self.sysctlString("hw.model") ?? "unknown"
        cores = ProcessInfo.processInfo.processorCount
        memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }
}
