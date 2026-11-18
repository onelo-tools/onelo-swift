import XCTest
@testable import OneloSwift

/// #1038 — a waitlist join sends the App's language, else the device language;
/// the backend stores the join's Page Language (one of the App Languages) on the
/// entry for the waitlist emails. Same scenarios in every SDK. The stub answers
/// only its own host; nothing touches the Keychain.
@MainActor
final class WaitlistLanguage1038Tests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var bodies: [[String: Any]] = []
        static let lock = NSLock()
        static let host = "wl1038.example.invalid"

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
            if request.url?.path.hasSuffix("/api/sdk/waitlist/join") == true {
                Self.lock.withLock { Self.bodies.append(json) }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: ["ok": true, "position": 1])) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static var last: [String: Any]? { lock.withLock { bodies.last } }
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
        Stub.lock.withLock { Stub.bodies = [] }
    }

    private func waitlist() -> OneloWaitlist {
        OneloWaitlist(client: _OneloHTTPClient(
            publishableKey: "onelo_pk_test_stub",
            baseURL: URL(string: "https://\(Stub.host)")!,
            securityContext: _OneloSecurityContext()
        ))
    }

    func test_join_sends_the_device_language_when_the_app_passes_none() async throws {
        let result = await waitlist().join("beta", email: "ada@example.com")
        XCTAssertTrue(result.success)
        let body = try XCTUnwrap(Stub.last)
        XCTAssertEqual(body["language"] as? String, OneloSignupMarketingConsent.deviceLanguage)
    }

    func test_join_sends_a_language_the_app_passes_unchanged() async throws {
        _ = await waitlist().join("beta", email: "ada@example.com", language: "pt-PT")
        XCTAssertEqual(try XCTUnwrap(Stub.last)["language"] as? String, "pt-PT")
    }

    func test_the_language_goes_next_to_the_consent_flags() {
        let body = OneloWaitlist.joinBody(
            publishableKey: "pk", email: "ada@example.com", slug: nil,
            consent: OneloWaitlistConsent(marketing: true), language: "pl"
        )
        XCTAssertEqual(body["language"] as? String, "pl")
        XCTAssertEqual(body["consent"] as? [String: Bool], ["marketing": true])
        XCTAssertNil(body["slug"])
    }
}
