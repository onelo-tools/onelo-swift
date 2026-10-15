import XCTest
@testable import OneloSwift

/// #519 — every Features call proves the signed-in user with
/// `Authorization: Bearer <Onelo access token>`, the same rules as the JS SDKs
/// (#518): a refused token (`401 invalid_user_token`) is refreshed once per
/// refusal episode and retried once, then the call goes anonymous (no token,
/// no `userId`); module-token never goes anonymous. `userIdHash` is never sent.
@MainActor
final class UserTokenTests: XCTestCase {

    // MARK: - Transport stub

    struct Captured {
        let host: String
        let path: String
        let authorization: String?
        let body: [String: Any]
    }

    /// The `Onelo`-level test's own host. Its instance keeps loading identities
    /// in the background after it returns; on a host of its own those requests
    /// cannot land in a later test's counts.
    nonisolated static let wiringHost = "usertoken-wiring.invalid"

    /// Captures every request to `usertoken.invalid` (and `wiringHost`) and answers through
    /// `responder` (path, Authorization header) → (status, json).
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var captured: [Captured] = []
        nonisolated(unsafe) static var responder: (String, String?) -> (Int, [String: Any]) = { _, _ in
            (200, ["features": [:]])
        }
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "usertoken.invalid" || request.url?.host == UserTokenTests.wiringHost
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization")
            var body: [String: Any] = [:]
            if let data = request.httpBody {
                body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } else if let stream = request.httpBodyStream {
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
                body = (try? JSONSerialization.jsonObject(with: collected) as? [String: Any]) ?? [:]
            }
            Self.lock.lock()
            Self.captured.append(Captured(host: request.url?.host ?? "", path: path, authorization: auth, body: body))
            let (status, json) = Self.responder(path, auth)
            Self.lock.unlock()

            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status != 204 {
                client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func requests(_ suffix: String, host: String = "usertoken.invalid") -> [Captured] {
            lock.lock(); defer { lock.unlock() }
            return captured.filter { $0.host == host && $0.path.hasSuffix(suffix) }
        }
    }

    static let refused: (Int, [String: Any]) = (401, ["detail": ["error": "invalid_user_token"]])

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
        Stub.lock.lock()
        Stub.captured = []
        Stub.responder = { _, _ in (200, ["features": [:]]) }
        Stub.lock.unlock()
    }

    // MARK: - Fakes

    /// Token source whose tokens and refreshes the test controls and counts.
    final class Tokens {
        var current: String?
        var refreshed: String?
        var refreshCount = 0
        var onRefresh: (() -> Void)?

        init(current: String?, refreshed: String? = nil) {
            self.current = current
            self.refreshed = refreshed
        }

        // Weak, not unowned: an identity `/resolve` started by `_load` can
        // outlive the test that made it, and an unowned read would then crash.
        @MainActor lazy var source = _OneloUserToken(
            current: { [weak self] in self?.current },
            refresh: { [weak self] in
                guard let self else { return nil }
                self.refreshCount += 1
                self.onRefresh?()
                return self.refreshed
            }
        )
    }

    private func makeFeatures(_ tokens: Tokens?) -> OneloFeatures {
        let client = _OneloHTTPClient(
            publishableKey: "pk_live_x",
            baseURL: URL(string: "https://usertoken.invalid")!,
            securityContext: _OneloSecurityContext()
        )
        // An injected stream keeps _load from opening a real connection.
        return OneloFeatures(client: client, eventStream: OneloEventStream(httpClient: client),
                             userToken: tokens?.source)
    }

    private func respond(_ responder: @escaping (String, String?) -> (Int, [String: Any])) {
        Stub.lock.lock(); Stub.responder = responder; Stub.lock.unlock()
    }

    // MARK: - The Bearer on every call

    func test_signedIn_everyCallCarriesTheBearer_andNoUserIdHash() async throws {
        let tokens = Tokens(current: "tok-1")
        let features = makeFeatures(tokens)
        respond { path, _ in
            path.hasSuffix("/module-token") ? (200, ["token": "mt"]) : (200, ["features": [:]])
        }

        await features._load(userId: "u1", userIdHash: "legacy-hash")
        await features.refresh(force: true)
        features.declare(["a"])
        await features._batchPing()
        _ = try await features.moduleToken(for: "slug")

        for suffix in ["/features/resolve", "/features/batch-ping", "/features/module-token"] {
            let reqs = Stub.requests(suffix)
            XCTAssertFalse(reqs.isEmpty, "no \(suffix) request")
            for r in reqs {
                XCTAssertEqual(r.authorization, "Bearer tok-1", suffix)
                XCTAssertNil(r.body["userIdHash"], "\(suffix) must never send userIdHash")
                XCTAssertEqual(r.body["userId"] as? String, "u1", "\(suffix) still names the user for old servers")
            }
        }
        XCTAssertEqual(tokens.refreshCount, 0)
    }

    func test_signedOut_sendsNoTokenAndNoUserId() async {
        let tokens = Tokens(current: nil)
        let features = makeFeatures(tokens)

        await features._load(userId: nil)
        await features.refresh(force: true)
        features.declare(["a"])
        await features._batchPing()

        for suffix in ["/features/resolve", "/features/batch-ping"] {
            let reqs = Stub.requests(suffix)
            XCTAssertFalse(reqs.isEmpty)
            for r in reqs {
                XCTAssertNil(r.authorization, suffix)
                XCTAssertNil(r.body["userId"], suffix)
            }
        }
    }

    // MARK: - Refusal: refresh once, retry once — never anonymous for a signed-in user

    /// `_load` resolves the new identity once; tests drive that call.
    private func loadIdentity(_ features: OneloFeatures, _ userId: String?) async {
        await features._load(userId: userId)
        await features._identityResolveTask?.value
    }

    /// onelo-swift-staging#1: `/resolve` for a signed-in user whose token is
    /// refused even after a refresh makes NO anonymous retry — the no-user
    /// snapshot must never stand in for theirs (FeaturesIdentityRaceTests).
    func test_refusedToken_refreshesOnce_retriesOnce_andNeverResolvesAnonymously() async {
        let tokens = Tokens(current: "stale", refreshed: "fresh")
        let features = makeFeatures(tokens)
        respond { _, auth in auth == nil ? (200, ["features": [:]]) : Self.refused }

        await loadIdentity(features, "u1")

        let reqs = Stub.requests("/features/resolve")
        XCTAssertEqual(reqs.map(\.authorization), ["Bearer stale", "Bearer fresh"])
        XCTAssertEqual(reqs[0].body["userId"] as? String, "u1")
        XCTAssertEqual(reqs[1].body["userId"] as? String, "u1")
        XCTAssertEqual(tokens.refreshCount, 1)
    }

    func test_refreshedTokenAccepted_usesTheAnswer_andEndsTheEpisode() async {
        let tokens = Tokens(current: "stale", refreshed: "fresh")
        let features = makeFeatures(tokens)
        respond { _, auth in
            auth == "Bearer stale" ? Self.refused : (200, ["features": ["f": ["status": "enabled"]]])
        }

        await loadIdentity(features, "u1")

        XCTAssertEqual(Stub.requests("/features/resolve").map(\.authorization), ["Bearer stale", "Bearer fresh"])
        XCTAssertEqual(features.feature("f").status, .enabled)
        XCTAssertFalse(tokens.source._refreshSpentForTesting, "an accepted token ends the refusal episode")
    }

    func test_otherUnauthorized_isNotRetried() async {
        let tokens = Tokens(current: "tok", refreshed: "fresh")
        let features = makeFeatures(tokens)
        respond { _, _ in (401, ["detail": ["error": "invalid_publishable_key"]]) }

        await loadIdentity(features, "u1")

        XCTAssertEqual(Stub.requests("/features/resolve").count, 1)
        XCTAssertEqual(tokens.refreshCount, 0)
    }

    func test_moduleToken_refusedTwice_throwsNotAuthenticated_andNeverGoesAnonymous() async {
        let tokens = Tokens(current: "stale", refreshed: "fresh")
        let features = makeFeatures(tokens)
        // Only module-token is refused. `_load` starts the identity's own
        // `/resolve`; refused too, it would race this call for the one refresh
        // of the refusal episode. It is awaited, so it is over before the call.
        respond { path, _ in path.hasSuffix("/module-token") ? Self.refused : (200, ["features": [:]]) }

        await loadIdentity(features, "u1")
        do {
            _ = try await features.moduleToken(for: "slug")
            XCTFail("expected a throw")
        } catch OneloFeaturesError.notAuthenticated {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertEqual(Stub.requests("/features/module-token").map(\.authorization), ["Bearer stale", "Bearer fresh"])
        XCTAssertEqual(tokens.refreshCount, 1)
    }

    // MARK: - One refresh per refusal episode

    func test_aSpentEpisode_doesNotRefreshAgain_untilATokenIsAccepted() async {
        let tokens = Tokens(current: "stale", refreshed: "still-refused")
        let features = makeFeatures(tokens)
        var refuse = true
        respond { _, auth in (auth != nil && refuse) ? Self.refused : (200, ["features": [:]]) }

        await loadIdentity(features, "u1")
        await features.refresh(force: true)
        XCTAssertEqual(tokens.refreshCount, 1, "the second refusal in the same episode must not refresh")
        XCTAssertEqual(Stub.requests("/features/resolve").map(\.authorization),
                       ["Bearer stale", "Bearer still-refused", "Bearer stale"])

        refuse = false
        await features.refresh(force: true) // accepted → episode over
        refuse = true
        await features.refresh(force: true)
        XCTAssertEqual(tokens.refreshCount, 2, "after an accepted token a new refusal may refresh again")
    }

    /// Review trap R2-1 of #530: batch-ping answers a throttled 204 before it
    /// looks at the token, so its 2xx must not end a refusal episode.
    func test_batchPing204_doesNotRearmTheRefresh() async {
        let tokens = Tokens(current: "stale", refreshed: "still-refused")
        let features = makeFeatures(tokens)
        respond { path, auth in
            if path.hasSuffix("/batch-ping") { return (204, [:]) }
            return auth != nil ? Self.refused : (200, ["features": [:]])
        }

        await loadIdentity(features, "u1")
        XCTAssertEqual(tokens.refreshCount, 1)

        features.declare(["a"])
        await features._batchPing()
        XCTAssertEqual(Stub.requests("/features/batch-ping").first?.authorization, "Bearer stale")
        XCTAssertTrue(tokens.source._refreshSpentForTesting, "a 204 from batch-ping proves nothing about the token")

        await features.refresh(force: true)
        XCTAssertEqual(tokens.refreshCount, 1)
    }

    /// Review trap R1-1 of #530: a host that answers every session republish
    /// (which a refresh causes) with a new Features call, against a server that
    /// refuses every token, must not loop refresh → call → refresh.
    func test_serverRefusingEveryToken_withAHostReloadingOnEveryRefresh_isBounded() async {
        let tokens = Tokens(current: "t0", refreshed: "t1")
        let features = makeFeatures(tokens)
        respond { _, auth in auth != nil ? Self.refused : (200, ["features": [:]]) }
        var reloads: [Task<Void, Never>] = []
        tokens.onRefresh = {
            // Without the episode gate every reload refreshes again, forever;
            // the cap only keeps a broken build from hanging the suite.
            guard reloads.count < 20 else { return }
            reloads.append(Task { @MainActor in await features.refresh(force: true) })
        }

        await features._load(userId: "u1")
        await features.refresh(force: true)
        var drained = 0
        while drained < reloads.count {
            await reloads[drained].value
            drained += 1
        }

        XCTAssertEqual(tokens.refreshCount, 1)
        XCTAssertEqual(reloads.count, 1)
        XCTAssertLessThanOrEqual(Stub.requests("/features/resolve").count, 5)
    }

    // MARK: - Event Stream

    private final class Opens {
        var calls: [(query: [String: String], authorization: String?)] = []
        var scripts: [AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>] = []
    }

    private static func refusedStream() -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: _OneloSSERejected(status: 401, errorCode: "invalid_user_token")) }
    }
    /// Yields one event and stays open until cancelled.
    private static func openStream() -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
        AsyncThrowingStream { $0.yield(.init(type: "up_to_date", data: "{}")) }
    }
    /// Yields one event and closes cleanly (→ the stream reconnects).
    private static func closingStream() -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
        AsyncThrowingStream { c in c.yield(.init(type: "up_to_date", data: "{}")); c.finish() }
    }

    private func makeStream(_ tokens: Tokens, _ opens: Opens) -> OneloEventStream {
        let client = _OneloHTTPClient(publishableKey: "pk_live_x", baseURL: URL(string: "https://usertoken.invalid")!,
                                      securityContext: _OneloSecurityContext())
        let stream = OneloEventStream(httpClient: client)
        stream.userToken = tokens.source
        stream._openStream = { items, headers in
            var q: [String: String] = [:]
            for i in items { q[i.name] = i.value ?? "" }
            opens.calls.append((q, headers["Authorization"]))
            return opens.scripts.isEmpty ? Self.openStream() : opens.scripts.removeFirst()
        }
        return stream
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_stream_connectCarriesTheBearer_andEveryReconnectReadsAFreshToken() async {
        let tokens = Tokens(current: "tok-1")
        let opens = Opens()
        opens.scripts = [Self.closingStream()]
        let stream = makeStream(tokens, opens)

        stream.start(userId: "u1")
        await waitUntil { opens.calls.count >= 1 }
        tokens.current = "tok-2"
        await waitUntil { opens.calls.count >= 2 }
        stream.stop()

        XCTAssertEqual(opens.calls.map(\.authorization), ["Bearer tok-1", "Bearer tok-2"])
        XCTAssertEqual(opens.calls.first?.query["userId"], "u1")
        XCTAssertNil(opens.calls.first?.query["userIdHash"])
    }

    func test_stream_refusedToken_refreshesOnce_thenConnectsAnonymous() async {
        let tokens = Tokens(current: "stale", refreshed: "fresh")
        let opens = Opens()
        opens.scripts = [Self.refusedStream(), Self.refusedStream()]
        let stream = makeStream(tokens, opens)

        stream.start(userId: "u1")
        await waitUntil { opens.calls.count >= 3 }
        stream.stop()

        XCTAssertEqual(opens.calls.map(\.authorization), ["Bearer stale", "Bearer fresh", nil])
        XCTAssertEqual(opens.calls[1].query["userId"], "u1")
        XCTAssertNil(opens.calls[2].query["userId"], "the anonymous connection names no user")
        XCTAssertEqual(tokens.refreshCount, 1)
    }

    func test_stream_refreshedTokenAccepted_isUsed_andEndsTheEpisode() async {
        let tokens = Tokens(current: "stale", refreshed: "fresh")
        let opens = Opens()
        opens.scripts = [Self.refusedStream()]
        let stream = makeStream(tokens, opens)

        stream.start(userId: "u1")
        await waitUntil { opens.calls.count >= 2 && !tokens.source._refreshSpentForTesting }
        stream.stop()

        XCTAssertEqual(opens.calls.map(\.authorization), ["Bearer stale", "Bearer fresh"])
        XCTAssertFalse(tokens.source._refreshSpentForTesting)
    }

    // MARK: - OneloAuth wiring

    private func session(_ user: String, token: String) -> OneloSession {
        OneloSession(accessToken: token, refreshToken: "r", expiresAt: Date().addingTimeInterval(900),
                     user: OneloUser(id: user, email: nil, role: .member, tenantId: nil))
    }

    func test_auth_tokenSource_readsTheSession_andAUserChangeStartsANewEpisode() async {
        let auth = OneloAuth(config: OneloConfig(publishableKey: "pk_live_x", apiUrl: URL(string: "https://usertoken.invalid")!),
                             urlSession: .shared, skipInitialize: true, storage: InMemorySessionStorage())
        defer { auth._clearSessionForTesting() }
        let current = await auth.userToken.current()
        XCTAssertNil(current, "signed out → no token")

        auth._injectSessionForTesting(session("u1", token: "a1"))
        let signedIn = await auth.userToken.current()
        XCTAssertEqual(signedIn, "a1")
        XCTAssertTrue(auth.eventStream.userToken === auth.userToken, "the shared stream proves the same user")

        // (A real refresh reads the Keychain; the episode state is what matters here.)
        auth.userToken._spendRefreshForTesting()
        XCTAssertTrue(auth.userToken._refreshSpentForTesting)
        auth._injectSessionForTesting(session("u1", token: "a2"))
        XCTAssertTrue(auth.userToken._refreshSpentForTesting, "a refresh republishing the same user keeps the episode")
        auth._injectSessionForTesting(session("u2", token: "b1"))
        XCTAssertFalse(auth.userToken._refreshSpentForTesting, "a different user starts a new episode")
    }

    func test_auth_overlappingRefreshes_shareOneRequest() async throws {
        let auth = OneloAuth(config: OneloConfig(publishableKey: "pk_live_x", apiUrl: URL(string: "https://usertoken.invalid")!),
                             urlSession: .shared, skipInitialize: true, storage: InMemorySessionStorage())
        var requests = 0
        auth._refreshOverrideForTesting = {
            requests += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }

        async let a = auth.refreshSession()
        async let b = auth.refreshSession()
        _ = try await (a, b)
        XCTAssertEqual(requests, 1, "two overlapping refreshes must send ONE /auth/refresh")

        _ = try await auth.refreshSession()
        XCTAssertEqual(requests, 2, "a later refresh runs again")
    }

    /// Constructs `Onelo` over an in-memory session store (#732), so it runs
    /// without the Keychain. The auth's `initialize()` is skipped: this test is
    /// about the token wiring, and `pk_live_x` is a rejected key whose launch
    /// would clear the injected session before the request.
    func test_onelo_wiresTheAuthTokenIntoFeatures() async {
        let onelo = Onelo(testingKey: "pk_live_x", baseURL: URL(string: "https://\(Self.wiringHost)")!,
                          autoLifecycleRefresh: false, skipAuthInitialize: true)
        onelo.auth.authObject._injectSessionForTesting(session("u9", token: "wired"))
        // No sign-out at the end: the session lives in this test's in-memory
        // store only, and clearing it would make `Onelo` load the signed-out
        // identity — an anonymous `/resolve` that lands in the next test's stub.
        await onelo.features._load(userId: "u9")
        await onelo.features.refresh(force: true)

        XCTAssertEqual(Stub.requests("/features/resolve", host: Self.wiringHost).last?.authorization, "Bearer wired")
    }
}
