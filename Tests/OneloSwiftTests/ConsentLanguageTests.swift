import XCTest
@testable import OneloSwift

/// #1073 — the consent check sends the device language; the backend picks the
/// Page Language and links each legal document in it. Same query as every SDK.
/// Storage is in memory: no Keychain prompt.
@MainActor
final class ConsentLanguageTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var urls: [URL] = []
        static let lock = NSLock()
        static let host = "consent1073.example.invalid"

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // Only the consent check: a session injection also sends a
            // presence heartbeat, which must not stand in for it.
            if request.url?.path == "/v1/sdk/consent/required" {
                Self.lock.withLock { Self.urls.append(request.url!) }
            }
            let reply: [String: Any] = ["required": [[
                "doc_type": "terms", "version_id": "v-1", "version": "2026-06-01",
                "enforcement": "block", "blocking": true,
                "url": "https://app/legal/t/a/terms?language=de",
                "consent_url": "https://app/legal/t/a/terms?language=de&gate=1",
            ]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(Stub.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(Stub.self)
        super.tearDown()
    }

    func test_required_consents_sends_the_device_language() async throws {
        let auth = OneloAuth(
            config: OneloConfig(
                publishableKey: "onelo_pk_test_stub",
                apiUrl: URL(string: "https://\(Stub.host)")!,
                callbackScheme: "turingo"
            ),
            urlSession: .shared,
            skipInitialize: true,
            storage: InMemorySessionStorage()
        )
        auth._injectSessionForTesting(OneloSession(
            accessToken: "tok", refreshToken: "ref", expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u1", email: "a@b.c", role: .member, tenantId: nil)
        ))

        let items = await auth.requiredConsents()

        let url = try XCTUnwrap(Stub.lock.withLock { Stub.urls.last(where: { $0.path == "/v1/sdk/consent/required" }) })
        XCTAssertEqual(url.path, "/v1/sdk/consent/required")
        let lang = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "lang" })?.value
        XCTAssertEqual(lang, OneloSignupMarketingConsent.deviceLanguage)
        XCTAssertEqual(items.first?.url?.absoluteString, "https://app/legal/t/a/terms?language=de")
    }
}
