import AppKit
import Foundation
import SiverCore

/// F7 Anti-AFK Pulse: one harmless input every 12–17 minutes, never while the user is using the Mac,
/// and always through Guardian.
public final class AntiAFK: @unchecked Sendable {
    public struct Config: Codable, Equatable, Sendable {
        public var enabled = true
        public var minIntervalS: Double = 12 * 60
        public var maxIntervalS: Double = 17 * 60
        /// Wait until the Mac has been untouched this long.
        public var userIdleS: Double = 10
        public var key = "space"
        /// `toProcess` (CGEvent.postToPid) was verified on a real Mac on 2026-11-18: Roblox takes the key in the
        /// background, so no focus change is needed. `hid` (bring Roblox forward for a moment) is the fallback.
        public var delivery: InputDriver.Delivery = .toProcess
        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case pulsed(InputDriver.Delivery)
        case skipped(String)
        case blocked(String)
    }

    public var config: Config
    private let guardian: Guardian
    private let input: InputDriver
    /// Set by the panic key. No pulses while true.
    public var paused: @Sendable () -> Bool = { false }
    public var onOutcome: (@Sendable (Outcome) -> Void)?
    public private(set) var lastPulseAt: Date?

    public init(config: Config = Config(), guardian: Guardian, input: InputDriver) {
        self.config = config; self.guardian = guardian; self.input = input
    }

    /// Runs until cancelled.
    public func run() async {
        while !Task.isCancelled {
            let wait = Double.random(in: config.minIntervalS...max(config.minIntervalS, config.maxIntervalS))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { break }
            guard config.enabled, !paused() else { continue }
            // The focus-swap path must not fight the user for the keyboard: wait (up to 2 minutes) for a quiet moment.
            // Background delivery changes nothing they can see, so it goes out on time even while they work.
            var waited = 0.0
            while config.delivery == .hid && input.userIdleSeconds() < config.userIdleS && waited < 120 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000); waited += 1
            }
            var outcome = await pulse()
            onOutcome?(outcome)
            if case .blocked = outcome {
                // Most blocks are short (a roll cutscene). Try once more in a minute rather than waiting a full cycle.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                outcome = await pulse()
                onOutcome?(outcome)
            }
        }
    }

    /// One pulse, right now. Also used by `siversolctl afk pulse`.
    public func pulse(ignoreUserActivity: Bool = false) async -> Outcome {
        guard !paused() else { return .skipped("automation is paused") }
        guard InputDriver.isTrusted else { return .skipped("Accessibility is not allowed for this app") }
        guard let roblox = FocusManager.robloxApp(), RobloxWindowFinder.mainWindow() != nil else { return .skipped("Roblox window not found") }
        if config.delivery == .hid, !ignoreUserActivity, input.userIdleSeconds() < config.userIdleS { return .skipped("the Mac is in use") }
        guard let key = Key(rawValue: config.key) else { return .skipped("unknown key \(config.key)") }
        switch await guardian.approve(.key(key.rawValue)) {
        case .approved: break
        case .blocked(let reason, _), .held(let reason): return .blocked(reason)
        }

        let pid = roblox.processIdentifier
        switch config.delivery {
        case .toProcess:
            await input.tap(key, delivery: .toProcess, pid: pid, yieldToUser: false)
        case .hid:
            let done = await FocusManager.withRobloxFrontmost {
                await self.input.tap(key, delivery: .hid, pid: pid)
            }
            guard let done else { return .skipped("Roblox would not come to the front") }
            if !done { input.releaseAll(pid: pid); return .skipped("the Mac was touched, so the key press was cut short") }
        }
        lastPulseAt = Date()
        return .pulsed(config.delivery)
    }
}
