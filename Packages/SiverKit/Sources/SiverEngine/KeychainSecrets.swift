import Foundation
import Security
import SiverCore
import SiverNotify

/// SiverSol's own secrets (webhook URLs, private server link) as one item in the login keychain.
/// Only ever touches the item with service `io.github.siverieg.siversol`; nothing that belongs to Roblox.
public enum KeychainSecrets {
    static let service = SiverSol.bundleId
    static let account = "secrets.v1"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func load() -> Secrets? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }

    @discardableResult
    public static func save(_ secrets: Secrets) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SiverSol webhooks"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Copy a `secrets.local.json` into the keychain. Existing routes not present in the file are kept.
    public static func importFile(_ url: URL) throws -> Secrets {
        let incoming = try Secrets.load(from: url)
        var merged = load() ?? Secrets()
        for (name, hook) in incoming.discordWebhooks where WebhookURL(hook) != nil { merged.discordWebhooks[name] = hook }
        if let link = incoming.privateServerLink, !link.isEmpty { merged.privateServerLink = link }
        if let code = incoming.privateServerShareCode, !code.isEmpty { merged.privateServerShareCode = code }
        guard save(merged) else { throw CocoaError(.fileWriteUnknown) }
        return merged
    }
}

/// App-side copy of the non-secret config: `~/Library/Application Support/SiverSol/siversol.json`.
public enum AppConfig {
    private struct File: Codable {
        var notify: NotifyConfig
        var extras: ExtrasConfig?
    }

    public static var url: URL { SiverSol.supportDirectory.appendingPathComponent("siversol.json") }

    public static func load() -> NotifyConfig {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return .default }
        return file.notify
    }

    public static func loadExtras() -> ExtrasConfig {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return ExtrasConfig() }
        return file.extras ?? ExtrasConfig()
    }

    /// Saves both parts. Passing nil for `extras` keeps what is already on disk.
    @discardableResult
    public static func save(_ config: NotifyConfig, extras: ExtrasConfig? = nil) -> Bool {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(File(notify: config, extras: extras ?? loadExtras())) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// One engine at a time: two would share the outbox files and double-post.
public final class EngineLock {
    private var fd: Int32 = -1
    private let path: String

    public init(directory: URL = SiverSol.supportDirectory) {
        path = directory.appendingPathComponent("engine.lock").path
    }

    /// True when this process now holds the lock.
    public func acquire() -> Bool {
        if fd >= 0 { return true }
        let f = open(path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) != 0 { close(f); return false }
        fd = f
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(f, 0)
        _ = pid.withCString { write(f, $0, strlen($0)) }
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    deinit { release() }
}
