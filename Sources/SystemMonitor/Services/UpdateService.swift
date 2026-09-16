import Foundation
import AppKit
import CryptoKit

/// Lightweight self-updater.
///
/// The app fetches a JSON manifest from a URL you host (GitHub Releases, a gist,
/// any static file). If it advertises a newer version, the user can update in
/// one click: the DMG is downloaded, its SHA-256 verified, the running app is
/// replaced, and it relaunches.
///
/// Manifest format (`appcast.json`):
/// ```json
/// {
///   "version": "1.1",
///   "build": 2,
///   "notes": ["Added mouse control", "Fixed fan slider"],
///   "url": "https://example.com/SentryBar-1.1.dmg",
///   "sha256": "optional-sha256-of-the-dmg"
/// }
/// ```
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// Hosted update manifest URL. Point this at your own `appcast.json`.
    static let feedURL = "https://raw.githubusercontent.com/haniff97/SentryBar/main/appcast.json"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: [String])
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var pending: Manifest?

    private init() {}

    struct Manifest: Decodable {
        let version: String
        let build: Int?
        let notes: [String]?
        let url: String
        let sha256: String?
    }

    func check(feedURL: String) {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            state = .failed("Set a valid update feed URL first.")
            return
        }
        state = .checking
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                guard let data, let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                    self.state = .failed("Update feed is invalid.")
                    return
                }
                self.pending = manifest
                if AppVersion.isNewer(manifest.version, than: AppVersion.short) {
                    self.state = .available(version: manifest.version, notes: manifest.notes ?? [])
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    func install() {
        guard let manifest = pending, let url = URL(string: manifest.url) else { return }
        state = .downloading
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                guard let tmp else { self.state = .failed("Download failed."); return }

                let dmg = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("SentryBar-update.dmg")
                try? FileManager.default.removeItem(at: dmg)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dmg)
                } catch {
                    self.state = .failed("Could not stage the download.")
                    return
                }

                if let expected = manifest.sha256, !expected.isEmpty {
                    guard Self.sha256(of: dmg)?.lowercased() == expected.lowercased() else {
                        self.state = .failed("Download failed its integrity check.")
                        return
                    }
                }

                self.state = .installing
                self.runInstaller(dmg: dmg)
            }
        }.resume()
    }

    // MARK: - Install helper

    private func runInstaller(dmg: URL) {
        let destination = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/sh
        PID="$1"; DMG="$2"; DEST="$3"; VOL="/Volumes/SentryBarUpdate"
        # Wait for the running app to exit.
        while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
        hdiutil attach "$DMG" -nobrowse -mountpoint "$VOL" >/dev/null 2>&1
        rm -rf "$DEST.old"
        mv "$DEST" "$DEST.old" 2>/dev/null
        ditto "$VOL/SentryBar.app" "$DEST"
        xattr -cr "$DEST"
        hdiutil detach "$VOL" >/dev/null 2>&1
        rm -rf "$DEST.old" "$DMG"
        open "$DEST"
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentrybar-update.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("Could not write the update script.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, "\(pid)", dmg.path, destination.path]
        do {
            try process.run()
        } catch {
            state = .failed("Could not start the updater.")
            return
        }

        // Give the script a moment, then quit so it can swap the bundle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
