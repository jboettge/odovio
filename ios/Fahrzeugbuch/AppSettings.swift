import Foundation
import Observation
import Security

@Observable
final class AppSettings {
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var token: String {
        didSet { Keychain.set(token, for: "apiToken") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        token = Keychain.get("apiToken") ?? ""
    }

    var isConfigured: Bool {
        URL(string: serverURL)?.host != nil && !token.isEmpty
    }

    var api: APIClient {
        APIClient(baseURL: URL(string: serverURL) ?? URL(string: "http://localhost")!, token: token)
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "fahrzeugbuch",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
