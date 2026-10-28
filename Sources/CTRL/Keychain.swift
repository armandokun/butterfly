import Foundation
import Security

/// API keys in the login Keychain: TypeSafe (commands) and Gemini (meeting transcripts).
enum Keychain {
    private static let service = "com.armandas.ctrl"

    static var apiKey: String? { read("typesafe-api-key", env: "TYPESAFE_API_KEY") }
    static func save(_ key: String) { write(key, "typesafe-api-key") }

    static var geminiKey: String? { read("gemini-api-key", env: "GEMINI_API_KEY") }
    static func saveGemini(_ key: String) { write(key, "gemini-api-key") }

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
