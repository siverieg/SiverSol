import Foundation

/// Turns a raw Roblox log into a fixture that is safe to commit (hard rule 6).
/// Whitelist only: lines SiverSol parses are kept, everything else is dropped, and the server id and
/// address in join lines are replaced with placeholders. Rich Presence lines carry only game data.
public enum LogSanitizer {
    public static func sanitize(_ text: String) -> String {
        var servers: [String: String] = [:]
        var out: [String] = []
        for sub in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = String(sub)
            guard let event = LogLineParser.parse(line) else { continue }
            let stamp = line.firstIndex(of: ",").map { String(line[..<$0]) } ?? "1970-01-01T00:00:00.000Z"
            switch event {
            case .presence:
                guard let r = line.range(of: LogLineParser.rpcMarker),
                      let json = LogLineParser.firstJSONObject(in: line[r.upperBound...]) else { continue }
                out.append("\(stamp),0.000000,00000000,6,Info [FLog::CreatorOutput] [BloxstrapRPC] \(json)")
            case .joined(let jobId, let placeId, _):
                let n = servers[jobId] ?? String(format: "00000000-0000-4000-8000-%012d", servers.count + 1)
                servers[jobId] = n
                out.append("\(stamp),0.000000,00000000,6 [FLog::Output] ! Joining game '\(n)' place \(placeId) at 0.0.0.0")
            case .signal(let signal, _):
                // Rebuilt from the parsed fields, so nothing else from the original line survives
                // (join bodies hold access codes; update lines hold URLs).
                let text: String
                switch signal {
                case .gameEvent(let e):
                    var clip: [String: Any] = [:]
                    if let d = e.captureDelayMs { clip["captureDelayMs"] = d }
                    if let d = e.durationS { clip["duration"] = d }
                    var game: [String: Any] = ["eventId": e.eventId, "eventName": e.eventName]
                    if !clip.isEmpty { game["clipOptions"] = clip }
                    let data = (try? JSONSerialization.data(withJSONObject: ["gameEvent": game], options: [.sortedKeys])) ?? Data()
                    text = "[FLog::CreatorOutput] [_MAPIEvent][v1/event/invoke] \(data.base64EncodedString())"
                case .heartbeat: text = "[FLog::Output] Settings Date timestamp is 0"
                case .dailyReset(let d): text = "[FLog::CreatorOutput] daily reset time \(Int(d.timeIntervalSince1970))"
                case .joinRequest(.privateServer): text = "[FLog::GameJoinUtil] GameJoinUtil::joinGamePostPrivateServer: URL: https://gamejoin.roblox.com/v1/join-private-game BODY: {}"
                case .joinRequest(.reserved): text = "[FLog::GameJoinUtil] GameJoinUtil::initiateTeleportToReservedServer: URL: https://gamejoin.roblox.com/v1/join-reserved-game POST Body: {}"
                case .joinRequest(.publicServer): continue
                case .session(.enteredPlay): text = "[FLog::SessionTransitionFSM] Entered play session."
                case .session(.teleported): text = "[FLog::SessionTransitionFSM] Teleported."
                case .session(.tearingDown): text = "[FLog::SessionTransitionFSM] Tearing down."
                case .updateRequired(let r): text = "[FLog::UpdateController] Update check thread: updateRequired \(r ? "TRUE" : "FALSE")"
                case .offeredVersion(let v): text = "[FLog::UpdateController] version response: {\"version\":\"\(v)\"}"
                case .windowSize(let w, let h): text = "[FLog::Graphics] SceneManager: resizing main targets to \(w)x\(h)"
                }
                out.append("\(stamp),0.000000,00000000,6 \(text)")
            case .merchant(let name, _):
                out.append("\(stamp),0.000000,00000000,6 [FLog::Output] [Merchant]: \(name) has arrived on the island...")
            case .disconnected(let reason, let kind, _):
                let text: String
                switch kind {
                case "reason-received": text = "[FLog::Network] Disconnect reason received: \(reason ?? 0)"
                case "notification": text = "[FLog::Network] Disconnection Notification. Reason: \(reason ?? 0)"
                case "sending": text = "[FLog::Network] Sending disconnect with reason: \(reason ?? 0)"
                default: text = "[FLog::Network] Connection lost"
                }
                out.append("\(stamp),0.000000,00000000,6 \(text)")
            }
        }
        return out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")
    }
}
