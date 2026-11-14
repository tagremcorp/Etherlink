import Foundation
import Security
import LinkCore

enum PairingStore {
    private static func query(_ peer: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.EtherLink.pairing.v1",
         kSecAttrAccount as String: peer]
    }
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LinkError.invalid("Could not generate a secure pairing key.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func save(_ secret: String, peer: String) throws {
        _ = try Validation.secret(secret)
        let data = Data(secret.utf8)
        let existing = SecItemUpdate(query(peer) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if existing == errSecSuccess { return }
        guard existing == errSecItemNotFound else { throw error(existing) }
        var q = query(peer)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }
    static func load(peer: String) throws -> String? {
        var q = query(peer)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    static func forget(peer: String) throws {
        let status = SecItemDelete(query(peer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private static func error(_ status: OSStatus) -> LinkError {
        .invalid("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}
