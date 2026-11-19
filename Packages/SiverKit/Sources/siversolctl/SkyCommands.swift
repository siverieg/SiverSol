import CoreGraphics
import Foundation
import ImageIO
import SiverCore
import SiverInput
import SiverNotify
import SiverSky
import SiverVision
import UniformTypeIdentifiers

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// `sky --biome RAINY --hour 23 [--dark] [--still] [--time 3] [--size 1120x740] --out file.png`
/// `sky --sheet --hour 13 [--dark] --out sheet.png` draws every catalog biome side by side.
/// Development only: it shows what the app's sky looks like without opening the app.
func skyCommand(_ args: Args) {
    guard let renderer = SkyRenderer() else { fail("no Metal renderer: \(SkyRenderer.lastError)") }
    let catalog = (try? BiomeCatalog.bundled()) ?? BiomeCatalog(builtIn: [])
    let hour = Double(args.value("hour") ?? "13") ?? 13
    let dark = args.flag("dark")
    let time = Double(args.value("time") ?? "7.3") ?? 7.3
    let out = args.value("out") ?? "/tmp/siversol/sky.png"
    var size = CGSize(width: 1120, height: 740)
    if let s = args.value("size"), let x = s.firstIndex(of: "x"), let w = Double(s[..<x]), let h = Double(s[s.index(after: x)...]) {
        size = CGSize(width: w, height: h)
    }
    func scene(_ key: String, in size: CGSize) -> SkyScene {
        let info = catalog.info(for: BiomeKey(key))
        let look = SkyModel.look(info.palette, hour: hour, dark: dark)
        var s = SkyScene(look: look, motion: !args.flag("still"))
        if let from = args.value("from") {
            s.from = SkyModel.look(catalog.info(for: BiomeKey(from)).palette, hour: hour, dark: dark)
            s.mix = Double(args.value("mix") ?? "0.5") ?? 0.5
        }
        if !args.flag("no-arc") {
            let hero = CGRect(x: size.width * 0.24, y: size.height * 0.14, width: size.width * 0.70, height: size.height * 0.24)
            s.arc = SkyArc.fitting(hero)
            s.body = look.night > 0.5 ? .moon : .sun
            s.bodyProgress = Double(args.value("progress") ?? "0.3") ?? 0.3
            s.rare = info.isRare
            if let shock = args.value("shock") { s.shock = Double(shock) }
        }
        // A rare sky surprise, to look at the drawing (developer tool only).
        switch args.value("egg") ?? "" {
        case "star": s.eggs.star = 0.55
        case "rainbow": s.eggs.rainbow = 1
        case "aurora": s.eggs.aurora = 1
        case "retro": s.eggs.retro = 1
        case "gold": s.eggs.gold = 1
        case "twin": s.eggs.twinMoon = 1
        case "bats": s.eggs.bats = 1
        case "fireworks": s.eggs.fireworks = 1.3
        default: break
        }
        return s
    }
    if args.flag("sheet") {
        let keys = catalog.all.map(\.key.value)
        let cell = CGSize(width: 420, height: 278), cols = 4
        let rows = (keys.count + cols - 1) / cols
        guard let ctx = CGContext(data: nil, width: Int(cell.width) * cols, height: Int(cell.height) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { fail("no context") }
        for (i, key) in keys.enumerated() {
            guard let image = renderer.image(scene(key, in: size), time: time, size: size, scale: 1) else { continue }
            let x = CGFloat(i % cols) * cell.width, y = CGFloat(rows - 1 - i / cols) * cell.height
            ctx.draw(image, in: CGRect(x: x, y: y, width: cell.width, height: cell.height))
        }
        if let image = ctx.makeImage() { writePNG(image, to: out) }
        print("sheet: \(keys.joined(separator: ", "))")
    } else {
        let key = args.value("biome") ?? "NORMAL"
        guard let image = renderer.image(scene(key, in: size), time: time, size: size, scale: CGFloat(Double(args.value("scale") ?? "1") ?? 1)) else { fail("render failed") }
        writePNG(image, to: out)
    }
    print("wrote \(out)")
}

/// `moment --seconds 6 --out DIR [--bitrate N] [--post]`: record a test clip of the Roblox window.
/// With `--post` the clip goes to the test route marked 🧪 (never to a hunt route), to check what Discord accepts.
func momentCommand(_ args: Args) async {
    guard let window = RobloxWindowFinder.mainWindow() else { fail("no Roblox window on screen") }
    let seconds = Double(args.value("seconds") ?? "6") ?? 6
    let dir = URL(fileURLWithPath: args.value("out") ?? "/tmp/siversol/moments", isDirectory: true)
    let store = MomentsStore(directory: dir)
    try? store.createDirectory()
    let at = Date()
    let id = MomentsStore.baseName(kind: .roll, title: "Test clip", at: at)
    let bitrate = Int(args.value("bitrate") ?? "") ?? MomentsStore.bitrate(seconds: seconds, maxBytes: nil)
    let started = Date()
    do {
        let r = try await MomentRecorder.record(.init(windowId: window.windowId, seconds: seconds, bitrate: bitrate, output: store.videoURL(id), thumbnail: store.thumbnailURL(id)))
        let moment = Moment(id: id, kind: .roll, title: "Test clip", detail: "test", biome: nil, at: at, seconds: r.seconds, bytes: r.bytes, eventId: nil)
        try? store.save(moment)
        print(String(format: "saved %@: %.1f s, %d frames, %dx%d, %.2f MB, took %.1f s", r.url.lastPathComponent, r.seconds, r.frames, r.width, r.height, Double(r.bytes) / 1_048_576, Date().timeIntervalSince(started)))
        if args.flag("post") {
            let rig = await NotifyRig.make()
            await rig.mesh.postMoment(moment, video: r.url.path, still: nil, origin: .test)
            await rig.finish("moment (TEST)", expect: ["moment-\(id)"])
        }
    } catch {
        fail("not recorded: \(error)")
    }
}

/// `foil --out sheet.png`: every foil level, seen and unseen, side by side. Development only.
func foilCommand(_ args: Args) {
    guard let renderer = FoilRenderer() else { fail("no foil renderer: \(FoilRenderer.lastError)") }
    let out = args.value("out") ?? "/tmp/siversol/foil.png"
    let cell = CGSize(width: 220, height: 300)
    let tiers: [(DexTier, String)] = [(.basic, "nothing"), (.epic, "rage"), (.unique, "starlight"), (.legendary, "undead"), (.mythic, "twilight"),
                                      (.exalted, "symphony"), (.glorious, "abyssalhunter"), (.transcendent, "treehouse")]
    guard let ctx = CGContext(data: nil, width: Int(cell.width) * tiers.count, height: Int(cell.height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { fail("no context") }
    for (i, (tier, id)) in tiers.enumerated() {
        for row in 0..<2 {
            var card = FoilCard(level: FoilLevel.of(tier: tier, chance: nil), top: tier.color, bottom: tier.color.mix(RGB(hex: 0x1E2F8F), 0.5), seed: SolDex.seed(id), seen: row == 0)
            card.tiltX = Double(args.value("progress") ?? "0") ?? 0
            if let image = renderer.image(card, time: Double(args.value("time") ?? "3.7") ?? 3.7, size: cell, scale: 1) {
                ctx.draw(image, in: CGRect(x: CGFloat(i) * cell.width, y: CGFloat(1 - row) * cell.height, width: cell.width, height: cell.height))
            }
        }
    }
    if let image = ctx.makeImage() { writePNG(image, to: out) }
    print("wrote \(out)")
}

/// `wrapped --out card.png [--hours 6] [--demo]`: draw a Session Wrapped card from the timeline (or from made-up data).
func wrappedCommand(_ args: Args) {
    let catalog = (try? BiomeCatalog.bundled()) ?? BiomeCatalog(builtIn: [])
    let auras = AuraCatalog.bundled()
    let hours = Double(args.value("hours") ?? "6") ?? 6
    let end = Date(), start = end.addingTimeInterval(-hours * 3600)
    var events: [SiverEvent] = []
    if args.flag("demo") {
        events = DemoDay.events(endingAt: end, hours: hours)
    } else {
        let store = TimelineStore(directory: TimelineStore.defaultDirectory)
        for day in Set([TimelineStore.day(start), TimelineStore.day(end)]) { events += store.events(day: day) }
    }
    let wrap = SessionWrap.build(events: events, start: start, end: end, isRare: { catalog.isRare($0) }, chance: { auras.chance(for: $0) },
                                 auraName: { auras.info(for: $0)?.display ?? AuraName.display($0) }, macroRuns: args.flag("demo") ? 4 : 0)
    guard let image = WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: SkyRenderer(), foil: FoilRenderer()) else { fail("could not draw the card") }
    let out = args.value("out") ?? "/tmp/siversol/wrapped.png"
    writePNG(image, to: out)
    print("wrote \(out): \(WrappedCard.duration(wrap.duration)), \(wrap.rares.count) rare, rarest roll \(wrap.rarestRoll ?? "none")")
}

/// `cards --out DIR`: write one of every Sky Card (the Discord payload as JSON, and its pictures) with made-up
/// data, so they can be looked at and scanned for anything private without sending a thing.
func cardSamplesCommand(_ args: Args) {
    let out = URL(fileURLWithPath: args.value("out") ?? "/tmp/siversol/cards", isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let catalog = (try? BiomeCatalog.bundled()) ?? BiomeCatalog(builtIn: [])
    let auras = AuraCatalog.bundled()
    let artist = LivingSkyArtist(catalog: catalog)
    let t = Date(timeIntervalSince1970: 1_795_002_142)
    let server = "0d3m0000-0000-4000-8000-000000000000"
    func ctx(_ origin: EventOrigin) -> RenderContext {
        var c = RenderContext(catalog: catalog, route: RouteConfig(name: "main", profile: .rich), origin: origin,
                              serverLink: "https://www.roblox.com/share?code=EXAMPLE&type=Server", todayCount: { _ in 3 }, now: t)
        c.auras = auras
        c.profileName = "Glitch Hunt"
        return c
    }
    func started(_ b: String) -> BiomeStarted {
        BiomeStarted(id: "s-\(b)", biome: BiomeRef(raw: b), at: t, observedStart: true, wasRunning: false, serverJobId: server, previous: "NORMAL")
    }
    let ended = BiomeEnded(id: "e", biome: BiomeRef(raw: "PUMPKIN MOON"), startedAt: t, at: t.addingTimeInterval(147), startedEventId: "s", startObserved: true,
                           reason: .changed, next: "NORMAL", serverJobId: server)
    var samples: [(String, DiscordMessage)] = [
        ("biome-started-pumpkin-moon", RichTemplates.biomeStarted(started("PUMPKIN MOON"), ctx(.live))),
        ("biome-started-rainy", RichTemplates.biomeStarted(started("RAINY"), ctx(.live))),
        ("rare-started-glitched", RichTemplates.biomeStarted(started("GLITCHED"), ctx(.live))),
        ("preview-started-windy", RichTemplates.biomeStarted(started("WINDY"), ctx(.test))),
        ("biome-ended", RichTemplates.biomeEnded(ended, ctx(.live))),
        ("aura-rolled", RichTemplates.auraRolled(AuraRolled(id: "r", name: "Symphony", at: t, durationS: 34.23, biome: BiomeRef(raw: "STARFALL")), ctx(.live))),
        ("aura-equipped", RichTemplates.aura(AuraEquipped(id: "a", internalName: "AbyssalHunter", at: t, biome: BiomeRef(raw: "RAINY"), biomeEventId: nil, initial: false, serverJobId: server), ctx(.live))),
        ("merchant", RichTemplates.merchant(MerchantArrived(id: "m", name: "Mari", at: t, biome: BiomeRef(raw: "NORMAL"), source: "log"), ctx(.live))),
        ("connected", RichTemplates.connected(route: RouteConfig(name: "main", profile: .rich), webhookName: nil, channelId: nil, catalog: catalog, now: t, profile: "Glitch Hunt")),
    ]
    samples.append(("incident", RichTemplates.incident(IncidentReport(id: "i", cause: "Roblox disconnected", steps: [.init("noticed", at: t), .init("reopened the private server", at: t.addingTimeInterval(20)), .init("in game", at: t.addingTimeInterval(51))], recovered: true), ctx(.live))))
    var drawn: [String] = []
    for (name, message) in samples {
        guard var card = message.sky else { continue }
        if let art = card.art {
            if let thumb = art.thumb, let p = artist.picture(thumb: thumb, art: art) {
                try? p.data.write(to: out.appendingPathComponent("\(name)-thumb.\(p.fileExtension)"))
                card.thumbnail = "sky-thumb.\(p.fileExtension)"
            }
            if let c = art.card, let p = artist.picture(card: c, art: art) {
                try? p.data.write(to: out.appendingPathComponent("\(name)-card.\(p.fileExtension)"))
                card.gallery = ["sky-card.\(p.fileExtension)"]
                drawn += p.text.map { "\(name): \($0)" }
                print(String(format: "%@ card: %dx%d, %d KB (%@)", name, p.width, p.height, p.data.count / 1024, p.fileExtension))
            }
        }
        var m = message
        m.sky = card
        try? m.json(pretty: true).write(to: out.appendingPathComponent("\(name).json"))
    }
    // The words drawn into the pictures, as text, so a scan can read them.
    try? drawn.joined(separator: "\n").write(to: out.appendingPathComponent("words-drawn-into-pictures.txt"), atomically: true, encoding: .utf8)
    print("wrote \(samples.count) cards to \(out.path)")
}
