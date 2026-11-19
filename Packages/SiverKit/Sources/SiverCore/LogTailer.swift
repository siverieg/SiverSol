import Foundation

/// Splits a byte stream into complete lines. A trailing partial line stays buffered until its `\n` arrives.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// A line longer than this without a newline is dropped (corrupt or binary data).
    public static let maxPending = 4 * 1024 * 1024

    public init() {}

    public var hasPartialLine: Bool { !pending.isEmpty }

    public mutating func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, pending[end - 1] == 0x0D { end -= 1 }   // CRLF
            lines.append(String(decoding: pending[start..<end], as: UTF8.self))
            start = nl + 1
        }
        pending = Data(pending[start...])
        if pending.count > Self.maxPending { pending.removeAll() }
        return lines
    }

    public mutating func reset() { pending.removeAll() }
}

/// Reads bytes appended to one log file. Keeps a byte offset; resets if the file shrinks or is replaced.
public final class LogTailer {
    public struct Read: Equatable {
        public var lines: [String] = []
        /// The file was truncated or swapped for a new one since the last poll; reading restarted from byte 0.
        public var didReset = false
        public var bytes = 0
    }

    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var buffer = LineBuffer()
    private var inode: UInt64?

    public init(url: URL) { self.url = url }

    /// Read whatever was appended since the last call. A missing file returns an empty read.
    public func poll() -> Read {
        var result = Read()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return result }
        let currentInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if (inode != nil && currentInode != inode) || size < offset {
            offset = 0
            buffer.reset()
            result.didReset = true
        }
        inode = currentInode
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            result.bytes = data.count
            result.lines = buffer.append(data)
        } catch {
            // Leave the offset alone; the next poll retries.
        }
        return result
    }
}
