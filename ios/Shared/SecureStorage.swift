import CryptoKit
import Foundation
import Security

/// Identifiers shared by the app and its AutoFill extension.
enum SafelyConfig {
    static let appGroup = "group.com.codecrackjd.safely"
    static let keychainService = "com.codecrackjd.safely"
}

/// Generic-password keychain items.
///
/// Items are readable after the first unlock so the app can answer the Safely Key while it runs in the
/// background, and they never leave this device (no iCloud Keychain, no backups to another phone).
enum Keychain {
    private static func baseQuery(_ account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SafelyConfig.keychainService,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    /// The app group doubles as a keychain access group, which is what lets the AutoFill extension
    /// read the vault key. Builds without that entitlement (simulator, unit tests) use the default group.
    private static let groups: [String?] = [SafelyConfig.appGroup, nil]

    static func data(for account: String) -> Data? {
        for group in groups {
            var query = baseQuery(account, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return data
            }
        }
        return nil
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        for group in groups {
            let query = baseQuery(account, group: group)
            SecItemDelete(query as CFDictionary)
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func delete(_ account: String) {
        for group in groups { SecItemDelete(baseQuery(account, group: group) as CFDictionary) }
    }
}

/// The 256-bit key that encrypts everything Safely writes to disk. Created on first launch.
enum MasterKey {
    private static let account = "master-key"

    static func load(createIfMissing: Bool) -> SymmetricKey? {
        if let data = Keychain.data(for: account) { return SymmetricKey(data: data) }
        guard createIfMissing else { return nil }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return Keychain.set(data, for: account) ? key : nil
    }
}

/// A Codable value stored as one AES-256-GCM sealed file in the shared container.
final class SecureFile<Value: Codable> {
    private let url: URL
    private let canCreateKey: Bool

    init(name: String, canCreateKey: Bool = true) {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: SafelyConfig.appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Safely", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.canCreateKey = canCreateKey
    }

    func load() -> Value? {
        guard let sealed = try? Data(contentsOf: url),
              let key = MasterKey.load(createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: plain)
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        guard let key = MasterKey.load(createIfMissing: canCreateKey),
              let plain = try? JSONEncoder().encode(value),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return false }
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true  // the key never leaves the device, so a backup would be useless
            var target = url
            try? target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}
