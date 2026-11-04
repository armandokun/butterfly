import CryptoKit
import Foundation
import Security

/// API keys in the login Keychain: TypeSafe (commands) and Gemini (meeting transcripts).
enum Keychain {
    static let service = "com.armandas.butterfly"

    static var apiKey: String? { read("typesafe-api-key", env: "TYPESAFE_API_KEY") }
    static func save(_ key: String) { write(key, "typesafe-api-key") }

    static var geminiKey: String? { read("gemini-api-key", env: "GEMINI_API_KEY") }
    static func saveGemini(_ key: String) { write(key, "gemini-api-key") }

    /// Key that encrypts screen-memory frames on disk (32 random bytes, made once). Lives only in this user's Keychain,
    /// so a copied ~/Library folder is unreadable without their login.
    static var screenKey: SymmetricKey {
        if let b64 = read("screen-memory-key", env: "BUTTERFLY_SCREEN_KEY"), let d = Data(base64Encoded: b64), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        write(k.withUnsafeBytes { Data($0) }.base64EncodedString(), "screen-memory-key")
        return k
    }

    private static func read(_ account: String, env: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ key: String, _ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
