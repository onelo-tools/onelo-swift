import XCTest
@testable import OneloSwift

/// Explicit feature environment (feature-environment-explicit.md):
/// `featureEnvironment` must be forwarded as `environment` in the `/resolve`
/// (and batch-ping / SSE) payload so the backend resolves the matching
/// snapshot regardless of the key prefix. When unset the field MUST be omitted
/// so the backend falls back to the key prefix (backward-compatible).
@MainActor
final class FeatureEnvironmentTests: XCTestCase {

    /// URLProtocol stub capturing POST bodies for `example.invalid`, same
    /// approach as SecureModeIdentifyTests. Distinct class so registration
    /// doesn't collide with that suite's protocol.
    final class FeatureEnvCapturingProtocol: URLProtocol {
        nonisolated(unsafe) static var capturedBodies: [(path: String, body: [String: Any])] = []
        nonisolated(unsafe) static var lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "example.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            var bodyJSON: [String: Any] = [:]
            if let data = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodyJSON = json
            } else if let stream = request.httpBodyStream {
                // URLSession upload/data tasks deliver the body via a stream,
                // not request.httpBody — drain it (mirror SecureModeIdentifyTests).
                stream.open()
                defer { stream.close() }
                var collected = Data()
                let bufSize = 4096
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: bufSize)
                    if read <= 0 { break }
                    collected.append(buf, count: read)
                }
                bodyJSON = (try? JSONSerialization.jsonObject(with: collected) as? [String: Any]) ?? [:]
            }
            Self.lock.lock()
            Self.capturedBodies.append((path: path, body: bodyJSON))
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"features":{}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() {
            lock.lock(); capturedBodies = []; lock.unlock()
        }

        static func resolveBodies() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return capturedBodies
                .filter { $0.path.contains("/api/sdk/features/resolve") }
                .map { $0.body }
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(FeatureEnvCapturingProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(FeatureEnvCapturingProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        FeatureEnvCapturingProtocol.reset()
    }

    private func makeFeatures(featureEnvironment: String?) -> OneloFeatures {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!
        )
        return OneloFeatures(client: client, featureEnvironment: featureEnvironment)
    }

    func test_resolve_body_includes_environment_when_set() async {
        let features = makeFeatures(featureEnvironment: "test")
        await features._load(userId: "u1")
        await features.refresh(force: true)

        let bodies = FeatureEnvCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty, "Expected at least one /resolve POST")
        XCTAssertEqual(bodies.last!["environment"] as? String, "test")
    }

    func test_resolve_body_omits_environment_when_unset() async {
        let features = makeFeatures(featureEnvironment: nil)
        await features._load(userId: "u1")
        await features.refresh(force: true)

        let bodies = FeatureEnvCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        XCTAssertNil(bodies.last!["environment"], "environment must be omitted when unset")
    }

    /// The Onelo facade resolves featureEnvironment (explicit arg wins) and
    /// threads it through to the features /resolve body.
    func test_Onelo_featureEnvironment_threads_to_resolve_body() async {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false,
            featureEnvironment: "test"
        )
        await onelo.identify("u2")
        await onelo.features.refresh(force: true)

        let bodies = FeatureEnvCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        XCTAssertEqual(bodies.last!["environment"] as? String, "test")
    }

    /// An invalid featureEnvironment value normalizes to nil → field omitted.
    func test_Onelo_invalid_featureEnvironment_normalizes_to_omitted() async {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false,
            featureEnvironment: "staging"  // not test/live → dropped
        )
        await onelo.identify("u3")
        await onelo.features.refresh(force: true)

        let bodies = FeatureEnvCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        XCTAssertNil(bodies.last!["environment"])
    }
}
