import Foundation
import SiverCore

public enum FormatProfile: String, Codable, Sendable {
    case rich
    /// Immutable plain messages that glitch-hunt bots can parse (SPEC F3).
    case huntCompat = "hunt-compat"
}

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case biome, aura, merchant, incident, status, newBiome, liveCard, daily
    /// Macro Studio: macro started, finished, stopped, recording saved.
    case macros
}

/// Who to ping for a biome: `everyone`, `role:<id>` or `user:<id>`.
public enum PingTarget: Codable, Equatable, Sendable {
    case everyone
    case role(String)
    case user(String)

    public init?(string: String) {
        if string == "everyone" { self = .everyone; return }
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return nil }
        switch parts[0] {
        case "role": self = .role(parts[1])
        case "user": self = .user(parts[1])
        default: return nil
        }
    }

    public var string: String {
        switch self {
        case .everyone: return "everyone"
        case .role(let id): return "role:\(id)"
        case .user(let id): return "user:\(id)"
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let t = PingTarget(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad ping target \(s)"))
        }
        self = t
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(string)
    }

    public var content: String {
        switch self {
        case .everyone: return "@everyone"
        case .role(let id): return "<@&\(id)>"
        case .user(let id): return "<@\(id)>"
        }
    }
    public var allowedMentions: AllowedMentions {
        switch self {
        case .everyone: return .everyone
        case .role(let id): return AllowedMentions(parse: [], roles: [id])
        case .user(let id): return AllowedMentions(parse: [], users: [id])
        }
    }
}

/// One webhook + filters + format. The webhook URL itself lives in secrets under the same `name`.
public struct RouteConfig: Codable, Equatable, Sendable {
    public var name: String
    public var profile: FormatProfile
    public var enabled: Bool
    public var events: [EventKind]
    /// Send NORMAL started/ended too. Hunt bots count these as "this macro is active".
    public var includeNormal: Bool
    /// When set, only these biomes are sent.
    public var onlyBiomes: [BiomeKey]?
    /// Master switch for pings on this route. Off by default (hard rule 9).
    public var pingsEnabled: Bool
    /// Biome key -> who to ping. Only consulted for real rare biomes.
    public var pings: [String: PingTarget]
    /// Rich only: also post a separate "ended" message (the Started message is always edited).
    public var endedMessages: Bool
    /// Forum channels: one thread per session.
    public var sessionThreads: Bool
    /// May this route receive test, simulated and replayed messages? Never true for a Hunt-Compat route.
    public var acceptsTests: Bool
    /// Digest: ordinary biomes are gathered into one "Biome feed" message an hour, edited in place, instead of a
    /// post each. Rare biomes, rolls and merchants still post on their own. Ignored on a Hunt-Compat route.
    public var digest = false

    public init(name: String, profile: FormatProfile, enabled: Bool = true, events: [EventKind] = EventKind.allCases,
                includeNormal: Bool = true, onlyBiomes: [BiomeKey]? = nil, pingsEnabled: Bool = false,
                pings: [String: PingTarget] = [:], endedMessages: Bool = true, sessionThreads: Bool = false,
                acceptsTests: Bool = true) {
        self.name = name; self.profile = profile; self.enabled = enabled; self.events = events
        self.includeNormal = includeNormal; self.onlyBiomes = onlyBiomes; self.pingsEnabled = pingsEnabled
        self.pings = pings; self.endedMessages = endedMessages; self.sessionThreads = sessionThreads
        self.acceptsTests = acceptsTests
    }

    /// The only kind of route that test, simulated or replayed content may reach: Rich, enabled for tests.
    /// A Hunt-Compat route can never be one, whatever its config says (a fake biome there would mislead a hunt server).
    public var isTestTarget: Bool { enabled && profile == .rich && acceptsTests }

    /// The rare biomes that ping @everyone when pings are turned on for a route.
    public static let defaultPings: [String: PingTarget] = ["GLITCHED": .everyone, "DREAMSPACE": .everyone, "CYBERSPACE": .everyone, "SINGULARITY": .everyone]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        profile = try c.decodeIfPresent(FormatProfile.self, forKey: .profile) ?? .rich
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // A hunt route is biome-only unless told otherwise; a rich route gets everything.
        events = try c.decodeIfPresent([EventKind].self, forKey: .events) ?? (profile == .huntCompat ? [.biome] : EventKind.allCases)
        includeNormal = try c.decodeIfPresent(Bool.self, forKey: .includeNormal) ?? true
        onlyBiomes = try c.decodeIfPresent([BiomeKey].self, forKey: .onlyBiomes)
        pingsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pingsEnabled) ?? false
        pings = try c.decodeIfPresent([String: PingTarget].self, forKey: .pings) ?? [:]
        endedMessages = try c.decodeIfPresent(Bool.self, forKey: .endedMessages) ?? true
        sessionThreads = try c.decodeIfPresent(Bool.self, forKey: .sessionThreads) ?? false
        acceptsTests = try c.decodeIfPresent(Bool.self, forKey: .acceptsTests) ?? true
        digest = try c.decodeIfPresent(Bool.self, forKey: .digest) ?? false
    }

    /// Does this biome go into the hourly feed on this route instead of getting its own message?
    public func digests(_ biome: BiomeKey, isRare: Bool) -> Bool { digest && profile == .rich && !isRare }

    public func wants(_ kind: EventKind) -> Bool {
        guard enabled else { return false }
        // Hunt-Compat routes carry biome events and nothing else, whatever the config says.
        if profile == .huntCompat { return kind == .biome && events.contains(.biome) }
        return events.contains(kind)
    }

    public func wants(biome: BiomeKey) -> Bool {
        guard wants(.biome) else { return false }
        if let onlyBiomes, !onlyBiomes.contains(biome) { return false }
        return includeNormal || biome != "NORMAL"
    }

    /// The ping for a biome on this route, or nil. Only rare biomes can ping.
    public func ping(for biome: BiomeKey, isRare: Bool) -> PingTarget? {
        guard pingsEnabled, isRare else { return nil }
        return pings[biome.value]
    }
}

/// No pings during set hours, except for the biomes nobody wants to sleep through.
public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled = false
    /// Local time, hours 0–23. 23 → 7 means from 23:00 until 07:00 the next morning.
    public var startHour = 23
    public var endHour = 7
    public var exceptions: [String] = ["GLITCHED", "DREAMSPACE"]

    public init(enabled: Bool = false, startHour: Int = 23, endHour: Int = 7, exceptions: [String] = ["GLITCHED", "DREAMSPACE"]) {
        self.enabled = enabled; self.startHour = startHour; self.endHour = endHour; self.exceptions = exceptions
    }

    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        return startHour < endHour ? (hour >= startHour && hour < endHour) : (hour >= startHour || hour < endHour)
    }

    /// May this biome ping right now?
    public func allowsPing(for biome: BiomeKey, at date: Date, calendar: Calendar = .current) -> Bool {
        !isQuiet(at: date, calendar: calendar) || exceptions.contains(biome.value)
    }
}

public struct NotifyConfig: Codable, Equatable, Sendable {
    public var routes: [RouteConfig]
    /// Route that carries the Live Session Card (F4).
    public var liveCardRoute: String?
    public var liveCardIntervalS: Int
    public var quietHours = QuietHours()
    /// How Rich routes look. Hunt-Compat routes are not affected.
    public var messageStyle = MessageStyle.skyCards
    /// Shown in the footer of every Sky Card ("SiverSol v1.0 · Glitch Hunt").
    public var profileName: String?

    public init(routes: [RouteConfig], liveCardRoute: String? = "test", liveCardIntervalS: Int = 60, quietHours: QuietHours = QuietHours(),
                messageStyle: MessageStyle = .skyCards, profileName: String? = nil) {
        self.routes = routes; self.liveCardRoute = liveCardRoute; self.liveCardIntervalS = liveCardIntervalS
        self.quietHours = quietHours; self.messageStyle = messageStyle; self.profileName = profileName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routes = try c.decode([RouteConfig].self, forKey: .routes)
        liveCardRoute = try c.decodeIfPresent(String.self, forKey: .liveCardRoute)
        liveCardIntervalS = try c.decodeIfPresent(Int.self, forKey: .liveCardIntervalS) ?? 60
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        messageStyle = try c.decodeIfPresent(MessageStyle.self, forKey: .messageStyle) ?? .skyCards
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
    }

    /// What a fresh install starts with: one Rich route called "main". Its webhook is asked for during onboarding.
    public static let `default` = NotifyConfig(routes: [RouteConfig(name: "main", profile: .rich, pings: RouteConfig.defaultPings)],
                                               liveCardRoute: "main")

    public func route(_ name: String) -> RouteConfig? { routes.first { $0.name == name } }

    /// Where test and simulated messages go: the first Rich route that accepts them.
    public var testRouteName: String? { routes.first(where: \.isTestTarget)?.name }
}

/// A validated Discord webhook URL. Anything else is refused before a single byte is sent.
public struct WebhookURL: Equatable, Sendable {
    public let id: String
    public let token: String
    public let host: String

    public init?(_ string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host,
              ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"].contains(host)
        else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "api", parts[1] == "webhooks",
              parts[2].allSatisfy(\.isNumber), !parts[3].isEmpty else { return nil }
        self.id = parts[2]; self.token = parts[3]; self.host = host
    }

    public var base: String { "https://\(host)/api/webhooks/\(id)/\(token)" }
    /// Safe to print: never includes the token.
    public var redacted: String { "https://\(host)/api/webhooks/\(id)/…" }
}

/// `Config/secrets.local.json` (gitignored). Phase 3 moves these into the Keychain at runtime.
public struct Secrets: Codable, Sendable {
    public var discordWebhooks: [String: String]
    public var privateServerLink: String?
    public var privateServerShareCode: String?

    public init(discordWebhooks: [String: String] = [:], privateServerLink: String? = nil, privateServerShareCode: String? = nil) {
        self.discordWebhooks = discordWebhooks; self.privateServerLink = privateServerLink
        self.privateServerShareCode = privateServerShareCode
    }

    public func webhook(_ route: String) -> WebhookURL? { discordWebhooks[route].flatMap(WebhookURL.init) }

    /// The share link, only if it really is a roblox.com URL.
    public var serverLink: String? {
        guard let s = privateServerLink?.trimmingCharacters(in: .whitespacesAndNewlines),
              let c = URLComponents(string: s), c.scheme == "https",
              let host = c.host, host == "www.roblox.com" || host == "roblox.com" else { return nil }
        return s
    }

    public static func load(from url: URL) throws -> Secrets {
        try JSONDecoder().decode(Secrets.self, from: Data(contentsOf: url))
    }
}

public enum ConfigLocator {
    /// Walk up from a starting folder until `Config/<name>` exists (repo checkout), else Application Support.
    public static func find(_ name: String, from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Config/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let support = SiverSol.supportDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: support.path) ? support : nil
    }

    public static func loadSecrets() throws -> Secrets {
        if let path = ProcessInfo.processInfo.environment["SIVERSOL_SECRETS"] { return try Secrets.load(from: URL(fileURLWithPath: path)) }
        guard let url = find("secrets.local.json") else { throw CocoaError(.fileNoSuchFile) }
        return try Secrets.load(from: url)
    }

    public static func loadConfig() -> NotifyConfig {
        guard let url = find("siversol.json"), let data = try? Data(contentsOf: url) else { return .default }
        struct File: Codable { var notify: NotifyConfig? }
        return (try? JSONDecoder().decode(File.self, from: data))?.notify ?? .default
    }
}
