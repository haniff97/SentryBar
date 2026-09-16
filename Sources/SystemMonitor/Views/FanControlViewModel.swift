import SwiftUI

struct FanState: Identifiable {
    let id: Int
    var mode: Int
    var target: Int
    var max: Int
}

/// Wraps `FanController` for the UI. All SMC writes happen on a serial
/// background queue so the popover stays responsive (unlock can block for
/// several seconds).
final class FanControlViewModel: ObservableObject {
    @Published private(set) var fans: [FanState] = []
    @Published private(set) var isBusy = false
    /// When enabled, mode and target changes made from either fan apply to all fans.
    @Published private(set) var areFansLinked = false
    @Published var statusMessage: String?

    private let controller: FanController?
    private let queue = DispatchQueue(label: "fan-control-ui")

    init(controller: FanController?) {
        self.controller = controller
    }

    func refresh() {
        guard let controller else { return }
        queue.async { [weak self] in
            let states = self?.makeStates(controller: controller) ?? []
            DispatchQueue.main.async {
                self?.fans = states
                if states.isEmpty {
                    self?.statusMessage = "No controllable fans on this machine."
                }
            }
        }
    }

    func setMode(_ id: Int, forced: Bool) {
        guard let controller else { return }
        let fanIDs = areFansLinked ? fans.map(\.id) : [id]
        setBusy(true)
        queue.async { [weak self] in
            let ok = fanIDs.allSatisfy { fanID in
                forced ? controller.forceMode(fan: fanID) : controller.setAutomatic(fan: fanID)
            }
            DispatchQueue.main.async {
                self?.apply(ok: ok) { states in
                    for index in states.indices where fanIDs.contains(states[index].id) {
                        states[index].mode = forced ? 1 : 0
                        if !forced {
                            states[index].target = Int(controller.actualRPM(states[index].id) ?? 0)
                        }
                    }
                }
                self?.setBusy(false)
            }
        }
    }

    func setTarget(_ id: Int, rpm: Int) {
        guard let controller else { return }
        let targets: [(id: Int, rpm: Int)]
        if areFansLinked {
            // Fan models may have different maximums; never request a value above
            // the maximum reported for the individual fan.
            targets = fans.map { (id: $0.id, rpm: min(rpm, $0.max)) }
        } else {
            targets = [(id: id, rpm: rpm)]
        }
        queue.async { [weak self] in
            let ok = targets.allSatisfy { controller.setTargetRPM(fan: $0.id, rpm: $0.rpm) }
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    for target in targets {
                        if let index = self.fans.firstIndex(where: { $0.id == target.id }) {
                            self.fans[index].target = target.rpm
                        }
                    }
                } else {
                    self.statusMessage = "Fan control failed — the SMC rejected the write."
                }
            }
        }
    }

    func toggleFansLinked() {
        guard fans.count > 1 else { return }
        areFansLinked.toggle()
        statusMessage = nil
    }

    func resetAll() {
        guard let controller else { return }
        setBusy(true)
        queue.async { [weak self] in
            let ok = controller.resetAllToAutomatic()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(ok: ok) { states in
                    for i in states.indices {
                        states[i].mode = 0
                        states[i].target = Int(controller.actualRPM(i) ?? 0)
                    }
                }
                self.setBusy(false)
            }
        }
    }

    // MARK: - Internals

    private func setBusy(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isBusy = value
            if value { self?.statusMessage = nil }
        }
    }

    private func makeStates(controller: FanController) -> [FanState] {
        let count = controller.fanCount()
        return (0..<count).map { i in
            FanState(id: i,
                     mode: controller.mode(i) ?? 0,
                     target: Int(controller.actualRPM(i) ?? 0),
                     max: Int(controller.maxRPM(i) ?? 5000))
        }
    }

    private func apply(ok: Bool, mutate: (inout [FanState]) -> Void) {
        if !ok {
            statusMessage = "Fan control failed — the SMC rejected the write."
            return
        }
        var states = fans
        mutate(&states)
        fans = states
    }
}
