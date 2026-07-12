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
        let client = _OneloHTTPClient(publishableKey: publishableKey, baseURL: baseURL)
        self.httpClient = client
        self.baseURL = baseURL
        self.callbackScheme = callbackScheme
        let monitorInstance = OneloMonitor(publishableKey: publishableKey, apiUrl: baseURL.absoluteString, environment: environment)
        self.monitor = monitorInstance
        // Auth is constructed FIRST so its OneloEventStream can be injected
        // into OneloFeatures below — single SSE connection per app, shared
        // between auth-event listeners and feature-deploy listeners.
        let oneloAuth = OneloAuth(config: OneloConfig(
            publishableKey: publishableKey,
            apiUrl: baseURL,
            callbackScheme: callbackScheme,
            suppressIdentifyWarning: suppressIdentifyWarning
        ))
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            // OneloAuth marks isReady=true as soon as the AuthClient is wired; attestation
            // (when required) runs in the background. Don't block features on the attest
            // token — kick off the initial features load once isReady, regardless of
            // whether the attest token has arrived. The token is mirrored to the features
            // HTTP client by a separate observer below as soon as it appears.
            for await ready in self.auth.authObject.$isReady.values {
                guard ready else { continue }
                if let token = self.auth.authObject.attestToken {
                    self.httpClient.attestToken = token
                    self.monitor._setAttestToken(token)
                }
                await self.features._load(userId: nil)
                break
            }
        }

        // Mirror the attest token from OneloAuth to the features HTTP client AND
        // the monitor transport whenever it changes. This decouples feature/monitor
        // requests from initialization order: requests issued before attestation
        // completes go without a token (the macOS backend path is soft); once
        // attestation finishes, subsequent requests carry it.
        //
        // Monitor needs this because it has its own URLSession (separate transport
        // for tight timeouts + crash-path semaphore) and the backend's
        // `validate_sdk_request_security` requires X-Bundle-Id + X-Attest-Token on
        // every live mobile/desktop request.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await token in self.auth.authObject.$attestToken.values {
                if let token {
                    self.httpClient.attestToken = token
                    self.monitor._setAttestToken(token)
                }
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
            UIApplication.shared.open(url)
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

