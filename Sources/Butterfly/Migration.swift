import Foundation
import Security

/// One-time move from the old app id (com.armandas.ctrl, "CTRL") to com.armandas.butterfly:
/// Application Support folder, Keychain keys (API keys + the screen-memory key), and settings.
/// Old copies are left in place, so going back to an old build still works.
enum Migration {
    private static let oldID = "com.armandas.ctrl"
    private static let doneKey = "migratedFromCTRL"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("CTRL"), new = support.appendingPathComponent("Butterfly")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.copyItem(at: old, to: new) }

        for account in ["typesafe-api-key", "gemini-api-key", "screen-memory-key"] { copyKeychain(account) }

        if let prefs = UserDefaults(suiteName: oldID)?.persistentDomain(forName: oldID) {
            for (k, v) in prefs where defaults.object(forKey: k) == nil && !k.hasPrefix("NSWindow Frame") && !k.hasPrefix("SU") {
                defaults.set(v, forKey: k)
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    private static func copyKeychain(_ account: String) {
        func query(_ service: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }
        guard SecItemCopyMatching(query(Keychain.service) as CFDictionary, nil) == errSecItemNotFound else { return }
        var read = query(oldID); read[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return }
        var add = query(Keychain.service); add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
