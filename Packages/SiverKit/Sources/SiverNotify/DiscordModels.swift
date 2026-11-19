import Foundation
import SiverCore

/// Who may be pinged by a message. Non-optional on `DiscordMessage`, so every request carries it (hard rule 9).
public struct AllowedMentions: Codable, Equatable, Sendable {
    public var parse: [String]
    public var roles: [String]?
    public var users: [String]?

    public init(parse: [String] = [], roles: [String]? = nil, users: [String]? = nil) {
        self.parse = parse; self.roles = roles; self.users = users
    }

    /// Nobody gets pinged, whatever the text says.
    public static let none = AllowedMentions(parse: [])
    public static let everyone = AllowedMentions(parse: ["everyone"])
    public var pingsAnyone: Bool { !parse.isEmpty || !(roles ?? []).isEmpty || !(users ?? []).isEmpty }
}

public struct Embed: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var name: String
        public var value: String
        public var inline: Bool
        public init(_ name: String, _ value: String, inline: Bool = true) {
            self.name = name; self.value = value; self.inline = inline
        }
    }
    public struct Media: Codable, Equatable, Sendable {
        public var url: String
        public init(url: String) { self.url = url }
    }
    public struct Footer: Codable, Equatable, Sendable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    public var title: String?
    public var description: String?
    public var url: String?
    public var color: Int?
    public var fields: [Field]?
    public var thumbnail: Media?
    public var image: Media?
    /// ISO8601. For biome events this is the log line's time, not the send time.
    public var timestamp: String?
    public var footer: Footer?

    public init(title: String? = nil, description: String? = nil, url: String? = nil, color: Int? = nil,
                fields: [Field]? = nil, thumbnail: Media? = nil, image: Media? = nil, timestamp: Date? = nil,
                footer: Footer? = Footer(text: SiverSol.footer)) {
        self.title = title; self.description = description; self.url = url; self.color = color
        self.fields = fields; self.thumbnail = thumbnail; self.image = image
        self.timestamp = timestamp.map(DiscordTime.iso); self.footer = footer
    }
}

/// A non-interactive link button row (works on plain webhooks with `with_components=true`).
public struct ActionRow: Codable, Equatable, Sendable {
    public struct Button: Codable, Equatable, Sendable {
        public var type = 2
        public var style = 5
        public var label: String
        public var url: String
    }
    public var type = 1
    public var components: [Button]

    public static func link(_ label: String, _ url: String) -> ActionRow {
        ActionRow(components: [Button(label: label, url: url)])
    }
}

public struct DiscordMessage: Codable, Equatable, Sendable {
    public var content: String?
    public var username: String?
    public var embeds: [Embed]
    public var allowedMentions: AllowedMentions
    public var components: [ActionRow]?
    public var threadName: String?
    /// The same message in the Sky Cards layout. It is kept with a queued message, and it is never part of a
    /// classic payload: `json()` writes either the card (Components V2) or the classic message, never both.
    /// Hunt-Compat messages never have one.
    public var sky: SkyCard?

    enum CodingKeys: String, CodingKey {
        case content, username, embeds, components, sky
        case allowedMentions = "allowed_mentions"
        case threadName = "thread_name"
    }

    public init(content: String? = nil, username: String? = nil, embeds: [Embed] = [],
                allowedMentions: AllowedMentions = .none, components: [ActionRow]? = nil, threadName: String? = nil) {
        self.content = content; self.username = username; self.embeds = embeds
        self.allowedMentions = allowedMentions; self.components = components; self.threadName = threadName
    }

    /// True when this message goes out in the Components V2 layout.
    public var isSkyCard: Bool { sky != nil }

    /// The bytes sent to Discord.
    public func json(pretty: Bool = false) -> Data {
        if let sky {
            let body = sky.payload(username: username, allowedMentions: allowedMentions, threadName: threadName)
            let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
            return (try? JSONSerialization.data(withJSONObject: body, options: options)) ?? Data("{}".utf8)
        }
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }

    /// This message without its Sky Cards form: what a classic send uses.
    public var classic: DiscordMessage { var m = self; m.sky = nil; return m }
}

public enum DiscordTime {
    /// `2026-11-18T11:42:22.289Z`
    public static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
    public static func unix(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }
    /// Discord renders these in the reader's own time zone. Style T = time, R = relative, f = date+time.
    public static func tag(_ date: Date, _ style: Character) -> String { "<t:\(unix(date)):\(style)>" }

    public static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s >= 86400 { return "\(s / 86400)d \((s % 86400) / 3600)h \((s % 3600) / 60)m" }
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m \(s % 60)s" }
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

/// Where a sent message lives, for jump links and edits.
public struct MessageRef: Codable, Equatable, Sendable {
    public var messageId: String
    public var channelId: String
    public var guildId: String?

    public init(messageId: String, channelId: String, guildId: String?) {
        self.messageId = messageId; self.channelId = channelId; self.guildId = guildId
    }

    public var jumpURL: String? {
        guildId.map { "https://discord.com/channels/\($0)/\(channelId)/\(messageId)" }
    }
}

/// Limits Discord sets that SiverSol has to stay inside.
public enum DiscordLimits {
    /// The largest file a webhook may upload to a server without boosts: 20 MB since August 2026.
    /// Checked against a real webhook on 2026-11-19 (19 MB accepted, 24 MB refused with error 40005).
    /// A little is held back for the rest of the request.
    public static let webhookFileBytes = 20 * 1024 * 1024 - 512 * 1024
}
