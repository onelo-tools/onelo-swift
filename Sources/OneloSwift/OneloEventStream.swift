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

    // MARK: - Connection state

    private var streamTask: Task<Void, Never>?
    private var currentUserId: String?
    private var currentUserIdHash: String?
    private var currentSinceVersion: Int = 0
    private var currentAppVersion: String?
    private var isStarted: Bool = false
    /// Explicit feature environment ("test"|"live") forwarded as the `environment`
    /// query param so the backend resolves the matching snapshot regardless of the
    /// key prefix. Nil → omitted → backend falls back to the key prefix. Set once by
    /// OneloFeatures; constant for the stream's lifetime, so it is intentionally NOT
    /// part of start()'s idempotency comparison. See
    /// docs/architecture/feature-environment-explicit.md.
    var featureEnvironment: String?

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

    /// Open (or re-open) the SSE connection with the given parameters.
    /// Idempotent: calling with the same `userId` + `sinceVersion` while
    /// already running is a no-op. Calling with different params tears
    /// the existing connection down and reconnects with the new ones.
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
           currentUserIdHash == userIdHash,
           currentSinceVersion == sinceVersion,
           currentAppVersion == appVersion {
            return  // no-op
        }
        currentUserId = userId
        currentUserIdHash = userIdHash
        currentSinceVersion = sinceVersion
        currentAppVersion = appVersion
        isStarted = true
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
        streamTask?.cancel()
        streamTask = nil
    }

    /// Internal test-only probe for the "stream is in started state" invariant.
    /// Mirrors the pre-3.51 `streamTask != nil` check that OneloFeaturesTests
    /// asserted to make sure `ready()` doesn't open a second connection.
    var _isStartedForTesting: Bool { isStarted }

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

    private func _connectOnce() async throws {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "key", value: httpClient.publishableKey),
            URLQueryItem(name: "since_version", value: String(currentSinceVersion)),
            URLQueryItem(name: "instance_id", value: OneloInstanceId.current()),
            URLQueryItem(name: "sdk_platform", value: "swift"),
            URLQueryItem(name: "sdk_version", value: OneloSDK.sdkVersion),
        ]
        if let av = currentAppVersion {
            queryItems.append(URLQueryItem(name: "app_version", value: av))
        }
        if let env = featureEnvironment {
            queryItems.append(URLQueryItem(name: "environment", value: env))
        }
        if let uid = currentUserId {
            queryItems.append(URLQueryItem(name: "userId", value: uid))
        }
        if let hash = currentUserIdHash {
            queryItems.append(URLQueryItem(name: "userIdHash", value: hash))
        }

        log.info("connecting userId=\(self.currentUserId ?? "<anon>", privacy: .public) sinceVersion=\(self.currentSinceVersion)")
        let stream = httpClient.stream(path: "/api/sdk/features/stream", queryItems: queryItems)
        for try await event in stream {
            if Task.isCancelled { return }
            _dispatch(event)
        }
    }

    private func _dispatch(_ event: _OneloHTTPClient.SSEEvent) {
        guard !event.type.isEmpty else { return }
        guard let list = handlers[event.type], !list.isEmpty else { return }
        for handler in list {
            handler(event.data)
        }
    }
}
