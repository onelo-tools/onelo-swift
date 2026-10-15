import Foundation
import os.log

/// Universal SSE event stream — ONE persistent connection per app, multiplexed
/// for every Onelo module that needs server-pushed events (auth session
/// revocation, features deploy, paywall access changes, etc.).
///
/// This is the canonical pattern documented in MDN's EventSource guide and
/// the HTML5 Living Standard §9.2: a single long-lived connection emits
/// named events, consumers register one handler per event name, the parser
/// dispatches incoming frames to whichever handlers match. Slack, Discord,
/// Stripe Dashboard, Linear, Notion all use the same shape.
///
/// Why this exists:
///   • Pre-3.51 each module (OneloFeatures, OneloAuth) opened its own SSE
///     stream against `/api/sdk/features/stream`. Two modules = two
///     connections per app, even though the backend Broadcaster fans out
///     to every subscriber for the same `app_id`. Wasteful, and the
///     reconnect / parser logic was duplicated.
///   • Backend `sdk_features_sse.py` already dispatches multiple typed
///     events on the same endpoint (see SSE-1 task). The wire protocol is
///     ready for multiplexing; the SDK side just needs the matching shape.
///
/// Lifecycle (mirrors EventSource):
///   1. `init(httpClient:)` — wires the SSE primitive. Cheap, no I/O.
///   2. `on(_:handler:)` — register one or more handlers per event name.
///      Multiple modules can register against the same name; all fire.
///   3. `start(userId:sinceVersion:appVersion:)` — opens the connection.
///      If already open with the same params, no-op. If already open with
///      different params (e.g. user signed in, anonymous → user-bound),
///      gracefully reconnects with the new query string.
///   4. `updateSinceVersion(_:)` — bumps the `since_version` query param
///      used on the next reconnect. Lets OneloFeatures persist its cache
///      version without forcing a reconnect on every applied snapshot.
///   5. `stop()` — closes the stream and cancels the reconnect loop. Used
///      by OneloAuth on sign-out, and by `deinit`.
///
/// Reconnect policy:
///   • Bounded exponential backoff [1, 2, 5, 10, 30] seconds, capped.
///   • Full jitter on each delay (AWS "exponential backoff and jitter"
///     pattern) so that N clients reconnecting after a backend bounce
///     spread their attempts across the window instead of thundering herd.
///   • CancellationError exits cleanly (no retry).
///
/// The signed-in user (#519): every connect sends `Authorization: Bearer
/// <access token>` read fresh from `userToken`, so a reconnect always proves the
/// user with a current token (the server checks it at connect only). A refused
/// token (`401 invalid_user_token`) is refreshed once and retried once; refused
/// again, that connection is opened anonymous (no Bearer, no `userId`) and the
/// next reconnect tries the user again. Same rules as the JS SDKs.
///
/// Concurrency: `@MainActor` so handlers can touch `@Published` vars on
/// modules (OneloAuth.currentSession, OneloFeatures.cache, etc.) without
/// hopping actors. The underlying URLSession.bytes loop runs on the
/// AsyncSequence's default executor and hands events back via main-actor
/// `Task` continuation.
@MainActor
public final class OneloEventStream {

    public typealias Handler = (String) -> Void

    // MARK: - Dependencies

    private let httpClient: _OneloHTTPClient
    private let log = Logger(subsystem: "com.onelo.sdk", category: "event-stream")

    // MARK: - Handler registry

    private var handlers: [String: [Handler]] = [:]
    private var activityHandlers: [() -> Void] = []

    // MARK: - Connection state

    private var streamTask: Task<Void, Never>?
    private var currentUserId: String?
    private var currentSinceVersion: Int = 0
    private var currentAppVersion: String?
    private var isStarted: Bool = false
    /// The user the connection now delivering frames was opened for: nil for a
    /// signed-out connection AND for the anonymous fallback after a refused
    /// token. Feature handlers compare it with their identity so a no-user
    /// snapshot never stands in for a signed-in user's (onelo-swift-staging#1).
    private(set) var connectionUserId: String?
    /// Explicit feature environment ("test"|"live") forwarded as the `environment`
    /// query param so the backend resolves the matching snapshot regardless of the
    /// key prefix. Nil → omitted → backend falls back to the key prefix. Set once by
    /// OneloFeatures; constant for the stream's lifetime, so it is intentionally NOT
    /// part of start()'s idempotency comparison. See
    /// docs/architecture/feature-environment-explicit.md.
    var featureEnvironment: String?
    /// The signed-in user's access token, sent as `Authorization: Bearer` on
    /// every connect. Set by `OneloAuth`, which owns this stream; nil (a
    /// standalone features stream) sends no token.
    var userToken: _OneloUserToken?
    private var userTokenRefusedWarned = false
    /// Test seam: opens one connection. Defaults to the real SSE transport.
    var _openStream: ((_ queryItems: [URLQueryItem], _ headers: [String: String]) -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>)?

    /// Bounded exponential backoff for SSE reconnects.
    private static let reconnectDelaysSeconds: [TimeInterval] = [1, 2, 5, 10, 30]

    // MARK: - Init

    init(httpClient: _OneloHTTPClient) {
        self.httpClient = httpClient
    }

    // MARK: - Public API

    /// Register a handler for a named SSE event. Multiple handlers per name
    /// are supported (mirror of `EventSource.addEventListener`). The payload
    /// passed to the handler is the raw `data:` lines joined with `\n`,
    /// usually a JSON string — the caller decodes it.
    public func on(_ eventType: String, handler: @escaping Handler) {
        handlers[eventType, default: []].append(handler)
    }

    /// Register a callback for every frame the connection delivers — a named
    /// event (handled or not) or the server's `: keepalive` comment. It runs
    /// before any event handler. This is the connection's liveness signal: a
    /// quiet app receives no named event for minutes, but the keepalive
    /// arrives every 30 s, so silence past a few keepalives means the
    /// connection is dead (#368).
    func onActivity(_ handler: @escaping () -> Void) {
        activityHandlers.append(handler)
    }

    /// Open (or re-open) the SSE connection with the given parameters.
    /// Idempotent: calling with the same `userId` + `sinceVersion` while
    /// already running is a no-op. Calling with different params tears
    /// the existing connection down and reconnects with the new ones.
    ///
    /// `userIdHash` is ignored: Secure Mode is retired, and the signed-in user
    /// is proven with their access token on every connect. Kept so existing
    /// code compiles.
    public func start(
        userId: String?,
        sinceVersion: Int = 0,
        appVersion: String? = nil,
        userIdHash: String? = nil
    ) {
        // Defensive: once bound to a real userId, refuse silent downgrade
        // back to nil. Anonymous-mode reload (e.g. OneloFeatures bootstrap)
        // must NOT kick out the auth-bound subscription that OneloAuth set
        // on sign-in — otherwise an in-flight `session.revoked` arriving
        // during the reconnect window vanishes into a closed queue and the
        // user stays logged in until the heartbeat fallback (~13 min).
        // Explicit teardown still works via `stop()`.
        if isStarted, currentUserId != nil, userId == nil {
            log.info("ignoring downgrade start(userId=nil) — already bound to a user")
            return
        }
        if isStarted,
           currentUserId == userId,
           currentSinceVersion == sinceVersion,
           currentAppVersion == appVersion {
            return  // no-op
        }
        currentUserId = userId
        currentSinceVersion = sinceVersion
        currentAppVersion = appVersion
        isStarted = true
        _startCallCountForTesting += 1
        _spawnConnectLoop()
    }

    /// Updates the `since_version` query param used on the NEXT reconnect.
    /// Does not force a reconnect — the current connection keeps serving
    /// events; if it drops, the reconnect picks up the new version.
    public func updateSinceVersion(_ version: Int) {
        currentSinceVersion = version
    }

    /// Closes the stream and stops reconnecting. Safe to call when already
    /// stopped. After `stop()`, registered handlers stay in place — calling
    /// `start(...)` again resumes delivery.
    public func stop() {
        isStarted = false
        _stopCallCountForTesting += 1
        streamTask?.cancel()
        streamTask = nil
    }

    /// Internal test-only probe for the "stream is in started state" invariant.
    /// Mirrors the pre-3.51 `streamTask != nil` check that OneloFeaturesTests
    /// asserted to make sure `ready()` doesn't open a second connection.
    var _isStartedForTesting: Bool { isStarted }

    /// Test-only call counters — let a caller-side zombie-detector test
    /// (OneloFeatures' `_checkSSEHealth` / `_resyncOnLifecycle`) verify that a
    /// stop()+start() reconnect cycle actually happened, not just that the
    /// stream ends up `isStarted == true` (which is also true when nothing
    /// happened at all, since `start()` is idempotent while already started).
    private(set) var _startCallCountForTesting = 0
    private(set) var _stopCallCountForTesting = 0

    // MARK: - Internals

    private func _spawnConnectLoop() {
        streamTask?.cancel()
        // Task inherits @MainActor isolation from the enclosing method,
        // so self.* accesses are direct (no await needed). The async
        // stream itself runs cooperatively under URLSession.
        streamTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, self.isStarted {
                do {
                    try await self._connectOnce()
                    // Clean close (server-side end-of-stream). Reset backoff.
                    attempt = 0
                    self.log.info("clean close, will reconnect")
                } catch is CancellationError {
                    return
                } catch {
                    self.log.warning("stream error: \(error.localizedDescription, privacy: .public)")
                    if Task.isCancelled { return }
                }

                if Task.isCancelled { return }
                let idx = min(attempt, OneloEventStream.reconnectDelaysSeconds.count - 1)
                let baseDelay = OneloEventStream.reconnectDelaysSeconds[idx]
                // Full jitter (AWS pattern) — randomize across [0, baseDelay]
                // to spread thundering-herd reconnects after a backend bounce.
                let jitter = Double.random(in: 0...baseDelay)
                attempt += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// The Event Stream's query string. Pure — nothing here is a credential.
    ///
    /// The Publishable Key used to be the first item; ADR-0003 moved it to the
    /// `X-Publishable-Key` request header (set in
    /// `_OneloHTTPClient.makeStreamRequest`), because a key in the URL is logged
    /// by every proxy on the way and the backend sunsets that form. Swift can
    /// set headers on this GET — `applySecurityHeaders` already puts three to six
    /// there — so nothing else about the connection changes.
    nonisolated static func _streamQueryItems(
        sinceVersion: Int,
        appVersion: String? = nil,
        environment: String? = nil,
        userId: String? = nil
    ) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "since_version", value: String(sinceVersion)),
            URLQueryItem(name: "instance_id", value: OneloInstanceId.current()),
            URLQueryItem(name: "sdk_platform", value: "swift"),
            URLQueryItem(name: "sdk_version", value: OneloSDK.sdkVersion),
        ]
        if let av = appVersion {
            queryItems.append(URLQueryItem(name: "app_version", value: av))
        }
        if let env = environment {
            queryItems.append(URLQueryItem(name: "environment", value: env))
        }
        if let uid = userId {
            queryItems.append(URLQueryItem(name: "userId", value: uid))
        }
        return queryItems
    }

    /// One connection, proving the signed-in user. The token is read fresh
    /// here, on every (re)connect. A refused token is refreshed once (shared
    /// with Features: one refresh per refusal episode) and retried once;
    /// refused again, this connection goes anonymous — no Bearer, no `userId`.
    private func _connectOnce() async throws {
        let token = await userToken?.current()
        try Task.checkCancellation()
        do {
            try await _consume(token: token, anonymous: false)
            return
        } catch let rejected as _OneloSSERejected where token != nil && rejected.isUserTokenRefusal {
            // fall through to the refusal handling below
        }
        if let fresh = await userToken?.refreshAfterRefusal() {
            try Task.checkCancellation()
            do {
                try await _consume(token: fresh, anonymous: false)
                return
            } catch let rejected as _OneloSSERejected where rejected.isUserTokenRefusal {
                // refused again — anonymous below
            }
        }
        try Task.checkCancellation()
        _warnUserTokenRefused()
        try await _consume(token: nil, anonymous: true)
    }

    private func _consume(token: String?, anonymous: Bool) async throws {
        // A connection whose user token was refused is anonymous: no `?userId`.
        let queryItems = Self._streamQueryItems(
            sinceVersion: currentSinceVersion,
            appVersion: currentAppVersion,
            environment: featureEnvironment,
            userId: anonymous ? nil : currentUserId
        )
        let headers = _OneloUserTokenWire.headers(token)
        connectionUserId = anonymous ? nil : currentUserId

        log.info("connecting userId=\(anonymous ? "<anon>" : (self.currentUserId ?? "<anon>"), privacy: .public) sinceVersion=\(self.currentSinceVersion)")
        let stream = _openStream?(queryItems, headers)
            ?? httpClient.stream(path: "/api/sdk/features/stream", queryItems: queryItems, headers: headers)
        var acceptanceNoted = false
        for try await event in stream {
            if Task.isCancelled { return }
            for handler in activityHandlers { handler() }
            // A keepalive only proves liveness; no handler receives it.
            if event.isComment { continue }
            // The server answers a connect with an event only after it checked
            // the token: the first one proves this token was accepted.
            if token != nil, !acceptanceNoted {
                acceptanceNoted = true
                userToken?.accepted()
            }
            _dispatch(event)
        }
    }

    private func _warnUserTokenRefused() {
        guard !userTokenRefusedWarned else { return }
        userTokenRefusedWarned = true
        print("[Onelo] The signed-in user's access token was refused by the Event Stream (invalid_user_token) "
              + "even after a refresh, so the stream was opened without a user.")
    }

    private func _dispatch(_ event: _OneloHTTPClient.SSEEvent) {
        guard !event.type.isEmpty else { return }
        guard let list = handlers[event.type], !list.isEmpty else { return }
        for handler in list {
            handler(event.data)
        }
    }
}
