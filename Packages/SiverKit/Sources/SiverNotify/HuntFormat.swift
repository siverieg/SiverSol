import Foundation
import SiverCore

/// What a glitch-hunt bot would read out of a message.
public struct HuntExtraction: Equatable, Sendable {
    public var event: String        // "started" | "ended"
    /// Space-less uppercase key, the way the bot stores it ("SANDSTORM").
    public var biome: String
    /// The 1–5 words captured after the anchor.
    public var words: [String]
    public var serverLink: String?
    public var timestamp: String?
}

/// Swift port of the open-source sora-bot `DefaultMacroParser` (github.com/masutty/sora-bot,
/// src/usermodules/biomehunt/macro-parsers/default-macro.parser.ts, read 2026-11-18).
/// Used two ways: the F3 acceptance test, and a runtime guard that stops simulated or replayed
/// events from ever looking like a real hunt message (hard rule 8).
public enum HuntFormat {
    // BIOME_WORD = [A-Za-z0-9_]+(?:['’-][A-Za-z0-9_]+)* ; up to 5 words.
    static let word = #"[A-Za-z0-9_]+(?:['’-][A-Za-z0-9_]+)*"#
    static let biomeRegex = try! NSRegularExpression(
        pattern: #"Biome\s+(Started|Ended)\b[^A-Za-z0-9]*("# + word + #"(?:\s+"# + word + #"){0,4})"#,
        options: [.caseInsensitive])
    static let linkRegex = try! NSRegularExpression(pattern: #"https?://(?:www\.)?roblox\.com/[^\s)\]"'<>]+"#, options: [.caseInsensitive])
    static let thumbnailRegex = try! NSRegularExpression(pattern: #"/([A-Z_]+)\.png$"#, options: [.caseInsensitive])
    static let mdLink = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#)
    static let mdChars = try! NSRegularExpression(pattern: #"[*_~`>#]"#)
    static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    /// Footer ids the bot uses to pick a macro-specific parser. Our footer must contain none of them.
    public static let knownMacroIds = ["coteab", "multiscope", "eggsol", "maxstellar", "droidscope", "j.jaram", "sora-minimal", "solrich"]

    /// The bot's seed list (space-less keys). NORMAL is not in it.
    public static let botSeedBiomes: Set<String> = [
        "WINDY", "SNOWY", "RAINY", "SANDSTORM", "HELL", "STARFALL", "HEAVEN", "CORRUPTION", "NULL",
        "GLITCHED", "CYBERSPACE", "DREAMSPACE", "SINGULARITY",
        "PUMPKINMOON", "GRAVEYARD", "BLAZINGSUN", "INCINERATOR", "BLOODRAIN", "AURORA", "EGGLAND",
    ]

    /// normalizeBiomeName: uppercase, drop everything that is not A–Z or 0–9.
    public static func normalize(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
    }

    static func stripMarkdown(_ text: String) -> String {
        var s = replace(mdLink, in: text, with: "$1")
        s = replace(mdChars, in: s, with: " ")
        s = replace(spaces, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    private static func candidates(_ embed: Embed) -> [String] {
        ([embed.title, embed.description] + (embed.fields ?? []).map { Optional($0.value) }).compactMap { $0 }
    }

    /// The raw anchor match, before the bot checks its biome list: does `embeds[0]` read as a biome event at all?
    public static func anchor(in message: DiscordMessage) -> (event: String, words: [String])? {
        guard let embed = message.embeds.first else { return nil }
        for text in candidates(embed) {
            let cleaned = stripMarkdown(text)
            guard let m = biomeRegex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  let e = Range(m.range(at: 1), in: cleaned), let w = Range(m.range(at: 2), in: cleaned) else { continue }
            return (cleaned[e].lowercased(), cleaned[w].split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return nil
    }

    /// True when a hunt bot's common parser would treat this message as a biome event. The rule-8 guard.
    public static func looksLikeHuntEvent(_ message: DiscordMessage) -> Bool {
        if anchor(in: message) != nil { return true }
        if let url = message.embeds.first?.thumbnail?.url,
           thumbnailRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil { return true }
        return false
    }

    /// Full extraction the way the bot does it: longest known biome the words start with.
    public static func extract(_ message: DiscordMessage, knownBiomes: Set<String> = botSeedBiomes) -> HuntExtraction? {
        guard let embed = message.embeds.first, let (event, words) = anchor(in: message) else { return nil }
        var biome: String?
        for length in stride(from: words.count, through: 1, by: -1) {
            let candidate = normalize(words.prefix(length).joined(separator: " "))
            if knownBiomes.contains(candidate) { biome = candidate; break }
        }
        guard let biome else { return nil }
        return HuntExtraction(event: event, biome: biome, words: words, serverLink: serverLink(in: message), timestamp: embed.timestamp)
    }

    /// First roblox.com URL in the raw embed text, else a link button.
    public static func serverLink(in message: DiscordMessage) -> String? {
        guard let embed = message.embeds.first else { return nil }
        for text in candidates(embed) {
            if let m = linkRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
                return String(text[r])
            }
        }
        for row in message.components ?? [] {
            for b in row.components {
                if let m = linkRegex.firstMatch(in: b.url, range: NSRange(b.url.startIndex..., in: b.url)), let r = Range(m.range, in: b.url) {
                    return String(b.url[r])
                }
            }
        }
        return nil
    }

    /// Which macro parser the bot would pick from the footer. nil = the common ("unknown") parser.
    public static func detectedMacro(footer: String?) -> String? {
        guard let f = footer?.lowercased() else { return nil }
        return knownMacroIds.first { f.contains($0) }
    }
}
