import Foundation
import IOKit

/// Reads GPU utilization from the IOAccelerator registry entry's
/// `PerformanceStatistics` ("Device Utilization %"). No privileges needed.
final class GPUUsageReader {
    private var service: io_service_t = 0

    init() {
        service = Self.matchService()
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    private static func matchService() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }

    /// GPU utilization 0...1, or nil if unavailable.
    func utilization() -> Double? {
        if service == 0 {
            service = Self.matchService()
            if service == 0 { return nil }
        }
        guard let stats = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            ?? (stats["Device Utilization %"] as? Int).map(Double.init)
        guard let value, value >= 0 else { return nil }
        return min(value / 100.0, 1.0)
    }
}
