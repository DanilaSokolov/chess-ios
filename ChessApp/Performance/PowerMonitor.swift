import ChessClient
import Foundation
import Observation
import os

/// Watches how hot the device is and whether Low Power Mode is on, and turns
/// both into a `RenderQuality` for the 3D board.
///
/// The system posts a notification on every change; there is nothing to poll.
/// To try it on an iPhone: Xcode → Window → Devices and Simulators → the
/// device → Device Conditions → Thermal State. The simulator runs on the Mac's
/// processor and never reports heat, so debug builds take a launch argument
/// instead (Edit Scheme → Run → Arguments, or `xcrun simctl launch`):
///
///     -simulateThermalState serious     nominal, fair, serious or critical
///     -simulateLowPowerMode YES
@MainActor
@Observable
final class PowerMonitor {
    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var isLowPowerMode: Bool

    var quality: RenderQuality {
        RenderQuality(thermalState: thermalState, isLowPowerMode: isLowPowerMode)
    }

    @ObservationIgnored private let observers = Observers()

    init() {
        (thermalState, isLowPowerMode) = Self.read()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            // Posted on a background thread; `.main` brings the block to the main thread,
            // and `assumeIsolated` tells the compiler that is where it runs.
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        report()
    }

    private func refresh() {
        let (thermal, lowPower) = Self.read()
        guard thermal != thermalState || lowPower != isLowPowerMode else { return }
        thermalState = thermal
        isLowPowerMode = lowPower
        report()
    }

    /// One mark on the Instruments timeline and one line in the log per change.
    private func report() {
        let state = thermalState.name
        let lowPower = isLowPowerMode
        let quality = quality
        Signposts.poi.emitEvent(
            "Thermal state", "\(state, privacy: .public), low power: \(lowPower), quality: \(quality.rawValue)")
        Signposts.log.info(
            "thermal state \(state, privacy: .public), low power \(lowPower), 3D quality \(String(describing: quality), privacy: .public)"
        )
    }

    private static func read() -> (ProcessInfo.ThermalState, Bool) {
        let info = ProcessInfo.processInfo
        var thermal = info.thermalState
        var lowPower = info.isLowPowerModeEnabled
        #if DEBUG
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "simulateThermalState"),
                let simulated = ProcessInfo.ThermalState.allCases.first(where: { $0.name == name })
            {
                thermal = simulated
            }
            if defaults.object(forKey: "simulateLowPowerMode") != nil {
                lowPower = defaults.bool(forKey: "simulateLowPowerMode")
            }
        #endif
        return (thermal, lowPower)
    }
}

/// Unsubscribes when the monitor goes away. A separate object, because a
/// main-actor class's own `deinit` may run on any thread and cannot touch its state.
nonisolated private final class Observers {
    var tokens: [any NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

extension ProcessInfo.ThermalState {
    static let allCases: [Self] = [.nominal, .fair, .serious, .critical]

    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
