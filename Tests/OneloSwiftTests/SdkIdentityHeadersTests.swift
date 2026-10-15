import XCTest
import Foundation
@testable import OneloSwift

/// #122 — every request the dashboard's version capture reads must carry the
/// SDK's NAME next to its version. The two header builders in this SDK
/// (`_OneloHTTPClient.applySecurityHeaders` and `OneloAuth.addStandardHeaders`)
/// are exercised through the real URLSession stack so the wiring is what is
/// asserted, not the helper alone.
@MainActor
final class SdkIdentityHeadersTests: XCTestCase {

    final class HeaderCapturingProtocol: URLProtocol {
        nonisolated(unsafe) static var captured: [(path: String, headers: [String: String])] = []
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "identity.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.captured.append((request.url?.path ?? "", request.allHTTPHeaderFields ?? [:]))
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func reset() { lock.lock(); captured = []; lock.unlock() }
        static func last(_ path: String) -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return captured.last(where: { $0.path.hasSuffix(path) })?.headers
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(HeaderCapturingProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(HeaderCapturingProtocol.self)
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        HeaderCapturingProtocol.reset()
    }

    private func assertIdentity(_ headers: [String: String]?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(headers?["X-Onelo-Sdk-Name"], "onelo-swift", file: file, line: line)
        XCTAssertEqual(headers?["X-SDK-Version"], OneloSDK.sdkVersion, file: file, line: line)
        XCTAssertEqual(headers?["User-Agent"], "onelo-swift/\(OneloSDK.sdkVersion)", file: file, line: line)
    }

    func test_httpClient_requests_carry_name_and_version() async {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://identity.invalid")!,
            securityContext: _OneloSecurityContext()
        )
        _ = try? await client.get(path: "/api/sdk/features/resolve")
        assertIdentity(HeaderCapturingProtocol.last("/api/sdk/features/resolve"))
    }

    func test_auth_addStandardHeaders_carries_name_and_version_proved_on_config_fetch() async {
        // signIn first refreshes PKCE via GET /api/sdk/config — the request the
        // backend's version capture reads (sdk.py) and one that goes through
        // `addStandardHeaders`. The stub answers 500, so signin itself never
        // leaves. This proves the ONE auth header builder is wired, not each
        // of its call sites (signin/signup/refresh/signout all call it).
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://identity.invalid")!,
            callbackScheme: "turingo"
        )
        let auth = OneloAuth(config: config, urlSession: .shared, skipInitialize: true, storage: InMemorySessionStorage())
        _ = try? await auth.signIn(email: "a@b.c", password: "pw")
        let headers = HeaderCapturingProtocol.last("/api/sdk/config")
        XCTAssertNotNil(headers, "config fetch never reached the network")
        assertIdentity(headers)
    }
}
