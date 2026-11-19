import Foundation
import SiverCore

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if ProcessInfo.processInfo.environment["SIVERSOL_DEBUG_HTTP"] != nil {
            // Never prints the URL (it holds the webhook token): only the method, what follows the token, and sizes.
            let tail = request.url?.path.components(separatedBy: "/").dropFirst(5).joined(separator: "/") ?? ""
            let sent = String(decoding: (request.httpBody ?? Data()).prefix(160), as: UTF8.self)
            let got = String(decoding: data.prefix(160), as: UTF8.self)
            FileHandle.standardError.write(Data("  http: \(request.httpMethod ?? "GET") …/\(tail)?\(request.url?.query ?? "") -> \(http.statusCode)\n    sent: \(sent)\n    got:  \(got)\n".utf8))
        }
        return (data, http)
    }
}

public struct FileAttachment: Sendable {
    public var name: String
    public var contentType: String
    public var data: Data
    public init(name: String, contentType: String, data: Data) {
        self.name = name; self.contentType = contentType; self.data = data
    }
}

public struct RateLimitInfo: Equatable, Sendable {
    public var remaining: Int?
    public var resetAfter: TimeInterval?

    init(_ http: HTTPURLResponse) {
        remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        resetAfter = http.value(forHTTPHeaderField: "X-RateLimit-Reset-After").flatMap(TimeInterval.init)
    }
    public init(remaining: Int? = nil, resetAfter: TimeInterval? = nil) {
        self.remaining = remaining; self.resetAfter = resetAfter
    }
}

public enum WebhookError: Error, Equatable {
    /// 429. Wait this long, then retry the same request.
    case rateLimited(retryAfter: TimeInterval)
    /// 401/403/404 on the webhook itself: the URL is revoked or wrong. The route is dead.
    case routeDead(status: Int)
    /// The message being edited no longer exists. Drop the edit, keep the route.
    case unknownMessage
    /// 400: Discord rejected the payload. Retrying will not help.
    case rejected(status: Int, body: String)
    /// 5xx. Retry with backoff.
    case server(status: Int)
    /// Timeout, offline, DNS. Retry with backoff.
    case transport(String)
    case badResponse

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport: return true
        default: return false
        }
    }
}

public struct WebhookInfo: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var guildId: String?
    public var channelId: String?
}

/// One attempt per call. Retries, ordering and persistence belong to the outbox.
public struct WebhookClient: Sendable {
    public let url: WebhookURL
    private let transport: HTTPTransport

    public init(url: WebhookURL, transport: HTTPTransport = URLSessionTransport()) {
        self.url = url; self.transport = transport
    }

    private struct Sent: Decodable { let id: String; let channel_id: String }
    private struct APIError: Decodable { let code: Int?; let retry_after: Double? }
    private struct Info: Decodable { let id: String; let name: String?; let guild_id: String?; let channel_id: String? }

    /// POST with `?wait=true`. Returns the created message's id and channel (the thread id when a thread was created).
    public func execute(_ message: DiscordMessage, files: [FileAttachment] = [], threadId: String? = nil) async throws -> (messageId: String, channelId: String, limit: RateLimitInfo) {
        var query = ["wait=true"]
        if message.components != nil || message.isSkyCard { query.append("with_components=true") }
        if let threadId { query.append("thread_id=\(threadId)") }
        let (data, http) = try await perform("POST", "\(url.base)?\(query.joined(separator: "&"))", message, files)
        guard let sent = try? JSONDecoder().decode(Sent.self, from: data) else { throw WebhookError.badResponse }
        return (sent.id, sent.channel_id, RateLimitInfo(http))
    }

    /// PATCH an earlier message from this webhook.
    @discardableResult
    public func edit(messageId: String, _ message: DiscordMessage, threadId: String? = nil) async throws -> RateLimitInfo {
        var query: [String] = []
        if message.components != nil || message.isSkyCard { query.append("with_components=true") }
        if let threadId { query.append("thread_id=\(threadId)") }
        let q = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        let (_, http) = try await perform("PATCH", "\(url.base)/messages/\(messageId)\(q)", message, [])
        return RateLimitInfo(http)
    }

    /// GET the webhook once to learn guild and channel for jump links.
    public func info() async throws -> WebhookInfo {
        var request = URLRequest(url: URL(string: url.base)!)
        request.setValue(SiverNotify.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await run(request)
        guard let i = try? JSONDecoder().decode(Info.self, from: data) else { throw WebhookError.badResponse }
        return WebhookInfo(id: i.id, name: i.name, guildId: i.guild_id, channelId: i.channel_id)
    }

    private func perform(_ method: String, _ urlString: String, _ message: DiscordMessage, _ files: [FileAttachment]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: urlString) else { throw WebhookError.badResponse }
        var request = URLRequest(url: u)
        request.httpMethod = method
        request.setValue(SiverNotify.userAgent, forHTTPHeaderField: "User-Agent")
        if files.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = message.json()
        } else {
            let boundary = "siversol-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(message, files, boundary: boundary)
        }
        return try await run(request)
    }

    static func multipart(_ message: DiscordMessage, _ files: [FileAttachment], boundary: String) -> Data {
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(message.json()); add("\r\n")
        for (i, f) in files.enumerated() {
            let safe = f.name.replacingOccurrences(of: "\"", with: "_")
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[\(i)]\"; filename=\"\(safe)\"\r\nContent-Type: \(f.contentType)\r\n\r\n")
            body.append(f.data); add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return body
    }

    private func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(request) }
        catch let e as WebhookError { throw e }
        catch { throw WebhookError.transport((error as? URLError).map { "\($0.code.rawValue)" } ?? "\(type(of: error))") }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 429:
            let api = try? JSONDecoder().decode(APIError.self, from: data)
            let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw WebhookError.rateLimited(retryAfter: api?.retry_after ?? header ?? 2)
        case 401, 403:
            throw WebhookError.routeDead(status: http.statusCode)
        case 404:
            // 10008 Unknown Message (an edit target was deleted) vs 10015 Unknown Webhook.
            if (try? JSONDecoder().decode(APIError.self, from: data))?.code == 10008 { throw WebhookError.unknownMessage }
            throw WebhookError.routeDead(status: 404)
        case 400..<500:
            throw WebhookError.rejected(status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        default:
            throw WebhookError.server(status: http.statusCode)
        }
    }
}
