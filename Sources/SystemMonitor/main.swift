import AppKit
import Foundation
import ApplicationServices

if CommandLine.arguments.contains("--test") {
    runSelfTest()
}

if CommandLine.arguments.contains("--fan-test") {
    runFanWriteTest()
}

if CommandLine.arguments.contains("--shade-test") {
    runShadeTest()
}

if CommandLine.arguments.contains("--ax-check") {
    print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
    print("InputMonitoring (CGPreflightListenEventAccess) = \(CGPreflightListenEventAccess())")
    let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
    let refcon = Unmanaged.passUnretained(KeyboardLock.shared).toOpaque()
    let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, _, _, _ in nil },
        userInfo: refcon
    )
    print("CGEvent.tapCreate = \(tap != nil)")
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    exit(0)
}

// Menu-bar utility: no dock icon, no regular window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
