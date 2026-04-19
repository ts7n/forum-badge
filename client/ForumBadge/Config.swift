import Foundation
import Security

enum GroupMode: String, Codable, CaseIterable {
    case off
    case menuOnly
    case menu
}

struct GroupPref: Codable, Equatable {
    var id: Int
    var mode: GroupMode
}

struct AppConfig: Codable, Equatable {
    static let defaultServerURL = "https://api.forumbadge.tml.sh"

    var enabled: Bool = false
    var serverURL: String = defaultServerURL
    var groups: [GroupPref] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? Self.defaultServerURL
        self.groups = try c.decodeIfPresent([GroupPref].self, forKey: .groups) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, serverURL, groups
    }
}

enum Config {
    private static let keychainService = "com.teddyml.ForumBadge"
    private static let keychainAccount = "serverPassword"

    static func configDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ForumBadge", isDirectory: true)
    }

    static func configFile() -> URL {
        configDir().appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        let url = configFile()
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig()
        }
        return cfg
    }

    static func save(_ cfg: AppConfig) throws {
        let dir = configDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = configFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        try data.write(to: url, options: [.atomic])
        // Force 0600 regardless of umask.
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    static func loadPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    static func savePassword(_ password: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        // Remove whatever is there, then add fresh. Avoids needing SecItemUpdate bookkeeping.
        SecItemDelete(baseQuery as CFDictionary)
        if password.isEmpty { return }
        var add = baseQuery
        add[kSecValueData as String] = password.data(using: .utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.write("Keychain SecItemAdd failed: \(status)")
        }
    }
}
