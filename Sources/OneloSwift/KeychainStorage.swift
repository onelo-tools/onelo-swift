import Foundation
import Security

/// Where `OneloAuth` keeps the session and its launch caches: string values
/// under string keys, one namespace per store.
///
/// The SDK reads it ONLY through this protocol, so the store can be swapped
/// without touching `OneloAuth`. Apps get the Keychain (`production()`); the
/// test suite injects an in-memory store and never reaches the real Keychain
/// (#732 — an ad-hoc-signed `xctest` binary otherwise raises a "wants to use
/// com.onelo.auth" dialog on every build).
protocol OneloSessionStorage: AnyObject, Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
    /// Remove every value in this store (sign-out, revocation).
    func clear() throws
    /// The server just accepted `refreshToken` (the token presented, before
    /// rotation) and returned a fresh session. A store that migrated exactly
    /// that token from the legacy shared Keychain (#740) now knows the session
    /// is this app's and removes the legacy copy. Other stores do nothing.
    func sessionRefreshSucceeded(refreshToken: String)
}

extension OneloSessionStorage {
    func sessionRefreshSucceeded(refreshToken: String) {}
}

enum OneloSessionStorageFactory {
    /// The store every app gets by default. This is the ONE place that picks
    /// the production backend: change it here and nowhere else. Tests never
    /// call it — they pass their own store explicitly.
    ///
    /// Since #740 that is this app's own session Keychain: the data protection
    /// keychain where the app is entitled to it, otherwise the macOS file-based
    /// keychain, always under a service scoped to this app's bundle id. See
    /// `OneloSessionKeychain`.
    static func production() -> any OneloSessionStorage {
        OneloSessionKeychain(
            service: OneloSessionKeychain.serviceName(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                processName: ProcessInfo.processInfo.processName
            ),
            backend: SecItemKeychainBackend(),
            defaults: .standard
        )
    }
}

/// Secure token storage backed by iOS/macOS Keychain.
///
/// Kept for source compatibility. The SDK itself no longer uses it: since #740
/// the session lives in `OneloSessionKeychain` (per-app service, data protection
/// keychain). This class still targets the macOS file-based keychain under the
/// service you pass.
public final class KeychainStorage: OneloSessionStorage, Sendable {
    private let service: String

    public init(service: String = "com.onelo.auth") {
        self.service = service
    }

    public func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // SecItemDelete above couldn't reach the existing entry (ACL mismatch
            // from a prior run as a different bundle / unsigned binary). Update in place.
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw OneloError.keychainError("SecItemUpdate failed with status: \(updateStatus)")
            }
            return
        }

        guard status == errSecSuccess else {
            throw OneloError.keychainError("SecItemAdd failed with status: \(status)")
        }
    }

    public func get(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OneloError.keychainError("SecItemDelete failed with status: \(status)")
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // Delete in a loop, not once. On the macOS file-based keychain a single
        // SecItemDelete with only {class, service} can remove just ONE matching
        // entry per call, and duplicate rows accumulate when an unsigned / ad-hoc
        // dev binary is rebuilt (each build's divergent ACL leaves orphaned
        // copies — the same situation `set()` works around above). A single
        // delete then leaves stale access_token / refresh_token rows behind,
        // which the post-sign-out `restoreSession()` reads back and re-publishes
        // the session ("logged out then auto-logged back in"). Loop until the
        // store reports nothing left so sign-out is final. The cap is a
        // belt-and-suspenders against an unexpected non-terminating status.
        for _ in 0..<100 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound {
                return  // nothing (more) to delete — done
            }
            guard status == errSecSuccess else {
                throw OneloError.keychainError("SecItemDelete (clear) failed with status: \(status)")
            }
        }
        // Reached the cap while deletes kept succeeding — extremely unlikely, but
        // surface it rather than silently claim sign-out cleared the store.
        throw OneloError.keychainError("SecItemDelete (clear) did not drain after 100 iterations")
    }
}

/// Per-install instance UUID for SDK telemetry (instance tracking).
/// Persisted in UserDefaults — per-bundle on iOS/macOS, survives app restart,
/// lost on reinstall / app data clear. Not a secret (just a counter key);
/// UserDefaults is sufficient and avoids macOS Keychain ACL issues that
/// require proper code signing to persist entries silently.
public enum OneloInstanceId {
    private static let key = "onelo.instance_id"

    public static func current() -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
