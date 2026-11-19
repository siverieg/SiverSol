import Foundation

/// One saved clip: a short video of the Roblox window, with a small note beside it saying what it shows.
public struct Moment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case roll, rareBiome }

    /// File name without its extension; also the id.
    public var id: String
    public var kind: Kind
    /// "Rolled Symphony", "GLITCHED".
    public var title: String
    public var detail: String
    public var biome: String?
    public var at: Date
    public var seconds: Double
    public var bytes: Int
    /// Id of the event the clip belongs to.
    public var eventId: String?

    public init(id: String, kind: Kind, title: String, detail: String, biome: String?, at: Date, seconds: Double, bytes: Int, eventId: String?) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.biome = biome
        self.at = at; self.seconds = seconds; self.bytes = bytes; self.eventId = eventId
    }
}

/// Where Moments are kept, and the rule that keeps the folder from growing without end.
///
/// Everything here stays inside one folder (`~/Movies/SiverSol Moments` by default). Only files SiverSol itself
/// named are ever listed or deleted: `Moment-<date>-<time>-<words>.mp4` and the `.json` and `.jpg` beside it.
/// Anything else a person puts in that folder is left alone, and nothing outside it is touched.
public struct MomentsStore: Sendable {
    public let directory: URL
    /// The folder may not grow past this many bytes; the oldest clips go first.
    public var capBytes: Int

    public static let defaultCapBytes = 2 * 1024 * 1024 * 1024
    public static let prefix = "Moment-"
    public static let videoExtension = "mp4"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/SiverSol Moments", isDirectory: true)
    }

    public init(directory: URL = MomentsStore.defaultDirectory, capBytes: Int = MomentsStore.defaultCapBytes) {
        self.directory = directory
        self.capBytes = capBytes
    }

    /// `Moment-20261119-164502-Rolled-Symphony`: sortable by time, readable in Finder, safe as a file name.
    public static func baseName(kind: Moment.Kind, title: String, at: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        let words = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let slug = String(words).split(separator: "-").joined(separator: "-")
        return "\(prefix)\(f.string(from: at))-\(String(slug.prefix(40)))"
    }

    public func videoURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).\(Self.videoExtension)") }
    public func noteURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    public func thumbnailURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).jpg") }

    /// Is this one of the names SiverSol gives its own files?
    public static func isOurs(_ fileName: String) -> Bool {
        guard fileName.hasPrefix(prefix) else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return [videoExtension, "json", "jpg"].contains(ext) && !fileName.contains("/")
    }

    public func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Write the note that goes with a finished clip.
    public func save(_ moment: Moment) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(moment).write(to: noteURL(moment.id), options: .atomic)
    }

    /// Every clip in the folder, newest first. A video without a note still shows up (with what the name tells).
    public func all() -> [Moment] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var out: [Moment] = []
        for name in names where Self.isOurs(name) && (name as NSString).pathExtension.lowercased() == Self.videoExtension {
            let id = (name as NSString).deletingPathExtension
            let attrs = try? fm.attributesOfItem(atPath: videoURL(id).path)
            // Never follow a link out of the folder.
            if (attrs?[.type] as? FileAttributeType) != .typeRegular { continue }
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if let data = try? Data(contentsOf: noteURL(id)), var m = try? d.decode(Moment.self, from: data) {
                m.id = id
                m.bytes = size
                out.append(m)
            } else {
                let made = (attrs?[.creationDate] as? Date) ?? .distantPast
                out.append(Moment(id: id, kind: .roll, title: id.replacingOccurrences(of: "-", with: " "), detail: "", biome: nil, at: made, seconds: 0, bytes: size, eventId: nil))
            }
        }
        return out.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
    }

    public func totalBytes() -> Int { all().reduce(0) { $0 + $1.bytes } }

    /// Which clips have to go so the folder fits under the cap: the oldest first, never the one being kept.
    public static func toTrim(_ moments: [Moment], capBytes: Int, keeping: String? = nil) -> [Moment] {
        var total = moments.reduce(0) { $0 + $1.bytes }
        var out: [Moment] = []
        for m in moments.sorted(by: { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }) {
            guard total > capBytes else { break }
            if m.id == keeping { continue }
            out.append(m)
            total -= m.bytes
        }
        return out
    }

    /// Delete the oldest clips until the folder fits under the cap. Returns what was removed.
    @discardableResult
    public func trim(keeping: String? = nil) -> [Moment] {
        let gone = Self.toTrim(all(), capBytes: capBytes, keeping: keeping)
        for m in gone { delete(m.id) }
        return gone
    }

    /// Remove one clip and the files beside it. Only names of our own pattern, only inside this folder.
    public func delete(_ id: String) {
        guard Self.isOurs("\(id).\(Self.videoExtension)") else { return }
        for url in [videoURL(id), noteURL(id), thumbnailURL(id)] where url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The bitrate for a clip of `seconds`: at most `ceiling`, and low enough to stay under `maxBytes` when the
    /// clip is meant to be uploaded (with a tenth held back for the container).
    public static func bitrate(seconds: Double, ceiling: Int = 3_500_000, maxBytes: Int?) -> Int {
        guard let maxBytes, seconds > 0 else { return ceiling }
        let fit = Int(Double(maxBytes) * 0.9 * 8 / seconds)
        return max(600_000, min(ceiling, fit))
    }

    /// 720p for a window of this size: the height is capped at 720, the width follows, both even numbers.
    public static func videoSize(windowPixels: CGSize, maxHeight: Int = 720) -> (width: Int, height: Int) {
        guard windowPixels.width > 0, windowPixels.height > 0 else { return (1280, 720) }
        let scale = min(1, Double(maxHeight) / Double(windowPixels.height))
        let w = Int((Double(windowPixels.width) * scale).rounded()) / 2 * 2
        let h = Int((Double(windowPixels.height) * scale).rounded()) / 2 * 2
        return (max(2, w), max(2, h))
    }
}
