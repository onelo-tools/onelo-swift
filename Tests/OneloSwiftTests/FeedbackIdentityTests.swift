import XCTest
@testable import OneloSwift

/// #820 — a signed-in Onelo Auth user's report names a VERIFIED reporter: the
/// feedback initiate call carries `Authorization: Bearer <access token>`.
/// Signed out, nothing is sent (anonymous); an explicit `userId` stays an
/// unverified label. Nothing here constructs `Onelo` (keychain).
@MainActor
final class FeedbackIdentityTests: XCTestCase {

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var seen: [[String: String]] = []
        nonisolated(unsafe) static var statuses: [Int] = []
        nonisolated(unsafe) static var lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "feedback-820.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            if request.url?.path.contains("/api/sdk/feedback/initiate") == true {
                Self.seen.append(request.allHTTPHeaderFields ?? [:])
            }
            let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
            Self.lock.unlock()
            let json: [String: Any] = status == 200
                ? ["hosted_url": "https://onelo.tools/feedback/hosted?ft=x"]
                : ["detail": ["error": "invalid_user_token"]]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        StubProtocol.lock.lock()
        StubProtocol.seen = []
        StubProtocol.statuses = []
        StubProtocol.lock.unlock()
    }

    private func makeFeedback(token: String?, refreshed: String? = nil) -> OneloFeedback {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://feedback-820.invalid")!,
            securityContext: _OneloSecurityContext()
        )
        let source = _OneloUserToken(current: { token }, refresh: { refreshed })
        return OneloFeedback(client: client, features: OneloFeatures(client: client), userToken: source)
    }

    private func header(_ i: Int, _ name: String) -> String? {
        StubProtocol.lock.lock(); defer { StubProtocol.lock.unlock() }
        return StubProtocol.seen[i].first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func testSignedInSendsTheAccessTokenAsBearer() async throws {
        let url = try await makeFeedback(token: "AT_1").fetchHostedURL()
        XCTAssertEqual(url.absoluteString, "https://onelo.tools/feedback/hosted?ft=x")
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual(header(0, "Authorization"), "Bearer AT_1")
        XCTAssertNil(header(0, "X-Onelo-User-Id"))
    }

    func testSignedOutIsAnonymous() async throws {
        _ = try await makeFeedback(token: nil).fetchHostedURL()
        XCTAssertNil(header(0, "Authorization"))
        XCTAssertNil(header(0, "X-Onelo-User-Id"))
    }

    func testSignedOutExplicitUserIdStaysAnUnverifiedLabel() async throws {
        _ = try await makeFeedback(token: nil).fetchHostedURL(options: OpenFeedbackOptions(userId: "dev-42"))
        XCTAssertNil(header(0, "Authorization"))
        XCTAssertEqual(header(0, "X-Onelo-User-Id"), "dev-42")
    }

    func testRefusedTokenIsRefreshedOnceAndRetried() async throws {
        StubProtocol.statuses = [401]
        _ = try await makeFeedback(token: "AT_OLD", refreshed: "AT_NEW").fetchHostedURL()
        XCTAssertEqual(StubProtocol.seen.count, 2)
        XCTAssertEqual(header(0, "Authorization"), "Bearer AT_OLD")
        XCTAssertEqual(header(1, "Authorization"), "Bearer AT_NEW")
    }

    func testRefusedAfterRefreshStillOpensWithoutTheToken() async throws {
        StubProtocol.statuses = [401, 401]
        let url = try await makeFeedback(token: "AT_OLD", refreshed: "AT_NEW")
            .fetchHostedURL(options: OpenFeedbackOptions(userId: "dev-42"))
        XCTAssertEqual(url.absoluteString, "https://onelo.tools/feedback/hosted?ft=x")
        XCTAssertEqual(StubProtocol.seen.count, 3)
        XCTAssertNil(header(2, "Authorization"))
        XCTAssertEqual(header(2, "X-Onelo-User-Id"), "dev-42")
    }

    func testANonRefusalErrorStillThrows() async {
        StubProtocol.statuses = [500]
        do {
            _ = try await makeFeedback(token: nil).fetchHostedURL()
            XCTFail("expected a thrown error")
        } catch {}
    }
}
