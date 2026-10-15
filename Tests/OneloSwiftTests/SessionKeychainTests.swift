import XCTest
import Security
@testable import OneloSwift

/// #740 — the per-app session store: where items go (data protection keychain
/// or the file-based fallback), per-app scoping, and the one-time migration from
/// the legacy shared `com.onelo.auth` service. Runs over `FakeKeychainBackend`;
/// no test reaches the real Keychain (#732).
final class SessionKeychainTests: XCTestCase {

    /// A keychain in memory, split by location, that counts calls and can
    /// answer chosen statuses the way the real one would.
    final class FakeKeychainBackend: OneloKeychainBackend, @unchecked Sendable {
        struct Item: Hashable { let location: OneloKeychainLocation; let service: String; let account: String }

        private let lock = NSLock()
        var entitled: Bool
        /// The process lacks the entitlement after all: every data protection call
        /// answers errSecMissingEntitlement.
        var dataProtectionMissingEntitlement = false
        /// Status the legacy read answers instead of the item (e.g. user denied).
        var legacyReadStatus: OSStatus?
        private(set) var items: [Item: String] = [:]
        private(set) var reads: [Item] = []
        private(set) var deletesAll: [(OneloKeychainLocation, String)] = []

        init(entitled: Bool) { self.entitled = entitled }

        func seed(_ value: String, service: String, account: String, in location: OneloKeychainLocation) {
            lock.lock(); defer { lock.unlock() }
            items[Item(location: location, service: service, account: account)] = value
        }

        func value(service: String, account: String, in location: OneloKeychainLocation) -> String? {
            lock.lock(); defer { lock.unlock() }
            return items[Item(location: location, service: service, account: account)]
        }

        func reads(service: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return reads.filter { $0.service == service }.count
        }

        private func refused(_ location: OneloKeychainLocation) -> Bool {
            location == .dataProtection && dataProtectionMissingEntitlement
        }

        func processHasKeychainEntitlement() -> Bool { entitled }

        func read(service: String, account: String, in location: OneloKeychainLocation) -> (status: OSStatus, value: String?) {
            lock.lock(); defer { lock.unlock() }
            let item = Item(location: location, service: service, account: account)
            reads.append(item)
            if refused(location) { return (errSecMissingEntitlement, nil) }
            if service == OneloSessionKeychain.legacyService, let status = legacyReadStatus { return (status, nil) }
            guard let value = items[item] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, value)
        }

        func write(_ value: String, service: String, account: String, in location: OneloKeychainLocation) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            if refused(location) { return errSecMissingEntitlement }
            items[Item(location: location, service: service, account: account)] = value
            return errSecSuccess
        }

        func delete(service: String, account: String, in location: OneloKeychainLocation) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            if refused(location) { return errSecMissingEntitlement }
            return items.removeValue(forKey: Item(location: location, service: service, account: account)) == nil
                ? errSecItemNotFound : errSecSuccess
        }

        /// Removes ONE matching item per call, like the file-based keychain can.
        func deleteAll(service: String, in location: OneloKeychainLocation) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            deletesAll.append((location, service))
            if refused(location) { return errSecMissingEntitlement }
            guard let item = items.keys.first(where: { $0.location == location && $0.service == service }) else {
                return errSecItemNotFound
            }
            items[item] = nil
            return errSecSuccess
        }
    }

    private let legacy = OneloSessionKeychain.legacyService
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "onelo.tests.session-keychain.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store(_ backend: FakeKeychainBackend, bundle: String = "pl.example.app") -> OneloSessionKeychain {
        OneloSessionKeychain(
            service: OneloSessionKeychain.serviceName(bundleIdentifier: bundle, processName: "App"),
            backend: backend,
            defaults: defaults
        )
    }

    // MARK: - Per-app scope

    func test_serviceIsScopedToTheApp_neverTheLegacySharedService() {
        XCTAssertEqual(OneloSessionKeychain.serviceName(bundleIdentifier: "pl.turingo.app", processName: "Turingo"),
                       "com.onelo.auth.pl.turingo.app")
        XCTAssertEqual(OneloSessionKeychain.serviceName(bundleIdentifier: nil, processName: "tool"), "com.onelo.auth.tool")
        XCTAssertEqual(OneloSessionKeychain.serviceName(bundleIdentifier: "", processName: "tool"), "com.onelo.auth.tool")
        XCTAssertNotEqual(OneloSessionKeychain.serviceName(bundleIdentifier: nil, processName: ""), legacy)
    }

    func test_twoAppsOnOneMac_keepSeparateSessions() throws {
        let backend = FakeKeychainBackend(entitled: false)
        let a = store(backend, bundle: "com.example.a")
        let b = store(backend, bundle: "com.example.b")
        try a.set("refresh-a", forKey: "refresh_token")
        try b.set("refresh-b", forKey: "refresh_token")

        XCTAssertEqual(try a.get(forKey: "refresh_token"), "refresh-a")
        XCTAssertEqual(try b.get(forKey: "refresh_token"), "refresh-b")
        try a.clear()
        XCTAssertNil(try a.get(forKey: "refresh_token"))
        XCTAssertEqual(try b.get(forKey: "refresh_token"), "refresh-b", "one app's sign-out cleared another app's session")
    }

    // MARK: - Location: data protection keychain or the fallback

    func test_entitledApp_usesTheDataProtectionKeychain_forStoreRestoreAndClear() throws {
        let backend = FakeKeychainBackend(entitled: true)
        let s = store(backend)
        XCTAssertEqual(s.location, .dataProtection)

        try s.set("refresh-1", forKey: "refresh_token")
        XCTAssertEqual(backend.value(service: s.service, account: "refresh_token", in: .dataProtection), "refresh-1")
        XCTAssertNil(backend.value(service: s.service, account: "refresh_token", in: .fileBased),
                     "an entitled app wrote to the file-based keychain")
        XCTAssertEqual(try s.get(forKey: "refresh_token"), "refresh-1")
        try s.clear()
        XCTAssertNil(try s.get(forKey: "refresh_token"))
        XCTAssertTrue(backend.deletesAll.allSatisfy { $0.0 == .dataProtection || $0.1 == legacy })
    }

    func test_dataProtectionQueries_carryTheFlag_andNoAccessGroup() {
        let dp = OneloKeychainQuery.base(service: "com.onelo.auth.x", account: "refresh_token", location: .dataProtection)
        XCTAssertEqual(dp[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertNil(dp[kSecAttrAccessGroup as String], "the app's default access group must be used")
        XCTAssertEqual(dp[kSecAttrService as String] as? String, "com.onelo.auth.x")
        XCTAssertEqual(dp[kSecAttrAccount as String] as? String, "refresh_token")

        let file = OneloKeychainQuery.base(service: "com.onelo.auth.x", account: nil, location: .fileBased)
        XCTAssertNil(file[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(file[kSecAttrAccount as String])
    }

    /// Unsigned / ad-hoc / Developer ID without a provisioning profile: no
    /// entitlement, so the per-app file-based fallback, decided without any
    /// keychain call.
    func test_unsignedDevBuild_usesThePerAppFileBasedFallback() throws {
        let backend = FakeKeychainBackend(entitled: false)
        let s = store(backend)
        XCTAssertEqual(s.location, .fileBased)

        try s.set("refresh-1", forKey: "refresh_token")
        XCTAssertEqual(backend.value(service: "com.onelo.auth.pl.example.app", account: "refresh_token", in: .fileBased),
                       "refresh-1")
        XCTAssertNil(backend.value(service: legacy, account: "refresh_token", in: .fileBased))
        XCTAssertEqual(try s.get(forKey: "refresh_token"), "refresh-1")
    }

    func test_missingEntitlementAtRuntime_switchesToTheFallback_andKeepsWorking() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.dataProtectionMissingEntitlement = true
        let s = store(backend)

        try s.set("refresh-1", forKey: "refresh_token")
        XCTAssertEqual(s.location, .fileBased)
        XCTAssertEqual(backend.value(service: s.service, account: "refresh_token", in: .fileBased), "refresh-1")
        XCTAssertEqual(try s.get(forKey: "refresh_token"), "refresh-1")
        try s.clear()
        XCTAssertNil(try s.get(forKey: "refresh_token"))
    }

    // MARK: - One-time migration from the legacy shared service

    func test_signedInUser_staysSignedIn_afterUpgrade_legacyRefreshTokenIsMigratedOnce() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        backend.seed("legacy-access", service: legacy, account: "access_token", in: .fileBased)
        let s = store(backend)

        XCTAssertEqual(try s.get(forKey: "refresh_token"), "legacy-refresh")
        XCTAssertNil(try s.get(forKey: "access_token"), "only the refresh token is migrated")
        XCTAssertEqual(backend.value(service: s.service, account: "refresh_token", in: .dataProtection), "legacy-refresh")
        XCTAssertEqual(backend.reads(service: legacy), 1, "the legacy store must be read once (one possible prompt)")
        XCTAssertEqual(s.migrationState, .pending(tokenHash: OneloSessionKeychain.tokenHash("legacy-refresh")))

        // The next launch reads nothing from the legacy store again.
        let next = store(backend)
        _ = try next.get(forKey: "refresh_token")
        XCTAssertEqual(backend.reads(service: legacy), 1)
    }

    func test_acceptedRefresh_deletesTheLegacyItems() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        backend.seed("legacy-access", service: legacy, account: "access_token", in: .fileBased)
        backend.seed("x", service: legacy, account: "user_json", in: .fileBased)
        let s = store(backend)
        _ = try s.get(forKey: "refresh_token")

        s.sessionRefreshSucceeded(refreshToken: "legacy-refresh")

        XCTAssertNil(backend.value(service: legacy, account: "refresh_token", in: .fileBased))
        XCTAssertNil(backend.value(service: legacy, account: "access_token", in: .fileBased))
        XCTAssertNil(backend.value(service: legacy, account: "user_json", in: .fileBased))
        XCTAssertEqual(s.migrationState, .done)
    }

    /// The legacy token may be another app's (every app shared the service).
    /// The server refuses it and the session is cleared: the legacy items stay
    /// for their owner, and a later sign-in in this app never deletes them.
    func test_refusedMigratedToken_keepsTheLegacyItemsForTheirOwner() throws {
        let backend = FakeKeychainBackend(entitled: false)
        backend.seed("other-apps-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        let s = store(backend)
        _ = try s.get(forKey: "refresh_token")

        try s.clear()  // OneloAuth on a refused refresh
        try s.set("own-refresh", forKey: "refresh_token")  // the user signs in
        s.sessionRefreshSucceeded(refreshToken: "own-refresh")

        XCTAssertEqual(backend.value(service: legacy, account: "refresh_token", in: .fileBased), "other-apps-refresh")
        XCTAssertEqual(s.migrationState, .done)
    }

    func test_deniedLegacyRead_signsTheUserInAgain_andIsNeverRetried() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        backend.legacyReadStatus = errSecAuthFailed  // the user clicked Deny
        let s = store(backend)

        XCTAssertNil(try s.get(forKey: "refresh_token"))
        XCTAssertEqual(s.migrationState, .done)
        backend.legacyReadStatus = nil
        _ = try store(backend).get(forKey: "refresh_token")
        XCTAssertEqual(backend.reads(service: legacy), 1, "a denied migration was retried (a second prompt)")
    }

    func test_storeWithItsOwnSession_neverReadsTheLegacyStore() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        let s0 = store(backend)
        backend.seed("own-refresh", service: s0.service, account: "refresh_token", in: .dataProtection)

        XCTAssertEqual(try s0.get(forKey: "refresh_token"), "own-refresh")
        XCTAssertEqual(backend.reads(service: legacy), 0)
        XCTAssertEqual(s0.migrationState, .done)
    }

    func test_freshInstall_withNoLegacySession_migratesNothing() throws {
        let backend = FakeKeychainBackend(entitled: true)
        let s = store(backend)
        XCTAssertNil(try s.get(forKey: "refresh_token"))
        XCTAssertEqual(s.migrationState, .done)
        s.sessionRefreshSucceeded(refreshToken: "own-refresh")
        XCTAssertTrue(backend.deletesAll.isEmpty, "nothing migrated, so nothing legacy to delete")
    }

    /// The unsigned fallback migrates the same way: legacy file-based shared
    /// service → per-app file-based service.
    func test_unsignedDevBuild_migratesIntoThePerAppFallback() throws {
        let backend = FakeKeychainBackend(entitled: false)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        let s = store(backend)
        XCTAssertEqual(try s.get(forKey: "refresh_token"), "legacy-refresh")
        XCTAssertEqual(backend.value(service: s.service, account: "refresh_token", in: .fileBased), "legacy-refresh")
    }

    /// Review R1: the first refresh of the migrated token fails transiently
    /// (offline, 429, 5xx), so the migration stays pending; the user signs in
    /// afresh; a later accepted refresh of THAT new token proves nothing about
    /// the legacy session. It may be another app's: keep it.
    func test_pendingMigration_thenAFreshSignIn_neverDeletesTheLegacyItems() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        let s = store(backend)
        _ = try s.get(forKey: "refresh_token")  // migrated, pending
        // No clear(): a transient failure keeps the session; sign-in overwrites it.
        try s.set("signed-in-refresh", forKey: "refresh_token")
        try s.set("signed-in-access", forKey: "access_token")

        s.sessionRefreshSucceeded(refreshToken: "signed-in-refresh")

        XCTAssertEqual(backend.value(service: legacy, account: "refresh_token", in: .fileBased), "legacy-refresh",
                       "a refresh of a token other than the migrated one deleted the legacy session")
        XCTAssertTrue(backend.deletesAll.filter { $0.1 == legacy }.isEmpty)
        XCTAssertEqual(s.migrationState, .done)
    }

    func test_pendingMigration_survivesARelaunch_andCompletesOnTheMigratedToken() throws {
        let backend = FakeKeychainBackend(entitled: true)
        backend.seed("legacy-refresh", service: legacy, account: "refresh_token", in: .fileBased)
        _ = try store(backend).get(forKey: "refresh_token")  // launch 1: migrated, refresh failed offline

        let relaunched = store(backend)
        relaunched.sessionRefreshSucceeded(refreshToken: "legacy-refresh")

        XCTAssertNil(backend.value(service: legacy, account: "refresh_token", in: .fileBased))
        XCTAssertEqual(relaunched.migrationState, .done)
    }
}
