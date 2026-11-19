import Foundation

/// Per-route send pacing: Discord's bucket headers, a per-channel minute budget, and backoff after errors.
public struct RateLimiter: Sendable {
    /// Discord allows about 30 messages a minute per channel across all webhooks; stay under it.
    public var maxPerMinute = 25
    /// Webhook bucket is 5 requests per 2 s. Allow a burst of 4 inside any 2 s window, so one biome change
    /// (Started post, Started edit, Ended post) goes out back to back instead of being spaced out.
    public var burst = 4
    public var burstWindow: TimeInterval = 2.05

    private var sent: [Date] = []
    private var bucketBlockedUntil: Date?
    private var backoffUntil: Date?
    public private(set) var failures = 0

    public init() {}

    /// Seconds to wait before the next request may go out. 0 = send now.
    public mutating func delay(now: Date) -> TimeInterval {
        sent.removeAll { now.timeIntervalSince($0) >= 60 }
        var until = now
        if let b = bucketBlockedUntil { until = max(until, b) }
        if let b = backoffUntil { until = max(until, b) }
        let recent = sent.filter { now.timeIntervalSince($0) < burstWindow }
        if recent.count >= burst { until = max(until, recent[recent.count - burst].addingTimeInterval(burstWindow)) }
        if sent.count >= maxPerMinute, let oldest = sent.first { until = max(until, oldest.addingTimeInterval(60)) }
        return max(0, until.timeIntervalSince(now))
    }

    public mutating func recordSuccess(now: Date, info: RateLimitInfo) {
        sent.append(now)
        failures = 0
        backoffUntil = nil
        if info.remaining == 0, let reset = info.resetAfter { bucketBlockedUntil = now.addingTimeInterval(reset) }
        else if let b = bucketBlockedUntil, b <= now { bucketBlockedUntil = nil }
    }

    /// 429: wait exactly what Discord asked for (plus a little).
    public mutating func recordRateLimited(now: Date, retryAfter: TimeInterval) {
        bucketBlockedUntil = now.addingTimeInterval(max(0.1, retryAfter) + 0.1)
    }

    /// Hold the route until a given time (used to keep a gap between creating a message and editing it).
    public mutating func hold(until: Date) {
        bucketBlockedUntil = max(bucketBlockedUntil ?? until, until)
    }

    /// 5xx, timeout, offline: 1, 2, 4 … 60 s.
    @discardableResult
    public mutating func recordFailure(now: Date) -> TimeInterval {
        failures += 1
        let wait = min(60, pow(2, Double(failures - 1)))
        backoffUntil = now.addingTimeInterval(wait)
        return wait
    }
}
