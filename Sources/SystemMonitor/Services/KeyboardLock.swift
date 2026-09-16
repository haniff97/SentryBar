import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "local.sysmon.SystemMonitor", category: "KeyboardLock")

// MARK: - Input Monitoring Detection
// CGPreflightListenEventAccess() can lag for ad-hoc signed builds, so we test
// an event tap first and use the official and HID-seize checks as fallbacks.

private enum InputMonitoringDetector {
    static func isGranted() -> Bool {
        // Method 1: Try creating a temporary listenOnly CGEvent tap.
        // Most reliable at runtime — directly tests whether the OS allows the tap.
        if checkViaTestEventTap() {
            logger.debug("Input Monitoring: detected via test tap.")
            return true
        }
        // Method 2: Official API (may lag behind actual state for running processes).
        if CGPreflightListenEventAccess() {
            logger.debug("Input Monitoring: detected via CGPreflightListenEventAccess.")
            return true
        }
        // Method 3: Try to seize a HID keyboard device.
        if checkViaHIDSeize() {
            logger.debug("Input Monitoring: detected via HID seize.")
            return true
        }
        logger.debug("Input Monitoring: NOT detected by any method.")
        return false
    }

    /// Attempts to create a temporary listenOnly CGEvent tap.
    /// If the system allows creation, Input Monitoring is granted.
    private static func checkViaTestEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    private static func checkViaHIDSeize() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var granted = false
        for device in devices {
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if status == kIOReturnSuccess {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                granted = true
                break
            }
            if status == IOReturn(kIOReturnExclusiveAccess) {
                granted = true
                break
            }
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return granted
    }

}

// MARK: - KeyboardLock

/// Blocks all keyboard input with a system-wide CGEventTap that swallows
/// key events (same idea as KeepClean). Mouse input is untouched so the
/// app's menu-bar popover stays usable to release the lock.
///
/// Permission approach uses event-tap, preflight, and HID-seize checks because
/// CGPreflightListenEventAccess() can lag for ad-hoc signed builds.
/// - Polls every second for permission changes (so Check Again is implicit).
/// - After permissions become available but tapCreate still fails, sets needsRelaunch.
final class KeyboardLock: ObservableObject {
    static let shared = KeyboardLock()

    @Published private(set) var isLocked = false
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var hasInputMonitoringPerm = InputMonitoringDetector.isGranted()
    /// True when the user has sent the app to System Settings but a relaunch
    /// is still needed for TCC to take effect in this process.
    @Published private(set) var needsRelaunch = false
    @Published var statusMessage: String?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var autoTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var escapePresses = 0
    private var escapeWindowStart = Date()

    var isAccessibilityTrusted: Bool { isTrusted }
    var hasInputMonitoring: Bool { hasInputMonitoringPerm }

    private init() {}

    // MARK: - Public API

    /// Re-check both TCC permissions using all four detection methods.
    /// If both are present but a blocking tap cannot be created, sets needsRelaunch.
    func refreshTrust() {
        isTrusted = AXIsProcessTrusted()
        hasInputMonitoringPerm = InputMonitoringDetector.isGranted()
        logger.info("refreshTrust: AX=\(self.isTrusted) IM=\(self.hasInputMonitoringPerm)")
        if isTrusted && hasInputMonitoringPerm {
            // Both permissions present — test whether a blocking tap can actually
            // be created. If not, the process predates the grant and needs relaunch.
            let canTap = probeBlockingTap()
            logger.info("refreshTrust: probeBlockingTap=\(canTap)")
            needsRelaunch = !canTap
        } else {
            // TCC may keep reporting the old denial to this running process after
            // the user enables a permission in System Settings.  Preserve a pending
            // relaunch request so the UI can still offer the way out of that stale
            // state instead of repeatedly sending the user back to Settings.
        }
    }

    /// Relaunch the app so newly-granted TCC permissions take effect.
    /// NSWorkspace.openApplication silently fails for the same running bundle, so
    /// we use `open -n <path>` (force-new-instance) as the primary mechanism.
    func relaunch() {
        let appPath = Bundle.main.bundleURL.path
        logger.info("Relaunch: opening \(appPath) with open -n")
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", appPath]
        do {
            try task.run()
        } catch {
            logger.error("open -n failed: \(error). Falling back to NSWorkspace.")
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        }
        // Give the new process a moment to start before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }

    /// Tries to create a blocking (defaultTap) CGEvent tap and immediately
    /// destroys it. Returns true if the running process can actually create one.
    /// A false result with both AX + IM detected means the process predates the
    /// grant and must be relaunched.
    private func probeBlockingTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Try HID-level first, then session-level (mirrors createTap).
        for tapPoint: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
            if let testTap = CGEvent.tapCreate(
                tap: tapPoint,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            ) {
                CFMachPortInvalidate(testTap)
                logger.info("probeBlockingTap: succeeded at \(tapPoint == .cghidEventTap ? "HID" : "session") level")
                return true
            }
        }
        logger.warning("probeBlockingTap: failed — process likely predates the grant, relaunch needed.")
        return false
    }

    /// Returns true if the lock was engaged.
    @discardableResult
    func lock() -> Bool {

        guard !isLocked else { return true }

        // Re-read latest permission state.
        refreshTrust()

        // Permission 1: Accessibility.
        if !isTrusted {
            requestAccessibilityAccess()
            openPrivacyPane(
                ventura: "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                legacy: "com.apple.preference.security?Privacy_Accessibility"
            )
            needsRelaunch = true
            statusMessage = nil
            startPolling()
            return false
        }

        // Permission 2: Input Monitoring.
        if !hasInputMonitoringPerm {
            CGRequestListenEventAccess()
            openPrivacyPane(
                ventura: "com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                legacy: "com.apple.preference.security?Privacy_ListenEvent"
            )
            needsRelaunch = true
            statusMessage = nil
            startPolling()
            return false
        }

        // Both permissions present — try to create the blocking tap.
        createTap()
        guard let tap else {
            // tapCreate failed even with permissions — most likely the process
            // was running before the grants were given and needs a restart.
            logger.error("CGEvent.tapCreate failed despite permissions — relaunch required.")
            needsRelaunch = true
            statusMessage = nil
            startPolling()
            return false
        }

        needsRelaunch = false
        statusMessage = nil
        stopPolling()

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source

        isLocked = true
        scheduleAutoUnlock()
        logger.info("Keyboard lock ENGAGED.")
        return true
    }

    func unlock() {
        guard isLocked else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        autoTimer?.invalidate()
        autoTimer = nil
        escapePresses = 0
        isLocked = false
        logger.info("Keyboard lock RELEASED.")
    }

    // MARK: - Polling (background re-check every 1 s while waiting for grants)

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.refreshTrust() }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Internals

    private func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func openPrivacyPane(ventura: String, legacy: String) {
        let candidates = [
            URL(string: "x-apple.systempreferences:\(ventura)")!,
            URL(string: "x-apple.systempreferences:\(legacy)")!,
        ]
        for url in candidates {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private func createTap() {
        let keyDownBit  = CGEventMask(1 << Int(CGEventType.keyDown.rawValue))
        let keyUpBit    = CGEventMask(1 << Int(CGEventType.keyUp.rawValue))
        let flagsBit    = CGEventMask(1 << Int(CGEventType.flagsChanged.rawValue))
        let sysBit      = CGEventMask(1 << 14)  // system-defined (matches KeepClean)
        let mask: CGEventMask = keyDownBit | keyUpBit | flagsBit | sysBit

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Try HID-level tap first; fall back to session-level (mirrors KeepClean).
        var createdTap: CFMachPort?

        createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: refcon
        )

        if createdTap == nil {
            logger.warning("HID-level tap failed, trying session-level.")
            createdTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: keyboardTapCallback,
                userInfo: refcon
            )
        }

        tap = createdTap
        logger.info("createTap result: \(self.tap != nil)")
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            logger.warning("Tap auto-disabled (type=\(type.rawValue)). Re-enabling…")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            // "5× Esc" emergency escape hatch.
            if AppSettings.shared.escapeComboEnabled,
               event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                let now = Date()
                if now.timeIntervalSince(escapeWindowStart) > 3.0 { escapePresses = 0 }
                escapeWindowStart = now
                escapePresses += 1
                if escapePresses >= 5 {
                    DispatchQueue.main.async { self.unlock() }
                }
            }
            return nil  // swallow
        default:
            return nil  // swallow all other key events
        }
    }

    private func scheduleAutoUnlock() {
        autoTimer?.invalidate()
        let seconds = AppSettings.shared.autoUnlockSeconds
        guard seconds > 0 else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.unlock()
        }
    }
}

// MARK: - C-callable event tap callback

private func keyboardTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let lock = Unmanaged<KeyboardLock>.fromOpaque(userInfo).takeUnretainedValue()
    return lock.handleEvent(type: type, event: event)
}
