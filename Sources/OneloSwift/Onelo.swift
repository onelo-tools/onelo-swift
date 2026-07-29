import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Main entry point for the Onelo SDK.
///
/// ```swift
/// let onelo = Onelo(publishableKey: "pk_live_...", baseURL: URL(string: "https://...")!)
/// await onelo.identify(userId)   // only needed when NOT using Onelo Auth
///
/// if onelo.features.feature("export-button").isEnabled {
///     showExportButton()
/// }
/// ```
@MainActor
public final class Onelo: ObservableObject {
    private let httpClient: _OneloHTTPClient
    private let baseURL: URL
    private let callbackScheme: String
    private var heartbeatTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    public let features: OneloFeatures
    public let paywall: OneloPaywall
    public let forms: OneloForms
    public let waitlist: OneloWaitlist
    public let auth: OneloAuthModule
    public let monitor: OneloMonitor
    public let feedback: OneloFeedback

    /// Initializes the Onelo SDK.
    ///
    /// - Parameters:
    ///   - publishableKey: Publishable key from the Onelo dashboard (`onelo_pk_live_...`).
    ///   - callbackScheme: URL scheme for hosted auth callback (e.g. `"myapp"`).
    ///   - baseURL: Onelo API base URL — required, copy from the dashboard snippet.
    ///   - suppressIdentifyWarning: Suppresses the "no userId — call onelo.identify()"
    ///     warning that fires when targeted features resolve in anonymous mode. Set
    ///     to `true` if your app is intentionally anonymous.
    ///   - featureDefaultStatus: Status returned by `features.feature(_:)` for any
    ///     name that isn't (yet) in the cache. Defaults to `.hidden` — fail-closed,
    ///     so a feature instrumented in code but not yet enabled in the dashboard
    ///     stays hidden in production. Pass `.enabled` (typically guarded by a
    ///     `#if DEBUG`) to flip the default during development so new gates render
    ///     their content until you toggle them in the dashboard.
    ///   - appVersion: The host app's release version string (e.g. `"2.3.1"`).
    ///     Optional. Sent to the dashboard alongside `instance_id` and `sdk_version`
    ///     for instance tracking — lets you see which app version each connected
    ///     SDK instance is running.
    ///   - environment: Optional environment tag (`"production"` / `"staging"` /
    ///     `"dev"` / custom). Auto-attached to every monitor event so the Monitor
    ///     dashboard can facet sessions and runs by environment. NOTE: this is the
    ///     Monitor tag and is unrelated to `featureEnvironment` below.
    ///   - featureEnvironment: Explicit Feature environment, `"test"` or `"live"`.
    ///     Forwarded to the backend so it resolves the matching feature snapshot
    ///     regardless of the key prefix — set the SAME value here and in your
    ///     backend SDK so a client and its server agree on env. When omitted, the
    ///     SDK resolves it from the `OneloFeatureEnvironment` Info.plist key, then
    ///     the `ONELO_FEATURE_ENVIRONMENT` process env var; if still unset the
    ///     backend falls back to the key prefix (old behavior). See
    ///     docs/architecture/feature-environment-explicit.md.
    public init(
        publishableKey: String,
        callbackScheme: String = "",
        baseURL: URL,
        suppressIdentifyWarning: Bool = false,
        featureDefaultStatus: FeatureStatus = .hidden,
        autoLifecycleRefresh: Bool = true,
        appVersion: String? = nil,
        environment: String? = nil,
        featureEnvironment: String? = nil
    ) {
        // Resolve the feature environment: explicit arg → Info.plist
        // (OneloFeatureEnvironment) → process env (ONELO_FEATURE_ENVIRONMENT).
        // Normalize to "test"/"live" only; anything else (incl. empty plist
        // entries) becomes nil so we never send a junk `environment` param —
        // the backend then falls back to the key prefix.
        let rawFeatureEnv = featureEnvironment
            ?? (Bundle.main.object(forInfoDictionaryKey: "OneloFeatureEnvironment") as? String)
            ?? ProcessInfo.processInfo.environment["ONELO_FEATURE_ENVIRONMENT"]
        let resolvedFeatureEnv: String? = (rawFeatureEnv == "test" || rawFeatureEnv == "live") ? rawFeatureEnv : nil
        self.baseURL = baseURL
        self.callbackScheme = callbackScheme
        // Auth is constructed FIRST: it owns BOTH the shared OneloEventStream
        // (single SSE connection per app, shared between auth-event and
        // feature-deploy listeners) AND the shared `_OneloSecurityContext` — the
        // single source of truth for the attest bearer + codesign fingerprint.
        // Both are injected into the sibling transports below so the entire SDK
        // reads ONE security context: a token written once by the producer
        // (OneloAuth) is visible to every transport with nothing to mirror.
        let oneloAuth = OneloAuth(config: OneloConfig(
            publishableKey: publishableKey,
            apiUrl: baseURL,
            callbackScheme: callbackScheme,
            suppressIdentifyWarning: suppressIdentifyWarning
        ))
        let securityContext = oneloAuth.securityContext
        let client = _OneloHTTPClient(publishableKey: publishableKey, baseURL: baseURL, securityContext: securityContext)
        self.httpClient = client
        let monitorInstance = OneloMonitor(publishableKey: publishableKey, apiUrl: baseURL.absoluteString, environment: environment, securityContext: securityContext)
        self.monitor = monitorInstance
        let featuresModule = OneloFeatures(
            client: client,
            eventStream: oneloAuth.eventStream,
            monitor: monitorInstance,
            suppressIdentifyWarning: suppressIdentifyWarning,
            defaultStatus: featureDefaultStatus,
            appVersion: appVersion,
            featureEnvironment: resolvedFeatureEnv
        )
        self.features = featuresModule
        // #37 — gate the discovery batch-ping on the App Attest token being ready
        // so cold-start pings don't 403 tokenless (bounded wait; no-op on macOS /
        // once the token lands). Returns whether the ping may proceed: false =
        // token still pending after the wait → _batchPing skips + defers to the
        // re-ping below. Weak-captures OneloAuth to avoid a retain cycle.
        featuresModule._attestReadyGate = { [weak oneloAuth] in
            await oneloAuth?._awaitAttestReady()
            return oneloAuth?._discoveryAttestReady() ?? true
        }
        // #37 — when the attest token arrives after a cold-start skip (fresh-install
        // attestation can exceed the 5s wait cap), re-fire the deferred discovery
        // ping. `_retryPendingDiscoveryPing` is a no-op unless a send was skipped,
        // so a normal token-ready start (which already pinged) is NOT double-pinged
        // when `$attestToken` replays. Same signal that feeds securityContext.
        Task { [weak featuresModule, weak oneloAuth] in
            guard let auth = oneloAuth else { return }
            for await token in auth.$attestToken.values where token != nil {
                await featuresModule?._retryPendingDiscoveryPing()
                break
            }
        }
        self.paywall = OneloPaywall(client: client)
        self.forms = OneloForms(client: client)
        self.waitlist = OneloWaitlist(client: client)
        self.feedback = OneloFeedback(client: client, features: featuresModule)
        self.auth = OneloAuthModule(auth: oneloAuth)

        // Wire the upsell tap router: "Available in <plan>" UI (menu badges
        // etc.) routes through the singleton because FeatureState has no
        // client reference. Last-created instance wins — the standard
        // single-instance setup.
        OneloUpgradeRouter.shared.install { [weak self] plan in
            Task { await self?.openUpgrade(forPlan: plan) }
        }

        // FAZA 3 — wire per-request App Attest assertions + self-heal into the
        // features/paywall transport. The provider forwards to OneloAuth's shared
        // OneloAppAttest and returns nil until attestation is set up (→ the legacy
        // X-Attest-Token bearer still applies), so ordering is not a concern.
        self.httpClient.assertionProvider = { [weak authObject = self.auth.authObject] m, p, q, b in
            await authObject?.assertionHeaders(method: m, path: p, query: q, body: b)
        }
        self.httpClient.onAttestReject = { [weak authObject = self.auth.authObject] _ in
            Task { @MainActor in authObject?.resetAttestedKeyForSelfHeal() }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // OneloAuth marks isReady=true as soon as the AuthClient is wired;
            // attestation (when required) runs in the background. Don't block
            // features on the attest token — kick off the initial features load
            // once isReady, regardless of whether the token has arrived.
            //
            // Nothing is mirrored here: the attest bearer + codesign fingerprint
            // reach EVERY transport (shared REST client, SSE, monitor, auth
            // URLSession) through the shared `securityContext` — the bearer via
            // OneloAuth's `attestToken` didSet whenever attestation completes, the
            // macOS codesign fingerprint seeded eagerly at OneloAuth init. A
            // request issued before the token lands simply goes without it (the
            // macOS backend path is soft; iOS reconnects) and the next one carries
            // it. This replaced the old per-transport mirror that silently missed
            // the SSE client and 403'd features/stream in a loop (#34).
            for await ready in self.auth.authObject.$isReady.values {
                guard ready else { continue }
                await self.features._load(userId: nil)
                break
            }
        }

        // React to auth session changes. We track (userId, entitlement) by hand
        // instead of `removeDuplicates(user.id)` so we can distinguish THREE
        // cases that a single emit could be:
        //
        //  • USER changed (login / logout / user-switch) → full re-identify:
        //    mirror the monitor id, re-subscribe the SSE features stream, and
        //    start/stop the heartbeat. (Same as before.)
        //  • SAME user, ENTITLEMENT changed (plan upgrade/downgrade picked up by
        //    revalidateEntitlement after a purchase) → re-resolve features with a
        //    LIGHT REST refresh. Without this, a buyer's newly-unlocked features
        //    stayed greyed until app foreground/heartbeat (~13min) because the
        //    old user-id-only watcher saw "same user" and did nothing.
        //  • Token refresh (same user, same entitlement, new accessToken, every
        //    ~13min) → NO-OP. We MUST NOT tear down + reopen the SSE on a token
        //    rotation (caused 499s in nginx + feature drift right after login).
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lastUserId: String? = nil
            var lastEntitlement: OneloEntitlement? = nil
            var seenFirst = false
            for await session in self.auth.authObject.$currentSession.values {
                let uid = session?.user.id
                let ent = session?.user.entitlement
                let userChanged = !seenFirst || uid != lastUserId
                let entChanged = seenFirst && uid == lastUserId && ent != lastEntitlement
                lastUserId = uid
                lastEntitlement = ent
                seenFirst = true

                if userChanged {
                    self.monitor.setUserId(uid)
                    await self.features._load(userId: uid)
                    if let session {
                        self.startHeartbeat(accessToken: session.accessToken)
                    } else {
                        self.stopHeartbeat()
                    }
                } else if entChanged {
                    await self.features.refresh(force: true)
                }
                // else: token refresh → no-op (preserves SSE stability).
            }
        }

        if autoLifecycleRefresh {
            registerLifecycleObservers()
        }
    }

    deinit {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
            #if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            #endif
        }
    }

    // MARK: - Lifecycle refresh
    //
    // App Nap aggressively suspends URLSession activity for `.accessory` macOS
    // apps (menu-bar tools, voice assistants). The SSE socket stays
    // `ESTABLISHED` but stops delivering data — Apple's recommended response is
    // to re-sync on app foreground / system wake, not to fight App Nap with a
    // power-assertion (battery anti-pattern).
    //
    // The auto-registered observers below call `features.refresh()`, which
    // pulls a fresh snapshot via REST and is debounced internally so the
    // foreground + wake notifications coalesce to a single network call.
    // Opt out via `autoLifecycleRefresh: false` if you orchestrate refresh
    // yourself.

    private func registerLifecycleObservers() {
        // Resync on lifecycle, NOT just refresh. App Nap can suspend both the
        // SSE socket AND the healthcheck timer at the same time, so the
        // periodic detector can't rescue us — the system-delivered foreground/
        // wake notification is the only reliable trigger to:
        //   1) tear down a likely-zombie SSE and reopen a fresh one
        //   2) pull a snapshot via REST so the cache updates immediately
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.features._resyncOnLifecycle()
            }
        }
        #if canImport(AppKit)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willBecomeActiveNotification,
                object: nil, queue: .main, using: handler
            )
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main, using: handler
            )
        )
        #elseif canImport(UIKit)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main, using: handler
            )
        )
        #endif
    }

    /// Set user context for feature targeting. Call once after login.
    /// Only needed when NOT using Onelo Auth — Onelo Auth sets this automatically.
    ///
    /// Also propagates the user id into ``monitor`` so captured events
    /// carry ``user_id`` — without this, Pro/Business apps using their
    /// own auth would emit monitor events as ``anonymous`` despite calling
    /// ``identify(...)`` correctly. The Onelo-Auth path already does this
    /// via the session watcher in ``init``; identity-mode has no watcher,
    /// so we do the same propagation by hand here.
    public func identify(_ userId: String, userIdHash: String? = nil) async {
        await features._load(userId: userId, userIdHash: userIdHash)
        self.monitor.setUserId(userId)
    }

    /// Clear the active identity. Use when the host's own auth signs the
    /// user out. (Onelo Auth has its own ``signOut`` flow that already
    /// resets state via the session watcher — call this only in
    /// identity-mode deployments.)
    public func clearIdentity() async {
        await features._load(userId: nil)
        self.monitor.setUserId(nil)
    }

    // MARK: - Upgrade flow ("Available in <plan>" tap)

    /// Resolves the right upgrade destination for `plan` and opens it in the
    /// system browser. The BACKEND decides the target (single source of truth
    /// for billing state): active subscribers land on the hosted manage page
    /// with the target plan highlighted ("Change plan", one explicit click to
    /// confirm — the link never executes the change itself); users without a
    /// subscription land on the hosted store.
    ///
    /// Requires a signed-in user. Wired automatically to upsell menu badges
    /// via ``OneloUpgradeRouter``; call directly from custom upsell UI.
    @MainActor
    public func openUpgrade(forPlan plan: String) async {
        if auth.authObject.currentSession?.isExpired == true {
            _ = try? await auth.authObject.refreshSession()
        }
        guard let session = auth.authObject.currentSession else {
            print("[Onelo] openUpgrade: no signed-in user — upgrade flow requires a session")
            return
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "key", value: httpClient.publishableKey),
            URLQueryItem(name: "plan", value: plan),
        ]
        if !callbackScheme.isEmpty {
            query.append(URLQueryItem(name: "callback_scheme", value: callbackScheme))
        }
        do {
            let resp = try await httpClient.get(
                path: "/api/sdk/paywall/upgrade-initiate",
                queryItems: query,
                headers: ["Authorization": "Bearer \(session.accessToken)"]
            )
            guard let urlStr = resp["upgrade_url"] as? String, let url = URL(string: urlStr) else {
                print("[Onelo] openUpgrade: malformed upgrade-initiate response")
                return
            }
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            // Swift 6 / Xcode 26 resolves open(_:) to the async overload in this
            // async context — must be awaited (matches openCustomerPortalInBrowser).
            await UIApplication.shared.open(url)
            #endif
        } catch {
            print("[Onelo] openUpgrade failed: \(error)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(accessToken: String) {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 780, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Refresh token if expired so the heartbeat doesn't silently 401
                if self.auth.authObject.currentSession?.isExpired == true {
                    _ = try? await self.auth.authObject.refreshSession()
                }
                guard let session = self.auth.authObject.currentSession else { return }
                var request = URLRequest(url: self.baseURL.appendingPathComponent("/api/sdk/presence/heartbeat"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}

