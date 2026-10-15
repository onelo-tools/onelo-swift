import XCTest
@testable import OneloSwift

/// onelo-swift-staging#1 — a feature snapshot belongs to ONE identity. Each test
/// here reproduces a race found in the Turingo investigation (turingo#88):
/// a late or anonymous answer replacing a signed-in user's snapshot, a previous
/// identity's snapshot carried over, `ready()` not following the identity, and
/// a `since_version` the client never confirmed for this user making the
/// stream answer `up_to_date` over a wrong snapshot.
@MainActor
final class FeaturesIdentityRaceTests: XCTestCase {

    // MARK: - Transport stub

    struct Captured {
        let path: String
        let authorization: String?
        let body: [String: Any]
    }

    struct Reply {
        var status: Int = 200
        var json: [String: Any] = ["features": [String: Any]()]
        /// When set, the answer is held until the test signals it.
        var hold: DispatchSemaphore? = nil
    }

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var captured: [Captured] = []
        /// Answers actually handed to the client, anonymous ones counted apart —
        /// so a test can prove the late answer it guards against was delivered.
        nonisolated(unsafe) static var deliveredAnonymous = 0
        nonisolated(unsafe) static var responder: (String, String?, [String: Any]) -> Reply = { _, _, _ in Reply() }
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "identityrace.invalid"
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
            Self.captured.append(Captured(path: path, authorization: auth, body: body))
            let reply = Self.responder(path, auth, body)
            Self.lock.unlock()
            pending = (reply, auth == nil && path.hasSuffix("/features/resolve"))
            guard let hold = reply.hold else { return finish() }
            // Hold off the loading thread, so other requests keep flowing; the
            // answer is delivered back on it once the test releases it.
            let thread = Thread.current
            DispatchQueue.global().async { [self] in
                hold.wait()
                perform(#selector(finish), on: thread, with: nil, waitUntilDone: false,
                        modes: [RunLoop.Mode.default.rawValue])
            }
        }

        private var pending: (Reply, Bool)?

        @objc private func finish() {
            guard let (reply, anonymousResolve) = pending else { return }
            pending = nil
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if reply.status != 204 {
                client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
            }
            client?.urlProtocolDidFinishLoading(self)
            if anonymousResolve {
                Self.lock.lock(); Self.deliveredAnonymous += 1; Self.lock.unlock()
            }
        }
        override func stopLoading() {}

        static func requests(_ suffix: String) -> [Captured] {
            lock.lock(); defer { lock.unlock() }
            return captured.filter { $0.path.hasSuffix(suffix) }
        }
    }

    static let refused = Reply(status: 401, json: ["detail": ["error": "invalid_user_token"]])

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(Stub.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(Stub.self)
        super.tearDown()
    }

    /// A fresh key per test, so persisted snapshots never leak between tests.
    private var pk = ""
    private var holds: [DispatchSemaphore] = []

    override func setUp() {
        super.setUp()
        pk = "onelo_pk_live_race\(UUID().uuidString.prefix(8))"
        Stub.lock.lock()
        Stub.captured = []
        Stub.deliveredAnonymous = 0
        Stub.responder = { _, _, _ in Reply() }
        Stub.lock.unlock()
    }

    override func tearDown() {
        // Never leave a URL-loading thread parked on a held answer.
        for h in holds { h.signal(); h.signal() }
        holds = []
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("io.onelo.features.\(pk).") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    final class Tokens {
        var current: String?
        var refreshed: String?
        init(current: String?, refreshed: String? = nil) {
            self.current = current
            self.refreshed = refreshed
        }
        @MainActor lazy var source = _OneloUserToken(
            // Weak: a resolve started by the test may outlive it.
            current: { [weak self] in self?.current },
            refresh: { [weak self] in self?.refreshed }
        )
    }

    private func client() -> _OneloHTTPClient {
        _OneloHTTPClient(publishableKey: pk, baseURL: URL(string: "https://identityrace.invalid")!,
                         securityContext: _OneloSecurityContext())
    }

    /// Features on an injected (auth-owned) stream that is never started, like
    /// the `Onelo` wrapper before a session exists.
    private func makeFeatures(_ tokens: Tokens?) -> OneloFeatures {
        let c = client()
        return OneloFeatures(client: c, eventStream: OneloEventStream(httpClient: c), userToken: tokens?.source)
    }

    private func respond(_ responder: @escaping (String, String?, [String: Any]) -> Reply) {
        Stub.lock.lock(); Stub.responder = responder; Stub.lock.unlock()
    }

    private func hold() -> DispatchSemaphore {
        let s = DispatchSemaphore(value: 0)
        holds.append(s)
        return s
    }

    private static func snapshot(_ enabled: [String]) -> [String: Any] {
        var features: [String: Any] = [:]
        for name in enabled { features[name] = ["status": "enabled"] }
        return ["features": features]
    }

    private func persist(_ userId: String?, version: Int, enabled: [String]) {
        var features: [String: Any] = [:]
        for name in enabled { features[name] = ["status": "enabled"] }
        let json: [String: Any] = ["config_version": version, "features": features]
        UserDefaults.standard.set(try! JSONSerialization.data(withJSONObject: json),
                                  forKey: "io.onelo.features.\(pk).\(userId ?? "anon")")
    }

    private func persisted(_ userId: String?) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "io.onelo.features.\(pk).\(userId ?? "anon")"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [String: [String: Any]]
        else { return [:] }
        return features.compactMapValues { $0["status"] as? String }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func status(_ f: OneloFeatures, _ name: String) -> FeatureStatus {
        f.feature(name).status
    }

    // MARK: - H1 / H6: an anonymous answer started before the user loaded

    /// The launch race: the lifecycle refresh fires before the session is
    /// restored (anonymous `/resolve`), the restored user loads, and the
    /// anonymous answer lands last. It must not replace the user's snapshot,
    /// in memory or on disk.
    func test_lateAnonymousResolve_doesNotReplaceTheSignedInUsersSnapshot() async {
        persist("u1", version: 3, enabled: ["basic", "pro-export"])
        let tokens = Tokens(current: nil)
        let features = makeFeatures(tokens)
        await features._load(userId: nil)
        await features._identityResolveTask?.value
        Stub.lock.lock(); Stub.deliveredAnonymous = 0; Stub.lock.unlock()
        let before = Stub.requests("/features/resolve").count

        let anonymousAnswer = hold()
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == nil
                ? Reply(json: Self.snapshot(["basic"]), hold: anonymousAnswer)
                : Reply(json: Self.snapshot(["basic", "pro-export"]))
        }
        let anonymous = Task { await features.refresh(force: true) }
        await waitUntil { Stub.requests("/features/resolve").count > before }

        // Session restored → the user's identity loads.
        tokens.current = "tok-u1"
        await features._load(userId: "u1")
        await waitUntil { self.status(features, "pro-export") == .enabled }

        let t0 = Date()
        anonymousAnswer.signal()
        await anonymous.value
        Stub.lock.lock(); let delivered = Stub.deliveredAnonymous; Stub.lock.unlock()
        XCTAssertEqual(delivered, 1, "the late anonymous answer must actually reach the client")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "the held answer must be delivered, not time out")

        XCTAssertEqual(status(features, "pro-export"), .enabled,
                       "a late anonymous answer replaced the signed-in user's snapshot")
        XCTAssertEqual(persisted("u1")["pro-export"], "enabled",
                       "a late anonymous answer was persisted under the user's key")
    }

    /// H6 — a refresh fired while a stored session is still being restored (the
    /// macOS activation at launch) waits for the restore instead of resolving
    /// anonymously ahead of it.
    func test_refreshDuringSessionRestore_waitsAndResolvesForTheRestoredUser() async {
        var restoring = true
        let tokens = Tokens(current: nil)
        let features = makeFeatures(tokens)
        features._identityPending = { restoring }
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == nil ? Reply(json: Self.snapshot(["basic"])) : Reply(json: Self.snapshot(["basic", "pro-export"]))
        }

        let lifecycle = Task { await features.refresh(force: true) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(Stub.requests("/features/resolve").isEmpty, "resolved anonymously during the restore")

        tokens.current = "tok-u1"
        restoring = false
        await features._load(userId: "u1")
        await lifecycle.value
        await features._identityResolveTask?.value

        XCTAssertTrue(Stub.requests("/features/resolve").allSatisfy { $0.authorization == "Bearer tok-u1" })
        XCTAssertEqual(status(features, "pro-export"), .enabled)
        XCTAssertTrue(features.isSnapshotConfirmed)
    }

    /// Review F1 — a restore that outlasts the bounded wait (config fetch +
    /// verify during an outage) must not let the refresh resolve for no user:
    /// that answer would replace the stored user's seeded snapshot, be
    /// persisted as `anon` and release `ready()`.
    func test_refreshOutlastingTheRestoreWait_doesNotResolveAnonymously() async {
        persist("u1", version: 3, enabled: ["basic", "pro-export"])
        let features = makeFeatures(Tokens(current: nil))
        features._identityPending = { true }
        features._identitySettleTimeout = 0.2
        features._seedPersistedSnapshot(userId: "u1")
        respond { _, _, _ in Reply(json: Self.snapshot(["basic"])) }

        await features.refresh(force: true)

        XCTAssertTrue(Stub.requests("/features/resolve").isEmpty, "resolved for no user while still restoring")
        XCTAssertEqual(status(features, "pro-export"), .enabled, "the seeded user snapshot was replaced")
        XCTAssertTrue(persisted(nil).isEmpty, "an anonymous answer was persisted")
        XCTAssertFalse(features.isSnapshotConfirmed, "ready() released on an anonymous answer")
    }

    /// Fast first render: during the restore the stored user's persisted
    /// snapshot is shown, unconfirmed, instead of the anonymous one.
    func test_seedFromStoredUser_rendersThatUsersSnapshot_unconfirmed() async {
        persist(nil, version: 3, enabled: ["basic"])
        persist("u1", version: 3, enabled: ["basic", "pro-export"])
        let features = makeFeatures(Tokens(current: nil))

        features._seedPersistedSnapshot(userId: "u1")

        XCTAssertEqual(status(features, "pro-export"), .enabled)
        XCTAssertFalse(features.isSnapshotConfirmed, "a persisted snapshot is not a confirmed one")
    }

    /// The user's bar: an app that awaits `ready()` at launch renders the
    /// complete gated UI on its first render — the restored user's snapshot,
    /// confirmed, even when an anonymous answer was racing it.
    func test_appAwaitingReadyAtLaunch_firstRenderIsTheRestoredUsersCompleteSnapshot() async {
        var restoring = true
        let tokens = Tokens(current: nil)
        let features = makeFeatures(tokens)
        features._identityPending = { restoring }
        let userAnswer = hold()
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == nil
                ? Reply(json: Self.snapshot(["basic"]))
                : Reply(json: Self.snapshot(["basic", "pro-export"]), hold: userAnswer)
        }

        var firstRender: (FeatureStatus, FeatureStatus)?
        let app = Task { @MainActor in
            await features.ready(timeout: 5)
            firstRender = (features.feature("basic").status, features.feature("pro-export").status)
        }
        _ = Task { await features.refresh(force: true) }   // activation at launch
        try? await Task.sleep(nanoseconds: 100_000_000)

        tokens.current = "tok-u1"
        restoring = false
        await features._load(userId: "u1")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(firstRender, "ready() returned before the restored user's snapshot")
        userAnswer.signal()
        await app.value

        XCTAssertEqual(firstRender?.0, .enabled)
        XCTAssertEqual(firstRender?.1, .enabled, "the first render was missing the user's gated feature")
    }

    // MARK: - H2: a result bound to the identity that asked

    func test_resolveForThePreviousUser_isDroppedAfterAUserSwitch() async {
        persist("a", version: 3, enabled: ["a-only"])
        persist("b", version: 3, enabled: ["b-only"])
        let tokens = Tokens(current: "tok-a")
        let features = makeFeatures(tokens)
        respond { _, _, _ in Reply(json: Self.snapshot(["a-only"])) }
        await features._load(userId: "a")
        await features._identityResolveTask?.value

        let aAnswer = hold()
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == "Bearer tok-a"
                ? Reply(json: Self.snapshot(["a-only"]), hold: aAnswer)
                : Reply(json: Self.snapshot(["b-only"]))
        }
        let before = Stub.requests("/features/resolve").count
        let forA = Task { await features.refresh(force: true) }
        await waitUntil { Stub.requests("/features/resolve").count > before }

        tokens.current = "tok-b"
        await features._load(userId: "b")
        aAnswer.signal()
        await forA.value

        XCTAssertEqual(status(features, "b-only"), .enabled)
        XCTAssertEqual(status(features, "a-only"), .hidden, "user a's answer was applied to user b")
        XCTAssertNil(persisted("b")["a-only"], "user a's answer was persisted under user b's key")
    }

    // MARK: - H3: no anonymous answer over a signed-in user

    func test_refusedToken_whileSignedIn_keepsTheUsersSnapshot() async {
        persist("u1", version: 3, enabled: ["basic", "pro-export"])
        let tokens = Tokens(current: "expired", refreshed: nil)
        let features = makeFeatures(tokens)
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == nil ? Reply(json: Self.snapshot(["basic"])) : Self.refused
        }

        await features._load(userId: "u1")
        await features.refresh(force: true)
        // Let any resolve started by the identity change settle too.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(status(features, "pro-export"), .enabled,
                       "an anonymous fallback answer replaced the signed-in user's snapshot")
        XCTAssertEqual(persisted("u1")["pro-export"], "enabled",
                       "an anonymous fallback answer was persisted under the user's key")
    }

    // MARK: - Carry-over: a new identity never inherits the previous snapshot

    func test_identityWithoutAPersistedSnapshot_doesNotInheritThePreviousOne() async {
        persist("a", version: 3, enabled: ["a-only"])
        let tokens = Tokens(current: "tok-a")
        let features = makeFeatures(tokens)
        let bAnswer = hold()
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == "Bearer tok-b"
                ? Reply(json: Self.snapshot(["b-only"]), hold: bAnswer)
                : Reply(json: Self.snapshot(["a-only"]))
        }
        await features._load(userId: "a")
        await features._identityResolveTask?.value
        XCTAssertEqual(status(features, "a-only"), .enabled)

        tokens.current = "tok-b"
        await features._load(userId: "b")

        XCTAssertEqual(status(features, "a-only"), .hidden,
                       "user b sees user a's snapshot until the stream answers")
    }

    // MARK: - H4: ready() follows the identity

    func test_ready_afterAnIdentityChange_waitsForTheNewIdentitysSnapshot() async {
        let tokens = Tokens(current: "tok-a")
        let features = makeFeatures(tokens)
        let bAnswer = hold()
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == "Bearer tok-b"
                ? Reply(json: Self.snapshot(["b-only"]), hold: bAnswer)
                : Reply(json: Self.snapshot(["a-only"]))
        }
        await features._load(userId: "a")
        await features._identityResolveTask?.value
        features._signalFirstEvent()
        await features.ready(timeout: 1)

        tokens.current = "tok-b"
        await features._load(userId: "b")
        let start = Date()
        await features.ready(timeout: 0.3)
        let waited = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(waited, 0.25,
                             "ready() returned for user b on the strength of user a's snapshot (\(waited)s)")
    }

    // MARK: - since_version poisoning

    private final class Opens {
        var queries: [[String: String]] = []
        var scripts: [AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>] = []
    }

    /// Stays open, delivering nothing, until cancelled.
    private static func silentStream() -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    /// A standalone `OneloFeatures` owns its stream, so `_load` opens it.
    private func makeStandalone(_ tokens: Tokens, _ opens: Opens) -> OneloFeatures {
        let features = OneloFeatures(client: client(), userToken: tokens.source)
        features._setOpenStreamForTesting { items, _ in
            var q: [String: String] = [:]
            for i in items { q[i.name] = i.value ?? "" }
            opens.queries.append(q)
            return opens.scripts.isEmpty ? Self.silentStream() : opens.scripts.removeFirst()
        }
        return features
    }

    /// A persisted snapshot is shown, but its version was never confirmed by the
    /// server for this user: asking with it lets the stream answer `up_to_date`
    /// over a possibly wrong snapshot (the app-wide version matches).
    func test_persistedVersion_isNotSentAsSinceVersion_untilConfirmed() async {
        persist("u1", version: 7, enabled: ["basic"])
        let tokens = Tokens(current: "tok-u1")
        respond { _, _, _ in Reply(json: Self.snapshot(["basic"])) }
        let opens = Opens()
        let features = makeStandalone(tokens, opens)

        await features._load(userId: "u1")
        await waitUntil { opens.queries.count >= 1 }
        features._stopPolling()

        XCTAssertEqual(status(features, "basic"), .enabled, "the persisted snapshot still renders at once")
        XCTAssertEqual(opens.queries.first?["since_version"], "0",
                       "an unconfirmed persisted version was sent as since_version")
    }

    func test_versionConfirmedByTheStream_isUsedOnReconnect() async {
        let tokens = Tokens(current: "tok-u1")
        respond { _, _, _ in Reply(json: Self.snapshot(["basic"])) }
        let opens = Opens()
        opens.scripts = [AsyncThrowingStream { c in
            c.yield(.init(type: "connected",
                          data: #"{"config_version":9,"features":{"basic":{"status":"enabled"}}}"#))
            c.finish()
        }]
        let features = makeStandalone(tokens, opens)

        await features._load(userId: "u1")
        await waitUntil { opens.queries.count >= 2 }
        features._stopPolling()

        XCTAssertEqual(opens.queries.first?["since_version"], "0")
        XCTAssertEqual(opens.queries.dropFirst().first?["since_version"], "9")
        XCTAssertEqual(status(features, "basic"), .enabled)
    }

    /// A stream whose token was refused reconnects anonymously; its snapshot is
    /// the no-user one and must not stand in for the signed-in user's.
    func test_anonymousFallbackStream_doesNotReplaceTheSignedInUsersSnapshot() async {
        persist("u1", version: 3, enabled: ["basic", "pro-export"])
        let tokens = Tokens(current: "expired", refreshed: nil)
        let opens = Opens()
        let refusal = AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
            $0.finish(throwing: _OneloSSERejected(status: 401, errorCode: "invalid_user_token"))
        }
        let anonymousSnapshot = AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
            $0.yield(.init(type: "connected",
                           data: #"{"config_version":4,"features":{"basic":{"status":"enabled"}}}"#))
        }
        opens.scripts = [refusal, anonymousSnapshot]
        respond { path, auth, _ in
            guard path.hasSuffix("/features/resolve") else { return Reply(status: 204) }
            return auth == nil ? Reply(json: Self.snapshot(["basic"])) : Self.refused
        }
        let features = makeStandalone(tokens, opens)

        await features._load(userId: "u1")
        await waitUntil { opens.queries.count >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        features._stopPolling()

        XCTAssertNil(opens.queries.dropFirst().first?["userId"], "the fallback connection is anonymous")
        XCTAssertEqual(status(features, "pro-export"), .enabled,
                       "the anonymous stream's snapshot replaced the signed-in user's")
        XCTAssertEqual(persisted("u1")["pro-export"], "enabled")
    }
}
