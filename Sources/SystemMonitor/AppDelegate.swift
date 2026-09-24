import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = MonitorService()
    let displays = DisplaysProvider()
    let fanControl: FanControlViewModel
    private var statusItem: NSStatusItem?
    private let statusView = StatusContentView()
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

    override init() {
        if let smc = monitor.smc {
            fanControl = FanControlViewModel(controller: FanController(smc: smc))
        } else {
            fanControl = FanControlViewModel(controller: nil)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView.onClick = { [weak self] in self?.togglePopover(nil) }
        statusView.onRightClick = { [weak self] in self?.showContextMenu() }
        item.view = statusView
        statusItem = item

        let hosting = NSHostingController(rootView: PopoverView(monitor: monitor, displays: displays, fanControl: fanControl))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(openSettings),
                                               name: .openSettings,
                                               object: nil)

        // Live status-bar title based on settings.
        let render = { [weak self] in self?.renderStatusTitle() }
        monitor.$metrics
            .receive(on: RunLoop.main)
            .sink { _ in render() }
            .store(in: &cancellables)
        AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in DispatchQueue.main.async { self.updateBrightnessShortcuts() } }
            .store(in: &cancellables)
        KeyboardLock.shared.$isLocked
            .receive(on: RunLoop.main)
            .sink { _ in render() }
            .store(in: &cancellables)

        monitor.start()
        displays.refresh() // restore saved display brightness on launch
        updateBrightnessShortcuts()
        render()
    }

    private func updateBrightnessShortcuts() {
        if AppSettings.shared.brightnessShortcuts {
            BrightnessShortcuts.shared.start(displays: displays)
        } else {
            BrightnessShortcuts.shared.stop()
        }
    }

    private func renderStatusTitle() {
        let m = monitor.metrics
        if KeyboardLock.shared.isLocked {
            statusView.update(icon: "lock.fill", lines: ["LOCKED"], bold: false)
            return
        }

        var lines: [String] = []
        var bold = false
        switch AppSettings.shared.menuBarContent {
        case .iconOnly:
            lines = []
        case .cpuUsage:
            lines = ["\(Int((m.cpuUsage * 100).rounded()))%"]
        case .cpuTemp:
            lines = [m.cpuTemp.map { "\(Int($0.rounded()))°C" } ?? ""]
        case .cpuUsageTemp:
            var parts = ["\(Int((m.cpuUsage * 100).rounded()))%"]
            if let temp = m.cpuTemp { parts.append("\(Int(temp.rounded()))°C") }
            lines = [parts.joined(separator: " ")]
        case .cpuTempFan:
            var top: [String] = []
            if let temp = m.cpuTemp { top.append("\(Int(temp.rounded()))°C") }
            if let gpu = m.gpuTemp { top.append("\(Int(gpu.rounded()))°C") }
            lines = [top.joined(separator: " / ")]
            if let maxFan = m.fanSpeeds.max() { lines.append("\(Int(maxFan.rounded())) RPM") }
            bold = lines.count > 1
        case .fanRPM:
            if let maxFan = m.fanSpeeds.max() {
                lines = ["\(Int(maxFan.rounded())) RPM"]
            } else {
                lines = ["fan n/a"]
            }
        case .battery:
            lines = [m.batteryPercent.map { "\($0)%" } ?? "no battery"]
        }

        statusView.update(icon: "cpu", lines: lines, bold: bold)
    }

    // MARK: - Menu bar interactions

    private func showContextMenu() {
        let menu = NSMenu()
        addItem(menu, "SentryBar", #selector(togglePopover))
        menu.addItem(.separator())
        addItem(menu, KeyboardLock.shared.isLocked ? "Unlock Keyboard" : "Lock Keyboard",
                #selector(toggleKeyboardLock))
        addItem(menu, LidClosedMode.shared.enabled ? "Disable Keep Awake" : "Enable Keep Awake",
                #selector(toggleKeepAwake))
        addItem(menu, "Reset Fans to Auto", #selector(resetFansToAuto))
        addItem(menu, "Charge Limit…", #selector(openChargeLimit))
        menu.addItem(.separator())
        addItem(menu, "Settings…", #selector(openSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SentryBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: StatusContentView.menuBarHeight + 5), in: statusView)
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleKeyboardLock() {
        if KeyboardLock.shared.isLocked {
            KeyboardLock.shared.unlock()
        } else {
            KeyboardLock.shared.lock()
        }
    }

    @objc private func toggleKeepAwake() {
        LidClosedMode.shared.setEnabled(!LidClosedMode.shared.enabled)
    }

    @objc private func resetFansToAuto() {
        fanControl.resetAll()
    }

    @objc private func openChargeLimit() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            displays.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
            startOutsideClickMonitor()
        }
    }

    /// Closes the popover when the user clicks anywhere outside the app
    /// (desktop, other apps, other menu-bar items). The `.transient` behavior
    /// alone is unreliable for accessory apps that aren't activated.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "SentryBar Settings"
            window.styleMask = [.titled, .closable]
            window.animationBehavior = .none
            window.setContentSize(NSSize(width: 380, height: 320))
            window.minSize = NSSize(width: 360, height: 300)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SoftwareBrightness.shared.removeAll()
        KeyboardLock.shared.unlock()
    }
}
