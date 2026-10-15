import XCTest
@testable import OneloSwift

/// #818 — Marketing Consent for an app's own screens: the sign-up question from
/// `/api/sdk/config`, `signUp(…, marketingConsent:)` and the waitlist consent
/// flags. The stub answers only its own host.
@MainActor
final class MarketingConsentTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var calls: [(path: String, query: String?, body: [String: Any])] = []
        static let lock = NSLock()
        static let host = "mc818.example.invalid"

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    collected.append(buf, count: n)
                }
                data = collected
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let path = request.url?.path ?? ""
            Self.lock.withLock { Self.calls.append((path, request.url?.query, json)) }
            let reply: [String: Any]
            if path.hasSuffix("/api/sdk/config") {
                reply = [
                    "supabase_url": "https://supabase.example.invalid", "supabase_anon_key": "anon",
                    "tenant_id": "t1", "allow_custom_branding": true,
                    "signup_marketing_consent": ["asked": true, "text": "Nowości od Turingo.", "language": "pl"],
                ]
            } else if path.hasSuffix("/api/sdk/waitlist/join") {
                reply = ["ok": true, "position": 3]
            } else {
                reply = [:]  // sign-up: no session → "verification required", enough for the body check
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func last(_ suffix: String) -> (path: String, query: String?, body: [String: Any])? {
            lock.withLock { calls.last(where: { $0.path.hasSuffix(suffix) }) }
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
    override func setUp() {
        super.setUp()
        Stub.lock.withLock { Stub.calls = [] }
    }

    private func makeAuth() -> OneloAuth {
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
        auth._setReadyForTesting(true)
        return auth
    }

    func test_config_decodes_the_question_and_an_older_backend_reads_as_not_asked() throws {
        let base = #""supabase_url":"s","supabase_anon_key":"a","tenant_id":"t""#
        let withQuestion = try JSONDecoder().decode(ResolvedConfig.self, from: Data(
            #"{\#(base),"signup_marketing_consent":{"asked":true,"text":"Hi","language":"en"}}"#.utf8))
        XCTAssertEqual(withQuestion.signupMarketingConsent, OneloSignupMarketingConsent(asked: true, text: "Hi", language: "en"))
        let older = try JSONDecoder().decode(ResolvedConfig.self, from: Data("{\(base)}".utf8))
        XCTAssertEqual(older.signupMarketingConsent, .notAsked)
    }

    func test_sign_up_sends_the_ticked_consent_in_the_language_of_the_text() async throws {
        let auth = makeAuth()
        _ = try await auth.signUp(email: "a@b.c", password: "Passw0rd!x", marketingConsent: true)
        // The PKCE fetch asked /config in the device language and kept the question.
        XCTAssertTrue(Stub.last("/api/sdk/config")?.query?.contains("lang=") ?? false)
        XCTAssertEqual(auth.signupMarketingConsent.text, "Nowości od Turingo.")
        let body = try XCTUnwrap(Stub.last("/api/sdk/auth/signup")?.body)
        XCTAssertEqual(body["marketing_consent"] as? Bool, true)
        XCTAssertEqual(body["lang"] as? String, "pl")
    }

    func test_sign_up_sends_nothing_about_marketing_by_default() async throws {
        let auth = makeAuth()
        _ = try await auth.signUp(email: "a@b.c", password: "Passw0rd!x")
        let body = try XCTUnwrap(Stub.last("/api/sdk/auth/signup")?.body)
        XCTAssertNil(body["marketing_consent"])
        XCTAssertNil(body["lang"])
    }

    func test_waitlist_join_sends_only_the_given_checkboxes() async throws {
        let client = _OneloHTTPClient(
            publishableKey: "onelo_pk_test_stub",
            baseURL: URL(string: "https://\(Stub.host)")!,
            securityContext: _OneloSecurityContext()
        )
        let waitlist = OneloWaitlist(client: client)
        _ = await waitlist.join("beta", email: "ada@example.com", consent: OneloWaitlistConsent(marketing: true))
        XCTAssertEqual(Stub.last("/api/sdk/waitlist/join")?.body["consent"] as? [String: Bool], ["marketing": true])
        _ = await waitlist.join("beta", email: "ada@example.com")
        XCTAssertNil(Stub.last("/api/sdk/waitlist/join")?.body["consent"])
    }
}
