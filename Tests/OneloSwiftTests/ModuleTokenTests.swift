import XCTest
@testable import OneloSwift

/// Features Entitlement Enforcement (Task 4.5):
/// `OneloFeatures.moduleToken(for:)` requests a short-lived per-feature JWT
/// from `POST /api/sdk/features/module-token`. The token is what the host
/// app passes to its OWN backend (or to Onelo-hosted modules) as proof
/// that the current user is entitled to a specific feature slug.
///
/// Wire contract:
///   - Request body: { publishableKey, userId, slug, userIdHash? }
///   - 200 → { token, expires_in } → return token
///   - 401 secure_mode_required → throw .secureModeRequired
///   - 401 invalid_user_hash    → throw .invalidUserHash
///   - 403 not_entitled         → throw .notEntitled
///   - no current user          → throw .notAuthenticated (no network call)
@MainActor
final class ModuleTokenTests: XCTestCase {

    // MARK: - URLProtocol stub

    /// Captures `/module-token` POST bodies AND lets each test stage the
    /// status code + JSON to return. Mirrors `SecureModeIdentifyTests` —
    /// registers globally so `URLSession.shared` (used by `_OneloHTTPClient`)
    /// routes through us when the host matches `example.invalid`.
    final class ModuleTokenStubProtocol: URLProtocol {
        nonisolated(unsafe) static var capturedBodies: [(path: String, body: [String: Any])] = []
        nonisolated(unsafe) static var nextStatusCode: Int = 200
        nonisolated(unsafe) static var nextResponseJSON: [String: Any] = ["token": "stub", "expires_in": 60]
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
            let status = Self.nextStatusCode
            let json = Self.nextResponseJSON
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() {
            lock.lock()
            capturedBodies = []
            nextStatusCode = 200
            nextResponseJSON = ["token": "stub", "expires_in": 60]
            lock.unlock()
        }

        static func tokenBodies() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return capturedBodies
                .filter { $0.path.contains("/api/sdk/features/module-token") }
                .map { $0.body }
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(ModuleTokenStubProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(ModuleTokenStubProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        ModuleTokenStubProtocol.reset()
    }

    // MARK: - Factory

    private func makeFeatures() -> OneloFeatures {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!
        )
        return OneloFeatures(client: client)
    }

    // MARK: - Tests

    func test_moduleToken_returns_token_on_200() async throws {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 200
        ModuleTokenStubProtocol.nextResponseJSON = ["token": "eyJ...", "expires_in": 60]

        await features._load(userId: "u1")
        let token = try await features.moduleToken(for: "ai-chat")

        XCTAssertEqual(token, "eyJ...")
        let bodies = ModuleTokenStubProtocol.tokenBodies()
        XCTAssertFalse(bodies.isEmpty, "Expected at least one /module-token POST")
        let body = bodies.last!
        XCTAssertEqual(body["slug"] as? String, "ai-chat")
        XCTAssertEqual(body["userId"] as? String, "u1")
        XCTAssertEqual(body["publishableKey"] as? String, "pk_test")
    }

    func test_moduleToken_threads_userIdHash_when_set() async throws {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 200
        ModuleTokenStubProtocol.nextResponseJSON = ["token": "tok", "expires_in": 60]

        await features._load(userId: "u1", userIdHash: "abcdef123456")
        _ = try await features.moduleToken(for: "ai-chat")

        let body = ModuleTokenStubProtocol.tokenBodies().last!
        XCTAssertEqual(body["userIdHash"] as? String, "abcdef123456")
    }

    func test_moduleToken_omits_userIdHash_when_nil() async throws {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 200
        ModuleTokenStubProtocol.nextResponseJSON = ["token": "tok", "expires_in": 60]

        await features._load(userId: "u1")
        _ = try await features.moduleToken(for: "ai-chat")

        let body = ModuleTokenStubProtocol.tokenBodies().last!
        XCTAssertNil(body["userIdHash"], "userIdHash must be omitted when not in secure mode")
    }

    func test_moduleToken_throws_notEntitled_on_403() async {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 403
        ModuleTokenStubProtocol.nextResponseJSON = ["detail": ["error": "not_entitled"]]

        await features._load(userId: "u1")
        do {
            _ = try await features.moduleToken(for: "ai-chat")
            XCTFail("Expected throw")
        } catch OneloFeaturesError.notEntitled {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_moduleToken_throws_secureModeRequired_on_401_secure_mode() async {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 401
        ModuleTokenStubProtocol.nextResponseJSON = ["detail": ["error": "secure_mode_required"]]

        await features._load(userId: "u1")
        do {
            _ = try await features.moduleToken(for: "ai-chat")
            XCTFail("Expected throw")
        } catch OneloFeaturesError.secureModeRequired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_moduleToken_throws_invalidUserHash_on_401_invalid_hash() async {
        let features = makeFeatures()
        ModuleTokenStubProtocol.nextStatusCode = 401
        ModuleTokenStubProtocol.nextResponseJSON = ["detail": ["error": "invalid_user_hash"]]

        await features._load(userId: "u1", userIdHash: "wronghash")
        do {
            _ = try await features.moduleToken(for: "ai-chat")
            XCTFail("Expected throw")
        } catch OneloFeaturesError.invalidUserHash {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_moduleToken_throws_notAuthenticated_when_no_user_id() async {
        let features = makeFeatures()
        // Don't call _load → currentUserId is nil → MUST NOT hit network.

        do {
            _ = try await features.moduleToken(for: "ai-chat")
            XCTFail("Expected throw")
        } catch OneloFeaturesError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertTrue(
            ModuleTokenStubProtocol.tokenBodies().isEmpty,
            "Should not have hit the network without a userId"
        )
    }
}
