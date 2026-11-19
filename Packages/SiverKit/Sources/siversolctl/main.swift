import Foundation
import ApplicationServices
import SiverCore
import SiverEngine
import SiverInput
import SiverNotify
import SiverVision

let usage = """
siversolctl \(SiverSol.version) — headless test tool for SiverSol (SPEC F13)

USAGE: siversolctl <command> [options]

BIOME RADAR
  tail [--once] [--no-learn]      Follow the live Roblox log and print parsed events.
                                  --once prints the current state and exits.
  history [file] [--verify]       Every event in the newest log (or a given file).
                                  --verify compares the tracker with an independent grep-style count.
  replay <file> [--speed N] [--route test]
                                  Replay a log through the parser and state machine.
                                  Speed 60 = one minute per second (default). 0 = no waiting.
                                  --route test also posts the events, marked REPLAY, to #siversol.
  sanitize <file> [--out path]    Make a commit-safe fixture from a raw log (whitelist + placeholders).

NOTIFY (posts go to the test route only, never in hunt format)
  webhook info                    Guild, channel and settings of every configured route.
  webhook test                    Send the "✅ SiverSol is connected" confirmation to the test route.
  webhook test-all                Send every template, marked TEST, to the test route.
  simulate <BIOME>                Send a "🧪 SIMULATED · <BIOME>" message to the test route.
  report [--day YYYY-MM-DD] [--post]
                                  Daily report from the real timeline, with the chart PNG. --post sends it marked TEST.
  audit [--since ISO] [--post]    Soak check: logs vs timeline vs delivered messages. --post sends the report.
  buildlog --phase P --done "a;b" --next N [--needs "x;y"] [--files "a.jpg;b.jpg"]
                                  Post a 🛠 Build Log to the test route.
  needs --action "a;b" [--detail D] [--title T]
                                  Post a ⚠️ Action needed message to the test route.
  run [--duration S] [--no-card] [--no-afk] [--no-rejoin] [--afk-interval S]
                                  Run the real engine headless: live log -> live routes + live card,
                                  anti-AFK and auto-rejoin included.

SCREEN + INPUT
  macro probe                     Check that the macro recorder's event tap works with Accessibility alone.
  macro list                      Macros in the library.
  macro record <name> [--seconds N] [--drive]
                                  Record in Roblox for N seconds. --drive posts a short scripted walk to record.
  macro play <name> [--loops N] [--speed X]
                                  Play a macro through Guardian.
  inspect                         Session facts, Log Lab entries, process memory/CPU and biome stats, right now.
  windows                         Print the Roblox window id, bounds and scale.
  snapshot <name>                 Save a PNG of the Roblox window to artifacts/screens/<name>.png.
  ocr [png]                       Print Vision OCR text with boxes (of a PNG, or of the live Roblox window).
  proof [--post]                  Take a proof shot (chat and player list covered). --post sends it as a TEST alert.
  guardian check                  Look at the screen and print what Guardian would allow. Presses nothing.
  input probe                     Test whether Roblox takes key events in the background (camera zoom out/in).
  afk pulse [--delivery hid|toProcess] [--force]
                                  Send one anti-AFK key press through Guardian.

  version | help
"""

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
RobloxChrome.prime()
let args = Args(Array(argv.dropFirst()), valueOptions: ["speed", "out", "route", "dir", "duration", "delivery", "afk-interval", "phase", "done", "next", "needs", "action", "detail", "day", "since", "title", "seconds", "loops", "play", "pretend-screen", "pretend-after", "rejoin-after", "interval", "biome", "hour", "time", "size", "from", "mix", "progress", "shock", "scale", "files", "bitrate", "hours", "egg"])

func newestLogOrFail(_ dir: URL) -> PlayerLog {
    guard let log = LogDiscovery.newest(in: dir) else { fail("No Roblox Player log in \(dir.path)") }
    return log
}

func readLog(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return String(decoding: data, as: UTF8.self)
}

let logsDir = args.value("dir").map { URL(fileURLWithPath: $0) } ?? SiverSol.logsDirectory

switch command {
case "tail":
    let catalog = loadCatalog(learn: !args.flag("no-learn"))
    let radar = BiomeRadar(logsDirectory: logsDir, catalog: catalog)
    if args.flag("once") {
        let events = radar.step()
        let s = radar.snapshot
        print("log:      \(s.logFile ?? "none")")
        print("lines:    \(s.linesRead) read, \(s.presenceLines) rich presence")
        print("server:   \(shortJob(s.serverJobId))   phase: \(s.phase.rawValue)")
        if let c = s.current {
            let info = catalog.info(for: c.biome.key)
            print("biome:    \(info.emoji) \(c.biome.key) since \(clock.string(from: c.since)) (\(duration(Date().timeIntervalSince(c.since))) ago)")
        } else {
            print("biome:    unknown")
        }
        print("aura:     \(s.equippedAura ?? "none")")
        if let last = s.lastEventAt { print("last line: \(clock.string(from: last))") }
        for e in events { print(describe(e, catalog: catalog)) }
    } else {
        print("Following \(logsDir.path) — Ctrl-C to stop")
        for await e in radar.events(pollInterval: 0.5) {
            var line = describe(e, catalog: catalog)
            if case .biomeStarted(let s) = e, s.wasRunning {} else {
                line += String(format: "   [+%.2fs]", Date().timeIntervalSince(e.at))
            }
            print(line)
            fflush(stdout)
        }
    }

case "history":
    let catalog = loadCatalog(learn: false)
    let path = args.positionals.first ?? newestLogOrFail(logsDir).url.path
    let text = readLog(path)
    let events = eventsInLog(text, sessionId: "history")
    for e in events { print(describe(e, catalog: catalog)) }
    let started = events.compactMap { e -> String? in if case .biomeStarted(let s) = e { return s.biome.key.value }; return nil }
    print("— \(started.count) biome starts, \(events.count) events, file \(URL(fileURLWithPath: path).lastPathComponent)")
    if args.flag("verify") {
        let grep = grepTransitions(text)
        if grep == started {
            print("VERIFY OK: tracker matches the independent count (\(grep.count) transitions, same order)")
        } else {
            print("VERIFY MISMATCH\n  tracker: \(started)\n  grep:    \(grep)")
            exit(1)
        }
    }

case "replay":
    guard let path = args.positionals.first else { fail("usage: siversolctl replay <file> [--speed N]", code: 2) }
    let speed = Double(args.value("speed") ?? "60") ?? 60
    if let route = args.value("route") {
        guard ConfigLocator.loadConfig().route(route)?.isTestTarget == true else { fail("replays may only be posted to a Rich route that accepts test messages (rule 8)", code: 2) }
        await replayToTest(path: path, speed: speed)
        exit(0)
    }
    let catalog = loadCatalog(learn: false)
    var tracker = BiomeTracker(sessionId: "replay-" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    var previous: Date?
    var count = 0
    for line in readLog(path).split(whereSeparator: \.isNewline) {
        guard let event = LogLineParser.parse(String(line)) else { continue }
        if speed > 0, let previous {
            let wait = min(event.timestamp.timeIntervalSince(previous) / speed, 30)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        previous = event.timestamp
        for e in tracker.ingest(event) {
            print(describe(e, catalog: catalog)); fflush(stdout); count += 1
        }
    }
    print("— replay done: \(count) events at \(speed == 0 ? "full" : "\(Int(speed))×") speed")

case "sanitize":
    guard let path = args.positionals.first else { fail("usage: siversolctl sanitize <file> [--out path]", code: 2) }
    let clean = LogSanitizer.sanitize(readLog(path))
    if let out = args.value("out") {
        do { try clean.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("cannot write \(out): \(error)") }
        print("wrote \(out): \(clean.split(separator: "\n").count) lines")
    } else {
        print(clean, terminator: "")
    }

case "webhook":
    switch args.positionals.first ?? "" {
    case "info": await webhookInfo()
    case "test": await webhookTest()
    case "test-all": await webhookTestAll()
    case "test-card": await webhookTestAll(cardOnly: true)
    default: fail("usage: siversolctl webhook info | test | test-all", code: 2)
    }

case "buildlog":
    func list(_ name: String) -> [String] { (args.value(name) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    guard let phase = args.value("phase"), !list("done").isEmpty else { fail("usage: siversolctl buildlog --phase P --done \"a;b\" --next N [--needs \"x;y\"]", code: 2) }
    await postStatus(kind: "buildlog", phase: phase, done: list("done"), next: args.value("next") ?? "—", needs: list("needs"), detail: nil, files: list("files"))

case "needs":
    let actions = (args.value("action") ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !actions.isEmpty else { fail("usage: siversolctl needs --action \"a;b\" [--detail D]", code: 2) }
    await postStatus(kind: "needs", phase: "", done: [], next: "", needs: actions, detail: args.value("detail"), title: args.value("title"))

case "audit":
    await audit(since: args.value("since"), post: args.flag("post"))

case "report":
    await dailyReportCommand(day: args.value("day"), post: args.flag("post"))

case "simulate":
    guard let name = args.positionals.first else { fail("usage: siversolctl simulate <BIOME>", code: 2) }
    await simulate(args.positionals.joined(separator: " ").isEmpty ? name : args.positionals.joined(separator: " "))

case "run":
    await runEngine(duration: args.value("duration").flatMap(Double.init), card: !args.flag("no-card"),
                    antiAFK: !args.flag("no-afk"), rejoin: !args.flag("no-rejoin"),
                    afkInterval: args.value("afk-interval").flatMap(Double.init), play: args.value("play"),
                    pretendScreen: args.value("pretend-screen"), pretendAfter: Double(args.value("pretend-after") ?? "60") ?? 60,
                    rejoinAfter: args.value("rejoin-after").flatMap(Double.init))

case "macro":
    switch args.positionals.first ?? "" {
    case "probe": await macroProbe()
    case "list": macroList()
    case "record":
        guard args.positionals.count >= 2 else { fail("usage: siversolctl macro record <name> [--seconds N] [--drive]", code: 2) }
        await macroRecord(name: args.positionals.dropFirst().joined(separator: " "), seconds: Double(args.value("seconds") ?? "10") ?? 10,
                          drive: args.flag("drive"), driveMouse: args.flag("drive-mouse"))
    case "drive":
        // Only the scripted input, with no recorder of its own: for testing the app's recorder from outside.
        guard await FocusManager.bringRobloxToFront(timeout: 2) else { fail("Roblox did not come to the front.") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if args.flag("mouse") { await driveScriptedMouse() } else { await driveScriptedWalk() }
        print("driven")
    case "autoclick":
        await macroAutoClick(seconds: Double(args.value("seconds") ?? "3") ?? 3, intervalMs: Double(args.value("interval") ?? "100") ?? 100)
    case "play":
        guard args.positionals.count >= 2 else { fail("usage: siversolctl macro play <name> [--loops N] [--speed X] [--notify]", code: 2) }
        await macroPlay(name: args.positionals.dropFirst().joined(separator: " "), loops: args.value("loops").flatMap(Int.init), speed: Double(args.value("speed") ?? ""), notify: args.flag("notify"))
    default: fail("usage: siversolctl macro probe | list | record | play | autoclick", code: 2)
    }

case "privacy-md":
    // The README's "Privacy & Permissions" section, from the same text the app shows.
    print(PermissionGuide.markdown(sourceURL: SiverSol.sourceURL))

case "inspect":
    await inspect()

case "snapshot":
    guard let name = args.positionals.first else { fail("usage: siversolctl snapshot <name>", code: 2) }
    await snapshot(name: name)

case "ocr":
    await ocr(path: args.positionals.first, fast: args.flag("fast"))

case "proof":
    await proofShot(post: args.flag("post"))

case "guardian":
    guard args.positionals.first == "check" else { fail("usage: siversolctl guardian check", code: 2) }
    await guardianCheck()

case "input":
    guard args.positionals.first == "probe" else { fail("usage: siversolctl input probe", code: 2) }
    await inputProbe()

case "afk":
    guard args.positionals.first == "pulse" else { fail("usage: siversolctl afk pulse [--delivery hid|toProcess] [--force]", code: 2) }
    await afkPulse(delivery: args.value("delivery"), force: args.flag("force"))

case "windows":
    let all = RobloxWindowFinder.allWindows()
    if all.isEmpty { fail("No on-screen Roblox window found.") }
    let main = RobloxWindowFinder.mainWindow(in: all)
    for w in all {
        let b = w.bounds
        print("windowId=\(w.windowId) pid=\(w.pid) layer=\(w.layer) x=\(Int(b.minX)) y=\(Int(b.minY)) w=\(Int(b.width)) h=\(Int(b.height)) scale=\(w.scale)\(w == main ? "  <- main" : "")")
    }
    print("screenRecording=\(SiverVision.hasScreenRecordingAccess) accessibility=\(AXIsProcessTrusted())")

case "sky":
    skyCommand(args)

case "cards":
    cardSamplesCommand(args)

case "wrapped":
    wrappedCommand(args)

case "foil":
    foilCommand(args)

case "moment":
    await momentCommand(args)

case "version", "--version":
    print(SiverSol.version)
case "help", "--help", "-h":
    print(usage)
default:
    fail("unknown command: \(command)\n\n\(usage)", code: 2)
}
