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
                Text("Keep it plugged into power.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
