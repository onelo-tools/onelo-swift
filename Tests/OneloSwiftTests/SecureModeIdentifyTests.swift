import XCTest
@testable import OneloSwift

/// Secure mode (Features Entitlement Enforcement, Task 2.5):
/// `Onelo.identify(_:userIdHash:)` and `OneloFeatures._load(userId:userIdHash:)`
/// must thread the hash into the `/resolve` POST body so the backend can
/// HMAC-verify the caller's claim to `userId`. When no hash is passed
/// (Turingo and other non-secure callers) the field MUST be omitted —
/// adding `userIdHash: nil` to the wire payload would change the request
/// shape for everyone and break the backward-compat contract.
@MainActor
final class SecureModeIdentifyTests: XCTestCase {

    // MARK: - URLProtocol stub

    /// URLProtocol stub registered globally on `URLProtocol.registerClass` so
    /// `URLSession.shared` (used by `_OneloHTTPClient`) routes through us.
    /// Captures the POST body for `/resolve` so we can assert what shipped.
    final class ResolveCapturingProtocol: URLProtocol {
        nonisolated(unsafe) static var capturedBodies: [(path: String, body: [String: Any])] = []
        nonisolated(unsafe) static var lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            // Only handle hosts we expect; otherwise let real stack go through.
            request.url?.host == "example.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            // URLProtocol does NOT populate request.httpBody for POSTs made
            // via `URLSession.upload`/data tasks reliably; however our HTTP
            // client sets `request.httpBody = JSONSerialization.data(...)`
            // before handing the request to URLSession, which DOES preserve
            // it on URLRequest for URLProtocol stubs.
            var bodyJSON: [String: Any] = [:]
            if let data = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodyJSON = json
            } else if let stream = request.httpBodyStream {
                // Fallback: drain stream
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
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Minimal valid /resolve response: no features.
            client?.urlProtocol(self, didLoad: Data(#"{"features":{}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() {
            lock.lock()
            capturedBodies = []
            lock.unlock()
        }

        static func snapshot() -> [(path: String, body: [String: Any])] {
            lock.lock()
            defer { lock.unlock() }
            return capturedBodies
        }

        static func resolveBodies() -> [[String: Any]] {
            snapshot()
                .filter { $0.path.contains("/api/sdk/features/resolve") }
                .map { $0.body }
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(ResolveCapturingProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(ResolveCapturingProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        ResolveCapturingProtocol.reset()
    }

    // MARK: - Factory

    private func makeFeatures() -> OneloFeatures {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            securityContext: _OneloSecurityContext()
        )
        return OneloFeatures(client: client)
    }

    // MARK: - Tests

    /// When `userIdHash` is supplied, the `/resolve` POST body MUST include
    /// it alongside `userId`. This is the contract Task 2.1 introduced on the
    /// backend.
    func test_load_with_hash_sends_userIdHash_in_resolve_body() async {
        let features = makeFeatures()

        // Trigger a REST refresh — `_load` itself doesn't POST `/resolve`
        // (it opens SSE + restores cache). The /resolve POST is reached via
        // `refresh(force: true)` after `_load` has primed `currentUserId`
        // and `currentUserIdHash`.
        await features._load(userId: "u1", userIdHash: "abcdef123456")
        await features.refresh(force: true)

        let bodies = ResolveCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty, "Expected at least one /resolve POST")
        let body = bodies.last!
        XCTAssertEqual(body["userId"] as? String, "u1")
        XCTAssertEqual(body["userIdHash"] as? String, "abcdef123456")
    }

    /// When no hash is supplied (default), the `/resolve` body MUST omit
    /// `userIdHash` — sending `null` would be a backward-incompatible change
    /// for callers like Turingo who don't run in secure mode.
    func test_load_without_hash_omits_userIdHash_field() async {
        let features = makeFeatures()

        await features._load(userId: "u1")
        await features.refresh(force: true)

        let bodies = ResolveCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        let body = bodies.last!
        XCTAssertEqual(body["userId"] as? String, "u1")
        XCTAssertNil(body["userIdHash"], "userIdHash must be omitted when not supplied")
    }

    /// The top-level facade `Onelo.identify(_:userIdHash:)` must thread the
    /// hash through to `OneloFeatures._load`. Backward-compat: existing
    /// `identify(_:)` callers still work because the new parameter has a
    /// default value of `nil`.
    func test_Onelo_identify_threads_hash_to_features_resolve() async {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        await onelo.identify("u2", userIdHash: "deadbeefcafe")
        await onelo.features.refresh(force: true)

        let bodies = ResolveCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        let body = bodies.last!
        XCTAssertEqual(body["userId"] as? String, "u2")
        XCTAssertEqual(body["userIdHash"] as? String, "deadbeefcafe")
    }

    /// Backward-compat smoke: existing single-argument `identify(_:)`
    /// continues to compile and execute, omitting the hash on the wire.
    func test_Onelo_identify_without_hash_compiles_and_omits_field() async {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        await onelo.identify("u3")
        await onelo.features.refresh(force: true)

        let bodies = ResolveCapturingProtocol.resolveBodies()
        XCTAssertFalse(bodies.isEmpty)
        let body = bodies.last!
        XCTAssertEqual(body["userId"] as? String, "u3")
        XCTAssertNil(body["userIdHash"])
    }
}
