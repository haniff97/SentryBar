import Foundation

/// Fan reads go directly to the SMC (works from user space); writes are
/// forwarded to the root-privileged `FanHelper` via `FanRootBridge`, because
/// user-space SMC writes return kIOReturnNotPrivileged.
final class FanController {
    private let smc: SMCHelper
    private let bridge: FanRootBridge
    private var modeKeyIsLower: Bool?

    init(smc: SMCHelper, bridge: FanRootBridge = .shared) {
        self.smc = smc
        self.bridge = bridge
    }

    // MARK: - Reading (direct)

    func fanCount() -> Int {
        smc.fanCount()
    }

    func actualRPM(_ id: Int) -> Double? {
        smc.read("F\(id)Ac")?.value
    }

    func maxRPM(_ id: Int) -> Double? {
        smc.read("F\(id)Mx")?.value
    }

    /// Current mode: 0 = automatic, 1 = forced. nil if not readable.
    func mode(_ id: Int) -> Int? {
        guard let (_, data) = smc.readKey(modeKey(id)), let byte = data.first else { return nil }
        return Int(byte)
    }

    private func modeKey(_ id: Int) -> String {
        if modeKeyIsLower == nil {
            modeKeyIsLower = smc.readKey("F0md") != nil
        }
        return modeKeyIsLower == true ? "F\(id)md" : "F\(id)Md"
    }

    // MARK: - Writing (via root helper)

    /// Force a fan into manual mode so its target can be set.
    /// May prompt for the admin password on first use.
    func forceMode(fan id: Int) -> Bool {
        bridge.force(id)
    }

    /// Return a fan to automatic (firmware) control.
    func setAutomatic(fan id: Int) -> Bool {
        bridge.auto(id)
    }

    /// Set the target RPM for a fan (fan is placed into forced mode if needed).
    func setTargetRPM(fan id: Int, rpm: Int) -> Bool {
        bridge.target(id, rpm: rpm)
    }

    /// Restore firmware fan control on all fans (and clear `Ftst`).
    func resetAllToAutomatic() -> Bool {
        bridge.reset()
    }
}
