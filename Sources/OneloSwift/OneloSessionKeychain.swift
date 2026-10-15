import CryptoKit
import Foundation
import Security
import os

private let _keychainLog = Logger(subsystem: "com.onelo.sdk", category: "keychain")

/// Which keychain implementation a SecItem call targets on macOS (TN3137).
/// iOS has only the data protection keychain and ignores the difference.
enum OneloKeychainLocation: Equatable, Sendable {
    /// `kSecUseDataProtectionKeychain: true`. Items belong to the app's
    /// keychain access group: no per-binary ACL, no "wants to use" prompt.
    case dataProtection
    /// The macOS file-based (login) keychain. Items carry a per-binary ACL.
    case fileBased
}

/// The raw keychain calls behind `OneloSessionKeychain`, one per operation,
/// each answering an `OSStatus`. The SDK's real backend is
/// `SecItemKeychainBackend`; tests inject a fake and never reach the real
/// Keychain (#732).
protocol OneloKeychainBackend: Sendable {
    /// True when the running process carries an entitlement that gives it a
    /// data protection keychain access group (app identifier or
    /// keychain-access-groups). Reads the code signature only: no keychain call,
    /// so no prompt.
    func processHasKeychainEntitlement() -> Bool
    func read(service: String, account: String, in location: OneloKeychainLocation) -> (status: OSStatus, value: String?)
    /// Replace the value, or add the item when there is none.
    func write(_ value: String, service: String, account: String, in location: OneloKeychainLocation) -> OSStatus
    func delete(service: String, account: String, in location: OneloKeychainLocation) -> OSStatus
    /// Delete the items of `service`. May remove only some of them per call on
    /// the file-based keychain, so callers repeat it until `errSecItemNotFound`.
    func deleteAll(service: String, in location: OneloKeychainLocation) -> OSStatus
}

/// The session store every app gets (#740).
///
/// - **Per app.** The service is `com.onelo.auth.<bundle id>`, so two apps on
///   one Mac never read or overwrite each other's session. Before #740 every
///   app shared `com.onelo.auth`, and each one hit the others' ACLs.
/// - **Data protection keychain where possible.** When the host app carries
///   an app identifier or keychain-access-groups entitlement (a provisioning
///   profile), items go to the data protection keychain, in the app's default
///   access group. Access there follows the app's identity, not a per-binary
///   ACL, so there is no prompt, also across rebuilds. On iOS this is the only
///   keychain.
/// - **Fallback.** A macOS process without that entitlement (unsigned, ad-hoc,
///   or Developer ID without a provisioning profile) cannot use the data
///   protection keychain (`errSecMissingEntitlement`). It uses the file-based
///   keychain under the same per-app service. A data protection call that
///   still answers `errSecMissingEntitlement` switches to the fallback for the
///   rest of the process.
/// - **One-time migration.** The first time this store is used and holds no
///   refresh token, it reads ONE legacy item, `refresh_token` under the shared
///   `com.onelo.auth` service, and copies it here. A per-app marker in
///   UserDefaults is written before that read, so it happens at most once ever
///   (and can prompt at most once). `OneloAuth` then restores the session with
///   that token. Only after the server accepts THAT token
///   (`sessionRefreshSucceeded(refreshToken:)`, matched by its SHA-256 kept
///   with the marker) are the legacy items deleted. If the server refuses it,
///   it may be another app's session: `clear()` abandons the migration and
///   keeps the legacy items. An accepted refresh of any other token (the user
///   signed in afresh while the migration was pending) abandons it as well.
final class OneloSessionKeychain: OneloSessionStorage, @unchecked Sendable {
    /// The shared service every app used before #740.
    static let legacyService = "com.onelo.auth"
    /// The one legacy item the migration reads.
    static let migratedAccount = "refresh_token"

    enum MigrationState: Equatable {
        /// A legacy refresh token (by its SHA-256) was copied here; the server
        /// has not yet accepted it.
        case pending(tokenHash: String)
        /// Nothing left to do: migrated and cleaned up, nothing to migrate, or abandoned.
        case done

        init?(marker: String) {
            if marker == "done" { self = .done; return }
            guard marker.hasPrefix("pending:") else { return nil }
            self = .pending(tokenHash: String(marker.dropFirst("pending:".count)))
        }

        var marker: String {
            switch self {
            case .pending(let hash): return "pending:\(hash)"
            case .done: return "done"
            }
        }

        var isPending: Bool { if case .pending = self { return true } else { return false } }
    }

    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `com.onelo.auth.<bundle id>`, or `com.onelo.auth.<process name>` for a
    /// process without a bundle id. Never the legacy shared service.
    static func serviceName(bundleIdentifier: String?, processName: String) -> String {
        let id = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? processName
        return "\(legacyService).\(id.isEmpty ? "unknown" : id)"
    }

    let service: String
    private let legacyService: String
    private let backend: any OneloKeychainBackend
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var _location: OneloKeychainLocation
    private var migrationChecked = false

    init(service: String,
         legacyService: String = OneloSessionKeychain.legacyService,
         backend: any OneloKeychainBackend,
         defaults: UserDefaults) {
        self.service = service
        self.legacyService = legacyService
        self.backend = backend
        self.defaults = defaults
        self._location = backend.processHasKeychainEntitlement() ? .dataProtection : .fileBased
    }

    /// Where this store's items live right now.
    var location: OneloKeychainLocation {
        lock.lock(); defer { lock.unlock() }
        return _location
    }

    var migrationMarkerKey: String { "onelo.session_keychain.legacy_migration.\(service)" }

    var migrationState: MigrationState? {
        defaults.string(forKey: migrationMarkerKey).flatMap(MigrationState.init(marker:))
    }

    // MARK: - OneloSessionStorage

    func set(_ value: String, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        migrateLegacySessionIfNeeded()
        let status = run { self.backend.write(value, service: self.service, account: key, in: $0) }
        guard status == errSecSuccess else {
            throw OneloError.keychainError("Keychain write failed with status: \(status)")
        }
    }

    func get(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        migrateLegacySessionIfNeeded()
        return try read(key)
    }

    func delete(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        migrateLegacySessionIfNeeded()
        let status = run { self.backend.delete(service: self.service, account: key, in: $0) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OneloError.keychainError("Keychain delete failed with status: \(status)")
        }
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        migrateLegacySessionIfNeeded()
        // The session is over before the server accepted a migrated token: it
        // may be another app's. Keep the legacy items for their owner.
        if migrationState?.isPending == true { setMigrationState(.done) }
        // Repeat: the file-based keychain may delete only some matches per call.
        for _ in 0..<100 {
            let status = run { self.backend.deleteAll(service: self.service, in: $0) }
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else {
                throw OneloError.keychainError("Keychain clear failed with status: \(status)")
            }
        }
        throw OneloError.keychainError("Keychain clear did not drain after 100 iterations")
    }

    func sessionRefreshSucceeded(refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        guard case .pending(let migratedHash)? = migrationState else { return }
        guard Self.tokenHash(refreshToken) == migratedHash else {
            // The accepted token is not the migrated one (the user signed in
            // afresh): nothing proves the legacy session is this app's. Keep it.
            setMigrationState(.done)
            return
        }
        // Best effort: the session is now this app's own; the legacy copy is stale.
        for _ in 0..<100 {
            let status = backend.deleteAll(service: legacyService, in: .fileBased)
            if status != errSecSuccess { break }
        }
        setMigrationState(.done)
        _keychainLog.info("legacy com.onelo.auth session removed after migration")
    }

    // MARK: - Internals

    private func read(_ key: String) throws -> String? {
        let result = runRead { self.backend.read(service: self.service, account: key, in: $0) }
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let value = result.value else {
            throw OneloError.keychainError("Keychain read failed with status: \(result.status)")
        }
        return value
    }

    /// Run `op` in the current location; on `errSecMissingEntitlement` from the
    /// data protection keychain, switch to the file-based fallback for the rest
    /// of the process and run it there.
    private func run(_ op: (OneloKeychainLocation) -> OSStatus) -> OSStatus {
        runRead { (status: op($0), value: nil) }.status
    }

    private func runRead(_ op: (OneloKeychainLocation) -> (status: OSStatus, value: String?)) -> (status: OSStatus, value: String?) {
        let result = op(_location)
        guard result.status == errSecMissingEntitlement, _location == .dataProtection else { return result }
        _location = .fileBased
        _keychainLog.error("data protection keychain refused (errSecMissingEntitlement); using the file-based keychain for this process")
        return op(.fileBased)
    }

    private func setMigrationState(_ state: MigrationState?) {
        if let state { defaults.set(state.marker, forKey: migrationMarkerKey) }
        else { defaults.removeObject(forKey: migrationMarkerKey) }
    }

    /// Once per process, and at most once per app ever: copy the legacy
    /// shared refresh token into this store when this store has none.
    private func migrateLegacySessionIfNeeded() {
        guard !migrationChecked else { return }
        migrationChecked = true
        guard migrationState == nil, legacyService != service else { return }

        let own = runRead { self.backend.read(service: self.service, account: Self.migratedAccount, in: $0) }
        if own.status == errSecSuccess {
            setMigrationState(.done)  // already holds a session — nothing to migrate
            return
        }
        // This store could not be read (locked, transient). Decide on a later launch.
        guard own.status == errSecItemNotFound else { return }

        // Mark BEFORE the legacy read: whatever happens (denied, cancelled,
        // crash), it is never attempted again, so it can prompt at most once.
        setMigrationState(.done)
        let legacy = backend.read(service: legacyService, account: Self.migratedAccount, in: .fileBased)
        guard legacy.status == errSecSuccess, let token = legacy.value, !token.isEmpty else {
            if legacy.status != errSecItemNotFound {
                _keychainLog.error("legacy session not migrated (status \(legacy.status, privacy: .public)); the user signs in again")
            }
            return
        }
        let wrote = run { self.backend.write(token, service: self.service, account: Self.migratedAccount, in: $0) }
        guard wrote == errSecSuccess else {
            _keychainLog.error("legacy session not migrated: write failed (status \(wrote, privacy: .public))")
            return
        }
        setMigrationState(.pending(tokenHash: Self.tokenHash(token)))
        _keychainLog.info("legacy com.onelo.auth refresh token migrated to \(self.service, privacy: .public)")
    }
}

/// The query every SecItem call starts from. Pure: builds a dictionary and
/// never calls the Keychain, so it is unit-tested directly.
enum OneloKeychainQuery {
    static func base(service: String, account: String?, location: OneloKeychainLocation) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        // Apple: set it for every operation (add, search, update, delete) that
        // targets the data protection keychain. No kSecAttrAccessGroup: the
        // app's default (first) access group, private to the app.
        if location == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

/// The real backend: SecItem calls. Only `OneloSessionStorageFactory.production()`
/// builds it.
struct SecItemKeychainBackend: OneloKeychainBackend {
    func processHasKeychainEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        for entitlement in ["com.apple.application-identifier", "keychain-access-groups"] {
            if SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil { return true }
        }
        return false
        #else
        return true  // iOS: the data protection keychain is the only keychain
        #endif
    }

    func read(service: String, account: String, in location: OneloKeychainLocation) -> (status: OSStatus, value: String?) {
        var query = OneloKeychainQuery.base(service: service, account: account, location: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return (errSecDecode, nil)
        }
        return (status, value)
    }

    func write(_ value: String, service: String, account: String, in location: OneloKeychainLocation) -> OSStatus {
        let query = OneloKeychainQuery.base(service: service, account: account, location: location)
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete(service: String, account: String, in location: OneloKeychainLocation) -> OSStatus {
        SecItemDelete(OneloKeychainQuery.base(service: service, account: account, location: location) as CFDictionary)
    }

    func deleteAll(service: String, in location: OneloKeychainLocation) -> OSStatus {
        SecItemDelete(OneloKeychainQuery.base(service: service, account: nil, location: location) as CFDictionary)
    }
}
