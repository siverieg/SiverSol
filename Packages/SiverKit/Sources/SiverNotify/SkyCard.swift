import Foundation
import SiverCore

/// How messages on Rich routes look. Hunt-Compat routes never change: they always send the classic v1.0 embed.
public enum MessageStyle: String, Codable, CaseIterable, Sendable {
    /// Discord's Components V2 layout, in the Living Sky style.
    case skyCards
    /// The embeds SiverSol v1.0 sent.
    case classic

    public var label: String { self == .skyCards ? "Sky cards" : "Classic embeds" }
}

/// What picture a card wants. The notifier asks an artist for it at send time; a card is sent without its
/// pictures rather than late.
public struct SkyArt: Codable, Equatable, Sendable {
    public enum Thumb: Codable, Equatable, Sendable {
        case biome(String)
        case aura(String)
        /// An SF Symbol on a tile of the given colour.
        case symbol(String, Int)
    }
    public enum Card: Codable, Equatable, Sendable {
        /// The biome's sky with its name: `line` is baked into the picture, so it must never go stale
        /// (clock times, not countdowns).
        case biome(key: String, eyebrow: String, title: String, line: String)
        /// The aura's Sol Dex card.
        case aura(name: String)
        /// A plain sky banner with a title.
        case banner(title: String, line: String, biome: String?)
    }
    public var thumb: Thumb?
    public var card: Card?
    /// Simulated, replayed and test messages carry a visible "Preview" ribbon.
    public var preview = false
    /// The local hour the event happened at: it picks the day or night sky.
    public var hour: Double = 12

    public init(thumb: Thumb? = nil, card: Card? = nil, preview: Bool = false, hour: Double = 12) {
        self.thumb = thumb; self.card = card; self.preview = preview; self.hour = hour
    }
}

/// One message in the Sky Cards layout. Every message has the same anatomy:
/// a headline with a line of context and a small picture, a rule, at most three short facts, optionally one
/// picture, optionally a "Join server" link, and a footer.
public struct SkyCard: Codable, Equatable, Sendable {
    public struct Button: Codable, Equatable, Sendable {
        public var label: String
        public var url: String
        public init(label: String, url: String) { self.label = label; self.url = url }
    }

    /// The container's accent: a colour from the app's own palette (a biome's accent, a tier's colour).
    public var accent: Int
    public var headline: String
    /// "<kind> · <short context>", shown small under the headline.
    public var context: String
    public var facts: [String]
    public var button: Button?
    public var footer: String
    public var art: SkyArt?
    /// File names of the pictures that go with the message (filled in when it is sent).
    public var thumbnail: String?
    public var gallery: [String] = []

    public static let maxFacts = 3
    /// Discord allows 40 components in a message and 4000 characters of text; a card stays far below both.
    public static let maxComponents = 40
    public static let maxText = 4000
    public static let thumbName = "sky-thumb.png"

    public init(accent: Int, headline: String, context: String, facts: [String], button: Button? = nil, footer: String, art: SkyArt? = nil) {
        self.accent = accent
        self.headline = headline
        self.context = context
        self.facts = Array(facts.filter { !$0.isEmpty }.prefix(Self.maxFacts))
        self.button = button
        self.footer = footer
        self.art = art
    }

    /// Every piece of text on the card, for limit and privacy checks.
    public var allText: [String] { [headline, context, footer] + facts }

    // MARK: Components V2

    /// The message body for Discord: `flags` 32768 (IS_COMPONENTS_V2), one Container, no content and no embeds.
    /// Sent with `?with_components=true`. Only non-interactive parts are used (a plain webhook may not send others).
    public func payload(username: String?, allowedMentions: AllowedMentions, threadName: String? = nil) -> [String: Any] {
        var inner: [[String: Any]] = []
        let head: [String: Any] = ["type": 10, "content": "### \(headline)\n-# \(context)"]
        if let thumbnail {
            inner.append(["type": 9, "components": [head],
                          "accessory": ["type": 11, "media": ["url": "attachment://\(thumbnail)"], "description": headline] as [String: Any]])
        } else {
            inner.append(head)
        }
        if !facts.isEmpty {
            inner.append(["type": 14, "divider": true, "spacing": 1])
            inner.append(["type": 10, "content": facts.joined(separator: "\n")])
        }
        if !gallery.isEmpty {
            inner.append(["type": 12, "items": gallery.prefix(10).map { ["media": ["url": "attachment://\($0)"], "description": headline] as [String: Any] }])
        }
        if let button {
            inner.append(["type": 1, "components": [["type": 2, "style": 5, "label": button.label, "url": button.url] as [String: Any]]])
        }
        inner.append(["type": 10, "content": "-# \(footer)"])
        var body: [String: Any] = [
            "flags": 32768,
            "components": [["type": 17, "accent_color": accent, "components": inner] as [String: Any]],
            "allowed_mentions": allowedMentions.dictionary,
        ]
        if let username { body["username"] = username }
        if let threadName { body["thread_name"] = threadName }
        return body
    }

    /// How many components the payload holds, nested ones included.
    public var componentCount: Int {
        var n = 1                                   // the container
        n += thumbnail == nil ? 1 : 3               // text, or section + text + thumbnail
        if !facts.isEmpty { n += 2 }
        if !gallery.isEmpty { n += 1 }
        if button != nil { n += 2 }
        return n + 1                                // the footer
    }

    // MARK: fallback

    /// The same card as a classic embed: same colour, same pictures, same words. Used when Discord refuses the
    /// Components V2 form.
    public func asEmbed(username: String?, allowedMentions: AllowedMentions, timestamp: Date?) -> DiscordMessage {
        var embed = Embed(title: headline, description: ([context] + facts).joined(separator: "\n"), color: accent, timestamp: timestamp,
                          footer: Embed.Footer(text: footer))
        if let thumbnail { embed.thumbnail = .init(url: "attachment://\(thumbnail)") }
        if let first = gallery.first(where: { !$0.hasSuffix(".mp4") }) { embed.image = .init(url: "attachment://\(first)") }
        return DiscordMessage(username: username, embeds: [embed], allowedMentions: allowedMentions,
                              components: button.map { [ActionRow.link($0.label, $0.url)] })
    }
}

extension AllowedMentions {
    var dictionary: [String: Any] {
        var d: [String: Any] = ["parse": parse]
        if let roles { d["roles"] = roles }
        if let users { d["users"] = users }
        return d
    }
}

/// Draws the pictures a card asks for. The app and the command-line tool plug in the Living Sky renderer; with no
/// artist a card simply goes out without pictures.
public protocol SkyArtist: Sendable {
    /// PNG or JPEG data and a file name, or nil when it could not be drawn.
    func thumbnail(_ thumb: SkyArt.Thumb, art: SkyArt) -> FileAttachment?
    func card(_ card: SkyArt.Card, art: SkyArt) -> FileAttachment?
}

/// One ordinary biome gathered for a route's hourly "Biome feed".
public struct DigestEntry: Codable, Equatable, Sendable {
    /// The Started event's id.
    public var id: String
    public var biome: String
    public var at: Date
    public var endedAt: Date?

    public init(id: String, biome: String, at: Date, endedAt: Date?) {
        self.id = id; self.biome = biome; self.at = at; self.endedAt = endedAt
    }
}
