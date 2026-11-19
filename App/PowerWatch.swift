import AppKit
import SiverCore
import SiverEngine

/// Low Power Mode and heat. While either is on, SiverSol's decoration stands still: the sky becomes a still
/// picture and the island stops animating. Nothing that watches the game changes its timing.
@MainActor
final class PowerWatch: ObservableObject {
    static let shared = PowerWatch()

    /// True in Low Power Mode or when the Mac reports a serious or critical thermal state.
    @Published private(set) var saving = false
    /// Set by the design review to photograph (and measure) the laptop profile on a Mac that is neither.
    var simulate: Bool? { didSet { update() } }
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    private func update() {
        let info = ProcessInfo.processInfo
        let thermal: PowerSaving.Thermal
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        let now = simulate ?? PowerSaving.decorationStill(lowPowerMode: info.isLowPowerModeEnabled, thermal: thermal)
        guard now != saving else { return }
        saving = now
        SkyState.shared.powerStill = now
    }

    /// Is this Mac a MacBook (does it have an internal battery)?
    static let isLaptop: Bool = PowerSource.read().hasBattery
}
