import XCTest
@testable import OneloSwift

@MainActor
final class OneloIdentityBridgeTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        OneloAuth(_testingConfig: OneloConfig(
            publishableKey: "pk_test",
            apiUrl: URL(string: "https://example.com")!,
            callbackScheme: ""
        ))
    }

    func testSessionPublisherEmitsUserIdOnSignIn() async {
        let auth = makeAuth()

        // Subscribe to the stream first, then inject — both on @MainActor so ordering is guaranteed.
        var iterator = auth.$currentSession.values.makeAsyncIterator()

        // Consume the initial nil that @Published emits on subscription.
        let initial: OneloSession?? = await iterator.next()
        XCTAssertNil(initial!)

        // Now inject a session and read the next emission.
        auth._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-xyz", email: nil, role: .member, tenantId: nil)
        ))

        let session: OneloSession?? = await iterator.next()
        XCTAssertEqual(session!!.user.id, "user-xyz")
    }

    /// Regression: v3.23.3 shipped without `monitor.setUserId(...)` inside the
    /// `$currentSession` watcher in `Onelo.init`, so monitor events for fully
    /// authenticated users were attributed to `anonymous` and multiple users
    /// on the same install collapsed into one install-bound session.
    /// See `Onelo.swift` — the propagation loop now mirrors session.user.id
    /// into the monitor alongside features/heartbeat.
    /// Identity-mode path (Pro/Business custom auth):
    /// `onelo.identify(externalUserId)` must propagate to the monitor too.
    /// Pre-fix only `features._load` got the user id; monitor stayed nil
    /// and events shipped as `anonymous`.
    func testMonitorReceivesUserIdViaIdentify() async throws {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        XCTAssertNil(onelo.monitor._currentUserIdForTesting())

        await onelo.identify("custom-auth-user-42")

        // `identify` mutates monitor state synchronously inside the
        // monitor's serial queue — poll briefly in case ordering shifts.
        try await waitForMonitorUserId(onelo.monitor, expected: "custom-auth-user-42")
    }

    /// Identity-mode logout: `clearIdentity()` mirrors the Onelo-Auth
    /// `signOut` semantics for apps that don't use Onelo Auth.
    func testMonitorUserIdClearedByClearIdentity() async throws {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        await onelo.identify("custom-auth-user-99")
        try await waitForMonitorUserId(onelo.monitor, expected: "custom-auth-user-99")

        await onelo.clearIdentity()
        try await waitForMonitorUserId(onelo.monitor, expected: nil)
    }

    func testMonitorReceivesUserIdWhenSessionAppears() async throws {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        // Pre-condition: no session → monitor user id is nil.
        XCTAssertNil(onelo.monitor._currentUserIdForTesting())

        // Yield so the watcher Tasks scheduled in `Onelo.init` get a chance
        // to subscribe to `$currentSession` before we inject.
        for _ in 0..<5 { await Task.yield() }

        onelo.auth.authObject._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-monitor-1", email: nil, role: .member, tenantId: nil)
        ))

        // Watcher hops through MainActor + the monitor's serial queue. Poll up
        // to ~2s so the test isn't tied to a specific scheduling delay.
        try await waitForMonitorUserId(onelo.monitor, expected: "user-monitor-1")
    }

    func testMonitorUserIdClearedOnSignOut() async throws {
        let onelo = Onelo(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.invalid")!,
            autoLifecycleRefresh: false
        )

        for _ in 0..<5 { await Task.yield() }

        onelo.auth.authObject._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-monitor-2", email: nil, role: .member, tenantId: nil)
        ))
        try await waitForMonitorUserId(onelo.monitor, expected: "user-monitor-2")

        onelo.auth.authObject._clearSessionForTesting()
        try await waitForMonitorUserId(onelo.monitor, expected: nil)
    }

    private func waitForMonitorUserId(
        _ monitor: OneloMonitor,
        expected: String?,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if monitor._currentUserIdForTesting() == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        XCTFail("Monitor user id did not reach \(expected ?? "nil") within \(timeout)s; got \(monitor._currentUserIdForTesting() ?? "nil")")
    }

    func testSessionPublisherEmitsNilWhenSessionCleared() async {
        let auth = makeAuth()

        var iterator = auth.$currentSession.values.makeAsyncIterator()

        // Consume the initial nil.
        _ = await iterator.next()

        // Inject a session → emission #1.
        auth._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-xyz", email: nil, role: .member, tenantId: nil)
        ))
        let sessionEmission = await iterator.next()
        XCTAssertEqual(sessionEmission??.user.id, "user-xyz")

        // Clear the session → emission #2 should be nil (OneloSession? = nil).
        auth._clearSessionForTesting()
        let nilEmission = await iterator.next()  // OneloSession??
        let innerValue: OneloSession? = nilEmission!  // unwrap next()-Optional, keep inner Optional
        XCTAssertNil(innerValue)
    }
}
