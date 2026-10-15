import XCTest
@testable import OneloSwift

/// The `Onelo`-level launch, end to end over an in-memory session store (#732,
/// onelo-swift-staging#1 F2/F3). `FeaturesIdentityRaceTests` covers the same
/// rules at the `OneloFeatures` seam; these run the real wiring in `Onelo.init`
/// (the persisted-snapshot seed, the restore watcher, the session watcher)
/// against a real `OneloAuth` whose config fetch and session verify are stubbed.
@MainActor
final class OneloLaunchTests: XCTestCase {

    // MARK: - Transport stub

    struct Captured {
        let path: String
        let authorization: String?
    }

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var captured: [Captured] = []
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "launch.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization")
            Self.lock.lock()
            Self.captured.append(Captured(path: path, authorization: auth))
            Self.lock.unlock()

            let (status, json) = Self.reply(path: path, authorization: auth)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let json { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        /// The backend at launch: the app config, a valid session, and a
        /// snapshot that holds the gated feature only for the signed-in user.
        private static func reply(path: String, authorization: String?) -> (Int, [String: Any]?) {
            if path.hasSuffix("/api/sdk/config") {
                return (200, [
                    "supabase_url": "https://launch.invalid",
                    "supabase_anon_key": "anon",
                    "tenant_id": "tenant-1",
                    "attest_required": false,
                    "paywall_enabled": false,
                ])
            }
            if path.hasSuffix("/api/sdk/auth/verify") { return (200, [:]) }
            if path.hasSuffix("/features/resolve") {
                let enabled = authorization == "Bearer access-u1" ? ["basic", "pro-export"] : ["basic"]
                var features: [String: Any] = [:]
                for name in enabled { features[name] = ["status": "enabled"] }
                return (200, ["features": features])
            }
            return (204, nil)
        }

        static func requests(_ suffix: String) -> [Captured] {
            lock.lock(); defer { lock.unlock() }
            return captured.filter { $0.path.hasSuffix(suffix) }
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(Stub.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(Stub.self)
        super.tearDown()
    }

    private let baseURL = URL(string: "https://launch.invalid")!
    /// A fresh key per test, so persisted snapshots never leak between tests.
    private var pk = ""

    override func setUp() {
        super.setUp()
        pk = "onelo_pk_live_launch\(UUID().uuidString.prefix(8))"
        Stub.lock.lock(); Stub.captured = []; Stub.lock.unlock()
    }

    override func tearDown() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.contains(".\(pk).") || key.hasSuffix(".\(pk)") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func persist(_ userId: String?, enabled: [String], key: String? = nil) {
        var features: [String: Any] = [:]
        for name in enabled { features[name] = ["status": "enabled"] }
        let json: [String: Any] = ["config_version": 3, "features": features]
        UserDefaults.standard.set(try! JSONSerialization.data(withJSONObject: json),
                                  forKey: "io.onelo.features.\(key ?? pk).\(userId ?? "anon")")
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: - F2: launch → restore → identity-bound features → complete first render

    /// An app with a stored session launches and awaits `ready()` before its
    /// first gated render. The restore runs (config, verify), the session
    /// becomes the stored user, and the first render is that user's COMPLETE
    /// snapshot. Features never resolve anonymously on the way.
    func test_launchWithAStoredSession_firstRenderIsTheRestoredUsersCompleteSnapshot() async throws {
        let storage = InMemorySessionStorage()
        try storage.storeSession(userId: "u1")
        // The last snapshot this user saw, from an older plan.
        persist("u1", enabled: ["basic"])

        let onelo = Onelo(testingKey: pk, baseURL: baseURL, storage: storage)

        // First paint, before the restore: the stored user's snapshot, unconfirmed.
        XCTAssertTrue(onelo.auth.authObject.isRestoringSession)
        XCTAssertEqual(onelo.features.feature("basic").status, .enabled)
        XCTAssertFalse(onelo.features.isSnapshotConfirmed, "a persisted snapshot is not a confirmed one")

        await onelo.features.ready(timeout: 5)
        let firstRender = (onelo.features.feature("basic").status,
                           onelo.features.feature("pro-export").status)

        XCTAssertTrue(onelo.features.isSnapshotConfirmed, "ready() returned without a confirmed snapshot")
        XCTAssertEqual(onelo.auth.authObject.currentSession?.user.id, "u1", "the session was not restored")
        XCTAssertFalse(onelo.auth.authObject.isRestoringSession)
        XCTAssertEqual(firstRender.0, .enabled)
        XCTAssertEqual(firstRender.1, .enabled, "the first render was missing the user's gated feature")
        XCTAssertFalse(Stub.requests("/api/sdk/auth/verify").isEmpty, "the restore did not verify the session")
        let resolves = Stub.requests("/features/resolve")
        XCTAssertFalse(resolves.isEmpty)
        XCTAssertTrue(resolves.allSatisfy { $0.authorization == "Bearer access-u1" },
                      "features resolved for someone other than the restored user: \(resolves.map(\.authorization))")
    }

    // MARK: - F3: a restore that never finishes

    /// The defined behaviour when `restoreSession()` never completes: features
    /// stay on the stored user's persisted snapshot, unconfirmed. Nothing
    /// resolves anonymously: `refresh()` gives up after the bounded wait with no
    /// request, `ready()` times out, and nothing is persisted for no user.
    func test_aRestoreThatNeverFinishes_keepsTheStoredUsersSnapshot_andNeverResolvesAnonymously() async throws {
        let storage = InMemorySessionStorage()
        try storage.storeSession(userId: "u1")
        persist("u1", enabled: ["basic", "pro-export"])

        // The auth's initialize() never runs, so the restore it would start
        // never finishes: `isRestoringSession` stays true for the whole test.
        let onelo = Onelo(testingKey: pk, baseURL: baseURL, storage: storage, skipAuthInitialize: true)
        onelo.features._identitySettleTimeout = 0.2
        XCTAssertTrue(onelo.auth.authObject.isRestoringSession)

        await onelo.features.refresh(force: true)
        await onelo.features.ready(timeout: 0.3)
        try await Task.sleep(nanoseconds: 200_000_000)  // let the launch watchers run

        XCTAssertTrue(onelo.auth.authObject.isRestoringSession)
        XCTAssertTrue(Stub.requests("/features/resolve").isEmpty, "resolved while the restore was still pending")
        XCTAssertEqual(onelo.features.feature("pro-export").status, .enabled, "the stored user's snapshot was replaced")
        XCTAssertFalse(onelo.features.isSnapshotConfirmed, "ready() released with no confirmed snapshot")
        XCTAssertNil(UserDefaults.standard.data(forKey: "io.onelo.features.\(pk).anon"),
                     "an anonymous snapshot was persisted")
    }

    /// A rejected publishable key ends the restore: the stored session is
    /// cleared, so nothing can be restored. The signed-out identity then loads,
    /// instead of features waiting for an identity that never comes.
    func test_aRejectedPublishableKey_endsTheRestore_andLoadsTheSignedOutIdentity() async throws {
        let storage = InMemorySessionStorage()
        try storage.storeSession(userId: "u1")
        // Not `onelo_pk_…`: rejected before any request.
        let badKey = "pk_rejected\(UUID().uuidString.prefix(8))"
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(badKey) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let onelo = Onelo(testingKey: badKey, baseURL: baseURL, storage: storage)
        await waitUntil { !onelo.auth.authObject.isRestoringSession }
        await waitUntil { !Stub.requests("/features/resolve").isEmpty }

        XCTAssertTrue(onelo.auth.authObject.isRevoked)
        XCTAssertFalse(onelo.auth.authObject.isRestoringSession, "the restore never ended")
        XCTAssertNil(onelo.auth.authObject.currentSession)
        XCTAssertFalse(onelo.auth.authObject.hasStoredSessionSync(), "the stored session was not cleared")
        let resolves = Stub.requests("/features/resolve")
        XCTAssertFalse(resolves.isEmpty, "the signed-out identity never loaded")
        XCTAssertTrue(resolves.allSatisfy { $0.authorization == nil })
    }

    // MARK: - #731: ready() after a sign-in waits for the signed-in user

    /// An app launches signed out, so the anonymous snapshot is confirmed. The
    /// user signs in, and the app awaits `ready()` straight from the session
    /// change, as a sink on `isAllowedIn` does: that runs before the session
    /// watcher loads the new identity. `ready()` must wait for the signed-in
    /// user's snapshot instead of returning on the anonymous confirmation.
    func test_readyRightAfterASignIn_waitsForTheSignedInUsersSnapshot() async throws {
        let onelo = Onelo(testingKey: pk, baseURL: baseURL)
        await waitUntil { !onelo.auth.authObject.isRestoringSession }
        await onelo.features.ready(timeout: 5)
        XCTAssertTrue(onelo.features.isSnapshotConfirmed, "the signed-out launch never confirmed a snapshot")
        XCTAssertNotEqual(onelo.features.feature("pro-export").status, .enabled)

        let user = OneloUser(id: "u1", email: nil, role: .member, tenantId: nil)
        onelo.auth.authObject._injectSessionForTesting(OneloSession(
            accessToken: "access-u1", refreshToken: "refresh-u1",
            expiresAt: Date().addingTimeInterval(3600), user: user))
        // The observable signal turns false with the session change itself.
        XCTAssertFalse(onelo.features.isSnapshotConfirmed,
                       "the anonymous snapshot still reads as confirmed for the signed-in user")

        await onelo.features.ready(timeout: 5)

        XCTAssertTrue(onelo.features.isSnapshotConfirmed, "ready() returned without a confirmed snapshot")
        XCTAssertEqual(onelo.features.feature("pro-export").status, .enabled,
                       "ready() returned on the anonymous snapshot, so gated UI opened without the user's feature")
    }
}
