import Foundation
@testable import OneloSwift

/// Session storage for tests: a dictionary behind a lock (#732).
///
/// Every test builds `OneloAuth` / `Onelo` over this store. The real Keychain
/// is never reached: an ad-hoc-signed `xctest` binary changes identity on every
/// build, so a Keychain read raises a "wants to use com.onelo.auth" dialog and
/// the test hangs until it is answered. `KeychainIsolationGuardTests` fails
/// when a test builds the SDK any other way.
final class InMemorySessionStorage: OneloSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func set(_ value: String, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func get(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func delete(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }

    private var _acceptedRefreshTokens: [String] = []
    /// The refresh tokens `OneloAuth` reported the server accepted (#740).
    var acceptedRefreshTokens: [String] {
        lock.lock(); defer { lock.unlock() }
        return _acceptedRefreshTokens
    }

    func sessionRefreshSucceeded(refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        _acceptedRefreshTokens.append(refreshToken)
    }

    /// Every stored value, for assertions.
    var snapshot: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    /// Seed a complete, restorable session — the fields `restoreSession()`
    /// and `hasStoredSessionSync()` require.
    func storeSession(userId: String, email: String? = nil, expiresIn: TimeInterval = 3600) throws {
        try set("access-\(userId)", forKey: "access_token")
        try set("refresh-\(userId)", forKey: "refresh_token")
        try set(String(Date().addingTimeInterval(expiresIn).timeIntervalSince1970), forKey: "expires_at")
        let user = OneloUser(id: userId, email: email, role: .member, tenantId: nil)
        try set(String(decoding: try JSONEncoder().encode(user), as: UTF8.self), forKey: "user_json")
    }
}

extension Onelo {
    /// The test-suite way to build `Onelo`: same parameters as the public
    /// initializer, over an in-memory store. `skipAuthInitialize` leaves the
    /// auth's `initialize()` (config fetch + session restore) unrun.
    @MainActor
    convenience init(
        testingKey publishableKey: String,
        baseURL: URL,
        callbackScheme: String = "",
        autoLifecycleRefresh: Bool = false,
        featureEnvironment: String? = nil,
        storage: InMemorySessionStorage = InMemorySessionStorage(),
        skipAuthInitialize: Bool = false
    ) {
        self.init(
            publishableKey: publishableKey,
            callbackScheme: callbackScheme,
            baseURL: baseURL,
            autoLifecycleRefresh: autoLifecycleRefresh,
            featureEnvironment: featureEnvironment,
            makeAuth: { config in
                skipAuthInitialize
                    ? OneloAuth(_testingConfig: config, storage: storage)
                    : OneloAuth(config: config, storage: storage)
            }
        )
    }
}
