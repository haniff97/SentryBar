import SwiftUI

struct LidClosedModeSection: View {
    @ObservedObject private var model = LidClosedMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: model.enabled ? "laptopcomputer" : "sleep")
                    .foregroundStyle(model.enabled ? Color.green : Color.secondary)
                Text("Lid Closed Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.enabled },
                    set: { model.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text(model.enabled
                 ? "Lid can close while tasks keep running."
                 : "Closing the lid sleeps the Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.enabled {
                Label("Thermal risk: with the lid shut the Mac can't cool as well. Keep it on a hard surface, plugged in, and avoid heavy sustained loads.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
        .onAppear { model.refresh() }
    }
}
