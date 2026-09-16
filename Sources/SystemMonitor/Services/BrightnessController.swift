import Foundation
import Darwin

/// Controls display brightness through the private CoreDisplay framework.
/// Symbols are resolved at runtime with dlsym (no link-time dependency).
/// Works on Apple displays (built-in + Apple external). Generic DDC/CI
/// monitors generally do not respond to these calls.
enum BrightnessController {
    private static let handle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            "CoreDisplay.framework/CoreDisplay"
        ]
        for path in paths {
            if let h = dlopen(path, RTLD_NOW) {
                return h
            }
        }
        return nil
    }()

    private static let setSymbol = dlsym(handle, "CoreDisplay_Display_SetUserBrightness")
    private static let getSymbol = dlsym(handle, "CoreDisplay_Display_GetUserBrightness")
    private static let infoSymbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary")

    private typealias SetBrightnessFn = @convention(c) (Int32, Double) -> Void
    private typealias GetBrightnessFn = @convention(c) (Int32) -> Double

    /// Whether the private symbols could be resolved on this system.
    static var isAvailable: Bool { setSymbol != nil && getSymbol != nil }

    /// Set brightness for a display. `value` is 0...1.
    static func setBrightness(displayID: UInt32, value: Double) {
        guard let setSymbol else { return }
        let fn = unsafeBitCast(setSymbol, to: SetBrightnessFn.self)
        fn(Int32(bitPattern: displayID), min(max(value, 0), 1))
    }

    /// Read current brightness (0...1) for a display, if supported.
    static func getBrightness(displayID: UInt32) -> Double? {
        guard let getSymbol else { return nil }
        let fn = unsafeBitCast(getSymbol, to: GetBrightnessFn.self)
        let value = fn(Int32(bitPattern: displayID))
        guard value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    /// Display vendor ID (e.g. 0x05AC = Apple). nil if unavailable.
    static func vendorID(displayID: UInt32) -> UInt32? {
        guard let infoSymbol else { return nil }
        typealias InfoFn = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
        let fn = unsafeBitCast(infoSymbol, to: InfoFn.self)
        guard let dict = fn(displayID)?.takeRetainedValue() as? [String: Any],
              let vendor = dict["DisplayVendorID"] as? NSNumber
        else { return nil }
        return vendor.uint32Value
    }

    /// CoreDisplay only drives Apple displays (built-in + Apple externals).
    /// Generic monitors (HP, Dell, LG…) ignore these calls.
    static func isAppleDisplay(_ displayID: UInt32) -> Bool {
        vendorID(displayID: displayID) == 0x05AC
    }
}
