import AppKit
import Combine

struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
    let isMain: Bool
    var brightness: Double?
    /// true = dimmed with a software overlay (works on any monitor).
    var software: Bool
}

/// Lists active displays (via NSScreen) and exposes brightness control.
/// Apple displays use hardware control (CoreDisplay); everything else gets
/// a software overlay that works regardless of monitor support.
///
/// Software brightness levels are persisted per display name and re-applied
/// on launch, so the last adjustment is remembered.
final class DisplaysProvider: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    private let defaults = UserDefaults.standard

    func refresh() {
        var result: [DisplayInfo] = []
        for screen in NSScreen.screens {
            guard let idNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = UInt32(truncating: idNum)
            let isApple = BrightnessController.isAppleDisplay(id)

            let brightness: Double?
            if isApple {
                // Hardware brightness is remembered by macOS itself.
                brightness = BrightnessController.getBrightness(displayID: id)
            } else {
                // Restore the last software level for this display.
                let saved = savedLevel(for: screen.localizedName) ?? 1.0
                SoftwareBrightness.shared.setBrightness(displayID: id, level: saved)
                brightness = saved
            }

            result.append(DisplayInfo(
                id: id,
                name: screen.localizedName,
                isMain: screen == NSScreen.main,
                brightness: brightness,
                software: !isApple
            ))
        }
        displays = result
        SoftwareBrightness.shared.reconcile(activeDisplayIDs: Set(result.map(\.id)))
    }

    func setBrightness(displayID: UInt32, value: Double) {
        guard let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }
        if displays[idx].software {
            SoftwareBrightness.shared.setBrightness(displayID: displayID, level: value)
            saveLevel(value, for: displays[idx].name)
        } else {
            BrightnessController.setBrightness(displayID: displayID, value: value)
        }
        displays[idx].brightness = value
    }

    // MARK: - Persistence (per display name)

    private func savedLevel(for name: String) -> Double? {
        guard let value = defaults.object(forKey: "swBrightness.\(name)") as? Double else { return nil }
        return min(max(value, 0), 1)
    }

    private func saveLevel(_ value: Double, for name: String) {
        defaults.set(min(max(value, 0), 1), forKey: "swBrightness.\(name)")
    }
}
