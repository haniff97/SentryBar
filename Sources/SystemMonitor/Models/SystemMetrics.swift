import Foundation

/// One snapshot of all monitored values.
struct SystemMetrics: Equatable {
    var cpuUsage: Double = 0
    var cpuPerCore: [Double] = []
    var cpuTemp: Double?
    var gpuTemp: Double?
    var memoryUsage: Double = 0
    var usedGB: Double = 0
    var totalGB: Double = 0
    var batteryPercent: Int?
    var isCharging: Bool?
    var externalPower: Bool?
    var batteryTemp: Double?
    var batteryHealth: Int?
    var batteryCycleCount: Int?
    var fanCount: Int = 0
    var fanSpeeds: [Double] = []
}
