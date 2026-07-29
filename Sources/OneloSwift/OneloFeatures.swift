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

    /// Last time we observed activity on the SSE channel (any event, including
    /// the server's `:` heartbeat comments which surface as empty events).
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
    /// HMAC-SHA256 of `userId` signed with the app's secret key, supplied by
    /// the host app when running in secure mode (Features Entitlement
    /// Enforcement). Threaded into `/resolve`, `/batch-ping`, and the SSE
    /// query string so the backend can verify the caller's claim to `userId`.
    /// Nil for callers not yet in secure mode (e.g. Turingo) — in that case
    /// the field is omitted from outgoing payloads.
    @ObservationIgnored private(set) var currentUserIdHash: String?
    @ObservationIgnored private var destroyed: Bool = false
    @ObservationIgnored private let _appVersion: String?
    /// Explicit feature environment ("test"|"live"). Forwarded on `/resolve`,
    /// `/batch-ping`, and the SSE stream so the backend resolves the matching
    /// snapshot regardless of the key prefix — letting a client and its server
    /// agree on env. Nil → omitted → backend uses the key prefix (old behavior).
    @ObservationIgnored private let _featureEnvironment: String?

    /// Cold-start synchronization. Set to `true` the first time the SSE stream
    /// delivers a `connected` or `up_to_date` event. Once flipped, it stays true
    /// for the lifetime of this `OneloFeatures` instance — `ready()` then becomes
    /// an instant return.
    @ObservationIgnored private var firstEventReceived: Bool = false
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
        featureEnvironment: String? = nil
    ) {
        self.client = client
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
        _registerEventHandlers()
    }

    /// Wires the four feature-side handlers onto the shared SSE stream.
    /// Called exactly once in `init` so duplicate registrations are
    /// impossible across `_load` / signin cycles.
    private func _registerEventHandlers() {
        eventStream.on("connected") { [weak self] data in
            guard let self,
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            // Server has a newer version — apply the full snapshot.
            if let features = payload["features"] as? [String: [String: Any]] {
                self._applySnapshot(
                    version: payload["config_version"] as? Int ?? self.configVersion,
                    features: features,
                )
            }
            self._maybeWarnAnonymous(payload)
            self._signalFirstEvent()
            self.lastEventReceived = Date()
        }
        eventStream.on("up_to_date") { [weak self] data in
            guard let self,
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            if let v = payload["config_version"] as? Int { self.configVersion = v }
            self._signalFirstEvent()
            self.lastEventReceived = Date()
        }
        eventStream.on("features_updated") { [weak self] data in
            guard let self,
                  let payload = OneloFeatures._decodeJSON(data) else { return }
            if let features = payload["features"] as? [String: [String: Any]] {
                self._applySnapshot(
                    version: payload["config_version"] as? Int ?? self.configVersion,
                    features: features,
                )
            }
            self.lastEventReceived = Date()
        }
        eventStream.on("discovery_requested") { [weak self] _ in
            self?._scheduleBatchPing()
            self?.lastEventReceived = Date()
        }
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

    /// Awaits the first SSE event (`connected` or `up_to_date`) so the host app
    /// can render feature-dependent UI without a cold-start flicker. After a long
    /// offline period the stale UserDefaults cache is shown immediately by `_load`,
    /// then SSE arrives ~50–300ms later with the fresh snapshot — re-rendering the
    /// view. Calling `await onelo.features.ready()` before the first render lets
    /// the app wait briefly for that fresh state.
    ///
    /// Behavior:
    /// - Returns immediately if the first SSE event has already arrived.
    /// - Returns after `timeout` seconds (default 1.5s) if SSE is slow or offline —
    ///   the host then renders from cache as before. SSE keeps reconnecting in the
    ///   background regardless, so the view will still update once the snapshot
    ///   arrives.
    /// - Does **not** open a second SSE connection; piggy-backs on the stream
    ///   started by `_load` (i.e. by SDK initialization).
    /// - Safe to call from multiple call-sites concurrently; all callers resolve
    ///   together on the first event (or each on its own timeout).
    /// - Never throws.
    public func ready(timeout: TimeInterval = 1.5) async {
        if firstEventReceived { return }

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
    ///   (no network call is made in this case).
    /// - `.notEntitled` (403) if the current user lacks access to `slug`.
    /// - `.secureModeRequired` (401) if the app requires `userIdHash` but
    ///   none was supplied.
    /// - `.invalidUserHash` (401) if the supplied `userIdHash` failed HMAC
    ///   verification on the backend.
    /// - `.networkError` for transport failures or malformed responses.
    public func moduleToken(for slug: String) async throws -> String {
        guard let uid = currentUserId else {
            throw OneloFeaturesError.notAuthenticated
        }
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "userId": uid,
            "slug": slug,
        ]
        if let hash = currentUserIdHash {
            body["userIdHash"] = hash
        }
        let status: Int
        let json: [String: Any]
        do {
            (status, json) = try await client.postRaw(
                path: "/api/sdk/features/module-token",
                body: body
            )
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
            let errCode = (json["detail"] as? [String: Any])?["error"] as? String
            switch errCode {
            case "secure_mode_required": throw OneloFeaturesError.secureModeRequired
            case "invalid_user_hash":    throw OneloFeaturesError.invalidUserHash
            default:                     throw OneloFeaturesError.notAuthenticated
            }
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
        await _runRefresh(userId: currentUserId)
    }

    func _runRefresh(userId: String?) async {
        var body: [String: Any] = ["publishableKey": client.publishableKey]
        if let uid = userId { body["userId"] = uid }
        if let hash = currentUserIdHash { body["userIdHash"] = hash }
        if let env = _featureEnvironment { body["environment"] = env }
        do {
            let response = try await client.post(path: "/api/sdk/features/resolve", body: body)
            guard let features = response["features"] as? [String: [String: Any]] else { return }
            _applyResolveResult(features)
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
        _writeCache()
    }

    // MARK: - Internal

    /// Test helper — injects cache entries without a network call.
    func _setCache(_ entries: [String: FeatureStatus]) {
        for (k, v) in entries { cache[k] = FeatureState(name: k, status: v) }
    }

    /// Signals to all pending `ready()` callers that the first SSE event has
    /// arrived. Idempotent — subsequent calls are no-ops. Exposed at module
    /// (internal) scope so tests can drive it without spinning up a real SSE
    /// stream; also called from `_handleSSEEvent` on the first `connected` /
    /// `up_to_date` event.
    func _signalFirstEvent() {
        guard !firstEventReceived else { return }
        firstEventReceived = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for (_, cont) in waiters { cont.resume() }
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

    var _lastRefreshAtForTesting: Date { lastRefreshAt }

    func _setLastEventReceivedForTesting(_ date: Date) {
        lastEventReceived = date
    }

    /// Test helper retained as a no-op shim — pre-3.51 it injected a
    /// fabricated task into OneloFeatures' private streamTask so the zombie
    /// detector could be exercised in isolation. The zombie detector now
    /// drives reconnects via `eventStream.start()`, which is itself unit-
    /// tested in OneloEventStream's own suite, so this helper has no work
    /// to do anymore. Kept (Sendable Task argument accepted, then dropped)
    /// only so the existing OneloFeaturesTests file compiles unchanged.
    func _installFakeStreamTaskForTesting(_ task: Task<Void, Never>) {
        task.cancel()
    }

    /// Bootstrap: restore cached snapshot, register discovered names, then open the
    /// SSE stream that delivers live deploys. Called by the Onelo orchestrator.
    func _load(userId: String?, userIdHash: String? = nil) async {
        currentUserId = userId
        currentUserIdHash = userIdHash
        _loadCache(userId: userId)
        if _shouldBatchPingOnLoad() {
            await _batchPing()
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
            eventStream.start(userId: userId, sinceVersion: configVersion, appVersion: _appVersion, userIdHash: userIdHash)
        } else {
            eventStream.updateSinceVersion(configVersion)
        }
        _startHealthcheck()
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

    private func _batchPing() async {
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
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "features": names,
        ]
        if let uid = currentUserId { body["userId"] = uid }
        if let hash = currentUserIdHash { body["userIdHash"] = hash }
        if let env = _featureEnvironment { body["environment"] = env }
        do {
            _ = try await client.post(
                path: "/api/sdk/features/batch-ping",
                body: body
            )
        } catch {
            // Best-effort, but loud enough to explain "discovery never
            // happens": a rejection here is almost always a test key bound
            // to a different device/app — the fix is dashboard → Features →
            // Deploy access → Unbind.
            print("[Onelo] features batch-ping rejected: \(error)")
        }
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

    private func _loadCache(userId: String?) {
        let key = _cacheKey(userId: userId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let v = json["config_version"] as? Int { configVersion = v }
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
        }
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
            eventStream.start(userId: currentUserId, sinceVersion: configVersion, appVersion: _appVersion, userIdHash: currentUserIdHash)
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
            eventStream.start(userId: currentUserId, sinceVersion: configVersion, appVersion: _appVersion, userIdHash: currentUserIdHash)
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
