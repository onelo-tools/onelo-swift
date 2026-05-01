import XCTest
@testable import OneloSwift

@MainActor
final class OneloPresenceHeartbeatTests: XCTestCase {

    func test_startHeartbeat_sends_request_to_presence_endpoint() async throws {
        let recorder = RequestRecorder()
        let auth = makeAuth(session: URLSession(configuration: recorder.sessionConfig()))
        let session = OneloSession(
            accessToken: "test_token",
            refreshToken: "ref",
            expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u1", email: "a@b.com", role: .member, tenantId: nil)
        )

        await auth._startHeartbeat(session: session)
        // Fire immediately once
        try await Task.sleep(nanoseconds: 50_000_000)
        await auth._stopHeartbeat()

        let urls = recorder.recordedURLs
        XCTAssertTrue(urls.contains { $0.path.hasSuffix("/api/sdk/presence/heartbeat") },
                      "Expected heartbeat request, got: \(urls.map(\.absoluteString))")
    }

    func test_stopHeartbeat_cancels_timer() async throws {
        let recorder = RequestRecorder()
        let auth = makeAuth(session: URLSession(configuration: recorder.sessionConfig()))
        let session = OneloSession(
            accessToken: "tok2",
            refreshToken: "ref",
            expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u2", email: nil, role: .member, tenantId: nil)
        )

        await auth._startHeartbeat(session: session)
        try await Task.sleep(nanoseconds: 50_000_000)
        await auth._stopHeartbeat()
        let countAfterStop = recorder.recordedURLs.count

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.recordedURLs.count, countAfterStop,
                       "No additional requests should fire after stopHeartbeat()")
    }

    func test_startHeartbeat_uses_bearer_token() async throws {
        let recorder = RequestRecorder()
        let auth = makeAuth(session: URLSession(configuration: recorder.sessionConfig()))
        let session = OneloSession(
            accessToken: "my_access_token",
            refreshToken: "ref",
            expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u3", email: nil, role: .member, tenantId: nil)
        )

        await auth._startHeartbeat(session: session)
        try await Task.sleep(nanoseconds: 50_000_000)
        await auth._stopHeartbeat()

        let authHeader = recorder.recordedHeaders.first?["Authorization"]
        XCTAssertEqual(authHeader, "Bearer my_access_token")
    }

    // MARK: - Helpers

    private func makeAuth(session: URLSession) -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://test.example.com")!
        )
        return OneloAuth(config: config, urlSession: session, skipInitialize: true)
    }
}

// MARK: - RequestRecorder

final class RequestRecorder: NSObject, URLProtocolClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _headers: [[String: String]] = []

    var recordedURLs: [URL] { lock.withLock { _urls } }
    var recordedHeaders: [[String: String]] { lock.withLock { _headers } }

    func sessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        RecordingProtocol.recorder = self
        return config
    }

    func record(url: URL, headers: [String: String]) {
        lock.withLock {
            _urls.append(url)
            _headers.append(headers)
        }
    }

    // URLProtocolClient stubs (unused)
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {}
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {}
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {}
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

final class RecordingProtocol: URLProtocol {
    static var recorder: RequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            let headers = request.allHTTPHeaderFields ?? [:]
            RecordingProtocol.recorder?.record(url: url, headers: headers)
        }
        // Return 204 No Content
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
