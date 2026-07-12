import Foundation
import CommonCrypto
import Supabase
import AuthenticationServices
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
// os.Logger is used everywhere (DEBUG + release) — replaces the previous
// `print()` calls which leaked SDK hints (plan name, hosted_flow_required)
// into shipped apps' Console.app. Logger respects user privacy: defaults
// to redacting interpolated values unless marked `.public`.
import os
private let _authLog = Logger(subsystem: "com.onelo.sdk", category: "auth")

/// OneloAuth — Swift SDK for Onelo authentication.
///
/// Initialize with just a publishable key from the Onelo dashboard:
/// ```swift
/// let auth = OneloAuth(config: OneloConfig(publishableKey: "onelo_pk_live_abc123"))
/// ```
@MainActor
public final class OneloAuth: ObservableObject {
    @Published public private(set) var currentSession: OneloSession? {
        didSet {
            rescheduleRefresh()
            // Heartbeat + SSE session listener follow the same lifecycle as
            // `currentSession`. Previously these lived inside `saveSession()`,
            // which fired on fresh sign-in but NOT on `restoreSession()` —
            // a restored-from-keychain user therefore had no heartbeat and
            // no SSE channel, so backend revoke_sdk_sessions() never reached
            // the client until the next app launch (or token refresh hit
            // a 401). Anchoring lifecycle here closes that gap.
            if let session = currentSession {
                _startHeartbeat(session: session)
            } else {
                _stopHeartbeat()
            }
        }
    }
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isReady: Bool = false
    /// Set when the publishable key is revoked or the app is deleted.
    @Published public private(set) var isRevoked: Bool = false
    /// Set when the user account has been deleted or suspended by an admin.
    @Published public private(set) var isUserRevoked: Bool = false
    /// Bumped each time the backend pushes a `legal.consent_required` SSE event
    /// (a blocking legal version took effect). `OneloAuthView` observes it and
    /// re-checks consent so a running, logged-in app shows the gate instantly —
    /// no polling. Durable fallback: the consent check on next auth / foreground.
    @Published public private(set) var consentRevision: Int = 0
    /// Single-owner claim for the hosted consent gate. Two presenters can want
    /// to show the same blocking gate at once — `OneloAuthView`'s built-in gate
    /// (while it's still mounted) AND a `.oneloConsentGate(auth:)` modifier on
    /// the post-login root — and a multi-window macOS app instantiates either
    /// per window. They all observe the SAME `consentRevision`/`requiredConsents`
    /// state, so without coordination each presents its own gate → duplicate
    /// windows. This token is the single source of truth for "who is presenting":
    /// a presenter renders the gate ONLY while it holds the claim; the first to
    /// claim wins, the rest stand down until it is released. Nil = gate is free.
    @Published public private(set) var consentGateOwner: UUID? = nil

    /// Claim the consent-gate presentation for `id`. Returns true if `id` now
    /// owns it (either it was free, or `id` already held it — idempotent). A
    /// presenter that gets `false` must NOT render the gate; another already is.
    @MainActor
    public func claimConsentGate(_ id: UUID) -> Bool {
        if consentGateOwner == nil || consentGateOwner == id {
            consentGateOwner = id
            return true
        }
        return false
    }

    /// Release the claim if (and only if) `id` currently holds it. Safe to call
    /// unconditionally on disappear / when a presenter's gate clears — a no-op
    /// when `id` isn't the owner, so it never steals another presenter's claim.
    @MainActor
    public func releaseConsentGate(_ id: UUID) {
        if consentGateOwner == id { consentGateOwner = nil }
    }
    /// True if the tenant's plan allows developer customization of the auth UI.
    /// Populated after `isReady` becomes true.
    @Published public private(set) var allowCustomBranding: Bool = false
    /// True if the backend requires App Attest for this app.
    /// Populated after `isReady` becomes true.
    @Published public private(set) var attestRequired: Bool = false
    /// Latest App Attest token, when one has been obtained. Updated asynchronously
    /// after `isReady = true` becomes true; observers can use this to know when
    /// attestation has completed (e.g. to set the same token on a feature HTTP client).
    @Published public private(set) var attestToken: String?
    /// App name returned by /initiate — shown in HostedSignInButton before Safari opens.
    @Published public private(set) var hostedAppName: String = "App"
    /// App logo URL returned by /initiate — shown in HostedSignInButton if set, otherwise Onelo logo.
    @Published public private(set) var hostedAppLogoUrl: URL? = nil
    /// True while a hosted-callback code is being exchanged for a session (via the
    /// in-app WebView OR an external-browser deep-link). `OneloAuthView` reads it
    /// to avoid flashing a fresh sign-in WebView while a login is completing.
    @Published public private(set) var isExchangingCode: Bool = false
    /// True if SDK gate is active — `OneloAuthView` opens the store instead of sign-in.
    @Published public private(set) var paywallEnabled: Bool = false
    /// True if app is in waitlist mode — `OneloAuthView` opens `sdkRedirectUrl` instead of sign-in.
    @Published public private(set) var waitlistMode: Bool = false
    /// Developer-configured URL to open when `waitlistMode` is true and `sdkRedirectUrl` is set.
    @Published public private(set) var sdkRedirectUrl: URL? = nil
    /// Hosted store URL (plan selection + registration). Non-nil when `paywallEnabled` is true.
    @Published public private(set) var storeUrl: URL? = nil
    /// Hosted manage URL (upgrade/cancel). Non-nil when `paywallEnabled` is true.
    @Published public private(set) var manageUrl: URL? = nil
    /// Plan-gated enabled OAuth providers (google/github/apple) from /api/sdk/config.
    /// Empty when social is disabled by the plan OR the developer. Drives the
    /// loading skeleton so it draws social pills only when the hosted form will.
    @Published public private(set) var oauthProviders: [String] = []

    private var client: AuthClient?
    private let keychain: KeychainStorage
    let config: OneloConfig

    /// Callback URL scheme registered for this SDK instance, exposed for
    /// SwiftUI helpers (e.g. `OneloCustomerPortalView`) that need to
    /// know which scheme to watch the embedded WKWebView for.
    public var callbackScheme: String { config.callbackScheme }
    private var pkceVerifier: String?
    private var _heartbeatTask: Task<Void, Never>?
    private var _refreshTask: Task<Void, Never>?
    /// Monotonic counter bumped at the start of every `signOut()`. Async writers
    /// that resurrect a session (proactive token `refreshSession()`, keychain
    /// `restoreSession()`) capture it BEFORE their network `await` and refuse to
    /// persist/publish a session if it changed — i.e. a sign-out landed while
    /// they were in flight. Without this an in-flight `refreshSession()` that
    /// returns AFTER `signOut()` runs `saveSession` + `currentSession = session`,
    /// bringing a signed-out user back both in memory AND in the Keychain → the
    /// app re-authenticates them on next launch and (mid-logout) shows a blank
    /// window because the host's auth view flips back to the signed-in state.
    private var _signOutEpoch: UInt64 = 0

    // Shared SSE pipe — single connection per app, multiplexed across
    // every module that needs server-pushed events. OneloAuth owns the
    // instance and registers a `session.revoked` handler at init; the
    // `Onelo` top-level wrapper forwards this same stream into
    // OneloFeatures so the SDK never opens more than one SSE connection.
    private let _httpClient: _OneloHTTPClient
    private let _eventStream: OneloEventStream

    /// Shared SSE event stream owned by this auth instance. Other Onelo
    /// modules (OneloFeatures, future OneloPaywall realtime) attach their
    /// handlers to this same stream via `eventStream.on(...)`.
    public var eventStream: OneloEventStream { _eventStream }
    /// Refresh this many seconds before the access token expires.
    private let _refreshLeadTime: TimeInterval = 60
    private let _urlSession: URLSession
    #if DEBUG
    private var _skipInitialize: Bool = false
    #endif

    private enum KeychainKeys {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expiresAt = "expires_at"
        static let userJson = "user_json"
        static let supabaseUrl = "supabase_url"
        static let supabaseAnonKey = "supabase_anon_key"
        static let oauthProviders = "oauth_providers"
    }

    public init(config: OneloConfig) {
        self.config = config
        self.keychain = KeychainStorage()
        self._urlSession = .shared
        let httpClient = _OneloHTTPClient(publishableKey: config.publishableKey, baseURL: config.apiUrl)
        self._httpClient = httpClient
        self._eventStream = OneloEventStream(httpClient: httpClient)
        // Register the auth-side handler before any session is loaded so we
        // never miss an event between init and first signin / restore.
        // `session.revoked` is emitted by `revoke_sdk_sessions()` on the
        // backend (account deletion, refund-induced logout, admin ban) —
        // it arrives in sub-second time via SSE; heartbeat is fallback.
        self._eventStream.on("session.revoked") { [weak self] payload in
            Task { @MainActor in self?._handleSessionRevoked(payload) }
        }
        // A blocking legal version just took effect → bump the revision so
        // OneloAuthView re-checks consent and shows the gate immediately.
        self._eventStream.on("legal.consent_required") { [weak self] _ in
            Task { @MainActor in self?.consentRevision += 1 }
        }
        OneloAuth.validateCallbackSchemeRegistration(config.callbackScheme)
        // Seed the cached provider list so the loading skeleton draws the right
        // number of social pills on the FIRST paint, before resolveConfig lands.
        if let cached = try? keychain.get(forKey: KeychainKeys.oauthProviders), !cached.isEmpty {
            oauthProviders = cached.split(separator: ",").map(String.init)
        }
        Task { await self.initialize() }
    }

    /// Handles `session.revoked` event from the shared SSE stream. Filters
    /// out broadcasts targeting a different user on the same app, then
    /// clears the local session — UI observes `currentSession` via
    /// `@Published` and re-presents the sign-in screen automatically.
    private func _handleSessionRevoked(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // The same app_id can have multiple buyers logged in simultaneously
        // (rare for indie apps but possible on macOS shared installs).
        // Filter to the current user; older backend payloads without
        // `app_user_id` are treated as "current user" for forward compat.
        let currentUserId = currentSession?.user.id
        if let target = json["app_user_id"] as? String,
           let me = currentUserId,
           target != me {
            return
        }

        let reason = (json["reason"] as? String) ?? "remote_revoke"
        _authLog.info("session.revoked received reason=\(reason, privacy: .public) — clearing session")
        try? keychain.clear()
        currentSession = nil
        isUserRevoked = true
    }

    /// Verifies that `callbackScheme` is registered with the host app —
    /// without registration, deep-link return after Stripe Checkout or
    /// OAuth lands on a system "address is invalid" alert and the buyer is
    /// stranded.
    ///
    /// Strategy: TWO independent checks, with the deterministic one
    /// (Info.plist via `Bundle.main`) treated as authoritative.
    ///
    /// 1. **Info.plist `CFBundleURLTypes`** — read once in-process from the
    ///    host's main bundle. Always accurate for the binary being run.
    ///    This is the source of truth.
    ///
    /// 2. **Launch Services lookup** (`NSWorkspace.urlForApplication` on
    ///    macOS / `UIApplication.canOpenURL` on iOS) — only used as a
    ///    secondary hint when Info.plist already says the scheme IS
    ///    declared. On macOS, freshly built apps run from Xcode's
    ///    DerivedData may not be registered with Launch Services yet,
    ///    which would produce a false-negative `nil`. We never treat that
    ///    as a hard failure — Info.plist trumps.
    ///
    /// Only fails (assertionFailure in DEBUG, print in release) when
    /// Info.plist itself confirms the scheme is missing. Avoids the
    /// previous DX bug where a correctly-configured macOS dev would crash
    /// on first run because LS hadn't indexed yet.
    private static func validateCallbackSchemeRegistration(_ scheme: String) {
        guard !scheme.isEmpty else { return }
        let needle = scheme.lowercased()

        // Authoritative check — read Info.plist directly. Always reliable.
        let bundleURLTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let declaredSchemes: Set<String> = Set(
            bundleURLTypes.flatMap { entry -> [String] in
                (entry["CFBundleURLSchemes"] as? [String]) ?? []
            }.map { $0.lowercased() }
        )
        let declared = declaredSchemes.contains(needle)

        if !declared {
            let message = """
            ❌ Onelo SDK: URL scheme '\(scheme)' is NOT declared in your Info.plist (CFBundleURLTypes).
               Deep-link return after Stripe Checkout or OAuth will fail with
               "Safari cannot open the page because the address is invalid."

               Fix: in Xcode, target → Info → URL Types → add the scheme '\(scheme)',
               or paste CFBundleURLTypes into Info.plist. See docs:
               https://onelo.tools/docs/swift-setup#url-scheme
            """
            #if DEBUG
            assertionFailure(message)
            #else
            // .fault is the highest level — guaranteed to land in Console
            // and unified logging, regardless of subsystem filtering.
            // `.public` because the developer (not the user) needs to see
            // their own scheme string to fix the misconfiguration.
            _authLog.fault("\(message, privacy: .public)")
            #endif
            return
        }

        // Info.plist says yes — sanity-check via Launch Services and only
        // log a debug hint if the lookup disagrees. This catches edge
        // cases like duplicate CFBundleURLSchemes pointing at the wrong
        // bundle identifier, without false-failing on stale LS index.
        #if DEBUG
        guard let testUrl = URL(string: "\(scheme)://_onelo_init_probe") else { return }
        let lsRegistered: Bool
        #if canImport(AppKit) && os(macOS)
        lsRegistered = NSWorkspace.shared.urlForApplication(toOpen: testUrl) != nil
        #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
        lsRegistered = UIApplication.shared.canOpenURL(testUrl)
        #else
        lsRegistered = true
        #endif
        if !lsRegistered {
            // .debug is verbose-tier — only surfaced when explicitly
            // enabled by Console's "Include Debug Messages". Keeps the
            // diagnostic away from regular user logs.
            _authLog.debug("""
            Onelo SDK: '\(scheme, privacy: .public)' is declared in Info.plist but Launch Services
               doesn't recognize it yet. This is normal on first run from Xcode —
               LS indexes lazily. If deep-link returns still fail after a clean
               build + launch, check for duplicate CFBundleURLSchemes pointing
               at a different bundle identifier.
            """)
        }
        #endif
    }

    #if DEBUG
    init(config: OneloConfig, urlSession: URLSession, skipInitialize: Bool) {
        self.config = config
        self.keychain = KeychainStorage()
        self._urlSession = urlSession
        self._skipInitialize = skipInitialize
        let httpClient = _OneloHTTPClient(publishableKey: config.publishableKey, baseURL: config.apiUrl)
        self._httpClient = httpClient
        self._eventStream = OneloEventStream(httpClient: httpClient)
    }
    #endif

    // MARK: - Public API

    /// Suspend until session restoration from Keychain finishes (i.e. `isReady`
    /// becomes true), then return. Use before emitting monitor events at startup
    /// that need accurate `user_id` — otherwise pre-restore events ship with
    /// `user_id = "anonymous"`.
    ///
    /// Throws `OneloError.timeout` if the SDK doesn't become ready within
    /// `timeout` seconds. Default 5s is a generous ceiling — typical restore
    /// completes in well under a second.
    ///
    /// ```swift
    /// try? await onelo.auth.awaitReady()
    /// onelo.monitor.event("app_launched", options: .init(ok: true))
    /// ```
    /// Synchronously read the cached user email from Keychain — useful for rendering UI
    /// (e.g. an account label in a menu) at app launch *before* `restoreSession()` has
    /// finished and `currentSession` has been populated. Returns nil if no session is
    /// stored, or if the stored user has no email.
    ///
    /// This bypasses the async init flow entirely: Keychain access is synchronous, so
    /// callers can use this on the main thread inside `applicationDidFinishLaunching`
    /// or while building a menu, without awaiting anything.
    public nonisolated func cachedUserEmailSync() -> String? {
        guard let json = try? keychain.get(forKey: KeychainKeys.userJson),
              let data = json.data(using: .utf8),
              let user = try? JSONDecoder().decode(OneloUser.self, from: data),
              let email = user.email,
              !email.isEmpty
        else { return nil }
        return email
    }

    /// Convenience: returns true when the current user has an active paid grant for this app.
    /// Reads from the snapshot embedded in `currentSession.user.entitlement` — call
    /// `revalidateEntitlement()` first if you need a fresh read after an out-of-band purchase.
    /// Returns false when there is no session at all, so callers can write:
    /// `if auth.hasActiveAccess { showApp() } else { showStoreOrSignIn() }`.
    public var hasActiveAccess: Bool {
        currentSession?.user.entitlement == .active
    }

    /// Re-fetch the current user from the backend and update `currentSession.user.entitlement`.
    /// Use this after returning from `OneloStoreView` / external checkout, or on
    /// app foreground if subscriptions may have lapsed offline.
    /// Silently no-ops when there is no session or the call fails — never throws on the
    /// happy path so it is safe to call defensively from UI code.
    @discardableResult
    public func revalidateEntitlement() async -> OneloEntitlement {
        guard let session = currentSession else { return .none }
        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/user")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")
        addStandardHeaders(&request)
        guard
            let (data, response) = try? await _urlSession.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return session.user.entitlement }
        let ent = OneloEntitlement(rawValue: (json["entitlement"] as? String) ?? "") ?? .none
        if ent != session.user.entitlement {
            let updatedUser = OneloUser(
                id: session.user.id, email: session.user.email, role: session.user.role,
                tenantId: session.user.tenantId, entitlement: ent
            )
            let updated = OneloSession(
                accessToken: session.accessToken, refreshToken: session.refreshToken,
                expiresAt: session.expiresAt, user: updatedUser
            )
            try? saveSession(updated)
            currentSession = updated
        }
        return ent
    }

    // MARK: - Legal consent

    /// Fetch the legal documents the signed-in user has not yet accepted. Each
    /// item carries an `enforcement` level and a server-computed `blocking`
    /// flag. `OneloAuthView` uses this to gate the app on a blocking ToS update.
    ///
    /// Returns `[]` when there is no session or the call fails — never throws on
    /// the happy path, so UI code can call it defensively.
    public func requiredConsents() async -> [OneloConsentRequirement] {
        guard let session = currentSession else { return [] }
        let url = config.apiUrl.appendingPathComponent("/v1/sdk/consent/required")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        addStandardHeaders(&request)
        guard
            let (data, response) = try? await _urlSession.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(OneloConsentRequiredResponse.self, from: data)
        else { return [] }
        return decoded.required
    }

    /// Record the signed-in user's acceptance of a specific document version.
    /// Idempotent server-side. Throws on no session or a non-2xx response so the
    /// gate can keep the user on the screen and let them retry.
    public func acceptConsent(versionId: String) async throws {
        guard let session = currentSession else { throw OneloError.notAuthenticated }
        let url = config.apiUrl.appendingPathComponent("/v1/sdk/consent/accept")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addStandardHeaders(&request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["document_version_id": versionId]
        )
        let (_, response) = try await _urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OneloError.serverError("Failed to record consent")
        }
    }

    public func awaitReady(timeout: TimeInterval = 5) async throws {
        if isReady { return }
        let deadlineNs = UInt64(timeout * 1_000_000_000)
        let started = DispatchTime.now()
        for await ready in $isReady.values {
            if ready { return }
            if DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds > deadlineNs {
                throw OneloError.timeout("awaitReady exceeded \(timeout)s")
            }
        }
    }

    @available(iOS 12.0, macOS 10.15, *)
    public func presentHostedSignIn(
        from context: ASWebAuthenticationPresentationContextProviding
    ) async throws -> OneloSession {
        let scheme = config.callbackScheme
        guard !scheme.isEmpty else {
            throw OneloError.serverError("callbackScheme must be set in OneloConfig to use presentHostedSignIn()")
        }

        isLoading = true
        defer { isLoading = false }

        // 1. Get one-time token + hosted URL
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/auth/initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
        ]
        var initRequest = URLRequest(url: components.url!)
        addStandardHeaders(&initRequest)
        let (initData, initResponse) = try await URLSession.shared.data(for: initRequest)
        guard let http = initResponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.serverError("Failed to initiate hosted auth flow")
        }
        let initJson = (try? JSONSerialization.jsonObject(with: initData)) as? [String: Any] ?? [:]
        guard
            let hostedUrlString = initJson["hosted_url"] as? String,
            let hostedUrl = URL(string: hostedUrlString)
        else {
            throw OneloError.serverError("Invalid initiate response")
        }

        // Store app metadata for UI
        if let name = initJson["app_name"] as? String { hostedAppName = name }
        if let logoStr = initJson["app_logo_url"] as? String { hostedAppLogoUrl = URL(string: logoStr) }

        // 2. Open hosted page via ASWebAuthenticationSession
        let callbackUrl: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: hostedUrl,
                callbackURLScheme: scheme
            ) { url, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: OneloError.cancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: OneloError.serverError(error.localizedDescription))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: OneloError.serverError("No callback URL"))
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        // 3. Extract code from callback URL
        guard
            let callbackComponents = URLComponents(url: callbackUrl, resolvingAgainstBaseURL: false),
            let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw OneloError.serverError("No code in callback URL")
        }

        // 4. Exchange code for session
        var exchangeBody: [String: String] = ["code": code, "publishableKey": config.publishableKey]
        if let verifier = pkceVerifier { exchangeBody["code_verifier"] = verifier }
        let exchangeUrl = config.apiUrl.appendingPathComponent("/api/sdk/auth/hosted-callback")
        var request = URLRequest(url: exchangeUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: exchangeBody)
        addStandardHeaders(&request)

        let (exchangeData, exchangeResponse) = try await URLSession.shared.data(for: request)
        guard let exchangeHttp = exchangeResponse as? HTTPURLResponse, exchangeHttp.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: exchangeData)) as? [String: Any] ?? [:]
            let msg = json["error"] as? String ?? "Code exchange failed"
            throw OneloError.serverError(msg)
        }

        let json = (try? JSONSerialization.jsonObject(with: exchangeData)) as? [String: Any] ?? [:]
        guard
            let accessToken = json["access_token"] as? String,
            let refreshToken = json["refresh_token"] as? String,
            let expiresIn = json["expires_in"] as? Int,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Invalid session response"
            throw OneloError.serverError(msg)
        }

        let userEmail = userData["email"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let user = OneloUser(
                id: userId,
                email: userEmail,
                role: .member,
                tenantId: nil,
                entitlement: OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none
            )
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    // MARK: - Hosted flow (WKWebView)

    /// Calls /api/sdk/paywall/store-initiate and returns a tokenized store URL for the WKWebView.
    /// The store page handles plan selection + payment + registration in one flow.
    /// After completion, it redirects to callbackScheme://callback?code=... — same as auth.
    public func initiateStoreFlow(lang: String = "en") async throws -> URL {
        let scheme = config.callbackScheme
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/paywall/store-initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
            URLQueryItem(name: "lang", value: lang),
        ]
        var request = URLRequest(url: components.url!)
        addStandardHeaders(&request)
        // If the user is already signed in, attach their access token so
        // /store-initiate can bind app_user_id to the resulting srt_*.
        // The hosted store then skips signup and goes straight to
        // checkout via mode='reauth' — the "lapsed buyer picks new plan"
        // path. Cold-start (no session) keeps the legacy behavior:
        // header omitted, server mints an unauthenticated token, store
        // shows the full signup form. See [[paywall_seamless_repurchase]].
        if let session = currentSession {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        // Surface server-side error codes verbatim so the host app can
        // branch on them. Most important: 409 store_not_configured means
        // the developer has paywall_enabled=true but hasn't added any
        // visible paywall_store_options — we must NOT open a WebView.
        if let http, http.statusCode != 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = (json["error"] as? String) ?? (json["detail"] as? String) ?? "store_initiate_failed"
            if code == "store_not_configured" {
                throw OneloError.storeNotConfigured
            }
            if code == "paywall_not_enabled" {
                throw OneloError.serverError("paywall_not_enabled")
            }
            throw OneloError.serverError("Failed to initiate store flow (\(http.statusCode): \(code))")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let urlStr = json["store_url"] as? String, let url = URL(string: urlStr) else {
            throw OneloError.serverError("Invalid store-initiate response")
        }
        if let name = json["app_name"] as? String { hostedAppName = name }
        if let logoStr = json["app_logo_url"] as? String { hostedAppLogoUrl = URL(string: logoStr) }
        return url
    }

    /// Returns the hosted auth URL. Waitlist+redirectUrl opens the redirect URL directly;
    /// all other cases (including paywall) open the auth page — Sign Up routing to store
    /// is handled inside the hosted auth page itself.
    public func initiateHostedFlow() async throws -> URL {
        if waitlistMode, let redirectUrl = sdkRedirectUrl {
            return redirectUrl
        }
        return try await _initiateAuthFlow()
    }

    /// Calls /api/sdk/auth/initiate and returns the raw auth URL (no routing).
    internal func _initiateAuthFlow() async throws -> URL {
        let scheme = config.callbackScheme
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/auth/initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
        ]
        var request = URLRequest(url: components.url!)
        addStandardHeaders(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.serverError("Failed to initiate hosted auth flow")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let urlStr = json["hosted_url"] as? String, let url = URL(string: urlStr) else {
            throw OneloError.serverError("Invalid initiate response")
        }
        if let name = json["app_name"] as? String { hostedAppName = name }
        if let logoStr = json["app_logo_url"] as? String { hostedAppLogoUrl = URL(string: logoStr) }
        return url
    }

    /// Backend routing decision from `GET /api/sdk/flow/init`.
    public enum FlowDecision {
        /// The caller already has access → show content, no WebView.
        case authorized
        /// Open `url` in the WebView; it returns one final `<scheme>://callback?code=…`.
        case present(surface: String, url: URL, appName: String?, appLogoUrl: URL?)
    }

    /// Ask the backend to decide the auth flow — the mirror of the JS SDK's
    /// `resolveFlow`. "Behind Onelo's walls": the sign-in ↔ store ↔ content
    /// routing lives ONCE, in `/api/sdk/flow/init`, so the SDK just opens
    /// whatever URL it is told (or shows content when already authorized).
    /// `OneloAuthView` uses this internally; accessory apps that present their
    /// own WebView can call it directly to get the same decision.
    public func resolveFlow(lang: String = "en") async throws -> FlowDecision {
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/flow/init"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: config.callbackScheme),
            URLQueryItem(name: "lang", value: lang),
        ]
        var request = URLRequest(url: components.url!)
        addStandardHeaders(&request)
        // Optional identity: a signed-in caller lets the backend decide
        // authorized-vs-store (bound to this user). Cold start (no session) →
        // sign_in. Mirrors `initiateStoreFlow`'s Bearer + JS resolveFlow.
        if let session = currentSession {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await _urlSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Preserve the store-not-configured mapping so loadHostedUrl's
            // existing catch shows the "store hasn't been set up" retry.
            let detail = (json["detail"] as? String) ?? (json["error"] as? String)
            if detail == "store_not_configured" { throw OneloError.storeNotConfigured }
            throw OneloError.serverError(detail ?? "flow/init failed (\(http.statusCode))")
        }
        switch json["action"] as? String {
        case "authorized":
            return .authorized
        case "present":
            guard let urlStr = json["url"] as? String, let url = URL(string: urlStr) else {
                throw OneloError.serverError("Invalid flow/init present response")
            }
            let name = json["app_name"] as? String
            let logoStr = json["app_logo_url"] as? String
            if let name { hostedAppName = name }
            if let logoStr { hostedAppLogoUrl = URL(string: logoStr) }
            return .present(
                surface: (json["surface"] as? String) ?? "",
                url: url,
                appName: name,
                appLogoUrl: logoStr.flatMap { URL(string: $0) }
            )
        default:
            throw OneloError.serverError("Invalid flow/init response")
        }
    }

    /// Opens the hosted Customer Portal in a WebAuth session. Lets the
    /// signed-in user manage subscriptions, request refunds (when within
    /// the app's `refund_window_days`), and view past invoices. Requires
    /// an active session — throws `OneloError.notAuthenticated` otherwise.
    ///
    /// Closes when the user taps "Return to app" inside the portal,
    /// which redirects to `<callbackScheme>://callback?source=portal`.
    public func initiateCustomerPortal() async throws -> URL {
        guard let session = currentSession else {
            throw OneloError.notAuthenticated
        }
        let scheme = config.callbackScheme
        // Token goes in Authorization: Bearer header — NOT in URL —
        // so it never lands in access logs, Referer headers, browser
        // history, MetricKit/crash reports. Backend reads either the
        // header or the legacy `?user_token=` query for backwards
        // compat with SDK < 3.40.
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/paywall/portal-initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
        ]
        var request = URLRequest(url: components.url!)
        addStandardHeaders(&request)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let http, http.statusCode != 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let msg = json["error"] as? String ?? "Failed to open Customer Portal"
            // Distinct error types so the host app can branch sensibly.
            if http.statusCode == 401 { throw OneloError.notAuthenticated }
            if http.statusCode == 403 { throw OneloError.serverError(msg) }
            throw OneloError.serverError(msg)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let urlStr = json["hosted_url"] as? String, let url = URL(string: urlStr) else {
            throw OneloError.serverError("Invalid portal-initiate response")
        }
        if let name = json["app_name"] as? String { hostedAppName = name }
        if let logoStr = json["app_logo_url"] as? String { hostedAppLogoUrl = URL(string: logoStr) }
        return url
    }

    /// True when the host app is an accessory / menubar / dock-less
    /// process — `LSUIElement=YES` in Info.plist OR
    /// `NSApp.activationPolicy() == .accessory`. On such apps,
    /// `ASWebAuthenticationSession.start()` silently never presents:
    /// the session callback never fires, the `await` hangs forever,
    /// no error is thrown. Detected in Turingo dev builds 2026-05-21.
    /// We use this to fall back to opening the portal in the system
    /// browser instead. Returns false on iOS / Catalyst.
    @MainActor
    private var isAccessoryApp: Bool {
        #if canImport(AppKit) && os(macOS)
        if NSApp.activationPolicy() == .accessory { return true }
        if let lsui = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, lsui { return true }
        if let lsui = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? String, lsui == "1" || lsui.lowercased() == "true" { return true }
        return false
        #else
        return false
        #endif
    }

    /// Convenience wrapper: opens the Customer Portal via
    /// ASWebAuthenticationSession and returns when the user dismisses.
    /// On iOS / macOS apps with a deep-link callback scheme this is the
    /// one-call entry point — call from a button handler.
    ///
    /// On macOS *menubar/accessory apps* (LSUIElement=true or
    /// .accessory activation policy) ASWebAuth never actually presents
    /// — there's no key window for it to attach to and the session
    /// silently hangs. This implementation detects that and falls back
    /// to `NSWorkspace.shared.open(url)` so the buyer at least sees the
    /// portal in their default browser. Apps that prefer to stay
    /// in-app should use `OneloCustomerPortalView` (WKWebView embedded
    /// in a SwiftUI sheet) instead.
    ///
    /// IMPORTANT: `context` (`ASWebAuthenticationPresentationContextProviding`)
    /// is held WEAKLY by the system session. Make sure your provider is
    /// retained elsewhere — typically a singleton class or a property
    /// on the view controller that owns the button. An ad-hoc anonymous
    /// adapter (`{ session in window }`) goes out of scope before
    /// presentation and the session silently fails to open.
    @MainActor
    public func openCustomerPortal(
        from context: ASWebAuthenticationPresentationContextProviding
    ) async throws {
        let url = try await initiateCustomerPortal()
        // Menubar / accessory apps can't host an ASWebAuth window.
        // Fall back to system browser — Stripe's deep-link callback
        // back into the host app's URL scheme still works the same.
        #if canImport(AppKit) && os(macOS)
        if isAccessoryApp {
            NSWorkspace.shared.open(url)
            return
        }
        #endif
        let scheme = config.callbackScheme
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            // Resume guard — ASWebAuth doesn't fire its callback when
            // the session can't present (rare race on macOS that the
            // explicit accessory-app check above mostly covers, but
            // also seen on first launch before the app has a key window).
            // A 30s deadline turns the silent hang into an explicit error
            // the host app can surface as a retry CTA.
            //
            // Atomic single-resume guard. NSLock + Bool because the
            // callback and the timeout can fire from arbitrary threads
            // and we need a CAS-style "exchange and tell me the old
            // value" to make sure only one of them resumes the
            // continuation.
            let resumeLock = NSLock()
            var didResume = false
            let exchange: () -> Bool = {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                if didResume { return true }
                didResume = true
                return false
            }
            let timeoutDeadline = DispatchTime.now() + .seconds(30)
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { [weak self] callbackUrl, error in
                guard exchange() == false else { return }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: OneloError.serverError(error.localizedDescription))
                    return
                }

                // 2026-05-26: portal can signal account-lifecycle events
                // via deep-link query params. When the buyer schedules
                // account deletion, the portal redirects to
                // `<scheme>://callback?source=portal&event=account_deletion_scheduled`
                // — route it through the shared handlePortalCallback so we
                // clear the local session INSTANTLY instead of waiting up to
                // 13 min for the heartbeat to pick up app_sessions.revoked_at
                // via 401. Same code path as the external-browser and embedded
                // portal presentations, so all three behave identically.
                if let callbackUrl {
                    Task { @MainActor [weak self] in
                        self?.handlePortalCallback(callbackUrl)
                    }
                }

                continuation.resume(returning: callbackUrl)
            }
            session.presentationContextProvider = context
            // Non-ephemeral on purpose. On macOS, ephemeral WebAuth
            // sessions detach into a separate system-managed window
            // outside the app's window manager — buyers see "browser
            // opens on another screen and nothing happens" because the
            // portal page is loading there, not inline with the app
            // (regression observed 2026-05-21). The portal page itself
            // already short-circuits replay via single-use prt_* tokens
            // (deleted after refund, 10-min TTL), so persistent
            // Safari cookies don't add meaningful risk.
            session.prefersEphemeralWebBrowserSession = false
            session.start()

            DispatchQueue.main.asyncAfter(deadline: timeoutDeadline) {
                guard exchange() == false else { return }
                session.cancel()
                continuation.resume(throwing: OneloError.timeout("Customer portal didn't open in 30s — accessory apps may need openCustomerPortalInBrowser() or OneloCustomerPortalView."))
            }
        }
    }

    /// Opens the hosted Customer Portal in the user's default browser
    /// via `NSWorkspace.shared.open` (macOS) / `UIApplication.shared.open`
    /// (iOS). No ASWebAuthenticationSession, no presentation context,
    /// no SwiftUI host required — just hands the URL off to the OS.
    ///
    /// Designed for accessory / menubar / dock-less apps where ASWebAuth
    /// can't attach to a key window and silently hangs (see
    /// `openCustomerPortal(from:)` notes). Stripe's deep-link callback
    /// back into the host app via the registered URL scheme works
    /// identically to the embedded path.
    @MainActor
    public func openCustomerPortalInBrowser() async throws {
        let url = try await initiateCustomerPortal()
        #if canImport(AppKit) && os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        await UIApplication.shared.open(url)
        #else
        throw OneloError.serverError("No system browser available on this platform")
        #endif
    }

    /// Hard account-lifecycle events the portal can deep-link back — each
    /// clears the local session instantly (mirrors the Electron SDK's
    /// `OneloElectronCustomerPortal.REVOKE_EVENTS` set).
    private static let portalRevokeEvents: Set<String> = [
        "account_deletion_scheduled", "account_revoked", "session_compromised",
    ]

    /// Process a portal deep-link the OS handed to your app. Only needed for
    /// the `openCustomerPortalInBrowser()` path — the portal redirects back
    /// into your app via the registered URL scheme and there's no ASWebAuth /
    /// WKWebView to intercept it. Wire it from SwiftUI's
    /// `.onOpenURL { url in auth.handlePortalCallback(url) }` or UIKit/AppKit's
    /// `application(_:open:options:)`.
    ///
    /// On a hard account event (deletion / revoke / compromise) it clears the
    /// local session INSTANTLY instead of waiting for the heartbeat to pick up
    /// the server-side revocation via a 401. Returns true when the URL was a
    /// portal callback (`source=portal`), false otherwise. Never throws.
    ///
    /// The in-app paths — `openCustomerPortal(from:)` and
    /// `OneloCustomerPortalView` — route through this same method, so all three
    /// presentation styles behave identically. Mirrors the Electron SDK's
    /// `customerPortal.handlePortalCallback(url)`.
    @MainActor
    @discardableResult
    public func handlePortalCallback(_ url: URL) -> Bool {
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            comps.queryItems?.first(where: { $0.name == "source" })?.value == "portal"
        else { return false }
        applyPortalEvent(comps.queryItems?.first(where: { $0.name == "event" })?.value)
        return true
    }

    /// Clear the local session on a hard portal event: wipe the keychain, drop
    /// the in-memory session, flag `isUserRevoked`. No-op for other / absent
    /// events. Shared by all three portal presentation paths.
    @MainActor
    private func applyPortalEvent(_ event: String?) {
        guard let event, OneloAuth.portalRevokeEvents.contains(event) else { return }
        try? keychain.clear()
        currentSession = nil
        isUserRevoked = true
    }

    /// Exchanges the auth code (intercepted from the WKWebView callback URL) for a session.
    public func exchangeHostedCode(_ code: String) async throws -> OneloSession {
        // Signals OneloAuthView that a login is completing, so it won't flash a
        // fresh sign-in WebView while the app foregrounds from an external-browser
        // deep-link return (the callback code is exchanged here whether it arrived
        // via the in-app WebView OR the app's onOpenURL). Cleared when done.
        isExchangingCode = true
        defer { isExchangingCode = false }
        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/hosted-callback")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["code": code, "publishableKey": config.publishableKey]
        if let verifier = pkceVerifier { body["code_verifier"] = verifier }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addStandardHeaders(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let msg = json["error"] as? String ?? "Code exchange failed"
            throw OneloError.serverError(msg)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard
            let accessToken = json["access_token"] as? String,
            let refreshToken = json["refresh_token"] as? String,
            let expiresIn = json["expires_in"] as? Int,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Invalid session response"
            throw OneloError.serverError(msg)
        }
        let userEmail = userData["email"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let user = OneloUser(
                id: userId,
                email: userEmail,
                role: .member,
                tenantId: nil,
                entitlement: OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none
            )
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    /// Sign in — goes through Onelo backend to track last_seen_at and validate app access.
    public func signIn(email: String, password: String) async throws -> OneloSession {
        isLoading = true
        defer { isLoading = false }

        return try await _signInAttempt(email: email, password: password, isRetry: false)
    }

    private func _signInAttempt(email: String, password: String, isRetry: Bool) async throws -> OneloSession {
        if pkceVerifier == nil {
            guard !isRetry else { throw OneloError.serverError("SDK not ready — call after isReady") }
            try await refreshPKCE()
        }
        guard let verifier = pkceVerifier else {
            throw OneloError.serverError("SDK not ready — call after isReady")
        }

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
            "code_verifier": verifier,
        ]

        let json: [String: Any]
        do {
            json = try await backendPost(path: "/api/sdk/auth/signin", body: body)
        } catch OneloError.serverError(let msg) where msg.contains("PKCE") && !isRetry {
            pkceVerifier = nil
            try await refreshPKCE()
            return try await _signInAttempt(email: email, password: password, isRetry: true)
        }

        guard
            let sessionData = json["session"] as? [String: Any],
            let accessToken = sessionData["access_token"] as? String,
            let refreshToken = sessionData["refresh_token"] as? String,
            let expiresIn = sessionData["expires_in"] as? Int,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Sign in failed"
            throw OneloError.serverError(msg)
        }
        pkceVerifier = nil

        let userEmail = userData["email"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let user = OneloUser(
                id: userId,
                email: userEmail,
                role: .member,
                tenantId: nil,
                entitlement: OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none
            )
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    /// Sign up — registers via Onelo backend so the user is tracked in app_users.
    /// Returns `true` if email verification is required.
    public func signUp(email: String, password: String) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        return try await _signUpAttempt(email: email, password: password, isRetry: false)
    }

    private func _signUpAttempt(email: String, password: String, isRetry: Bool) async throws -> Bool {
        if pkceVerifier == nil {
            guard !isRetry else { throw OneloError.serverError("SDK not ready — call after isReady") }
            try await refreshPKCE()
        }
        guard let verifier = pkceVerifier else {
            throw OneloError.serverError("SDK not ready — call after isReady")
        }

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
            "code_verifier": verifier,
        ]

        let json: [String: Any]
        do {
            json = try await backendPost(path: "/api/sdk/auth/signup", body: body)
        } catch OneloError.serverError(let msg) where msg.contains("PKCE") && !isRetry {
            pkceVerifier = nil
            try await refreshPKCE()
            return try await _signUpAttempt(email: email, password: password, isRetry: true)
        }

        if let errMsg = json["error"] as? String {
            throw OneloError.serverError(errMsg)
        }
        pkceVerifier = nil

        if let sessionData = json["session"] as? [String: Any],
           let accessToken = sessionData["access_token"] as? String,
           let refreshToken = sessionData["refresh_token"] as? String,
           let expiresIn = sessionData["expires_in"] as? Int,
           let userData = json["user"] as? [String: Any],
           let userId = userData["id"] as? String {
            let userEmail = userData["email"] as? String
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let user = OneloUser(
                id: userId,
                email: userEmail,
                role: .member,
                tenantId: nil,
                entitlement: OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none
            )
            let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
            try saveSession(session)
            currentSession = session
            return false
        }

        return true
    }

    public func signOut() async throws {
        // Invalidate any session-restoring work that is mid-flight (a proactive
        // token refresh awaiting the network, a restore awaiting verify). They
        // capture this epoch before their await and bail if it moved, so they
        // can't write the just-cleared tokens back after we sign out.
        _signOutEpoch &+= 1
        isLoading = true
        defer { isLoading = false }

        // Tear down ALL local session state up-front, BEFORE the network await
        // below. Previously keychain.clear()/currentSession=nil ran AFTER
        // `await client.signOut()`, leaving a window where the proactive
        // `_refreshTask` (token still in keychain, session still live) could
        // fire, capture the already-bumped epoch, refresh successfully and
        // write the session back — the "logged out but bounced right back" bug.
        // Cancel the refresh task explicitly too: setting currentSession=nil
        // cancels it via didSet, but doing it first removes any doubt about
        // ordering. _stopHeartbeat() is likewise covered by didSet but kept
        // explicit for clarity.
        #if DEBUG
        _authLog.debug("signOut: clearing local state (refreshTask, keychain, session)")
        #endif
        _refreshTask?.cancel()
        _refreshTask = nil
        try? keychain.clear()
        currentSession = nil
        pkceVerifier = nil
        _stopHeartbeat()

        // Best-effort server-side revoke (Supabase client + Onelo session). Runs
        // AFTER local teardown so even if this await hangs/fails, the user is
        // already locally signed out.
        if let client {
            try? await client.signOut()
        }

        // Re-initialize to mint a fresh PKCE verifier + client for the NEXT
        // sign-in — but MUST NOT restore a session. `initialize()` ends with
        // `restoreSession()`, which reads the Keychain; if `clear()` above
        // didn't fully purge it (e.g. duplicate entries left by prior unsigned
        // dev builds with divergent macOS Keychain ACLs), that restore would
        // re-publish the just-signed-out session ~1s later — the "logged out
        // then auto-logged back in" bug. The sign-out epoch can't guard this
        // because it's already bumped before this initialize runs, so the
        // restore would capture the new epoch and proceed. Skip restore
        // explicitly: an explicit user sign-out must never auto-restore.
        Task { await self.initialize(allowRestore: false) }
        #if DEBUG
        _authLog.debug("signOut: done, initialize(allowRestore: false) spawned")
        #endif
    }

    public func resetPassword(email: String, redirectTo: URL? = nil) async throws {
        let client = try requireClient()
        try await client.resetPasswordForEmail(email, redirectTo: redirectTo)
    }

    public func signInWithMagicLink(email: String, redirectTo: URL? = nil) async throws {
        let client = try requireClient()
        try await client.signInWithOTP(email: email, redirectTo: redirectTo)
    }

    /// Refreshes the session via Onelo backend — validates ban status and app membership.
    public func refreshSession() async throws -> OneloSession? {
        let epoch = _signOutEpoch
        guard let refreshToken = try keychain.get(forKey: KeychainKeys.refreshToken) else { return nil }

        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken,
            "publishableKey": config.publishableKey,
        ])
        addStandardHeaders(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        // A signOut() landed while this refresh was in flight — abandon it.
        // Don't re-save tokens or republish the session; the user is signed out.
        guard epoch == _signOutEpoch else { return nil }
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 403 {
            // Account deleted or suspended — treat as a hard revocation
            let detail = json["detail"] as? String ?? ""
            let isRevocation = detail.contains("account_deleted")
                || detail.contains("account_suspended")
                || detail.contains("account_payment_failed")
            if isRevocation {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return nil
            }
        }

        if http.statusCode >= 400 {
            let msg = json["error"] as? String ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
            try keychain.clear()
            currentSession = nil
            throw OneloError.serverError(msg)
        }

        if let errMsg = json["error"] as? String {
            try keychain.clear()
            currentSession = nil
            throw OneloError.serverError(errMsg)
        }

        guard
            let sessionData = json["session"] as? [String: Any],
            let accessToken = sessionData["access_token"] as? String,
            let newRefreshToken = sessionData["refresh_token"] as? String,
            let expiresIn = sessionData["expires_in"] as? Int
        else {
            throw OneloError.serverError("Refresh failed")
        }

        // Server returns a fresh `user` block (with current entitlement) on every refresh.
        // Fall back to the cached user if the server omitted it (older backend).
        let refreshedUser: OneloUser = {
            if let userData = json["user"] as? [String: Any],
               let userId = userData["id"] as? String {
                let userEmail = userData["email"] as? String
                let ent = OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none
                return OneloUser(id: userId, email: userEmail, role: .member, tenantId: nil, entitlement: ent)
            }
            return currentSession?.user ?? OneloUser(id: "", email: nil, role: .member, tenantId: nil)
        }()
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: refreshedUser)
        try saveSession(session)
        currentSession = session
        return session
    }

    private func refreshPKCE() async throws {
        let resolved = try await resolveConfig()
        let authURL = URL(string: resolved.supabaseUrl)!.appendingPathComponent("/auth/v1")
        client = AuthClient(
            url: authURL,
            headers: ["apikey": resolved.supabaseAnonKey],
            localStorage: AuthClient.Configuration.defaultLocalStorage
        )
        try? keychain.set(resolved.supabaseUrl, forKey: KeychainKeys.supabaseUrl)
        try? keychain.set(resolved.supabaseAnonKey, forKey: KeychainKeys.supabaseAnonKey)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Private

    /// - Parameter allowRestore: when false, the SDK is reset (fresh PKCE +
    ///   client) WITHOUT re-reading the Keychain to restore a session. Used by
    ///   `signOut()` so an explicit sign-out can never auto-restore. Defaults
    ///   to true for the app-launch path, which SHOULD restore a saved session.
    private func initialize(allowRestore: Bool = true) async {
        #if DEBUG
        guard !_skipInitialize else { return }
        #endif
        isReady = false
        do {
            let resolved = try await resolveConfig()
            allowCustomBranding = resolved.allowCustomBranding
            attestRequired = resolved.attestRequired
            if let name = resolved.appName, !name.isEmpty { hostedAppName = name }
            if let logoStr = resolved.appLogoUrl { hostedAppLogoUrl = URL(string: logoStr) }
            paywallEnabled = resolved.paywallEnabled
            waitlistMode = resolved.waitlistMode
            if let urlStr = resolved.sdkRedirectUrl { sdkRedirectUrl = URL(string: urlStr) }
            if let urlStr = resolved.storeUrl { storeUrl = URL(string: urlStr) }
            if let urlStr = resolved.manageUrl { manageUrl = URL(string: urlStr) }
            oauthProviders = resolved.oauthProviders
            // Cache so the loading skeleton can draw the right social-pill count on
            // the NEXT launch's first paint, before this resolveConfig completes.
            try? keychain.set(oauthProviders.joined(separator: ","), forKey: KeychainKeys.oauthProviders)

            try? keychain.set(resolved.supabaseUrl, forKey: KeychainKeys.supabaseUrl)
            try? keychain.set(resolved.supabaseAnonKey, forKey: KeychainKeys.supabaseAnonKey)

            let authURL = URL(string: resolved.supabaseUrl)!
                .appendingPathComponent("/auth/v1")
            client = AuthClient(
                url: authURL,
                headers: ["apikey": resolved.supabaseAnonKey],
                localStorage: AuthClient.Configuration.defaultLocalStorage
            )
            // Mark SDK as ready immediately so the UI can proceed (login button enables,
            // hosted flow can start, etc.). Attestation, when required, runs in the
            // background and writes to `self.attestToken` when complete.
            //
            // Why not block on attestation here:
            //   - On macOS the backend's attest path is soft (accepts requests without
            //     X-Attest-Token), and DCAppAttestService can hang on Apple's servers
            //     when the App Attest entitlement is missing. Awaiting it would freeze
            //     the entire SDK init for a non-blocker.
            //   - On iOS attestation normally completes in ~1s; by the time the user
            //     clicks Sign In and finishes the hosted flow, the token is in place.
            //     If a request is issued before attestation finishes, the backend
            //     returns attest_token_required and the caller can retry.
            isReady = true
            if allowRestore { await restoreSession() }
            if resolved.attestRequired {
                Task { [weak self] in
                    await self?._refreshAttestToken()
                }
            }
        } catch OneloError.invalidPublishableKey {
            // Key was revoked or app deleted — clear session and signal to the UI
            try? keychain.clear()
            currentSession = nil
            isRevoked = true
        } catch {
            // Network offline or transient error — fall back to cached config so
            // the user can still use a valid existing session.
            if let url = try? keychain.get(forKey: KeychainKeys.supabaseUrl),
               let key = try? keychain.get(forKey: KeychainKeys.supabaseAnonKey) {
                let authURL = URL(string: url)!.appendingPathComponent("/auth/v1")
                client = AuthClient(
                    url: authURL,
                    headers: ["apikey": key],
                    localStorage: AuthClient.Configuration.defaultLocalStorage
                )
                isReady = true
                if allowRestore { await restoreSession() }
            }
        }
    }

    private func resolveConfig() async throws -> ResolvedConfig {
        guard config.publishableKey.hasPrefix("onelo_pk_") else {
            throw OneloError.invalidPublishableKey("Key must start with onelo_pk_")
        }

        let verifier = generateCodeVerifier()
        pkceVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        var configRequest = URLRequest(url: components.url!)
        addStandardHeaders(&configRequest)
        let (data, response) = try await URLSession.shared.data(for: configRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.invalidPublishableKey("Server rejected the key")
        }

        return try JSONDecoder().decode(ResolvedConfig.self, from: data)
    }

    private func requireClient() throws -> AuthClient {
        guard let client else {
            throw OneloError.notAuthenticated
        }
        return client
    }

    /// Adds standard SDK headers (X-Publishable-Key, X-Bundle-Id, X-Attest-Token,
    /// X-Onelo-Instance-Id) to a request.
    private func addStandardHeaders(_ request: inout URLRequest) {
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")
        request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        if let token = attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
    }

    /// Fetches a fresh App Attest token and caches it. No-op on unsupported platforms.
    /// Safe to call from a detached Task — internally hops to the cooperative pool
    /// for DCAppAttestService / network / keychain work, then writes back to
    /// `self.attestToken` on the main actor.
    func _refreshAttestToken() async {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *) {
            let attest = OneloAppAttest(
                baseURL: config.apiUrl.absoluteString,
                publishableKey: config.publishableKey
            )
            if let token = try? await attest.getAttestToken() {
                self.attestToken = token
            }
        }
        #endif
    }

    /// Returns the cached App Attest token, if any. Used by Onelo to copy the token
    /// to the features HTTP client after initialization completes.
    func cachedAttestToken() -> String? { attestToken }

    private func restoreSession() async {
        let epoch = _signOutEpoch
        guard
            let accessToken = try? keychain.get(forKey: KeychainKeys.accessToken),
            let refreshToken = try? keychain.get(forKey: KeychainKeys.refreshToken),
            let expiresAtStr = try? keychain.get(forKey: KeychainKeys.expiresAt),
            let expiresAtInterval = TimeInterval(expiresAtStr),
            let userJsonStr = try? keychain.get(forKey: KeychainKeys.userJson),
            let userJson = userJsonStr.data(using: .utf8),
            let user = try? JSONDecoder().decode(OneloUser.self, from: userJson)
        else { return }

        guard !user.id.isEmpty else {
            try? keychain.clear()
            return
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtInterval)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)

        if session.isExpiringSoon {
            _ = try? await refreshSession()
        } else {
            // Verify session is still valid against the backend before exposing it to the app.
            // This catches users that were deleted or suspended while offline.
            let revoked = await verifySession(accessToken: accessToken)
            // Bail if a signOut() ran while we were verifying — don't resurrect.
            guard epoch == _signOutEpoch else { return }
            if !revoked {
                currentSession = session
                // Refresh entitlement against the canonical paywall_access table — the keychain
                // copy may be stale (subscription may have lapsed while offline). Best-effort:
                // if the network call fails, the cached value stays.
                if paywallEnabled {
                    _ = await revalidateEntitlement()
                }
            }
        }
    }

    /// Calls the backend /verify endpoint to check whether the account has been revoked.
    /// Returns `true` if the session was revoked (and has been cleared), `false` if it is valid.
    @discardableResult
    private func verifySession(accessToken: String) async -> Bool {
        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/verify")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        addStandardHeaders(&request)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Network error — fail open, let the app proceed with the cached session
            return false
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 200 {
            return false
        }

        if http.statusCode == 403 {
            let detail = json["detail"] as? String ?? ""
            let isRevocation = detail.contains("revoked")
                || detail.contains("deleted")
                || detail.contains("suspended")
            if isRevocation {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return true
            }
        }

        if http.statusCode == 401 {
            // Token expired — trigger normal refresh flow
            _ = try? await refreshSession()
            return false
        }

        // Unexpected error — fail open
        return false
    }

    /// Cancels any pending refresh and schedules a new one based on the current session.
    /// Called automatically whenever `currentSession` changes (via its `didSet`), so a
    /// fresh refresh is always queued for `expiresAt - _refreshLeadTime`. When the session
    /// is cleared (sign-out, revocation, refresh failure), the pending task is cancelled.
    private func rescheduleRefresh() {
        _refreshTask?.cancel()
        _refreshTask = nil

        guard let session = currentSession else { return }

        let delay = session.expiresAt.timeIntervalSinceNow - _refreshLeadTime
        // If already past the lead window, refresh immediately.
        let sleepNs: UInt64 = delay > 0 ? UInt64(delay * 1_000_000_000) : 0

        _refreshTask = Task { [weak self] in
            if sleepNs > 0 {
                try? await Task.sleep(nanoseconds: sleepNs)
            }
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.refreshSession()
        }
    }

    private func saveSession(_ session: OneloSession) throws {
        try keychain.set(session.accessToken, forKey: KeychainKeys.accessToken)
        try keychain.set(session.refreshToken, forKey: KeychainKeys.refreshToken)
        try keychain.set(String(session.expiresAt.timeIntervalSince1970), forKey: KeychainKeys.expiresAt)
        let userJson = try JSONEncoder().encode(session.user)
        try keychain.set(String(data: userJson, encoding: .utf8) ?? "", forKey: KeychainKeys.userJson)
        // Heartbeat + SSE start lives in `currentSession.didSet` now so
        // session restore from keychain triggers the same lifecycle as
        // fresh sign-in. Don't start it here — it would double-start.
    }

    // MARK: - Presence Heartbeat

    private static let heartbeatInterval: TimeInterval = 13 * 60

    func _startHeartbeat(session: OneloSession) {
        _stopHeartbeat()
        _heartbeatTask = Task { [weak self] in
            guard let self else { return }
            // Fire immediately, then repeat on interval
            while !Task.isCancelled {
                await self._sendHeartbeat(accessToken: session.accessToken)
                try? await Task.sleep(nanoseconds: UInt64(OneloAuth.heartbeatInterval * 1_000_000_000))
            }
        }
        // SDK 3.51+: shared SSE event stream delivers `session.revoked`
        // in sub-second time. The handler was registered in `init` so it
        // survives across signin → signout cycles. Heartbeat above stays
        // as the fallback for the rare case the long-lived SSE connection
        // is blocked by a corporate firewall.
        _eventStream.start(userId: session.user.id)
    }

    func _stopHeartbeat() {
        _heartbeatTask?.cancel()
        _heartbeatTask = nil
        _eventStream.stop()
    }

    // Inline SSE listener was removed in 3.51. Auth-side delivery now flows
    // through `_eventStream` (see `init` registration and the `_handleSessionRevoked`
    // method above). Single SSE connection per app, multiplexed across modules.

    private func _sendHeartbeat(accessToken: String) async {
        let url = config.apiUrl.appendingPathComponent("/api/sdk/presence/heartbeat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // 2026-05-26: heartbeat is now a validity probe, not just a ping.
        // Backend sdk_presence.heartbeat returns 401 when:
        //   • app_users.revoked_at IS NOT NULL (cron hard-deleted)
        //   • app_users.banned_at IS NOT NULL (admin ban)
        //   • zero app_sessions for this user with revoked_at IS NULL
        //     (revoke_sdk_sessions fired — account deletion initiated,
        //     refund-induced logout, admin force-logout)
        //
        // Without acting on the 401 here, the SDK keeps the user "logged
        // in" until the access token expires (~15 min) OR the app restarts.
        // For UX consistency with backend-side revoke we need to clear
        // the session immediately on heartbeat 401.
        guard let (_, response) = try? await _urlSession.data(for: request),
              let http = response as? HTTPURLResponse else {
            return  // Network error — fail-open, next heartbeat will retry.
        }

        if http.statusCode == 401 {
            // Server says: this session is no longer valid. Clear local
            // state. The dev's UI observes currentSession via @Published
            // and re-presents OneloAuthView automatically.
            try? keychain.clear()
            currentSession = nil
            isUserRevoked = true
        }
    }

    private func backendPost(path: String, body: [String: String]) async throws -> [String: Any] {
        let url = config.apiUrl.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addStandardHeaders(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode >= 400 {
            // Detect hosted_flow_required from both Next.js {"error":"hosted_flow_required"}
            // and Python {"detail":{"error":"hosted_flow_required"}} response shapes.
            let errorCode = json["error"] as? String
                ?? (json["detail"] as? [String: Any])?["error"] as? String
            if errorCode == "hosted_flow_required" {
                let hint = json["hint"] as? String
                    ?? (json["detail"] as? [String: Any])?["hint"] as? String
                    ?? "Use OneloAuthView or presentHostedSignIn() — direct signIn/signUp is not available on the free plan."
                // .error so the dev sees it during debugging without
                // surfacing in regular user logs. Hint marked `.public`
                // because it's developer-facing (plan name etc) but
                // doesn't expose end-user PII.
                _authLog.error("hosted_flow_required: \(hint, privacy: .public)")
                _authLog.error("Fix: switch to OneloAuthView in your UI, or upgrade your Onelo plan to enable a custom auth UI.")
                throw OneloError.requiresHostedFlow
            }
            let msg = errorCode ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
            throw OneloError.serverError(msg)
        }

        return json
    }

    // MARK: - Testing support

    #if DEBUG
    /// Initializer for unit tests. Sets `_skipInitialize` before the enqueued Task runs,
    /// preventing `initialize()` from making network calls or mutating state.
    /// Tests control session state directly via `_injectSessionForTesting` / `_clearSessionForTesting`.
    convenience init(_testingConfig config: OneloConfig) {
        self.init(config: config)
        _skipInitialize = true
    }

    func _injectSessionForTesting(_ session: OneloSession) {
        currentSession = session
    }

    func _clearSessionForTesting() {
        currentSession = nil
    }
    #endif

    func backendPostAny(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = config.apiUrl.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addStandardHeaders(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode >= 400 {
            let errorCode = json["error"] as? String
                ?? (json["detail"] as? [String: Any])?["error"] as? String
            if errorCode == "hosted_flow_required" {
                let hint = json["hint"] as? String
                    ?? (json["detail"] as? [String: Any])?["hint"] as? String
                    ?? "Use OneloAuthView or presentHostedSignIn() — direct signIn/signUp is not available on the free plan."
                // .error so the dev sees it during debugging without
                // surfacing in regular user logs. Hint marked `.public`
                // because it's developer-facing (plan name etc) but
                // doesn't expose end-user PII.
                _authLog.error("hosted_flow_required: \(hint, privacy: .public)")
                _authLog.error("Fix: switch to OneloAuthView in your UI, or upgrade your Onelo plan to enable a custom auth UI.")
                throw OneloError.requiresHostedFlow
            }
            let msg = errorCode ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
            throw OneloError.serverError(msg)
        }

        return json
    }
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
