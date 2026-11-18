import XCTest
@testable import OneloSwift

/// #1039 — every SDK sends the device language when it opens a hosted page and
/// the App passes none; a language the App passes is sent unchanged. The backend
/// picks the Page Language within the App Languages (#1036); the SDK never
/// chooses. Same scenarios in every SDK. Storage is in memory: no Keychain prompt.
@MainActor
final class PageLanguage1039Tests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var urls: [URL] = []
        static let lock = NSLock()
        static let host = "lang1039.example.invalid"

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self.urls.append(request.url!) }
            let path = request.url!.path
            let (status, reply): (Int, [String: Any])
            if path.hasSuffix("/store-initiate") {
                (status, reply) = (200, ["store_url": "https://st.example/store/hosted?token=srt_1"])
            } else if path.hasSuffix("/flow/init") {
                (status, reply) = (200, ["action": "authorized"])
            } else {
                // upgrade-initiate: a malformed answer ends the call right after the request.
                (status, reply) = (200, [:])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func lang(sentTo suffix: String) -> String? {
            let url = lock.withLock { urls.last(where: { $0.path.hasSuffix(suffix) }) }
            guard let url else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "lang" })?.value
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
        Stub.lock.withLock { Stub.urls = [] }
    }

    private let baseURL = URL(string: "https://\(Stub.host)")!
    private let session = OneloSession(
        accessToken: "tok", refreshToken: "ref", expiresAt: Date().addingTimeInterval(3600),
        user: OneloUser(id: "u1", email: "a@b.c", role: .member, tenantId: nil)
    )

    private func makeAuth() -> OneloAuth {
        OneloAuth(
            config: OneloConfig(publishableKey: "onelo_pk_test_stub", apiUrl: baseURL, callbackScheme: "turingo"),
            urlSession: .shared,
            skipInitialize: true,
            storage: InMemorySessionStorage()
        )
    }

    private var device: String { OneloSignupMarketingConsent.deviceLanguage }

    // MARK: Store (store-initiate)

    func test_store_sends_the_device_language_when_the_app_passes_none() async throws {
        _ = try await makeAuth().initiateStoreFlow()
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/store-initiate"), device)
    }

    func test_store_sends_the_language_the_app_passes_unchanged() async throws {
        _ = try await makeAuth().initiateStoreFlow(lang: "pt-BR")
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/store-initiate"), "pt-BR")
    }

    // MARK: Sign-in (flow/init)

    func test_sign_in_sends_the_device_language_when_the_app_passes_none() async throws {
        _ = try await makeAuth().resolveFlow()
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/flow/init"), device)
    }

    func test_sign_in_sends_the_language_the_app_passes_unchanged() async throws {
        _ = try await makeAuth().resolveFlow(lang: "pl")
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/flow/init"), "pl")
    }

    // MARK: Upgrade (upgrade-initiate)

    func test_upgrade_sends_the_device_language() async throws {
        // No callback scheme: a declared one is checked against Info.plist,
        // which a test bundle does not have.
        let onelo = Onelo(testingKey: "onelo_pk_test_stub", baseURL: baseURL, skipAuthInitialize: true)
        onelo.auth.authObject._injectSessionForTesting(session)
        await onelo.openUpgrade(forPlan: "pro")
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/upgrade-initiate"), device)
    }

    func test_the_device_language_is_a_real_tag() {
        XCTAssertFalse(device.isEmpty)
    }
}
