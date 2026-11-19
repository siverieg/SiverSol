import XCTest
@testable import SiverCore
@testable import SiverNotify

func date(_ iso: String) -> Date { try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso) }

let fakeHook = "https://discord.com/api/webhooks/111/test-token"
let fakeHuntHook = "https://discord.com/api/webhooks/222/hunt-token"
let fakeLink = "https://www.roblox.com/share?code=abc123&type=Server"

func catalog() -> BiomeCatalog { try! BiomeCatalog.bundled() }

func started(_ biome: String, at: String = "2026-11-18T11:42:22.289Z", observed: Bool = true, wasRunning: Bool = false, id: String? = nil) -> BiomeStarted {
    BiomeStarted(id: id ?? "s|\(at)|bs|\(biome)", biome: BiomeRef(raw: biome), at: date(at), observedStart: observed,
                 wasRunning: wasRunning, serverJobId: "dff0485d-0000", previous: "NORMAL")
}

func ended(_ biome: String, startedAt: String = "2026-11-18T11:42:22.289Z", at: String = "2026-11-18T11:44:22.289Z",
           reason: BiomeEndReason = .changed, startId: String? = nil) -> BiomeEnded {
    BiomeEnded(id: "s|\(at)|be|\(biome)", biome: BiomeRef(raw: biome), startedAt: date(startedAt), at: date(at),
               startedEventId: startId ?? "s|\(startedAt)|bs|\(biome)", startObserved: true, reason: reason, next: "NORMAL",
               serverJobId: "dff0485d-0000")
}

/// Virtual clock: sleeping just moves time forward, so retry/backoff tests run instantly.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = date("2026-11-18T12:00:00.000Z")) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ t: TimeInterval) { lock.lock(); current.addTimeInterval(t); lock.unlock() }
    var environment: NotifyMesh.Environment {
        var e = NotifyMesh.Environment()
        e.now = { self.now }
        e.sleep = { self.advance($0) }
        return e
    }
}

/// A fake Discord. Records every request and answers like the real API.
final class MockDiscord: HTTPTransport, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: String; let message: DiscordMessage?; let at: Date; let body: Data }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var nextId = 1000
    var clock: VirtualClock?
    /// Return a non-nil (status, body) to fail a request.
    var fault: (@Sendable (Call, Int) -> (Int, String)?)?
    var offline = false
    var guildId = "9001"

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var posts: [Call] { calls.filter { $0.method == "POST" } }
    var patches: [Call] { calls.filter { $0.method == "PATCH" } }
    func titles(_ method: String = "POST") -> [String] { calls.filter { $0.method == method }.compactMap { $0.message?.embeds.first?.title } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = request.httpBody ?? Data()
        var message = try? JSONDecoder().decode(DiscordMessage.self, from: body)
        if message == nil,
           let marker = body.range(of: Data("name=\"payload_json\"".utf8)),
           let start = body.range(of: Data("\r\n\r\n".utf8), in: marker.upperBound..<body.endIndex),
           let end = body.range(of: Data("\r\n--".utf8), in: start.upperBound..<body.endIndex) {
            // Slice the JSON part out as bytes: the rest of a multipart body can be binary (a PNG).
            message = try? JSONDecoder().decode(DiscordMessage.self, from: body.subdata(in: start.upperBound..<end.lowerBound))
        }
        let call = Call(method: request.httpMethod ?? "GET", path: url.path, query: url.query ?? "", message: message, at: clock?.now ?? Date(), body: body)
        lock.lock()
        let index = _calls.count
        if offline { lock.unlock(); throw URLError(.notConnectedToInternet) }
        _calls.append(call)
        nextId += 1
        let id = nextId
        lock.unlock()
        func respond(_ status: Int, _ json: String, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if let (status, json) = fault?(call, index) { return respond(status, json) }
        if call.method == "GET" { return respond(200, #"{"id":"111","name":"SiverSol test","guild_id":"\#(guildId)","channel_id":"5005"}"#) }
        let threadId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "thread_id" }?.value
        let channel = threadId ?? (message?.threadName != nil ? "7777" : "5005")
        return respond(200, #"{"id":"\#(id)","channel_id":"\#(channel)"}"#, headers: ["X-RateLimit-Remaining": "4", "X-RateLimit-Reset-After": "1"])
    }
}

struct Rig {
    let discord = MockDiscord()
    let clock = VirtualClock()
    let store: OutboxStore
    let mesh: NotifyMesh
    let logs = LogBox()

    /// The older tests look at classic embeds, so that is what a rig sends unless a test asks for Sky Cards.
    init(routes: [RouteConfig] = [RouteConfig(name: "test", profile: .rich)], directory: URL? = nil, link: String? = fakeLink,
         style: MessageStyle = .classic) async {
        discord.clock = clock
        store = OutboxStore(directory: directory)
        mesh = NotifyMesh(config: NotifyConfig(routes: routes, messageStyle: style),
                          secrets: Secrets(discordWebhooks: ["test": fakeHook, "hunt": fakeHuntHook], privateServerLink: link),
                          catalog: catalog(), store: store, transport: discord, environment: clock.environment)
        let logs = self.logs
        await mesh.setLogger { logs.add($0) }
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-notify-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
