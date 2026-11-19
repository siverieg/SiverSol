import Foundation
import SiverCore

/// What a webhook URL resolves to. Discord gives a webhook token its own name and the ids of its server and
/// channel, but not their names, so the "Open channel" link is the way to see where messages land.
public struct WebhookDiagnosis: Equatable, Sendable {
    public var ok: Bool
    public var webhookName: String?
    public var guildId: String?
    public var channelId: String?
    public var latencyMs: Int?
    /// A plain sentence for the user when something is wrong.
    public var problem: String?

    public init(ok: Bool, webhookName: String? = nil, guildId: String? = nil, channelId: String? = nil, latencyMs: Int? = nil, problem: String? = nil) {
        self.ok = ok; self.webhookName = webhookName; self.guildId = guildId; self.channelId = channelId
        self.latencyMs = latencyMs; self.problem = problem
    }

    public var channelURL: URL? {
        guard let guildId, let channelId else { return nil }
        return URL(string: "https://discord.com/channels/\(guildId)/\(channelId)")
    }
}

/// Webhook Doctor: validate a URL before it is saved, and report how a route is doing.
public enum WebhookDoctor {
    /// Check the shape of the URL, then ask Discord about it. Nothing is posted.
    public static func examine(_ urlString: String, transport: HTTPTransport = URLSessionTransport(timeout: 10)) async -> WebhookDiagnosis {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return WebhookDiagnosis(ok: false, problem: "Paste a Discord webhook URL.") }
        guard let url = WebhookURL(trimmed) else {
            return WebhookDiagnosis(ok: false, problem: "That is not a Discord webhook URL. It should look like https://discord.com/api/webhooks/<numbers>/<token>.")
        }
        let started = Date()
        do {
            let info = try await WebhookClient(url: url, transport: transport).info()
            return WebhookDiagnosis(ok: true, webhookName: info.name, guildId: info.guildId, channelId: info.channelId,
                                    latencyMs: Int((Date().timeIntervalSince(started) * 1000).rounded()), problem: nil)
        } catch WebhookError.routeDead(let status) {
            return WebhookDiagnosis(ok: false, problem: "Discord says this webhook does not exist (HTTP \(status)). It may have been deleted; create a new one in the channel's Integrations settings.")
        } catch WebhookError.rateLimited {
            return WebhookDiagnosis(ok: false, problem: "Discord is rate limiting this webhook right now. Wait a moment and try again.")
        } catch WebhookError.transport {
            return WebhookDiagnosis(ok: false, problem: "Could not reach Discord. Check the internet connection.")
        } catch {
            return WebhookDiagnosis(ok: false, problem: "Discord answered in an unexpected way. Try again.")
        }
    }
}
