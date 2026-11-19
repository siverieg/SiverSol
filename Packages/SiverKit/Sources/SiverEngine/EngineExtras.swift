import AppKit
import Foundation
import SiverCore
import SiverInput
import SiverNotify
import SiverVision

/// The permission-free extras (Phase C). Everything here uses only: the log, NSWorkspace, window bounds,
/// libproc statistics, NWPathMonitor, ProcessInfo, URLSession and NSSound.
extension SiverEngine {
    // MARK: read-only views for the UI

    public var sessionInfo: SessionInfo { extra.session }
    public var logLabEntries: [LogLabEntry] { extra.logLab }
    public var unknownSignals: [String: Int] { extra.unknownSignals }
    public var resourceSamples: [ResourceSample] { extra.resourceSamples }
    public var networkTimeline: [NetworkChange] { network.timeline }
    public var windowWarning: String? { extra.windowWarning }
    /// Seconds left of the current roll cutscene (0 when none).
    public var cutsceneRemaining: TimeInterval { extra.cutsceneRemaining() }

    /// The next daily reset: the game's own print when it is still ahead, otherwise the next 00:00 UTC.
    public func nextDailyReset(now: Date = Date()) -> Date {
        if let fromGame = extra.session.dailyResetAt, fromGame > now { return fromGame }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.startOfDay(for: now).addingTimeInterval(86400)
    }

    public func biomeIntel(now: Date = Date()) -> BiomeIntel {
        BiomeIntel.compute(events: timeline.events(day: TimelineStore.day(now)), now: now)
    }

    // MARK: wiring

    func startExtras() {
        let extra = self.extra
        let lockOn = options.extras.cutsceneLock
        guardian.hold = { lockOn && extra.cutsceneRemaining() > 0 ? "a roll cutscene is playing" : nil }
        if options.extras.networkSentinel {
            network.onChange = { [weak self] change in
                self?.onLog?(change.online ? "network: back online (\(change.interface))" : "network: connection dropped")
            }
            network.start()
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.extrasTick()
            }
        })
    }

    /// Split a batch into what is announced now and what needs special handling (rolls, duplicate equips).
    func applyRollFeed(to events: [SiverEvent]) -> [SiverEvent] {
        var out: [SiverEvent] = []
        for event in events {
            switch event {
            case .auraRolled(let roll):
                extra.noteRoll(roll.name, at: roll.at)
                if options.extras.cutsceneLock { extra.lockForCutscene(until: roll.at.addingTimeInterval(roll.cutsceneSeconds)) }
                playSoundCue()
                guard options.extras.auraRollFeed else { continue }
                // Announced after the screenshot at the cutscene's best moment, not right now.
                tasks.append(Task { [weak self] in await self?.announceRoll(roll) })
            case .auraEquipped(let equip) where !equip.initial && options.extras.auraRollFeed && extra.wasJustRolled(equip.internalName, at: equip.at):
                continue   // the roll announcement already covers this aura
            case .biomeStarted(let s) where !s.wasRunning && catalog.isRare(s.biome.key):
                playSoundCue()
                out.append(event)
            case .auraEquipped(let equip) where !equip.initial && (auras.chance(for: equip.internalName) ?? 0) >= options.proof.auraChanceAtLeast:
                playSoundCue()
                out.append(event)
            default:
                out.append(event)
            }
        }
        return out
    }

    private func announceRoll(_ roll: AuraRolled) async {
        let shotAt = roll.at.addingTimeInterval(Double(roll.captureDelayMs ?? 0) / 1000)
        let wait = shotAt.timeIntervalSinceNow
        // A roll found late (the Mac was asleep) is announced without waiting.
        if wait > 0, wait < 120 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        var attachments: [String: [String]] = [:]
        if options.proof.enabled, abs(shotAt.timeIntervalSinceNow) < 20, let path = await takeProofShot(name: roll.id) {
            attachments[roll.id] = [path]
        }
        await mesh.handle(batch: [.auraRolled(roll)], attachments: attachments)
    }

    func playSoundCue() {
        guard options.extras.soundCue else { return }
        DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
    }

    // MARK: periodic checks (every 5 s)

    func extrasTick() async {
        let now = Date()
        let snap = radar.snapshot
        extra.setClientVersion(snap.clientVersion)
        let x = options.extras
        macros.tick(now: now)
        // Daily reset trigger for macros: fires once when the reset time passes.
        let resetMark = "macro-reset-\(TimelineStore.day(now))"
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        if now.timeIntervalSince(cal.startOfDay(for: now)) < 60, isRunning, extra.raise(resetMark) { macros.dailyReset() }

        if x.batteryGuard, let alert = extra.noteBattery(PowerSource.read(), now: now) {
            let low: Bool
            if case .low = alert { low = true } else { low = false }
            await postStatus(RichTemplates.info(title: low ? "Battery is getting low" : "Running on battery",
                                                text: "\(alert.sentence). SiverSol keeps watching; plug in when you can.", color: 0xFFCC00),
                             id: "battery-\(low ? "low" : "on")-\(Int(now.timeIntervalSince1970 / 600))")
            onPowerAlert?(alert)
            onLog?("power: \(alert.sentence)")
        }

        if x.resourceMonitor, let pid = RobloxWindowFinder.mainWindow()?.pid ?? FocusManager.robloxApp()?.processIdentifier,
           RobloxWindowFinder.gameIsOpen, let usage = ProcessStats.usage(pid: pid) {
            let sample = extra.addSample(pid: pid, memory: usage.memory, cpuNs: usage.cpuNs, at: now)
            if sample.memoryGB >= x.memoryAlertGB {
                if extra.raise("memory-high") {
                    let rare = snap.current.map { catalog.isRare($0.biome.key) } ?? false
                    let willRejoin = x.memoryAutoRejoin && !rare
                    await postStatus(RichTemplates.info(title: "📈 Roblox is using a lot of memory",
                                                        text: String(format: "Roblox is at **%.1f GB** (your limit is %.1f GB). %@", sample.memoryGB, x.memoryAlertGB,
                                                                     willRejoin ? "Rejoining to free it." : (x.memoryAutoRejoin ? "A rare biome is active, so Roblox is left alone." : "Rejoining usually frees it; SiverSol can do that for you if you turn on auto-rejoin on high memory.")),
                                                        color: 0xFFCC00), id: "memory-\(Int(now.timeIntervalSince1970 / 1800))")
                    if willRejoin { await handle(.memoryHigh(gigabytes: sample.memoryGB)) }
                }
            } else if sample.memoryGB < x.memoryAlertGB * 0.9 {
                extra.lower("memory-high")
            }
        }

        if x.windowGuard {
            var warning: String?
            if !NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId).isEmpty {
                if let w = RobloxWindowFinder.mainWindow() {
                    if w.bounds.width < 800 || w.bounds.height < 600 {
                        warning = "The Roblox window is small (\(Int(w.bounds.width))×\(Int(w.bounds.height))). On-screen text is read reliably from about 960×900 up."
                    }
                } else if RobloxWindowFinder.hasGameWindow() {
                    warning = "The Roblox window is minimized or hidden. Biome alerts keep working; screenshots, merchant reading and clicks are paused."
                }
            }
            if warning != extra.windowWarning {
                extra.windowWarning = warning
                if let warning { onLog?("window guard: \(warning)") }
            }
        }

        if x.updateWatch, let running = snap.clientVersion {
            let previous = outbox.meta("client.version")
            if previous != running {
                outbox.setMeta("client.version", running)
                if previous != nil {
                    await postStatus(RichTemplates.info(title: "⬆️ Roblox updated to \(running)",
                                                        text: "The client was \(previous!) before. If something looks off after an update, check that biome alerts still arrive.",
                                                        color: 0x5865F2), id: "client-\(running)")
                }
            }
            let info = extra.session
            if info.updatePending, let offered = info.offeredVersion ?? Optional("a newer version"), outbox.meta("update.warned") != offered {
                outbox.setMeta("update.warned", offered)
                await postStatus(RichTemplates.info(title: "🕓 A Roblox update is waiting",
                                                    text: "The update server offers **\(offered)**; this session runs \(running). The next time Roblox starts it will update first, which makes that rejoin slower.",
                                                    color: 0xFFCC00), id: "update-pending-\(offered)")
            }
        }

        if x.menuSentinel, let since = snap.menuSince, now.timeIntervalSince(since) >= 120 {
            if extra.raise("menu-stuck") {
                await postStatus(RichTemplates.actionNeeded("Open Roblox and click **Play** on the Sol's RNG title screen.",
                                                            detail: "The game has been on its title screen for over 2 minutes and SiverSol could not get past it by itself (it needs Screen Recording and Accessibility to click Play, and a visible Roblox window)."),
                                 id: "menu-stuck-\(Int(since.timeIntervalSince1970))")
            }
        } else {
            extra.lower("menu-stuck")
        }

        if x.dailyResetPing {
            let reset = nextDailyReset(now: now)
            let left = reset.timeIntervalSince(now)
            if left <= 600, left > 0, extra.raise("reset-\(Int(reset.timeIntervalSince1970))") {
                await postStatus(RichTemplates.info(title: "⏰ Daily reset in 10 minutes",
                                                    text: "Sol's RNG resets its daily things \(DiscordTime.tag(reset, "R")) (\(DiscordTime.tag(reset, "t"))).", color: 0x5865F2),
                                 id: "daily-reset-\(Int(reset.timeIntervalSince1970))")
            }
        }
    }

    /// Post an informational message to every Rich route that carries status messages.
    func postStatus(_ message: DiscordMessage, id: String) async {
        for route in config.routes where route.wants(.status) && route.profile == .rich {
            await mesh.post(message, route: route.name, id: id)
        }
    }

    /// One line for the Live Session Card and the dashboard: where we are and for how long.
    public func sessionLine(now: Date = Date()) -> String? {
        let info = extra.session
        guard options.extras.sessionInspector, info.joinedAt != nil || info.clientVersion != nil else { return nil }
        var parts: [String] = []
        if let kind = info.joinKind { parts.append(kind.label) }
        if let joined = info.joinedAt { parts.append("joined \(DiscordTime.tag(joined, "R"))") }
        if info.teleports > 0 { parts.append("\(info.teleports) teleport\(info.teleports == 1 ? "" : "s")") }
        if info.joins > 1 { parts.append("\(info.joins) joins") }
        if let v = info.clientVersion { parts.append("client \(v)") }
        return parts.joined(separator: " · ")
    }
}
