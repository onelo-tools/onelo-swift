import XCTest
@testable import OneloSwift

/// ADR-0003 — the Event Stream's credential is an `X-Publishable-Key` request
/// header for every SDK except browser `onelo-js`, which alone cannot set one.
///
/// Swift already set `User-Agent`, `X-Onelo-OS`, `X-Onelo-Instance-Id`,
/// `X-Bundle-Id` (and the attest headers) on this exact GET, so the migration is
/// only: send the key as a header, and stop writing it into the query string.
/// The backend (`sdk_features_sse.py`) resolves the header when `?key=` is
/// absent, and deliberately does NOT stamp `Deprecation`/`Sunset` on such a
/// connection — a query-string key still gets stamped, which is why leaving the
/// parameter in place "just in case" would keep the sunset alive.
final class EventStreamCredentialHeaderTests: XCTestCase {

    private func makeClient(key: String = "onelo_pk_live_abc123") -> _OneloHTTPClient {
        _OneloHTTPClient(
            publishableKey: key,
            baseURL: URL(string: "https://api.example.invalid")!,
            securityContext: _OneloSecurityContext()
        )
    }

    // MARK: - The request the SSE transport actually sends

    func test_streamRequest_sendsPublishableKeyHeader() throws {
        let client = makeClient()

        let request = try client.makeStreamRequest(
            path: "/api/sdk/features/stream",
            queryItems: OneloEventStream._streamQueryItems(sinceVersion: 0)
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Publishable-Key"),
            "onelo_pk_live_abc123",
            "ADR-0003: the Event Stream credential travels as a request header"
        )
    }

    func test_streamRequest_doesNotPutTheKeyInTheURL() throws {
        let client = makeClient()

        let request = try client.makeStreamRequest(
            path: "/api/sdk/features/stream",
            queryItems: OneloEventStream._streamQueryItems(sinceVersion: 7)
        )

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(
            url.contains("onelo_pk_live_abc123"),
            "no key may appear in an Event Stream URL — it lands in the proxy access log"
        )
        let names = URLComponents(string: url)?.queryItems?.map(\.name) ?? []
        XCTAssertFalse(names.contains("key"), "?key= is the parameter ADR-0003 removes")
        XCTAssertFalse(names.contains("token"), "the Stream Token is browser onelo-js only")
    }

    func test_streamRequest_keepsTheExistingSecurityHeaders() throws {
        let client = makeClient()

        let request = try client.makeStreamRequest(path: "/api/sdk/features/stream")

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "onelo-swift/\(OneloSDK.sdkVersion)"
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Onelo-Instance-Id"))
    }

    // MARK: - The query string the Event Stream builds

    func test_streamQueryItems_carryEveryNonCredentialParameter() {
        let items = OneloEventStream._streamQueryItems(
            sinceVersion: 42,
            appVersion: "1.2.3",
            environment: "test",
            userId: "user-1"
        )
        var map: [String: String] = [:]
        for item in items where map[item.name] == nil {
            map[item.name] = item.value ?? ""
        }

        XCTAssertEqual(map["since_version"], "42")
        XCTAssertEqual(map["sdk_platform"], "swift")
        XCTAssertEqual(map["sdk_version"], OneloSDK.sdkVersion)
        XCTAssertEqual(map["app_version"], "1.2.3")
        XCTAssertEqual(map["environment"], "test")
        XCTAssertEqual(map["userId"], "user-1")
        XCTAssertNil(map["userIdHash"], "Secure Mode is retired (#519)")
        XCTAssertNotNil(map["instance_id"])
        XCTAssertNil(map["key"])
    }

    func test_streamQueryItems_omitTheOptionalsWhenUnset() {
        let names = OneloEventStream._streamQueryItems(sinceVersion: 0).map(\.name)

        XCTAssertFalse(names.contains("app_version"))
        XCTAssertFalse(names.contains("environment"))
        XCTAssertFalse(names.contains("userId"))
        XCTAssertFalse(names.contains("userIdHash"))
        XCTAssertFalse(names.contains("key"))
    }
}
