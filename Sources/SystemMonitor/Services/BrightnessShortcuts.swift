import ApplicationServices
import CoreGraphics
import Foundation

/// Global F1/F2 shortcut: F1 lowers and F2 raises the brightness of the
/// currently selected display. Uses a CGEventTap that swallows F1/F2 and
/// passes everything else through. Requires Accessibility + Input Monitoring.
final class BrightnessShortcuts {
    static let shared = BrightnessShortcuts()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    weak var displays: DisplaysProvider?

    private let step = 1.0 / 16.0

    private init() {}

    var isRunning: Bool { tap != nil }

    func start(displays: DisplaysProvider) {
        stop()
        guard AXIsProcessTrusted() else { return }
        self.displays = displays

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let shortcuts = Unmanaged<BrightnessShortcuts>.fromOpaque(refcon).takeUnretainedValue()
                return shortcuts.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return }

        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        source = src
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 122 {            // F1
                stepBrightness(-1)
                return nil               // swallow
            } else if code == 120 {      // F2
                stepBrightness(+1)
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func stepBrightness(_ direction: Int) {
        guard let displays else { return }
        guard let id = displays.selectedDisplayID else { return }
        let current = displays.displays.first(where: { $0.id == id })?.brightness ?? 1.0
        let newValue = min(max(current + Double(direction) * step, 0), 1)
        displays.setBrightness(displayID: id, value: newValue)
    }
}
