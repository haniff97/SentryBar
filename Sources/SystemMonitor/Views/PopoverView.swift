import SwiftUI

extension View {
    /// Card background with a little more contrast and a hairline border so
    /// adjacent cards don't visually blend into each other.
    func cardSurface(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
import AppKit

enum PopoverTab: String, CaseIterable, Identifiable {
    case system = "System"
    case display = "Display"
    case keyboard = "Keyboard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "gauge.with.dots.needle.67percent"
        case .display: return "sun.max"
        case .keyboard: return "lock"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: MonitorService
    @ObservedObject var displays: DisplaysProvider
    @ObservedObject var fanControl: FanControlViewModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: PopoverTab = .system

    private var cpuPercent: String {
        String(format: "%.1f%%", monitor.metrics.cpuUsage * 100)
    }

    private var memPercent: String {
        String(format: "%.1f%%", monitor.metrics.memoryUsage * 100)
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            Picker("", selection: $tab) {
                ForEach(PopoverTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .system:
                systemTab
            case .display:
                VStack(spacing: 10) {
                    DisplaysSection(provider: displays)
                    LidClosedModeSection()
                }
            case .keyboard:
                KeyboardLockSection()
            }

            footer
        }
        .padding(14)
        .frame(width: 330)
        // More opaque than the default popover material so the panel doesn't
        // blend into whatever is behind it.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
    }

    private var systemTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(title: "CPU",
                         value: cpuPercent,
                         color: .blue,
                         history: monitor.cpuHistory)
                StatCard(title: "Memory",
                         value: memPercent,
                         color: .purple,
                         history: monitor.memHistory)
            }

            if settings.advancedMode, monitor.metrics.pCoreUsage != nil {
                computeCard
            }

            HStack(spacing: 8) {
                if let temp = monitor.metrics.cpuTemp {
                    MetricBadge(icon: "thermometer.medium",
                                label: "CPU temp",
                                value: String(format: "%.0f°C", temp))
                }
                if let temp = monitor.metrics.gpuTemp {
                    MetricBadge(icon: "cpu",
                                label: "GPU temp",
                                value: String(format: "%.0f°C", temp))
                }
                if monitor.metrics.fanCount > 0 {
                    ForEach(monitor.metrics.fanSpeeds.indices, id: \.self) { i in
                        MetricBadge(icon: "fan.fill",
                                    label: "Fan \(i + 1)",
                                    value: "\(Int(monitor.metrics.fanSpeeds[i])) rpm")
                    }
                } else {
                    MetricBadge(icon: "fan.fill", label: "Fan", value: "n/a")
                }
            }

            if settings.advancedMode {
                FanControlSection(model: fanControl,
                                  currentSpeeds: monitor.metrics.fanSpeeds)
            } else {
                Text("Fans are managed by macOS.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Toggle("Advanced", isOn: $settings.advancedMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("Show per-core load and manual fan control")
            }

            BatteryCard(percent: monitor.metrics.batteryPercent,
                        isCharging: monitor.metrics.isCharging,
                        externalPower: monitor.metrics.externalPower,
                        health: monitor.metrics.batteryHealth,
                        cycleCount: monitor.metrics.batteryCycleCount,
                        temperature: monitor.metrics.batteryTemp)
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(monitor.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "—")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .font(.caption)
                .buttonStyle(.link)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .foregroundStyle(.tint)
            Text("SentryBar")
                .font(.headline)
            if !monitor.smcAvailable {
                Text("SMC unavailable")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow.opacity(0.2)))
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var computeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compute")
                .font(.caption)
                .foregroundStyle(.secondary)
            computeRow("P-cores", monitor.metrics.pCoreUsage, monitor.pHistory, .blue)
            computeRow("E-cores", monitor.metrics.eCoreUsage, monitor.eHistory, .teal)
            computeRow("GPU", monitor.metrics.gpuUsage, monitor.gpuHistory, .purple)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
    }

    private func computeRow(_ label: String, _ value: Double?, _ history: [Double], _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a")
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            MiniGraph(values: history, color: color)
                .frame(height: 18)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let color: Color
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.semibold)
                .monospacedDigit()
            MiniGraph(values: history, color: color)
                .frame(height: 28)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
    }
}

struct MetricBadge: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 8)
    }
}

struct DisplaysSection: View {
    @ObservedObject var provider: DisplaysProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Displays")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !BrightnessController.isAvailable {
                Text("Brightness control unavailable on this system.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if provider.displays.isEmpty {
                Text("No displays found.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.displays) { display in
                    row(display)
                }
                Text("Apple displays adjust hardware; others use a software overlay.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
        .onAppear { provider.refresh() }
    }

    private func row(_ display: DisplayInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.software ? "sun.min" : "display")
                .foregroundStyle(.secondary)
            Text(display.isMain ? "\(display.name) (built-in)" : display.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            Spacer(minLength: 4)
            if display.software {
                Text("software")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let brightness = display.brightness {
                Slider(value: binding(for: display, initial: brightness), in: 0...1)
                    .controlSize(.small)
            }
        }
    }

    private func binding(for display: DisplayInfo, initial: Double) -> Binding<Double> {
        Binding<Double>(
            get: {
                provider.displays.first(where: { $0.id == display.id })?.brightness ?? initial
            },
            set: { provider.setBrightness(displayID: display.id, value: $0) }
        )
    }
}

struct BatteryCard: View {
    let percent: Int?
    let isCharging: Bool?
    let externalPower: Bool?
    let health: Int?
    let cycleCount: Int?
    let temperature: Double?

    private var iconName: String {
        guard let percent else { return "battery.0" }
        let level = max(0, min(100, percent))
        if level >= 100 { return isCharging == true ? "battery.100.bolt" : "battery.100" }
        if level >= 75 { return "battery.75" }
        if level >= 50 { return "battery.50" }
        if level >= 25 { return "battery.25" }
        return "battery.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(percent.map { $0 <= 20 ? Color.red : Color.green } ?? .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(percent.map { "\($0)%" } ?? "no battery")
                            .font(.system(.title3, design: .rounded))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        if isCharging == true {
                            Label("Charging", systemImage: "bolt.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if externalPower == true {
                            Label("AC", systemImage: "powerplug.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Battery", systemImage: "battery.0")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        if let health {
                            Text("Health \(health)%")
                        }
                        if let cycleCount {
                            Text("\(cycleCount) cycles")
                        }
                        if let temperature {
                            Text(String(format: "%.0f°C", temperature))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                openChargeLimitSettings()
            } label: {
                Label("Set Charge Limit (80% recommended)", systemImage: "battery.75")
                    .frame(maxWidth: .infinity)
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text("Protect battery life while plugged in. In Battery settings, click ⓘ next to Charging to choose the limit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
    }

    private func openChargeLimitSettings() {
        // Uses Apple's supported charge-limit control (macOS 26.4+ on Apple
        // silicon) instead of changing private SMC charging keys.
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}

struct MiniGraph: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let step = size.width / max(CGFloat(values.count - 1), 1)
            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step,
                        y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }

            if points.count > 1 {
                let line = Path { p in
                    p.move(to: points[0])
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                let fill = Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: points[0])
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                }
                fill.fill(color.opacity(0.15))
                line.stroke(color, style: StrokeStyle(lineWidth: 1.5,
                                                      lineCap: .round,
                                                      lineJoin: .round))
            }
        }
    }
}
