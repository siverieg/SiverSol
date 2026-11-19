import Foundation

/// What the Mac is running on. Read from IOKit's power source list (`IOPSCopyPowerSourcesInfo`), which needs no
/// permission. A Mac without an internal battery (a Mac mini, an iMac, a Studio) is never "on battery".
public struct PowerReading: Equatable, Sendable {
    /// True on a MacBook: there is an internal battery.
    public var hasBattery: Bool
    public var onBattery: Bool
    public var percent: Int?
    /// Minutes until empty as the system estimates it; nil while it is still working that out.
    public var minutesLeft: Int?

    public init(hasBattery: Bool, onBattery: Bool, percent: Int? = nil, minutesLeft: Int? = nil) {
        self.hasBattery = hasBattery; self.onBattery = onBattery; self.percent = percent; self.minutesLeft = minutesLeft
    }

    public static let desktop = PowerReading(hasBattery: false, onBattery: false)

    /// `sources`: the dictionaries IOKit describes each power source with.
    public static func parse(_ sources: [[String: Any]]) -> PowerReading {
        guard let battery = sources.first(where: { ($0["Type"] as? String) == "InternalBattery" && ($0["Is Present"] as? Bool ?? true) }) else { return .desktop }
        var reading = PowerReading(hasBattery: true, onBattery: (battery["Power Source State"] as? String) == "Battery Power")
        if let now = battery["Current Capacity"] as? Int, let full = battery["Max Capacity"] as? Int, full > 0 {
            reading.percent = min(100, max(0, Int((Double(now) / Double(full) * 100).rounded())))
        }
        if reading.onBattery, let minutes = battery["Time to Empty"] as? Int, minutes > 0 { reading.minutesLeft = minutes }
        return reading
    }
}

/// Battery guard: says so, calmly and once, when a MacBook that is watching goes on battery, and once more if
/// it then drops below 20%. Plugging back in resets it.
public struct BatteryGuard: Sendable {
    public enum Alert: Equatable, Sendable {
        case onBattery(percent: Int?, minutesLeft: Int?)
        case low(percent: Int, minutesLeft: Int?)

        /// "Your MacBook is on battery, 18%, about 40 min left"
        public var sentence: String {
            switch self {
            case .onBattery(let percent, let minutes):
                return (["Your MacBook is on battery"] + [percent.map { "\($0)%" }, minutes.map { "about \(Self.time($0)) left" }].compactMap { $0 }).joined(separator: ", ")
            case .low(let percent, let minutes):
                return (["Your MacBook is down to \(percent)% on battery"] + [minutes.map { "about \(Self.time($0)) left" }].compactMap { $0 }).joined(separator: ", ")
            }
        }

        /// A few words for the island.
        public var short: String {
            switch self {
            case .onBattery(let percent, _): return percent.map { "On battery · \($0)%" } ?? "On battery"
            case .low(let percent, _): return "Battery \(percent)%"
            }
        }

        static func time(_ minutes: Int) -> String {
            minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        }
    }

    public var lowPercent = 20
    /// A loose cable must not send an alert every few seconds.
    public var quietSeconds: TimeInterval = 600
    private var wasOnBattery = false
    private var lowSent = false
    private var lastAlert: Date?

    public init() {}

    public mutating func note(_ r: PowerReading, now: Date = Date()) -> Alert? {
        guard r.hasBattery else { return nil }
        guard r.onBattery else {
            wasOnBattery = false
            lowSent = false
            return nil
        }
        let low = r.percent.map { $0 < lowPercent } ?? false
        if !wasOnBattery {
            wasOnBattery = true
            if let lastAlert, now.timeIntervalSince(lastAlert) < quietSeconds { return nil }
            lastAlert = now
            // Unplugged and already low: one message says both.
            if low, let percent = r.percent { lowSent = true; return .low(percent: percent, minutesLeft: r.minutesLeft) }
            return .onBattery(percent: r.percent, minutesLeft: r.minutesLeft)
        }
        if low, !lowSent, let percent = r.percent {
            lowSent = true
            lastAlert = now
            return .low(percent: percent, minutesLeft: r.minutesLeft)
        }
        return nil
    }
}

/// When the Mac is saving energy or running hot, SiverSol's own decoration stands still: the sky becomes a
/// still picture and the island stops animating. Reading the log, the screen checks and Discord keep their
/// timing; none of that is decoration.
public enum PowerSaving {
    public enum Thermal: Int, Sendable { case nominal, fair, serious, critical }

    public static func decorationStill(lowPowerMode: Bool, thermal: Thermal) -> Bool {
        lowPowerMode || thermal.rawValue >= Thermal.serious.rawValue
    }
}

/// What to tell someone the first time SiverSol runs on a MacBook.
public enum LaptopNotes {
    public static let lidTitle = "Closing the lid"
    public static let lid = "A MacBook sleeps when its lid is closed, and a sleeping Mac cannot watch the sky. It only stays awake with the lid shut when it is plugged into power and an external display (clamshell mode). With the lid open SiverSol keeps the Mac awake while it watches; you can still let the display turn off."
}
