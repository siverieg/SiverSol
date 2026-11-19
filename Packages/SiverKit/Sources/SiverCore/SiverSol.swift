import Foundation

/// App-wide constants shared by the app, the CLI and the tests.
public enum SiverSol {
    public static let version = "1.0.0"
    /// Where the source code lives, for the "Verify it yourself" link.
    public static let sourceURL = "https://github.com/siverieg/SiverSol"
    /// Footer on every Discord embed (SPEC: "Footer on everything").
    public static let footer = "SiverSol v\(version)"
    public static let bundleId = "io.github.siverieg.siversol"
    /// Sol's RNG place id (read from a real client log).
    public static let solsRNGPlaceId: Int64 = 15_532_962_292

    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Roblox", isDirectory: true)
    }

    /// `~/Library/Application Support/SiverSol`, created on first use.
    /// Developers can point it somewhere else with the `SIVERSOL_HOME` environment variable (the design review
    /// and some tests do, so they never touch real data).
    public static var supportDirectory: URL {
        let custom = ProcessInfo.processInfo.environment["SIVERSOL_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let url = custom ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SiverSol", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
