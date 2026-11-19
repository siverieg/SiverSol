import Foundation

/// One Roblox game log: `<version>_<yyyymmddThhmmssZ>_Player_<hex>_last.log`.
public struct PlayerLog: Equatable, Sendable {
    public let url: URL
    /// Launch time from the file name. Roblox can still write to an older log after a newer one exists,
    /// so this, not mtime, decides which log is current.
    public let launchedAt: Date
    /// Stable id for one Roblox launch, e.g. `20261118T121315Z_6a2e9`.
    public let sessionId: String
    public let version: String
}

public enum LogDiscovery {
    /// File names already looked at. The folder is listed twice a second while SiverSol is watching, and a name
    /// never changes what it means, so each one is parsed once (parsing every name on every look cost about 2% of
    /// a core on a folder with twenty logs).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var parsed: [String: PlayerLog?] = [:]
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Parse a file name. CrashHandler logs, installer logs and anything else return nil.
    public static func playerLog(at url: URL) -> PlayerLog? {
        let key = url.path
        lock.lock()
        if let hit = parsed[key] { lock.unlock(); return hit }
        lock.unlock()
        let result = parse(url)
        lock.lock()
        if parsed.count > 2000 { parsed.removeAll() }
        parsed[key] = result
        lock.unlock()
        return result
    }

    private static func parse(_ url: URL) -> PlayerLog? {
        let name = url.lastPathComponent
        guard !name.contains("CrashHandler"),
              let m = name.wholeMatch(of: #/(.+)_(\d{8}T\d{6}Z)_Player_([0-9A-Za-z]+)_last\.log/#)
        else { return nil }
        lock.lock()
        let date = stamp.date(from: String(m.2))
        lock.unlock()
        guard let date else { return nil }
        return PlayerLog(url: url, launchedAt: date, sessionId: "\(m.2)_\(m.3)", version: String(m.1))
    }

    /// All game logs in the folder, newest launch first.
    public static func playerLogs(in directory: URL) -> [PlayerLog] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(playerLog(at:)).sorted {
            $0.launchedAt != $1.launchedAt ? $0.launchedAt > $1.launchedAt : $0.sessionId > $1.sessionId
        }
    }

    public static func newest(in directory: URL) -> PlayerLog? { playerLogs(in: directory).first }
}
