import Foundation
import Security

/// Secure token storage backed by iOS/macOS Keychain.
///
/// Uses Data Protection Keychain on macOS (`kSecUseDataProtectionKeychain`)
/// to avoid ACL-based code-signature checks. Without this, macOS ties keychain
/// items to the binary's cdhash at "Always Allow" time — a rebuild then fails
/// to access the stored tokens because the cdhash no longer matches.
public final class KeychainStorage: Sendable {
    private let service: String

    public init(service: String = "com.onelo.auth") {
        self.service = service
    }

    public func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        addDataProtection(&query)
        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        addDataProtection(&attributes)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OneloError.keychainError("SecItemAdd failed with status: \(status)")
        }
    }

    public func get(forKey key: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        addDataProtection(&query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            throw OneloError.keychainError("SecItemCopyMatching failed with status: \(status)")
        }

        return string
    }

    public func delete(forKey key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        addDataProtection(&query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OneloError.keychainError("SecItemDelete failed with status: \(status)")
        }
    }

    public func clear() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        addDataProtection(&query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OneloError.keychainError("SecItemDelete (clear) failed with status: \(status)")
        }
    }

    // MARK: - Private

    private func addDataProtection(_ query: inout [String: Any]) {
        #if os(macOS)
        // Data Protection Keychain skips legacy ACL code-signature checks.
        // Without this, macOS ties the item to the binary's cdhash — a rebuild
        // then fails with errSecAuthFailed because the cdhash no longer matches.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
    }
}
