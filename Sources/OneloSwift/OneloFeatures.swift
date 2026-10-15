import Foundation
import Observation

@MainActor
@Observable
public final class OneloFeatures {
    private let client: _OneloHTTPClient
    /// #37 — bounded "wait until the App Attest token is ready" gate, wired by
    /// `Onelo` to `OneloAuth._awaitAttestReady` + a readiness check. Awaited before
    /// the discovery batch-ping so the gated endpoint isn't hit tokenless during
    /// cold-start (which 403s on iOS → retry noise + delayed discovery). Returns
    /// `true` when the ping may proceed (token present / attestation not required /
    /// macOS / terminal attest error), `false` when the token is STILL pending
    /// after the wait (fresh-install attestation can exceed the 5s cap) — in which
    /// case `_batchPing` skips the tokenless send and defers to the token-arrival
    /// re-ping wired in `Onelo`. `nil` (unwired / standalone) → treated as ready.
    var _attestReadyGate: (() async -> Bool)? = nil
    /// #37 — set when `_batchPing` SKIPPED a send because the attest token wasn't
    /// ready yet. The token-arrival watcher (wired in `Onelo`) re-fires the ping
    /// ONLY when this is true, so a normal (token-ready) cold/warm start pings
    /// exactly once — no double-ping from the watcher replaying `$attestToken`.
    private var _pendingTokenPing = false
    @ObservationIgnored private weak var monitor: OneloMonitor?
    /// The only observable property: SwiftUI reads `cache[name]` via `feature(_:)`
    /// and must re-render when SSE pushes a new snapshot. Everything else below is
    /// internal bookkeeping and must NOT trigger view invalidation — otherwise any
    /// call to `feature(_:)` from inside `body` mutates a tracked property and
    /// the view re-evaluates forever.
    private var cache: [String: FeatureState] = [:]
    /// #606 — change subscribers (`subscribe(_:)`), fired after every snapshot
    /// mutation. Ignored by Observation: registering a listener is not a state
    /// change a view should re-render for.
    @ObservationIgnored private var changeListeners: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var discoveredNames: Set<String> = []
    @ObservationIgnored private var configVersion: Int = 0
    /// Shared SSE pipe. When OneloFeatures is constructed via the top-level
    /// `Onelo` wrapper, this is the SAME instance owned by `OneloAuth` — so
    /// auth and features share a single SSE connection. When OneloFeatures
    /// is used standalone (without OneloAuth), it owns its own stream.
    @ObservationIgnored private let eventStream: OneloEventStream
    /// True when this instance created its own eventStream (standalone use)
    /// so `_stopPolling` knows it owns the lifecycle. When the stream is
    /// injected from OneloAuth, OneloAuth owns it — features just deregisters.
    @ObservationIgnored private let ownsEventStream: Bool
    @ObservationIgnored private var pendingPingTask: Task<Void, Never>?

    /// Last time we observed activity on the SSE channel: any event, or the
    /// server's `: keepalive` comment (`OneloEventStream.onActivity`).
    /// Used by the healthcheck timer to detect zombie connections — sockets that
    /// stay TCP-`ESTABLISHED` but stop delivering data, typically because macOS
    /// App Nap suspended the URLSession or a NAT box dropped the flow.
    @ObservationIgnored private var lastEventReceived: Date = Date()
    @ObservationIgnored private var healthcheckTask: Task<Void, Never>?
    /// Public via `refresh()` — last time we ran the REST refresh path. Used to
    /// debounce flurries of lifecycle calls (foreground + system-wake firing
    /// within a few ms of each other) to one network call.
    @ObservationIgnored private var lastRefreshAt: Date = .distantPast
    /// Treat the SSE connection as zombie if no event arrives within this window.
    /// Server emits `:` heartbeats every 30s, so 90s = 3 missed heartbeats.
    /// Internal var (not let) so tests can shrink it.
    @ObservationIgnored var _sseStaleThreshold: TimeInterval = 90
    /// Lifecycle resync uses a shorter window than the periodic healthcheck —
    /// foreground/wake is a strong signal the app was suspended, so be eager.
    @ObservationIgnored var _sseLifecycleStaleThreshold: TimeInterval = 60
    @ObservationIgnored var _refreshDebounce: TimeInterval = 1.0
    private let suppressIdentifyWarning: Bool
    /// Status returned for any feature whose name isn't (yet) in the cache.
    /// Defaults to `.hidden` — fail-closed, so a feature that has been instrumented
    /// in code but not yet enabled in the dashboard stays hidden in production.
    /// Set to `.enabled` during development to flip the default and have new
    /// gates show their content until you toggle them in the dashboard.
    private let defaultStatus: FeatureStatus
    @ObservationIgnored private var anonymousWarningLogged: Bool = false
    @ObservationIgnored private var currentUserId: String?
    /// The signed-in Onelo user's access token, sent as `Authorization: Bearer`
    /// on every Features call so the server knows who the user really is
    /// (#519). Wired by `Onelo` to `OneloAuth`; nil (standalone use) sends no token.
    @ObservationIgnored private let userToken: _OneloUserToken?
    @ObservationIgnored private var userTokenRefusedWarned = false
    @ObservationIgnored private var destroyed: Bool = false
    @ObservationIgnored private let _appVersion: String?
    /// Explicit feature environment ("test"|"live"). Forwarded on `/resolve`,
    /// `/batch-ping`, and the SSE stream so the backend resolves the matching
    /// snapshot regardless of the key prefix — letting a client and its server
    /// agree on env. Nil → omitted → backend uses the key prefix (old behavior).
    @ObservationIgnored private let _featureEnvironment: String?

    /// True once the server has confirmed the snapshot in memory for the
    /// CURRENT identity (onelo-swift-staging#1): a `connected` / `features_updated` frame on a
    /// connection that proved this identity, an `up_to_date` answering a version
    /// confirmed for it, or a `/resolve` sent for it. Reset on every identity
    /// change — a persisted or previous identity's snapshot is never "ready".
    /// Observable, so SwiftUI can gate on it; it never changes inside `feature(_:)`.
    public private(set) var isSnapshotConfirmed: Bool = false
    /// Bumped on every identity change. A result started under an older
    /// generation (a `/resolve` in flight, a stream frame for another user) is
    /// dropped instead of replacing the current identity's snapshot.
    @ObservationIgnored private var identityGeneration: UInt64 = 0
    /// False until the first `_load`; the first load is always an identity change.
    @ObservationIgnored private var identityLoaded = false
    /// The `config_version` the server confirmed for the current identity, 0
    /// until it has. Only this is sent as `since_version`: the version is
    /// app-wide, so sending a persisted (or another identity's) version would let
    /// the stream answer `up_to_date` over a snapshot it never resolved for
    /// this user.
    @ObservationIgnored private var confirmedVersion: Int = 0
    /// Wired by `Onelo` to "a stored session is still being restored". While it
    /// holds, refreshes wait (bounded) so they resolve for the restored user
    /// instead of anonymously.
    @ObservationIgnored var _identityPending: (() -> Bool)? = nil
    /// The signed-in Onelo user, as `Onelo` hears it the moment the session
    /// changes (#731). The identity itself loads a turn later, from the session
    /// watcher; until then the snapshot in memory belongs to someone else, so
    /// it is not confirmed and `ready()` waits. Nil when nobody is signed in.
    @ObservationIgnored private var signedInUserId: String?
    /// Upper bound on that wait.
    @ObservationIgnored var _identitySettleTimeout: TimeInterval = 10
    /// The `/resolve` started by the last identity change (test seam).
    @ObservationIgnored private(set) var _identityResolveTask: Task<Void, Never>?
    /// Pending `ready()` continuations keyed by a per-call UUID so that the signal
    /// and the timeout can each atomically claim a specific entry without risking a
    /// double-resume on `CheckedContinuation`. All access is serialized by the
    /// `@MainActor` isolation of this class.
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        client: _OneloHTTPClient,
        eventStream: OneloEventStream? = nil,
        monitor: OneloMonitor? = nil,
        suppressIdentifyWarning: Bool = false,
        defaultStatus: FeatureStatus = .hidden,
        appVersion: String? = nil,
        featureEnvironment: String? = nil,
        userToken: _OneloUserToken? = nil
    ) {
        self.client = client
        self.userToken = userToken
        self.monitor = monitor
        self.suppressIdentifyWarning = suppressIdentifyWarning
        self.defaultStatus = defaultStatus
        self._appVersion = appVersion
        self._featureEnvironment = featureEnvironment
        // Use the injected stream (single connection across modules) when
        // provided. Standalone callers get a private one so OneloFeatures
        // still works without OneloAuth.
        if let injected = eventStream {
            self.eventStream = injected
            self.ownsEventStream = false
        } else {
            self.eventStream = OneloEventStream(httpClient: client)
            self.ownsEventStream = true
        }
        // The features stream carries the env so the SSE snapshot matches what
        // /resolve returns. Safe to set even on an injected (shared) stream —
        // auth ignores it; only the features endpoint reads `environment`.
        self.eventStream.featureEnvironment = featureEnvironment
        // A stream this instance owns proves the user the same way its calls
        // do; an injected (auth-owned) stream already has auth's token source.
        if ownsEventStream, let userToken { self.eventStream.userToken = userToken }
        _registerEventHandlers()
    }

    /// Wires the four feature-side handlers onto the shared SSE stream.
    /// Called exactly once in `init` so duplicate registrations are
    /// impossible across `_load` / signin cycles.
    private func _registerEventHandlers() {
        // Every frame — including the keepalive comment, which reaches no
        // handler below — proves the connection is alive (#368).
        eventStream.onActivity { [weak self] in
            self?.lastEventReceived = Date()
        }
        eventStream.on("connected") { [weak self] data in
            guard let self, self._streamSpeaksForCurrentIdentity(),
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            // Server has a newer version — apply the full snapshot.
            if let features = payload["features"] as? [String: [String: Any]] {
                self._applySnapshot(
                    version: payload["config_version"] as? Int ?? self.configVersion,
                    features: features,
                )
                self._confirmSnapshot()
            }
            self._maybeWarnAnonymous(payload)
        }
        eventStream.on("up_to_date") { [weak self] data in
            guard let self, self._streamSpeaksForCurrentIdentity(),
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            // Confirms only a version the server already confirmed for THIS
            // identity — never a persisted or another identity's one.
            if let v = payload["config_version"] as? Int, self.confirmedVersion != 0, v == self.confirmedVersion {
                self._confirmSnapshot()
            }
        }
        eventStream.on("features_updated") { [weak self] data in
            guard let self, self._streamSpeaksForCurrentIdentity(),
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            if let features = payload["features"] as? [String: [String: Any]] {
                self._applySnapshot(
                    version: payload["config_version"] as? Int ?? self.configVersion,
                    features: features,
                )
                self._confirmSnapshot()
            }
        }
        eventStream.on("discovery_requested") { [weak self] _ in
            self?._scheduleBatchPing()
        }
    }

    /// Whether the frame being dispatched is about the current identity: the
    /// connection names the same user, and it is not the anonymous fallback of a
    /// refused token while a user is signed in (its snapshot is the no-user one).
    private func _streamSpeaksForCurrentIdentity() -> Bool {
        eventStream.connectionUserId == currentUserId
    }

    private static func _decodeJSON(_ data: String) -> [String: Any]? {
        guard let bytes = data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        return parsed
    }

    // MARK: - Public API

    /// Declares a list of feature names upfront — registers them immediately via batch-ping.
    /// Call this at app startup with all known feature names.
    public func declare(_ names: [String]) {
        for name in names { discoveredNames.insert(name) }
        _scheduleBatchPing()
    }

    /// Returns the feature state for the given name.
    /// Registers the name for auto-discovery if seen for the first time.
    ///
    /// SwiftUI safety: `feature(_:)` is designed to be called from `body` and from
    /// `TimelineView` ticks. It must read observable state (`cache`) and only
    /// touch internal tracking when a name is genuinely new — otherwise every
    /// repeat call would mutate `discoveredNames` and could risk re-render loops
    /// on hot paths. `discoveredNames` is also `@ObservationIgnored` for the
    /// same reason.
    public func feature(_ name: String) -> FeatureState {
        let state = cache[name] ?? FeatureState(name: name, status: defaultStatus)
        if !discoveredNames.contains(name) {
            discoveredNames.insert(name)
            _scheduleBatchPing()
            monitor?._trackFeatureCall(name)
        }
        // Record evaluation in monitor's flag buffer — next captured error
        // will include active flag state, enabling flag↔error correlation.
        monitor?.recordFlag(name, value: state.status.rawValue)
        return state
    }

    /// Awaits a snapshot the server has confirmed for the CURRENT identity, so
    /// the host app can present gated UI complete on its first render — at
    /// launch, and again after a sign-in or a user switch.
    ///
    /// Behavior:
    /// - Returns immediately when ``isSnapshotConfirmed`` is true.
    /// - Otherwise waits until the stream (`connected` / `features_updated`) or
    ///   a `/resolve` confirms a snapshot for the current identity. A stored
    ///   session still being restored at launch counts as "not settled": the
    ///   wait ends with the restored user's snapshot, not an anonymous one.
    /// - An identity change resets it: after sign-in or a user switch, `ready()`
    ///   waits for the new user's snapshot even if it returned before.
    /// - Returns after `timeout` seconds (default 1.5s) if the network is slow or
    ///   offline; the persisted snapshot of that identity (if any) is then what
    ///   ``feature(_:)`` returns, and the UI updates when the snapshot lands
    ///   (``subscribe(_:)`` fires).
    /// - Safe to call from multiple call-sites concurrently. Never throws.
    public func ready(timeout: TimeInterval = 1.5) async {
        if isSnapshotConfirmed && !_awaitsSignedInUser { return }

        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyWaiters[id] = cont

            // Schedule the fallback. The timeout Task and `_signalFirstEvent` race
            // to claim this entry; whichever runs first removes it from the dict
            // and resumes the continuation, the other observes its absence and
            // does nothing — preventing any double-resume on the continuation.
            Task { [weak self] in
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self else { return }
                    if let pending = self.readyWaiters.removeValue(forKey: id) {
                        pending.resume()
                    }
                }
            }
        }
    }

    /// Requests a short-lived per-feature JWT from
    /// `POST /api/sdk/features/module-token`. The token is what the host
    /// app forwards to its OWN backend (or to Onelo-hosted modules) as
    /// proof that the current user is entitled to `slug`. The backend
    /// re-verifies entitlement on every request — the token is short-lived
    /// (60s by default) and bound to `(userId, slug)`.
    ///
    /// Throws:
    /// - `.notAuthenticated` if `_load(userId:)` hasn't been called yet
    ///   (no network call is made in this case), or the signed-in user's
    ///   access token was refused even after a refresh.
    /// - `.notEntitled` (403) if the current user lacks access to `slug`.
    /// - `.networkError` for transport failures or malformed responses.
    public func moduleToken(for slug: String) async throws -> String {
        guard let uid = currentUserId else {
            throw OneloFeaturesError.notAuthenticated
        }
        let body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "userId": uid,
            "slug": slug,
        ]
        let status: Int
        let json: [String: Any]
        do {
            // A module token is always for a user, so a refused token ends
            // here (`.notAuthenticated`) instead of retrying anonymously.
            (status, json) = try await _sendWithUserToken(
                userToken,
                anonymousFallback: false,
                onRefused: { _warnUserTokenRefused() }
            ) { attempt in
                try await client.postRaw(
                    path: "/api/sdk/features/module-token",
                    body: body,
                    headers: _OneloUserTokenWire.headers(attempt.token)
                )
            }
        } catch {
            throw OneloFeaturesError.networkError
        }
        switch status {
        case 200:
            guard let token = json["token"] as? String, !token.isEmpty else {
                throw OneloFeaturesError.networkError
            }
            return token
        case 401:
            throw OneloFeaturesError.notAuthenticated
        case 403:
            throw OneloFeaturesError.notEntitled
        default:
            throw OneloFeaturesError.networkError
        }
    }

    /// Returns the names of all features currently enabled in the cache.
    /// Used by `OneloFeedback` to attach session context to the initiate request.
    public func getActiveFeatures() -> [String] {
        let active: Set<FeatureStatus> = [.enabled, .new, .beta]
        return cache.compactMap { name, state in active.contains(state.status) ? name : nil }
    }

    /// Force-refresh the feature snapshot from the server via REST. Safe to call
    /// frequently — debounced internally to one network call per second by
    /// default — and does NOT touch the SSE stream. Use this on app foreground /
    /// system wake (the SDK does this automatically when `autoLifecycleRefresh`
    /// is enabled) or any time you want to reconcile after a likely-suspended
    /// period.
    ///
    /// - Parameter force: When `true`, bypasses the 1-second debounce. Use this
    ///   from user-initiated paths (e.g. a "Refresh" button in your menu) where
    ///   the user expects an unconditional response. Default `false` — best for
    ///   programmatic calls where flurries of requests should coalesce.
    ///
    /// Never throws; network errors are swallowed (cached state stays valid).
    public func refresh(force: Bool = false) async {
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastRefreshAt) >= _refreshDebounce else { return }
        }
        lastRefreshAt = now
        await _awaitIdentitySettled()
        // Still restoring after the bounded wait (a slow config fetch / verify
        // in an outage): resolving now would answer for no user and replace
        // the restored user's snapshot. The identity's own load resolves once
        // the restore ends, so skip this one.
        if _identityPending?() == true { return }
        await _runRefresh(userId: currentUserId)
    }

    /// While a stored session is being restored, wait (bounded) for it, so a
    /// refresh fired at launch — the macOS activation, a host's menu — resolves
    /// for the restored user, not anonymously ahead of it.
    private func _awaitIdentitySettled() async {
        guard let pending = _identityPending, pending() else { return }
        let deadline = Date().addingTimeInterval(_identitySettleTimeout)
        while pending(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A comparable picture of the current snapshot — the plan-change
    /// refresher (#659) re-checks until it differs.
    func snapshotKey() -> String {
        cache.keys.sorted().map { name -> String in
            let s = cache[name]!
            return "\(name)|\(s.status)|\(String(describing: s.reason))|\(s.requiredPlan ?? "")|\(s.upgradeCta)"
        }.joined(separator: "\n")
    }

    func _runRefresh(userId: String?) async {
        // The answer belongs to the identity that asked. A user switch (or the
        // restored user loading) while it is in flight makes it stale.
        let generation = identityGeneration
        do {
            // A request for no user carries no token: the answer must be the one
            // for the identity this snapshot is kept under. A signed-in user whose
            // token is refused even after a refresh gets NO anonymous retry here:
            // the anonymous snapshot (open-to-everyone features only) must never
            // stand in for theirs — their own snapshot stays until a call succeeds.
            let (status, response) = try await _sendWithUserToken(
                userId == nil ? nil : userToken,
                anonymousFallback: userId == nil,
                onRefused: { _warnUserTokenRefused() }
            ) { attempt in
                var body: [String: Any] = ["publishableKey": client.publishableKey]
                // `userId` rides along with the token: the server ignores it
                // when the token is valid, and a server without #517 still
                // resolves by it. An anonymous fallback names no user.
                if let uid = userId, !attempt.anonymous { body["userId"] = uid }
                if let env = _featureEnvironment { body["environment"] = env }
                return try await client.postRaw(
                    path: "/api/sdk/features/resolve",
                    body: body,
                    headers: _OneloUserTokenWire.headers(attempt.token)
                )
            }
            guard generation == identityGeneration, userId == currentUserId else { return }
            guard (200..<300).contains(status),
                  let features = response["features"] as? [String: [String: Any]] else { return }
            _applyResolveResult(features)
            _confirmSnapshot()
            _maybeWarnAnonymous(response)
        } catch {
            // best-effort — SSE will catch up later
        }
    }

    /// Internal seam for tests: applies a `/resolve` response shape to the cache
    /// without touching configVersion (REST resolve doesn't return it; SSE owns
    /// the version cursor).
    func _applyResolveResult(_ features: [String: [String: Any]]) {
        var next: [String: FeatureState] = [:]
        for (name, dict) in features {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let wire = try? JSONDecoder().decode(FeatureStateWire.self, from: data),
                  let status = FeatureStatus(rawValue: wire.status) else { continue }
            next[name] = FeatureState(
                name: name,
                status: status,
                reason: wire.reason,
                requiredPlan: wire.requiredPlan,
                requiredPlanLabel: wire.requiredPlanLabel,
                upgradeCta: wire.upgradeCta ?? false
            )
        }
        cache = next
        _emitChange()
        _writeCache()
    }

    // MARK: - Change callback

    /// Subscribe to feature-state changes (#606). Fires on the main actor after
    /// every snapshot change: a plan change or a dashboard deploy pushed over
    /// the Event Stream, an identity swap, a `/resolve` refresh. Re-read
    /// ``feature(_:)`` inside it. SwiftUI views need no subscription (this class
    /// is `@Observable`); use it from AppKit / UIKit code such as a menu.
    /// Parity with `onelo.features.subscribe` in the JS, Electron and React
    /// Native SDKs.
    ///
    /// - Returns: A closure that removes the listener. Keep it, and call it when
    ///   the owner goes away.
    @discardableResult
    public func subscribe(_ listener: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        changeListeners[id] = listener
        return { [weak self] in _ = self?.changeListeners.removeValue(forKey: id) }
    }

    private func _emitChange() {
        // Snapshot first: a listener may unsubscribe (or subscribe) while we
        // iterate.
        for listener in Array(changeListeners.values) { listener() }
    }

    // MARK: - Internal

    /// Test helper — injects cache entries without a network call.
    func _setCache(_ entries: [String: FeatureStatus]) {
        for (k, v) in entries { cache[k] = FeatureState(name: k, status: v) }
        _emitChange()
    }

    /// Marks the snapshot confirmed for the current identity and releases every
    /// pending `ready()` caller. Idempotent until the next identity change.
    private func _confirmSnapshot() {
        // A confirmation for the identity a sign-in is replacing releases nobody:
        // the signed-in user's own load confirms next.
        guard !_awaitsSignedInUser else { return }
        if !isSnapshotConfirmed { isSnapshotConfirmed = true }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for (_, cont) in waiters { cont.resume() }
    }

    /// Test seam — confirms the current identity's snapshot without a network
    /// call (the name predates identity-bound readiness).
    func _signalFirstEvent() {
        _confirmSnapshot()
    }

    /// Test helper — reports whether the SSE stream is in the "started" state.
    /// After the 3.51 unification this is delegated to OneloEventStream's
    /// public `isStarted` mirror via `_eventStreamStartedForTesting`.
    func _sseTaskActive() -> Bool {
        return _eventStreamStartedForTesting
    }

    /// Internal probe used by the test helper. OneloEventStream tracks its
    /// own `isStarted` flag; we surface it here so tests can keep asserting
    /// the same invariant ("ready() must not open a second connection")
    /// without reaching across modules.
    private var _eventStreamStartedForTesting: Bool {
        eventStream._isStartedForTesting
    }

    /// Test-only reconnect counters, delegated to the underlying event stream
    /// — see `OneloEventStream._startCallCountForTesting` / `_stopCallCountForTesting`.
    var _eventStreamStartCallCountForTesting: Int { eventStream._startCallCountForTesting }
    var _eventStreamStopCallCountForTesting: Int { eventStream._stopCallCountForTesting }

    var _lastRefreshAtForTesting: Date { lastRefreshAt }

    func _setLastEventReceivedForTesting(_ date: Date) {
        lastEventReceived = date
    }

    /// Test seam — replaces the transport of the stream this instance owns.
    func _setOpenStreamForTesting(
        _ open: @escaping (_ queryItems: [URLQueryItem], _ headers: [String: String]) -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>
    ) {
        eventStream._openStream = open
    }

    /// Test helper — puts the underlying event stream into the "started"
    /// state (post-3.51 unification, `_checkSSEHealth` / `_resyncOnLifecycle`
    /// gate on `eventStream._isStartedForTesting`, not a private streamTask).
    func _startEventStreamForTesting(userId: String? = nil) {
        eventStream.start(userId: userId)
    }

    func _stopEventStreamForTesting() {
        eventStream.stop()
    }

    /// Bootstrap: restore cached snapshot, register discovered names, then open the
    /// SSE stream that delivers live deploys. Called by the Onelo orchestrator.
    ///
    /// `userIdHash` is ignored: Secure Mode is retired, and the signed-in Onelo
    /// user is proven with their access token automatically.
    func _load(userId: String?, userIdHash: String? = nil) async {
        let identityChanged = !identityLoaded || userId != currentUserId
        identityLoaded = true
        if identityChanged {
            // A new identity starts unconfirmed, from ITS persisted snapshot or
            // from nothing — never from the previous identity's.
            identityGeneration &+= 1
            currentUserId = userId
            isSnapshotConfirmed = false
            confirmedVersion = 0
            _replaceWithPersistedSnapshot(userId: userId)
        }
        // Stream lifecycle:
        //   • Injected stream (Onelo wrapper, ownsEventStream=false): OneloAuth
        //     drives start/stop based on currentSession. We must NOT call start()
        //     here — each repeated _load (lifecycle resync, identity change)
        //     would otherwise reconnect the shared stream and any in-flight
        //     `session.revoked` arriving during the reconnect window would
        //     land in a closed queue and be lost. Mirror the current cache
        //     version into the stream so the next reconnect (driven by auth)
        //     carries the right `since_version`.
        //   • Standalone stream (ownsEventStream=true): no auth-side driver
        //     exists, so OneloFeatures must open the connection itself.
        if ownsEventStream {
            eventStream.start(userId: userId, sinceVersion: confirmedVersion, appVersion: _appVersion)
        } else {
            eventStream.updateSinceVersion(confirmedVersion)
        }
        _startHealthcheck()
        if identityChanged {
            // Confirm the new identity's snapshot over REST in parallel to the
            // stream: one round trip, also when the stream is slow, reconnecting
            // (backoff after a server restart) or absent (no session → the
            // auth-owned stream is closed).
            lastRefreshAt = Date()
            _identityResolveTask = Task { [weak self] in
                await self?._runRefresh(userId: userId)
            }
        }
        // Discovery last: its attest wait + round trip must not delay the
        // identity's own snapshot (the session watcher awaits `_load`).
        if _shouldBatchPingOnLoad() {
            await _batchPing()
        }
    }

    /// Loads the signed-out identity unless an identity was already loaded —
    /// the end of a launch restore that produced no session.
    func _loadInitialIdentityIfNeeded() async {
        guard !identityLoaded else { return }
        await _load(userId: nil)
    }

    /// A user is signed in whose identity has not loaded yet (#731).
    private var _awaitsSignedInUser: Bool {
        guard let signedInUserId else { return false }
        return signedInUserId != currentUserId
    }

    /// Called by `Onelo` synchronously on every session change, before the host
    /// app hears of it (`isAllowedIn`, `currentSession`) and before the session
    /// watcher loads the new identity. A sign-in or a user switch un-confirms the
    /// snapshot at once, so `isSnapshotConfirmed` and `ready()` never answer for
    /// the previous identity in between.
    func _signedInUserWillChange(to userId: String?) {
        signedInUserId = userId
        if _awaitsSignedInUser && isSnapshotConfirmed { isSnapshotConfirmed = false }
    }

    /// Fast first render at launch: while a stored session is being restored,
    /// show THAT user's persisted snapshot (unconfirmed) instead of the
    /// anonymous one. The identity itself loads when the session is restored.
    func _seedPersistedSnapshot(userId: String) {
        guard !identityLoaded else { return }
        _replaceWithPersistedSnapshot(userId: userId)
    }

    /// Decide whether to send a batch-ping on startup.
    ///
    /// - Test keys ALWAYS ping: the dev experience needs reliable, immediate
    ///   discovery of new slugs added to the code (and `last_seen_at` keeps
    ///   the dashboard's "feature alive" indicator fresh during iteration).
    /// - Live keys SAMPLE at 1% — for a production app with 10k concurrent
    ///   sessions, that's ~100 batch-pings/min instead of 10k. The backend
    ///   only uses live-key batch-ping to bump `last_seen_at` for the
    ///   dashboard staleness signal; one in a hundred is plenty of resolution
    ///   for "is this feature still being checked in prod?" without DDoS-ing
    ///   the registry endpoint at every app launch.
    private func _shouldBatchPingOnLoad() -> Bool {
        // Reliable discovery is driven by the FEATURE ENVIRONMENT (test), NOT the
        // key prefix. So a normal `pk_live` key + OneloFeatureEnvironment=test
        // discovers reliably — no separate dev/test key needed. (Binding is per
        // app+instance via X-Onelo-Instance-Id, also independent of the key.)
        // Legacy `_test_` keys still always-ping for back-compat.
        if _featureEnvironment == "test" || client.publishableKey.contains("_test_") {
            return true
        }
        // Live env: 1% sample. Per-process random so a flaky network won't
        // skew the distribution by retrying — each launch is one coin flip.
        return Int.random(in: 0..<100) == 0
    }

    /// Closes the SSE stream and cancels reconnect attempts. Called on SDK
    /// teardown. Kept named `_stopPolling` for back-compat with the old
    /// polling-based API; there's nothing left to poll.
    func _stopPolling() {
        destroyed = true
        // Only tear the SSE down if we OWN the connection (standalone use).
        // When the stream was injected from OneloAuth, OneloAuth's lifecycle
        // owns it — features just stops calling start().
        if ownsEventStream {
            eventStream.stop()
        }
        pendingPingTask?.cancel()
        pendingPingTask = nil
        healthcheckTask?.cancel()
        healthcheckTask = nil
    }

    // MARK: - Private

    private func _scheduleBatchPing() {
        pendingPingTask?.cancel()
        pendingPingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?._batchPing()
        }
    }

    /// Internal (not private) so the user-token tests can drive one ping.
    func _batchPing() async {
        let names = Array(discoveredNames)
        guard !names.isEmpty else { return }
        // #37 — wait (bounded) for the App Attest token; if it's STILL pending
        // after the wait (fresh-install attestation can exceed the 5s cap), SKIP
        // the tokenless send (it would 403) and mark it pending — the token-arrival
        // watcher wired in `Onelo` re-fires this ping once the token lands. An
        // unwired/standalone gate is nil → `nil == false` is false → still sends.
        if await _attestReadyGate?() == false {
            _pendingTokenPing = true
            return
        }
        _pendingTokenPing = false
        let userId = currentUserId
        do {
            // batch-ping answers a throttled 204 BEFORE it looks at the token,
            // so its 2xx proves nothing about the token and must not end a
            // refusal episode (`provesAcceptance: false`).
            let (status, json) = try await _sendWithUserToken(
                userToken,
                provesAcceptance: false,
                onRefused: { _warnUserTokenRefused() }
            ) { attempt in
                var body: [String: Any] = [
                    "publishableKey": client.publishableKey,
                    "features": names,
                ]
                if let uid = userId, !attempt.anonymous { body["userId"] = uid }
                if let env = _featureEnvironment { body["environment"] = env }
                return try await client.postRaw(
                    path: "/api/sdk/features/batch-ping",
                    body: body,
                    headers: _OneloUserTokenWire.headers(attempt.token)
                )
            }
            if !(200..<300).contains(status) {
                let detail = (json["detail"] as? String)
                    ?? ((json["detail"] as? [String: Any])?["message"] as? String)
                    ?? "HTTP \(status)"
                _logBatchPingRejected(detail)
            }
        } catch {
            _logBatchPingRejected("\(error)")
        }
    }

    /// Best-effort, but loud enough to explain "discovery never happens": a
    /// rejection here is almost always a test key bound to a different
    /// device/app — the fix is dashboard → Features → Deploy access → Unbind.
    private func _logBatchPingRejected(_ detail: String) {
        print("[Onelo] features batch-ping rejected: \(detail)")
    }

    /// The server refused the signed-in user's access token even after a
    /// refresh, so the call went out anonymous. Features has no error
    /// callback; this one-time log is its error channel (like the
    /// anonymous-mode warning).
    private func _warnUserTokenRefused() {
        guard !userTokenRefusedWarned else { return }
        userTokenRefusedWarned = true
        print("""
            [Onelo] The signed-in user's access token was refused by Features (invalid_user_token) \
            even after a refresh, so the request was made without a user. \
            Check that the publishableKey belongs to the app the user signed in to.
            """)
    }

    /// #37 — re-fire a discovery batch-ping that was SKIPPED because the attest
    /// token wasn't ready yet. Called by `Onelo`'s token-arrival watcher. No-op
    /// unless a send was actually skipped, so a normal token-ready start (which
    /// already pinged) is NOT double-pinged when the watcher replays `$attestToken`.
    func _retryPendingDiscoveryPing() async {
        guard _pendingTokenPing else { return }
        await _batchPing()
    }

    /// Logs a one-time warning when the backend reports anonymous mode (no userId)
    /// AND at least one targeted feature was hidden purely because of it. Helps
    /// developers using their own auth system catch missing identify() calls.
    /// Suppressed via `OneloConfig.suppressIdentifyWarning`.
    private func _maybeWarnAnonymous(_ response: [String: Any]) {
        guard !suppressIdentifyWarning, !anonymousWarningLogged else { return }
        guard (response["anonymous"] as? Bool) == true else { return }
        let misses = response["targeting_misses"] as? Int ?? 0
        guard misses > 0 else { return }
        anonymousWarningLogged = true
        print("""
            [Onelo] \(misses) feature(s) hidden because no user is identified.
            If you handle auth yourself, call onelo.identify(userId) after login so per-user/per-plan targeting can apply.
            If your app is intentionally anonymous, pass suppressIdentifyWarning: true in OneloConfig to silence this.
            """)
    }

    // MARK: - SSE

    /// Opens the Server-Sent Events channel. The server pushes a `connected`
    /// event with a fresh snapshot if our `since_version` is stale, an
    /// `up_to_date` event if our cache is current, and `features_updated` events
    /// whenever an admin clicks Deploy in the dashboard. On error we reconnect
    /// with bounded exponential backoff.
    ///
    /// Reconnect loop mirrors the Python SDK's `SSEConsumer.run` pattern:
    ///   - clean close → reset attempt counter and reconnect immediately-ish
    ///   - any thrown error (network blip, broken pipe, 5xx, server-side close
    ///     surfacing as `URLError(.cancelled)`) → log, back off, retry
    ///   - `CancellationError` from the OUTER task (e.g. `signOut`, `identify`
    ///     re-`_load`, `deinit`) → exit cleanly, no retry
    ///   - `Task.isCancelled` checked before AND after the backoff sleep so we
    ///     never retry into a cancelled state
    ///
    /// In 3.51+ the connect / consume / dispatch trio lives in
    /// `OneloEventStream` so both auth and features can share a single
    /// SSE connection. The four feature event names (`connected`,
    /// `up_to_date`, `features_updated`, `discovery_requested`) are
    /// registered as handlers in `_registerEventHandlers()` (init time)
    /// and the connection itself is opened by `_load()` via
    /// `eventStream.start(userId:sinceVersion:appVersion:)`.

    private func _applySnapshot(version: Int, features: [String: [String: Any]]) {
        configVersion = version
        confirmedVersion = version
        var next: [String: FeatureState] = [:]
        for (name, dict) in features {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let wire = try? JSONDecoder().decode(FeatureStateWire.self, from: data),
                  let status = FeatureStatus(rawValue: wire.status) else { continue }
            next[name] = FeatureState(
                name: name,
                status: status,
                reason: wire.reason,
                requiredPlan: wire.requiredPlan,
                requiredPlanLabel: wire.requiredPlanLabel,
                upgradeCta: wire.upgradeCta ?? false
            )
        }
        cache = next
        _emitChange()
        _writeCache()
        // Mirror the new version into the shared SSE stream so the NEXT
        // reconnect carries the right `since_version` query param — the
        // backend can then short-circuit with `up_to_date` instead of
        // resending the full snapshot.
        eventStream.updateSinceVersion(version)
    }

    // MARK: - Persistence
    //
    // Feature snapshots live in UserDefaults rather than Keychain. They aren't
    // sensitive (anyone with the SDK can read the same data from the server),
    // and UserDefaults survives app restarts which gives an instant cold-start
    // experience: cached state is shown immediately, then SSE reconciles in the
    // background.

    private func _cacheKey(userId: String?) -> String {
        return "io.onelo.features.\(client.publishableKey).\(userId ?? "anon")"
    }

    /// Replaces the in-memory snapshot with the one persisted for `userId`, or
    /// with an empty one when there is none.
    private func _replaceWithPersistedSnapshot(userId: String?) {
        if !_loadCache(userId: userId) {
            configVersion = 0
            cache = [:]
            _emitChange()
        }
    }

    @discardableResult
    private func _loadCache(userId: String?) -> Bool {
        let key = _cacheKey(userId: userId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        configVersion = json["config_version"] as? Int ?? 0
        // v2 shape: features = [name: {status, reason?, required_plan?, upgrade_cta?}].
        // Persisting reason/required_plan matters: after a cold start the SSE
        // handshake often answers `up_to_date` (no fresh snapshot), so whatever
        // the cache restored IS the state the UI renders. A status-only cache
        // (v1) made `upgradeHint`/"Available in <plan>" badges silently
        // degrade to a bare "Upgrade" until the next deploy.
        if let features = json["features"] as? [String: [String: Any]] {
            var next: [String: FeatureState] = [:]
            for (name, entry) in features {
                guard let raw = entry["status"] as? String,
                      let status = FeatureStatus(rawValue: raw) else { continue }
                next[name] = FeatureState(
                    name: name,
                    status: status,
                    reason: (entry["reason"] as? String).flatMap(FeatureReason.init(rawValue:)),
                    requiredPlan: entry["required_plan"] as? String,
                    requiredPlanLabel: entry["required_plan_label"] as? String,
                    upgradeCta: (entry["upgrade_cta"] as? Bool) ?? false
                )
            }
            cache = next
            _emitChange()
            return true
        } else if let features = json["features"] as? [String: String] {
            // v1 (status-only) cache written by SDK ≤ 3.55 — accept once; the
            // next _writeCache persists the v2 shape.
            var next: [String: FeatureState] = [:]
            for (name, raw) in features {
                if let status = FeatureStatus(rawValue: raw) {
                    next[name] = FeatureState(name: name, status: status)
                }
            }
            cache = next
            _emitChange()
            return true
        }
        return false
    }

    // MARK: - Healthcheck (zombie SSE detector)

    /// Starts (or restarts) the loop that watches for zombie SSE connections.
    /// Idempotent — calling repeatedly cancels the previous task.
    private func _startHealthcheck() {
        healthcheckTask?.cancel()
        // Reset the clock — a fresh `_load` means SSE is being (re)opened, so
        // give it a full window before the first staleness check.
        lastEventReceived = Date()
        healthcheckTask = Task { [weak self] in
            // Poll at a third of the staleness window so detection is timely
            // without burning cycles. With default 90s threshold → 30s interval.
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(5, self._sseStaleThreshold / 3)
                let nanos = UInt64(interval * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self._checkSSEHealth()
                }
            }
        }
    }

    /// Internal seam — invoked by the healthcheck timer and by tests directly.
    /// If we have an active SSE task and no event has arrived within the
    /// staleness window, reconnect.
    func _checkSSEHealth() {
        guard !destroyed, eventStream._isStartedForTesting else { return }
        let elapsed = Date().timeIntervalSince(lastEventReceived)
        guard elapsed > _sseStaleThreshold else { return }
        print("[Onelo] SSE features stream looks stale (no events for \(Int(elapsed))s) — reconnecting")
        lastEventReceived = Date()
        // Only cycle the connection when WE own its lifecycle. When the
        // stream is shared with OneloAuth, the auth module is the single
        // source of truth — force-cycling here would race against an
        // in-flight `session.revoked` delivery.
        if ownsEventStream {
            eventStream.stop()
            eventStream.start(userId: currentUserId, sinceVersion: confirmedVersion, appVersion: _appVersion)
        }
    }

    /// Lifecycle resync — invoked from app-foreground / system-wake hooks.
    ///
    /// Why this exists separately from `_checkSSEHealth`: under macOS App Nap,
    /// the healthcheck `Task.sleep` is itself throttled — the timer that's
    /// supposed to detect zombie SSE is also asleep. So we cannot rely on it
    /// to recover. The lifecycle notification is the one signal the system
    /// guarantees to deliver on wake; we use it to forcibly resync.
    ///
    /// Strategy:
    /// 1. If `lastEventReceived` is older than `_sseLifecycleStaleThreshold`
    ///    (default 60s — eager, since we KNOW the app was inactive), kill the
    ///    zombie SSE task and open a fresh one. Without this, the cache might
    ///    update via REST below but the next dashboard `Deploy` still wouldn't
    ///    propagate — leaving us one App Nap cycle from drift again.
    /// 2. ALWAYS run a force REST refresh in parallel — instant cache reconcile
    ///    while the new SSE handshake completes (snapshot endpoint is faster
    ///    than the SSE `connected` round-trip on average).
    func _resyncOnLifecycle() {
        guard !destroyed else { return }
        let elapsed = Date().timeIntervalSince(lastEventReceived)
        if eventStream._isStartedForTesting,
           elapsed > _sseLifecycleStaleThreshold,
           ownsEventStream {
            // Same reasoning as `_checkSSEHealth` — only cycle when we own
            // the stream's lifecycle. Auth-driven streams handle their own
            // reconnects without OneloFeatures intervention.
            print("[Onelo] Lifecycle resync — SSE stale (\(Int(elapsed))s), forcing reconnect")
            lastEventReceived = Date()
            eventStream.stop()
            eventStream.start(userId: currentUserId, sinceVersion: confirmedVersion, appVersion: _appVersion)
        }
        Task { [weak self] in
            await self?.refresh(force: true)
        }
    }

    private func _writeCache() {
        let key = _cacheKey(userId: currentUserId)
        // v2 shape — see _loadCache for why the full state (not just status)
        // must survive restarts.
        var features: [String: [String: Any]] = [:]
        for (name, state) in cache {
            var entry: [String: Any] = ["status": state.status.rawValue]
            if let reason = state.reason { entry["reason"] = reason.rawValue }
            if let plan = state.requiredPlan { entry["required_plan"] = plan }
            if let label = state.requiredPlanLabel { entry["required_plan_label"] = label }
            if state.upgradeCta { entry["upgrade_cta"] = true }
            features[name] = entry
        }
        let snapshot: [String: Any] = [
            "config_version": configVersion,
            "features": features,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
