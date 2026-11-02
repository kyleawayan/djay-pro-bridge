import Foundation
import Security

enum OBSPasswordStore {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "System One Debugger OBS WebSocket",
                                              kSecAttrAccount as String: "default"]

    static func load() -> String {
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ password: String) {
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
