import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Polling interval", selection: $settings.pollInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
            Section("Menu bar") {
                Picker("Content", selection: $settings.menuBarContent) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.rawValue).tag(content)
                    }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Section("Keyboard Lock") {
                Toggle("Unlock with 5× Esc", isOn: $settings.escapeComboEnabled)
                Picker("Auto-unlock after", selection: $settings.autoUnlockSeconds) {
                    Text("Never").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
            }
            Section("Updates") {
                HStack {
                    Button("Check for Updates") {
                        updater.check(feedURL: UpdateService.feedURL)
                    }
                    Spacer()
                    updateStatus
                }
            }
            Section("About") {
                HStack {
                    Text("SentryBar")
                    Spacer()
                    Text("\(AppVersion.display) (build \(AppVersion.build))")
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("What's new") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Changelog.releases) { release in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("v\(release.version) — \(release.date)")
                                        .font(.caption)
                                        .bold()
                                    ForEach(release.highlights, id: \.self) { line in
                                        Text("• \(line)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
        .padding(14)
        .frame(width: 380)
        .onAppear { settings.refreshLaunchStatus() }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case .available(let version, let notes):
            HStack(spacing: 8) {
                Text("v\(version) available").font(.caption).foregroundStyle(.green)
                Button("Update Now") { updater.install() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
            }
        case .downloading:
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .installing:
            Text("Installing… the app will restart").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.orange)
        }
    }
}
