# SystemMonitor — Agent Notes

macOS menu-bar utility (Swift + SwiftUI, SPM package) that monitors system sensors
and provides controls: CPU/RAM/battery/fan monitoring, display brightness, fan control,
"run with lid closed", and a keyboard cleaner lock.

Working dir: `/Users/user/Documents/Default Project/SystemMonitor`
Target hardware: Apple Silicon M1 Pro (MacBookPro18,3), macOS 26.

## Build / run commands

```bash
swift build                        # debug build
swift run SystemMonitor            # run the menu-bar app
swift run SystemMonitor --test     # CLI self-test of every sensor reading
swift run SystemMonitor --fan-test # safe fan round-trip (needs root/password)
swift run SystemMonitor --shade-test 0.5  # dim a display 3s (software)
./dist/SystemMonitor.app/Contents/MacOS/SystemMonitor --ax-check  # TCC/diagnostic
./scripts/make-app.sh              # build release + package dist/SystemMonitor.app
open dist/SystemMonitor.app        # launch the packaged app
```

## Architecture (Sources/SystemMonitor)

| File | Purpose |
|---|---|
| `Services/SMCHelper.swift` | Apple SMC read + write client |
| `Services/CPUUsage.swift` / `MemoryInfo.swift` | Mach kernel CPU/RAM |
| `Services/BatteryInfo.swift` | IOKit battery (%, health, cycles) |
| `Services/FanController.swift` | Fan reads (direct) + writes (via root helper) |
| `Sources/FanHelper/main.swift` | Root-privileged fan-write daemon (unix socket) |
| `Services/FanRootBridge.swift` | Spawns FanHelper via osascript, socket client |
| `Services/BrightnessController.swift` | CoreDisplay hardware brightness (Apple displays) |
| `Services/SoftwareBrightness.swift` | Black-overlay software dim (any monitor) |
| `Services/DisplaysProvider.swift` | NSScreen enumeration + routing |
| `Services/LidClosedMode.swift` | pmset disablesleep toggle (admin) |
| `Services/KeyboardLock.swift` | CGEventTap keyboard block (AX + Input Monitoring) |
| `Services/MonitorService.swift` | 2s polling + history |
| `Views/*` | Tabs: System / Display / Keyboard |

## Key obstacles solved

1. **SMC reads returned `kIOReturnBadArgument`** — three fixes:
   - SMC wire struct must be the **80-byte `SMCKeyData`** (vers.release = `UInt16`,
     explicit `padding: UInt16`, correct alignment) — Swift's default layout otherwise
     produces 76 bytes and the kernel rejects it.
   - Keys are **big-endian FourCC** (`"FNum"` → `0x464E756D`).
   - `IOConnectCallStructMethod`'s 6th arg is the **output buffer size in bytes**
     (I passed `1`). Model = open-source Stats `smc.swift`.

2. **Fan writes blocked (`kIOReturnNotPrivileged`)** — user-space SMC writes need root.
   Built a second executable (`FanHelper`) that runs as root via one osascript admin
   prompt and serves commands over `/tmp/com.systemmonitor.fanhelper.sock`
   (`force/auto/target/reset`). Reads stay in-process.

3. **HP P224 brightness did nothing** — CoreDisplay only drives Apple displays; DDC/CI
   over I2C (both AVService and IOFB paths) never responds on this monitor. Discovered
   MonitorControl "controls" it via a **software shade overlay** (`SwBrightness` prefs).
   Implemented `SoftwareBrightness` (black borderless `.statusBar` window).
   **Crashed in `_NSWindowTransformAnimation dealloc`** on slider drag → set
   `window.animationBehavior = .none`, only `setFrame` when the frame actually changes,
   `orderOut` instead of `close`.

4. **Keyboard lock tap was "impotent"** — blocking event taps require **BOTH**
   Accessibility AND **Input Monitoring** (`CGPreflightListenEventAccess`); without
   Input Monitoring the tap exists but never swallows events (learned from the open-source
   KeepClean repo). Also re-enable the tap on `tapDisabledByTimeout`/`tapDisabledByUserInput`.

5. **TCC grants lost after every rebuild** — ad-hoc `codesign -s -` produces a new cdhash
   each build, so macOS forgets the Accessibility/Input Monitoring grants. Fixed by signing
   with an **identifier-only designated requirement** (no cdhash) in `make-app.sh`:
   `codesign --force --sign - --identifier local.sysmon.SystemMonitor -r <file with
   'designated => identifier "local.sysmon.SystemMonitor"'>`.
   After re-granting once, grants now survive rebuilds.
   Note: Accessibility + Input Monitoring grants require a **relaunch** to take effect.

6. **Keyboard lock toggle looped on permission — "already on" but toggle stays off** —
   `CGPreflightListenEventAccess()` / `AXIsProcessTrusted()` return `false` for the
   *currently running process* even after the user grants in System Settings; the grant
   only takes effect after the app is **relaunched**. The old `lock()` did an immediate
   re-check after prompting → always failed → re-opened System Settings in an infinite
   loop. Fix: `lock()` now sets `needsRelaunch = true` and returns early; the UI shows
   a **"Relaunch App"** button (orange) that calls `relaunch()` which opens a new instance
   and calls `NSApp.terminate`. After relaunch the tap creates successfully.

7. **`CGPreflightListenEventAccess()` unreliable for ad-hoc builds** — even after granting
   Input Monitoring, `CGPreflightListenEventAccess()` still returns `false` for the running
   process. Modelled `InputMonitoringDetector` after KeepClean (github.com/adhamhaithameid/KeepClean):
   tries four methods in order: (1) create a listenOnly test tap, (2) `CGPreflightListenEventAccess`,
   (3) IOHIDManager keyboard seize, (4) IOHIDManager SPI/I2C device open. Also: HID-level
   tap falls back to session-level tap; background 1-second poll refreshes UI while user
   is in System Settings; Ventura deep-link URLs used first with legacy fallback.

8. **Intermittent Swift build deadlock** — `swift-frontend` hangs at 0% CPU (whole-module
   release builds most often); error "input file … was modified during the build".
   Workaround: `pkill -9 -f swift-frontend` + `rm -rf .build` + retry.

9. **SMC key map (M1 Pro)**: fans `FNum`/`F{n}Ac`/`F{n}Mx`, mode `F0Md` (uppercase;
   `Ftst` absent on macOS 26), CPU temp = max of `Tp09..Tp0c`, GPU temp `Tg05`,
   `F0Tg` = target (flt/fpe2). Fan speeds are little-endian `flt` floats.

## Current status

- Monitoring: CPU (max of 4 P-cores), GPU, RAM, battery, fans — all verified.
- Display tab: hardware brightness (Apple) + software overlay (others) + lid-closed mode.
- Keyboard Lock: see obstacles 10–13 below. Status as of 2026-08-29:
  - `relaunch()` now works via `open -n` (was silently broken).
  - `probeBlockingTap()` auto-detects stale-process state and shows relaunch prompt
    without requiring the user to click the toggle first.
  - Grant confusion with old `SystemMonitor 2.app` removed — only `SystemMonitor.app`
    exists in `dist/` now.
  - **Still unverified end-to-end** — user needs to: add `dist/SystemMonitor.app` to
    both Accessibility + Input Monitoring, click Relaunch, then toggle on.
- Fan Control: plumbing verified (socket works); **root write path not yet confirmed**
  working on macOS 26 — user still needs to test toggling "Forced" + entering password.

## Key obstacles solved (continued)

10. **`NSWorkspace.openApplication` silently failed for Relaunch** — when `relaunch()`
    called `NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, …)`, macOS
    silently refused to open a second instance of the already-running app (same bundle
    URL). The app appeared to close without reopening. Fix: use `/usr/bin/open -n <path>`
    via `Process`, which force-creates a new instance regardless of what's running.
    `NSWorkspace` with `createsNewApplicationInstance = true` is the fallback.

11. **Old `SystemMonitor 2.app` in `dist/` caused grant confusion** — a previous build
    had left `dist/SystemMonitor 2.app` alongside `dist/SystemMonitor.app`. The user
    had granted Accessibility to "SystemMonitor 2" (the old binary) thinking it was the
    current app; `dist/SystemMonitor.app` had no grants at all. `AXIsProcessTrusted()`
    therefore returned `false` even though System Settings showed a toggle ON. Fix:
    deleted `dist/SystemMonitor 2.app`. Always verify the entry in System Settings has
    **no name suffix and a blank/white icon** matching the current binary.

12. **`AXIsProcessTrusted()` / `CGPreflightListenEventAccess()` return stale values for
    running processes** — even after the user adds the app to Accessibility or Input
    Monitoring and toggles it ON in System Settings, the **currently running process**
    still gets `false` from both APIs until it is relaunched. The old `refreshTrust()`
    logic only set `needsRelaunch = false` when both returned `true`, meaning a stale
    process would never show the Relaunch prompt until the user clicked the toggle
    (which triggered `lock()` → `createTap()` → failure → `needsRelaunch = true`).
    Users saw green ✅ badges in the permission prompt but no obvious next step.
    Fix: `refreshTrust()` now calls `probeBlockingTap()` when both permissions are
    detected. If the blocking tap creation fails, `needsRelaunch = true` is set
    immediately and the Relaunch prompt appears automatically.

13. **`probeBlockingTap()` — ground-truth tap test** — added a new private helper that
    creates a real `defaultTap` (same parameters as the live lock tap) at HID-level,
    then session-level as fallback, and immediately invalidates it. This is the only
    reliable way to know whether the running process can actually lock the keyboard,
    independent of what AX/IM flag APIs report. Called by `refreshTrust()` and
    indirectly by the 1-second background poll.

14. **`make-app.sh` codesign failed with "resource fork / detritus not allowed"** —
    `xattr -cr "$APP"` was called before `cp` of the binaries, so macOS re-attached
    quarantine xattrs during the copy. Also, Finder sometimes adds `com.apple.FinderInfo`
    after the copy. Fix: run `xattr -cr` immediately before codesign (after all copies),
    and use `codesign --deep` so nested helpers (FanHelper) are also signed cleanly.

15. **Keyboard Accessibility can be OFF while System Settings appears enabled** —
    the bundled executable was checked directly with `--ax-check` and reported
    `AXIsProcessTrusted = false`, while Input Monitoring could be green. This is a
    TCC record/path identity mismatch or a stale grant, not something a CGEvent tap
    can bypass. The app now keeps a pending `needsRelaunch` state instead of losing
    it when the running process reports stale permissions, prioritizes the missing
    permission badges, and always exposes a Relaunch button after a permission
    request. The HID-open fallback was also removed because finding a built-in HID
    device was a false positive for Input Monitoring. User remediation: remove the
    existing System Monitor entry from Accessibility, add exactly
    `dist/SystemMonitor.app`, enable it, then quit/reopen the packaged app.

16. **Fan helper socket protocol deadlocked** — the app writes a command then waits
    for its reply, but the original helper waited for EOF before sending that reply.
    Each command therefore timed out and was surfaced as “SMC rejected the write.”
    Fix: the helper now reads one newline-delimited command, replies immediately,
    closes the client, and then accepts the next connection.

17. **Fan helper could not launch from a path containing spaces** — `FanRootBridge`
    passed the helper path directly to AppleScript's `do shell script`. A project
    path such as `/Users/user/Documents/Default Project/...` was split by the shell,
    so the privileged helper never started and no password prompt appeared. Fix:
    shell-quote the helper path (including safe embedded-single-quote escaping)
    before constructing the AppleScript command. Rebuild/copy both executables into
    `dist/SystemMonitor.app`, clear xattrs, and re-sign the bundle after this change.
    **Forced** means manual fan control; **Auto** returns control to macOS. This was
    verified working after the quoted-path fix.

18. **Linked manual fan control** — the UI labels manual mode as **Manual** (rather
    than Forced) and includes a **Link fans** button when more than one fan exists.
    While linked, changing either fan to Manual/Auto applies that mode to every fan;
    moving either slider writes the target to every fan. Targets are capped at the
    individual fan's reported maximum RPM, since paired fans can have different caps.

19. **Battery charge limiter uses the native macOS setting** — on Apple silicon with
    macOS Tahoe 26.4+, System Monitor exposes a `Charge Limit…` button in the battery
    card. It opens `com.apple.Battery-Settings.extension`, where the user can select
    Apple's supported 80–100% limit. Do not silently install or invoke third-party
    root-level SMC tools such as `actuallymentor/battery`; those are only appropriate
    as an explicit future advanced/optional integration for ranges or controls that
    Apple's native setting does not provide.

20. **Make Charge Limit discoverable** — do not hide the feature behind the small
    trailing Battery-card button. The card has a full-width `Set Charge Limit
    (80–100%)` button and short instruction explaining that macOS Battery settings
    opens next, where the user clicks the info button beside Charging to choose a
    native limit.

## Considerations for future sessions

- **Always check `dist/` for stale old builds** before debugging TCC issues. Any old
  `.app` bundle left there can be mistakenly granted permissions by the user.

- **TCC grants are per binary path + designated requirement.** Our signing uses
  `designated => identifier "local.sysmon.SystemMonitor"` (no cdhash), so grants
  survive rebuilds as long as `make-app.sh` is used correctly and the DR is set.
  However, if the user ever grants to a `swift run` binary or any other path, those
  grants are wasted and the correct app still needs grants.

- **Relaunch is always required after granting AX or IM to a running process.**
  `AXIsProcessTrusted()` and CGEvent blocking tap creation both reflect the state at
  process-launch time, not live TCC state. The `probeBlockingTap()` approach is the
  right gate: if it returns false, show Relaunch regardless of what the flag APIs say.

- **Input Monitoring for blocking taps (defaultTap) vs. listenOnly taps** — a
  `listenOnly` tap can be created with only Input Monitoring and no AX. A `defaultTap`
  (blocking/swallowing) requires BOTH AX and IM. `InputMonitoringDetector` uses a
  listenOnly test tap as method 1, so it can return `true` even if the blocking tap
  would still fail. `probeBlockingTap()` uses `defaultTap` specifically to avoid this
  false-positive.

- **`open -n` vs `NSWorkspace.openApplication`** — always use `open -n <path>` (via
  `Process`) when relaunching self. `NSWorkspace.openApplication` without
  `createsNewApplicationInstance = true` silently no-ops on the same running bundle.
  Even with that flag set, it can be unreliable. `open -n` is the UNIX-level command
  and is the most reliable for force-new-instance launches.

- **Keyboard lock end-to-end flow (correct):**
  1. Build + sign: `./scripts/make-app.sh`
  2. Open `dist/SystemMonitor.app` (not `swift run`)
  3. System Settings → Privacy & Security → Accessibility → `+` → add
     `dist/SystemMonitor.app` → toggle ON
  4. System Settings → Privacy & Security → Input Monitoring → `+` → add
     `dist/SystemMonitor.app` → toggle ON
  5. Back in app → Keyboard tab → click **"Check again"** if badges not ✅
  6. Click **"Relaunch App"** (orange button) — app closes + reopens
  7. Toggle **Keyboard Lock ON** → locked 🔒

## Next (roadmap)

1. **Verify keyboard lock end-to-end** — follow the 7-step flow above after the latest
   build. If the relaunch prompt doesn't appear automatically after granting both perms,
   click "Check again" to force `refreshTrust()` → `probeBlockingTap()`.
2. Mouse control (public API: `com.apple.mouse.scaling` etc.).
3. Per-app volume (private `AudioHardware` — hardest, port BackgroundMusic approach).
4. DDC/CI for monitors that do expose it (probe passed here, HP does not).
5. Polish: proper app icon, notarization, stable signing cert (replace identifier-only
   ad-hoc), reduce rebuild-deadlock exposure.
