import Foundation
import Security

/// API key in the login Keychain: Gemini (meeting transcripts).
enum Keychain {
    static let service = "com.armandas.butterfly"

    static var geminiKey: String? { read("gemini-api-key", env: "GEMINI_API_KEY") }
    static func saveGemini(_ key: String) { write(key, "gemini-api-key") }

    /// Cortex (shared memory) connection: its ingest URL and Butterfly's key there.
    static var cortexURL: String? { read("cortex-url", env: "CORTEX_URL") }
    static var cortexKey: String? { read("cortex-key", env: "CORTEX_KEY") }
    static func saveCortex(url: String, key: String) { write(url, "cortex-url"); write(key, "cortex-key") }

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
