import SwiftUI

struct FanControlSection: View {
    @ObservedObject var model: FanControlViewModel
    /// Current RPM per fan, from the live monitor.
    let currentSpeeds: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fan Control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.fans.isEmpty {
                Text("No controllable fans on this machine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.fans) { fan in
                    fanRow(fan)
                }
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if model.fans.count > 1 {
                Button {
                    model.toggleFansLinked()
                } label: {
                    Label(model.areFansLinked ? "Fans linked" : "Link fans",
                          systemImage: model.areFansLinked ? "link" : "link.badge.plus")
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(model.areFansLinked ? .blue : .gray)
                .disabled(model.isBusy)

                Text(model.areFansLinked
                     ? "Move either slider to set both fans."
                     : "Link fans to control both from either slider.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Manual control overrides Apple's thermal management. Fan speed may be returned to automatic by macOS.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Reset all to automatic") { model.resetAll() }
                .font(.caption)
                .disabled(model.isBusy)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
        .onAppear { model.refresh() }
    }

    private func fanRow(_ fan: FanState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text("Fan \(fan.id + 1)")
                    .font(.caption)
                Spacer()
                Picker("", selection: modeBinding(fan)) {
                    Text("Auto").tag(0)
                    Text("Manual").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
                .disabled(model.isBusy)
            }

            if fan.mode == 1 {
                Slider(value: targetBinding(fan), in: 0...Double(max(fan.max, 1)))
                    .controlSize(.small)
                    .disabled(model.isBusy)
                Text("Target \(fan.target) rpm · Current \(current(fan.id)) rpm · Max \(fan.max)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Current \(current(fan.id)) rpm · Max \(fan.max)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modeBinding(_ fan: FanState) -> Binding<Int> {
        Binding<Int>(
            get: { model.fans.first(where: { $0.id == fan.id })?.mode ?? fan.mode },
            set: { model.setMode(fan.id, forced: $0 == 1) }
        )
    }

    private func targetBinding(_ fan: FanState) -> Binding<Double> {
        Binding<Double>(
            get: {
                Double(model.fans.first(where: { $0.id == fan.id })?.target ?? fan.target)
            },
            set: { model.setTarget(fan.id, rpm: Int($0)) }
        )
    }

    private func current(_ id: Int) -> Int {
        guard currentSpeeds.indices.contains(id) else { return 0 }
        return Int(currentSpeeds[id].rounded())
    }
}
