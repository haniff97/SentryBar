import Foundation
import Darwin

/// Reads memory usage via `host_statistics64` (public Mach API).
enum MemoryInfo {
    static let pageSize = UInt64(vm_kernel_page_size)

    /// Returns (used fraction 0...1, used GB, total GB).
    /// "Used" = active + wired + compressor pages, the standard macOS reading.
    static func usage() -> (usedFraction: Double, usedGB: Double, totalGB: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let total = ProcessInfo.processInfo.physicalMemory
        let used = (UInt64(stats.active_count)
                  + UInt64(stats.wire_count)
                  + UInt64(stats.compressor_page_count)) * pageSize
        let totalGB = Double(total) / 1_073_741_824
        let usedGB = Double(used) / 1_073_741_824
        guard totalGB > 0 else { return nil }
        return (usedGB / totalGB, usedGB, totalGB)
    }
}
