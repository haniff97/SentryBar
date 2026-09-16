import Foundation
import Darwin

/// Reads CPU usage by diffing per-core tick counters from the Mach kernel.
/// Public API: `host_processor_info` + `PROCESSOR_CPU_LOAD_INFO`.
final class CPUUsage {
    private struct CoreTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
    }

    private var previous: [CoreTicks]?

    init() {}

    /// Returns (overall usage 0...1, per-core usage 0...1).
    /// First call returns 0 since it needs a baseline.
    func sample() -> (overall: Double, perCore: [Double])? {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let count = Int(numCPUs)
        var ticks: [CoreTicks] = []
        for i in 0..<count {
            let base = i * Int(CPU_STATE_MAX)
            ticks.append(CoreTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]),
                system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[base + Int(CPU_STATE_NICE)])
            ))
        }

        guard let previous = previous else {
            self.previous = ticks
            return (0, Array(repeating: 0, count: count))
        }
        self.previous = ticks

        var perCore: [Double] = []
        var busyTotal: UInt64 = 0
        var deltaTotal: UInt64 = 0
        for i in 0..<count {
            let delta = ticks[i].total - previous[i].total
            let busy = (ticks[i].user + ticks[i].system + ticks[i].nice)
                   - (previous[i].user + previous[i].system + previous[i].nice)
            busyTotal += busy
            deltaTotal += delta
            perCore.append(delta > 0 ? Double(busy) / Double(delta) : 0)
        }

        let overall = deltaTotal > 0 ? Double(busyTotal) / Double(deltaTotal) : 0
        return (overall, perCore)
    }
}
