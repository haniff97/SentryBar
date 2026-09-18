import Foundation
import Combine

/// Polls all sensors on a timer and publishes results for the UI.
final class MonitorService: ObservableObject {
    @Published private(set) var metrics = SystemMetrics()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var pHistory: [Double] = []
    @Published private(set) var eHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var smcAvailable: Bool

    private let cpu = CPUUsage()
    private let gpu = GPUUsageReader()
    let smc: SMCHelper?
    private var timer: Timer?
    private var settingsCancellable: AnyCancellable?
    private let historyCapacity = 60

    init() {
        smc = SMCHelper()
        smcAvailable = smc != nil
        settingsCancellable = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires *before* the value updates; hop once.
                DispatchQueue.main.async { self?.start() }
            }
    }

    func start() {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        var m = metrics

        if let cpuInfo = cpu.sample() {
            m.cpuUsage = cpuInfo.overall
            m.cpuPerCore = cpuInfo.perCore
            m.pCoreUsage = cpuInfo.pCore
            m.eCoreUsage = cpuInfo.eCore
        }
        m.gpuUsage = gpu.utilization()
        if let mem = MemoryInfo.usage() {
            m.memoryUsage = mem.usedFraction
            m.usedGB = mem.usedGB
            m.totalGB = mem.totalGB
        }

        let battery = BatteryInfo.snapshot()
        m.batteryPercent = battery.percent
        m.isCharging = battery.isCharging
        m.externalPower = battery.externalPower
        m.batteryTemp = battery.temperature
        m.batteryHealth = battery.health
        m.batteryCycleCount = battery.cycleCount

        if let smc {
            m.cpuTemp = smc.cpuTemperature()
            m.gpuTemp = smc.gpuTemperature()
            m.fanCount = smc.fanCount()
            m.fanSpeeds = smc.fanSpeeds()
        } else {
            m.cpuTemp = nil
            m.gpuTemp = nil
            m.fanCount = 0
            m.fanSpeeds = []
        }

        metrics = m
        cpuHistory.append(m.cpuUsage)
        memHistory.append(m.memoryUsage)
        pHistory.append(m.pCoreUsage ?? 0)
        eHistory.append(m.eCoreUsage ?? 0)
        gpuHistory.append(m.gpuUsage ?? 0)
        if cpuHistory.count > historyCapacity {
            let drop = cpuHistory.count - historyCapacity
            cpuHistory.removeFirst(drop)
            memHistory.removeFirst(drop)
            pHistory.removeFirst(drop)
            eHistory.removeFirst(drop)
            gpuHistory.removeFirst(drop)
        }
        lastUpdated = Date()
    }
}
