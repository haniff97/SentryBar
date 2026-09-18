import SwiftUI
import AppKit

struct KeyboardLockSection: View {
    @ObservedObject private var lock = KeyboardLock.shared
    @ObservedObject private var settings = AppSettings.shared

    // True only when running from dist/SentryBar.app (bundle ID set correctly).
    // swift run produces an ad-hoc binary with no bundle ID, so TCC grants never stick.
    private var isPackagedApp: Bool {
        Bundle.main.bundleIdentifier == "local.sysmon.SystemMonitor"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: lock.isLocked ? "lock.fill" : "keyboard")
                    .foregroundStyle(lock.isLocked ? Color.red : Color.secondary)
                Text("Keyboard Lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    // Disable the toggle entirely if not running from the packaged app.
                    .disabled(!isPackagedApp)
            }

            // ── Gate 0: wrong binary ──────────────────────────────────────────────
            if !isPackagedApp {
                wrongBinaryWarning

            // ── Gate 1: keyboard is locked ───────────────────────────────────────
            } else if lock.isLocked {
                Text("Keyboard is disabled. Release with the switch, the menu-bar icon, \(settings.escapeComboEnabled ? "or press Esc 5 times" : "or mouse only").")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if settings.autoUnlockSeconds > 0 {
                    Text("Auto-unlocks in \(Int(settings.autoUnlockSeconds))s.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

            // ── Gate 2: one or more permissions still missing ─────────────────
            } else if !lock.isTrusted || !lock.hasInputMonitoring {
                permissionPrompt

            // ── Gate 3: permissions present but tap failed — relaunch needed ─────
            } else if lock.needsRelaunch {
                relaunchPrompt

            // ── Gate 4: misc error ────────────────────────────────────────────────
            } else if let message = lock.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)

            // ── Ready ─────────────────────────────────────────────────────────────
            } else {
                Text("Off: keyboard works normally. On: all keys are blocked (mouse stays usable).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
        .onAppear { lock.refreshTrust() }
    }

    // MARK: - Sub-views

    /// Shown when running via `swift run` instead of dist/SentryBar.app.
    /// macOS TCC grants are tied to a binary path/hash, so they never stick for
    /// the `swift run` debug binary which changes on every build.
    @ViewBuilder
    private var wrongBinaryWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Keyboard Lock requires the packaged app.")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.red)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption2)
            }

            Text("You are running via **swift run** — macOS TCC permission grants will not stick to this binary. Run the packaged app instead:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("open dist/SentryBar.app")
                .font(.system(.caption2, design: .monospaced))
                .padding(4)
                .background(Color.black.opacity(0.15))
                .cornerRadius(4)

            HStack(spacing: 8) {
                Button("Open Packaged App") {
                    // For swift run, the executable is at .build/debug/SystemMonitor.
                    // Walk up to the project root (3 levels) and open dist/SentryBar.app.
                    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
                    let projectURL = execURL
                        .deletingLastPathComponent()  // debug/
                        .deletingLastPathComponent()  // .build/
                        .deletingLastPathComponent()  // project root
                    let appURL = projectURL.appendingPathComponent("dist/SentryBar.app")
                    NSWorkspace.shared.openApplication(
                        at: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, _ in }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)

                Button("Reveal in Finder") {
                    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
                    let distURL = execURL
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("dist")
                    NSWorkspace.shared.activateFileViewerSelecting([distURL])
                }
                .font(.caption)
                .controlSize(.small)
            }
        }
    }

    /// Shown when both permissions are granted but a process restart is needed.
    @ViewBuilder
    private var relaunchPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Permissions granted — relaunch required.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } icon: {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(.orange)
                    .font(.caption2)
            }

            Text("macOS only applies Accessibility / Input Monitoring grants after the app restarts. Click **Relaunch** below, then toggle Keyboard Lock on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Relaunch App") {
                    lock.relaunch()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)

                Button("Check again") { lock.refreshTrust() }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
    }

    /// Shown when permissions haven't been granted yet.
    @ViewBuilder
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show which permissions are still missing.
            HStack(spacing: 12) {
                permissionBadge(
                    label: "Accessibility",
                    granted: lock.isTrusted,
                    systemImage: "hand.raised"
                )
                permissionBadge(
                    label: "Input Monitoring",
                    granted: lock.hasInputMonitoring,
                    systemImage: "keyboard"
                )
            }

            if !lock.hasInputMonitoring {
                Text("**Input Monitoring** is missing. Open the pane below, click the **+** button, and add **SentryBar.app** from the dist/ folder. Then click Relaunch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Toggle the switch above to request missing permissions, then click **Relaunch App**.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if !lock.isTrusted {
                    Button("Open Accessibility") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
                            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
                if !lock.hasInputMonitoring {
                    Button("Open Input Monitoring") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")
                            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
                        )
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
                Button("Check again") { lock.refreshTrust() }
                    .font(.caption)
                    .controlSize(.small)
            }

            // TCC can report a stale denial until the app restarts.  Once a lock
            // attempt has requested permissions, always make relaunch available;
            // if a permission is still genuinely missing, the next launch shows
            // this prompt again with the exact missing badge.
            if lock.needsRelaunch || (lock.isTrusted && lock.hasInputMonitoring) {
                Button("Relaunch App") { lock.relaunch() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
            }

            // Reveal app in Finder so user can drag it into the + dialog
            Button("Reveal App in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionBadge(label: String, granted: Bool, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundStyle(granted ? .secondary : .primary)
        }
    }

    // MARK: - Toggle binding

    private var toggleBinding: Binding<Bool> {
        Binding<Bool>(
            get: { lock.isLocked },
            set: { on in
                if on {
                    _ = lock.lock()
                } else {
                    lock.unlock()
                }
            }
        )
    }
}
