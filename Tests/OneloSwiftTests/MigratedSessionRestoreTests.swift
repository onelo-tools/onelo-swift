import XCTest
@testable import OneloSwift

/// #740 — a session migrated from the legacy shared Keychain is only its
/// refresh token. The launch restores it with one refresh: the user stays
/// signed in after the upgrade. A refused token (another app's) is cleared.
/// Runs over the in-memory store (#732) with the backend stubbed.
@MainActor
final class MigratedSessionRestoreTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var refreshBodies: [String] = []
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "migration.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            var status = 204
            var json: [String: Any]?
            if path.hasSuffix("/api/sdk/config") {
                status = 200
                json = ["supabase_url": "https://migration.invalid", "supabase_anon_key": "anon",
                        "tenant_id": "tenant-1", "attest_required": false, "paywall_enabled": false]
            } else if path.hasSuffix("/api/sdk/auth/refresh") {
                let body = Self.body(of: request)
                let token = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["refresh_token"] as? String ?? ""
                Self.lock.lock(); Self.refreshBodies.append(token); Self.lock.unlock()
                if token == "legacy-own" {
                    status = 200
                    json = ["session": ["access_token": "access-u1", "refresh_token": "rotated-u1", "expires_in": 3600],
                            "user": ["id": "u1", "email": "u1@example.com", "entitlement": "none"]]
                } else {
                    status = 401
                    json = ["detail": ["error": "session_invalid"]]
                }
            } else if path.hasSuffix("/features/resolve") {
                status = 200
                json = ["features": [:]]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let json { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        private static func body(of request: URLRequest) -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
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

    private let baseURL = URL(string: "https://migration.invalid")!
    private var pk = ""

    override func setUp() {
        super.setUp()
        pk = "onelo_pk_live_migration\(UUID().uuidString.prefix(8))"
        Stub.lock.lock(); Stub.refreshBodies = []; Stub.lock.unlock()
    }

    override func tearDown() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(pk) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_migratedRefreshTokenOnly_isRestoredWithOneRefresh_andTheUserStaysSignedIn() async throws {
        let storage = InMemorySessionStorage(["refresh_token": "legacy-own"])
        let onelo = Onelo(testingKey: pk, baseURL: baseURL, storage: storage)

        XCTAssertTrue(onelo.auth.authObject.hasStoredSessionSync(), "a migrated session must count as restorable")
        XCTAssertTrue(onelo.auth.authObject.isRestoringSession, "the first paint must be the splash, not sign-in")

        await waitUntil { !onelo.auth.authObject.isRestoringSession }

        XCTAssertEqual(onelo.auth.authObject.currentSession?.user.id, "u1", "the migrated session was not restored")
        XCTAssertEqual(Stub.refreshBodies, ["legacy-own"])
        let stored = storage.snapshot
        XCTAssertEqual(stored["access_token"], "access-u1")
        XCTAssertEqual(stored["refresh_token"], "rotated-u1")
        XCTAssertNotNil(stored["user_json"])
        XCTAssertEqual(storage.acceptedRefreshTokens, ["legacy-own"],
                       "the store must be told the server accepted the migrated token (not the rotated one)")
    }

    func test_refusedMigratedToken_isCleared_andTheUserSignsInAgain() async throws {
        let storage = InMemorySessionStorage(["refresh_token": "another-apps"])
        let onelo = Onelo(testingKey: pk, baseURL: baseURL, storage: storage)

        await waitUntil { !onelo.auth.authObject.isRestoringSession }
        await waitUntil { storage.snapshot["refresh_token"] == nil }

        XCTAssertNil(onelo.auth.authObject.currentSession)
        XCTAssertNil(storage.snapshot["refresh_token"], "a refused token must be cleared")
        XCTAssertEqual(storage.acceptedRefreshTokens, [], "a refused token must not complete the migration")
        XCTAssertFalse(onelo.auth.authObject.hasStoredSessionSync())
    }
}
