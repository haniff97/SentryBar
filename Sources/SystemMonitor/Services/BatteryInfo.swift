import Foundation
import IOKit.ps

/// Reads battery status via IOKit's public power-source APIs:
/// `IOPSCopyPowerSourcesInfo` for charge/state, the `IOPMPowerSource`
/// registry entry for cycle count / capacities / temperature.
enum BatteryInfo {
    struct Snapshot {
        var percent: Int?
        var isCharging: Bool?
        var externalPower: Bool?
        var temperature: Double?
        var health: Int?
        var cycleCount: Int?
    }

    static func snapshot() -> Snapshot {
        var out = powerSourcesSnapshot()
        out.temperature = registryValue("Temperature").flatMap { temp in
            temp > 0 && temp < 100 ? Double(temp) : nil
        }
        out.cycleCount = registryValue("CycleCount")
        out.health = batteryHealth()
        return out
    }

    // MARK: - Charge level / state via IOPSCopyPowerSourcesInfo

    private static func powerSourcesSnapshot() -> Snapshot {
        var out = Snapshot()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return out
        }
        let sources: [CFTypeRef] = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            if let current = desc[kIOPSCurrentCapacityKey] as? Int, maxCapacity > 0 {
                out.percent = Int((Double(current) / Double(maxCapacity) * 100).rounded())
            }
            out.isCharging = desc[kIOPSIsChargingKey] as? Bool
            out.externalPower = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        return out
    }

    // MARK: - Registry properties via IOPMPowerSource

    private static func registryValue(_ key: String) -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }
        if let n = property as? NSNumber { return n.intValue }
        if let n = property as? Int { return n }
        return nil
    }

    /// Health % = current full-charge capacity / design capacity.
    private static func batteryHealth() -> Int? {
        let maxCapacity = registryValue("AppleRawMaxCapacity")
            ?? registryValue("MaxCapacity")
        let designCapacity = registryValue("AppleRawDesignCapacity")
            ?? registryValue("DesignCapacity")
        guard let maxCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
    }
}
