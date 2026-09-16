import AppKit

/// Software brightness via a black overlay window — the same technique
/// MonitorControl's "software brightness" uses. Works on ANY display,
/// including monitors that ignore hardware brightness (DDC/CI / CoreDisplay).
/// Non-destructive: windows vanish when the app quits, restoring full brightness.
final class SoftwareBrightness {
    static let shared = SoftwareBrightness()

    private var shades: [UInt32: NSWindow] = [:]

    private init() {}

    /// `level` 0...1 (1 = full brightness / no overlay).
    func setBrightness(displayID: UInt32, level: Double) {
        DispatchQueue.main.async {
            let clamped = min(max(level, 0), 1)
            let opacity = 1.0 - clamped
            if opacity <= 0.001 {
                self.remove(displayID: displayID)
                return
            }
            guard let screen = Self.screen(for: displayID) else { return }

            if let window = self.shades[displayID] {
                window.alphaValue = opacity
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: false)
                }
                return
            }

            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
            window.level = .statusBar
            window.backgroundColor = .black
            window.alphaValue = opacity
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.canHide = false
            window.hidesOnDeactivate = false
            window.orderFrontRegardless()
            self.shades[displayID] = window
        }
    }

    /// Remove the overlay for a display (restores full brightness).
    func remove(displayID: UInt32) {
        DispatchQueue.main.async {
            self.shades[displayID]?.orderOut(nil)
            self.shades[displayID] = nil
        }
    }

    func removeAll() {
        DispatchQueue.main.async {
            for (_, window) in self.shades {
                window.orderOut(nil)
            }
            self.shades.removeAll()
        }
    }

    /// Drop overlays for displays that are no longer connected.
    func reconcile(activeDisplayIDs: Set<UInt32>) {
        DispatchQueue.main.async {
            for id in self.shades.keys where !activeDisplayIDs.contains(id) {
                self.shades[id]?.orderOut(nil)
                self.shades[id] = nil
            }
        }
    }

    private static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { UInt32(truncating: $0) } == displayID
        }
    }
}
