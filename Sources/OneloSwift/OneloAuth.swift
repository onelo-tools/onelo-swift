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
            // A different user (or signing out) starts a new token-refusal
            // episode for the Features calls. The same user — a refresh
            // republishing the session — does not: that is what keeps a
            // persistently refused token from looping refresh → call → refresh.
            if oldValue?.user.id != currentSession?.user.id { userToken.reset() }
            // "Allowed in" depends on the session AND on the entitlement carried
            // inside it, so it has to be recomputed on every republish — not only
            // when the session appears or disappears.
            _recomputeAllowedIn()
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
    @Published public private(set) var isReady: Bool = false { didSet { _recomputeAllowedIn() } }

    /// **Should this user see your app?** — the one question a host app actually
    /// needs, published so you can drive your own windows from it.
    ///
    /// `true` only when the session is restored (`isReady`), a session exists, and
    /// either the app has no paywall or the user holds active access.
    ///
    /// This exists because the two signals next to it answer DIFFERENT questions
    /// and were being used for this one:
    ///   • `currentSession != nil` means SIGNED IN. A user with no plan on a
    ///     paywalled app is signed in and must still NOT reach your app —
    ///     `OneloAuthView` sends them to the store or to "no active plan".
    ///     Turingo shipped that mistake on 2026-08-17 and let plan-less users in.
    ///   • `hasActiveAccess` means HAS A PAID GRANT. On an app with no paywall it
    ///     is false for everyone, so gating on it locks out every legitimate user.
    ///
    /// `isReady` is part of the condition on purpose: `paywallEnabled` arrives with
    /// the remote config, and before it lands it is `false` — so a check written
    /// without it says "allowed in" to everyone for the first moments after launch.
    ///
    /// ```swift
    /// auth.$isAllowedIn.sink { allowed in if allowed { self.showApp() } }
    /// ```
    @Published public private(set) var isAllowedIn: Bool = false

    /// The SERVER'S answer when it gave one; the legacy derivation only when it
    /// did not.
    ///
    /// `!paywallEnabled || hasActiveAccess` lived here, in the JS SDK and in
    /// Flutter — three copies of one rule, and each was found wrong on a
    /// different day (the JS one answered "allowed" while its config was still
    /// loading, letting a plan-less user into a paid app). Onelo computes it now
    /// in `app/lib/access_gate.user_access_payload` and ships it with the user.
    ///
    /// `isReady` and the session check stay local: they are facts about THIS
    /// client, not policy. A stored session says who someone is; only the server
    /// says whether they may be here.
    private func _recomputeAllowedIn() {
        guard isReady, let session = currentSession else {
            if isAllowedIn { isAllowedIn = false }
            return
        }
        // Older backend: no `allowed_in` in the payload. Falling back keeps an
        // SDK released ahead of the server from locking every user out. It is a
        // COMPATIBILITY path, not a second source of truth, and goes away once
        // the field is everywhere.
        let next = session.user.allowedIn ?? (!paywallEnabled || hasActiveAccess)
        if next != isAllowedIn { isAllowedIn = next }
    }
    /// True while an auto-login restore of a stored session is in flight (Keychain
    /// read → backend verify/refresh). Distinguishes "restoring an existing
    /// session" from "no session, show sign-in" so the UI can paint a branded
    /// splash on cold-start auto-login instead of flashing the sign-in form (#36).
    /// Set at the start of `restoreSession()` (true iff a complete stored session
    /// exists) and cleared on every exit path.
    @Published public private(set) var isRestoringSession: Bool = false
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
    @Published public private(set) var attestToken: String? {
        didSet {
            // OneloAuth is the SINGLE PRODUCER of the attest bearer. Publishing it
            // to the shared `_OneloSecurityContext` here is the ONE write that
            // reaches EVERY transport at once — the auth URLSession, the shared
            // REST/features client, the SSE stream client, and the monitor — since
            // they all read the same context by reference. This replaced the old
            // "mirror the token into each transport's own field" model, where the
            // features/stream SSE transport was silently left unmirrored and 403'd
            // `attest_invalid` in a permanent reconnect loop (#34), while auth
            // endpoints (which read the token here) passed 200 with the same token.
            // didSet doesn't fire during init, and `securityContext` is created
            // before the first (post-init, async) attestToken assignment, so this
            // is always safe.
            securityContext.attestToken = attestToken
        }
    }
    #if canImport(DeviceCheck)
    /// Last App Attest failure, if attestation was attempted and failed. `nil` when
    /// attestation has not run, is not required, or last succeeded. A security
    /// mechanism must never fail silently — observe this (and check the unified log,
    /// subsystem `io.onelo.sdk`, category `attest`) to see why `attestToken` is nil.
    @Published public private(set) var attestError: OneloAttestError?
    #endif
    /// #25 — max time a gated entry point waits (polling) for background App
    /// Attest to set `attestToken` before proceeding tokenless. Covers a
    /// slow-but-working handshake (~3-4 round trips) while capping a stalled
    /// network so the auth flow never hangs.
    private static let attestWaitCapMs: Int = 5000
    /// App name returned by /initiate — shown before the hosted page opens.
    @Published public private(set) var hostedAppName: String = "App"
    /// App logo URL returned by /initiate — shown before the hosted page opens, if set.
    @Published public private(set) var hostedAppLogoUrl: URL? = nil
    /// True while a hosted-callback code is being exchanged for a session (via the
    /// in-app WebView OR an external-browser deep-link). `OneloAuthView` reads it
    /// to avoid flashing a fresh sign-in WebView while a login is completing.
    @Published public private(set) var isExchangingCode: Bool = false

    /// A hosted surface the app must show because the Access Gate refused a
    /// sign-in that finished OUTSIDE the WebView — today, a magic link.
    ///
    /// `OneloAuthView` observes this and loads it. Nothing here interprets the
    /// URL: which screen it is, and what it says, is settled server-side.
    /// Cleared by `clearPendingGate()` once presented, so a later re-resolve
    /// does not reopen a screen the user already dismissed.
    @Published public private(set) var pendingGateUrl: URL? = nil

    /// Called by the view once it has presented `pendingGateUrl`.
    public func clearPendingGate() { pendingGateUrl = nil }
    /// True if SDK gate is active — `OneloAuthView` opens the store instead of sign-in.
    @Published public private(set) var paywallEnabled: Bool = false { didSet { _recomputeAllowedIn() } }
    /// False on an Apple-store build whose app has not opted into showing the
    /// store in-app (App Review guideline 3.1.1). `paywallEnabled` stays true —
    /// the plan requirement is real, it simply cannot be satisfied here, so the
    /// sign-up affordance is hidden and the buyer purchases on the web.
    /// Defaults true so an older backend behaves exactly as before.
    @Published public private(set) var inAppStoreAllowed: Bool = true
    /// Branding page background hex (`checkout_bg_color`, default `#111111`) from
    /// `/api/sdk/config`. `OneloAuthView` parses + paints it so the pre-auth /
    /// loading frame matches the hosted page instead of flashing a system colour
    /// (#26). Nil until config resolves (view falls back to the config default).
    @Published public private(set) var pageBackgroundColorHex: String?
    /// Branding "Brand color" hex (`primary_color`) from `/api/sdk/config` (#601).
    /// SDK-drawn controls shown before a hosted page loads (the retry "Sign In"
    /// button) paint it; nil until config resolves or when the app has none →
    /// neutral grey, never Onelo orange.
    @Published public private(set) var brandPrimaryColorHex: String?
    /// The app's resolved brand tokens (#681) — the ONE model every piece of
    /// this SDK's native chrome paints from. `/api/sdk/config` sets it (cached in
    /// the keychain for the next launch's first paint); a store / portal /
    /// upgrade initiate response carrying `brand_tokens` refreshes it. `.neutral`
    /// before any of that — never Onelo orange.
    @Published public private(set) var brandTokens: OneloBrandTokens = .neutral

    /// Adopt the branding a config / initiate response body carries (#681).
    /// No-op when the body carries none.
    func adoptBrandTokens(fromJSON json: [String: Any]) {
        guard let t = OneloBrandTokens.from(json: json) else { return }
        setBrandTokens(t)
    }

    private func setBrandTokens(_ t: OneloBrandTokens) {
        guard t != brandTokens else { return }
        brandTokens = t
        if let json = try? JSONEncoder().encode(t), let s = String(data: json, encoding: .utf8) {
            try? keychain.set(s, forKey: KeychainKeys.brandTokens)
        }
    }
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
    /// #818 — should your own sign-up screen ask for Marketing Consent, and
    /// with what text (in the device language). From `/api/sdk/config`.
    @Published public private(set) var signupMarketingConsent: OneloSignupMarketingConsent = .notAsked

    private var client: AuthClient?
    private let keychain: any OneloSessionStorage
    let config: OneloConfig

    /// Callback URL scheme registered for this SDK instance, exposed for
    /// SwiftUI helpers (e.g. `OneloCustomerPortalView`) that need to
    /// know which scheme to watch the embedded WKWebView for.
    public var callbackScheme: String { config.callbackScheme }
    private var pkceVerifier: String?

    /// Verifier bound to the CURRENT hosted flow (`/auth/initiate`, `/flow/init`).
    /// Mirrored into the Keychain so a deep link that relaunches the app can still
    /// complete the exchange. See `KeychainKeys.flowVerifier`.
    private var flowVerifier: String?
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

    /// Single source of truth for the attest bearer + macOS codesign fingerprint,
    /// shared BY REFERENCE with every other transport (see `_OneloSecurityContext`).
    /// OneloAuth is the producer: it writes `attestToken` here via didSet and seeds
    /// the codesign fingerprint at init. Exposed so the top-level `Onelo` wrapper
    /// can hand the SAME instance to the shared REST client and the monitor — one
    /// context, every transport, nothing to keep in sync.
    let securityContext: _OneloSecurityContext

    /// Shared SSE event stream owned by this auth instance. Other Onelo
    /// modules (OneloFeatures, future OneloPaywall realtime) attach their
    /// handlers to this same stream via `eventStream.on(...)`.
    public var eventStream: OneloEventStream { _eventStream }

    /// The signed-in user's access token for the Features calls and the Event
    /// Stream (#519): read fresh per call (an expired one is refreshed first),
    /// refreshed at most once per refusal episode.
    lazy var userToken: _OneloUserToken = _OneloUserToken(
        current: { [weak self] in await self?._accessTokenForFeatures() },
        refresh: { [weak self] in (try? await self?.refreshSession())??.accessToken }
    )

    /// In-flight `refreshSession()`, shared by concurrent callers (the scheduled
    /// refresh, a refused Features token, a manual call). Without it two callers
    /// present the same rotating refresh token and the second is refused — which
    /// clears the session and signs the user out.
    private var _refreshInFlight: Task<OneloSession?, Error>?
    /// Refresh this many seconds before the access token expires.
    private let _refreshLeadTime: TimeInterval = 60
    /// Consecutive transient refresh failures (offline, a lost response, 429,
    /// 5xx — incl. `503 refresh_unavailable`). Drives the retry backoff:
    /// 5 s, 10 s, 20 s, 40 s, then every 60 s. Reset by the next good refresh.
    private var _refreshRetryAttempt = 0
    /// Until then no caller starts a refresh on its own — the scheduled retry
    /// owns it (no hammering /auth/refresh during an outage).
    private var _refreshBackoffUntil: Date?
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
        static let checkoutBgColor = "checkout_bg_color"
        /// #681 — the resolved brand tokens JSON, for the next launch's first paint.
        static let brandTokens = "brand_tokens"
        /// PKCE verifier for a hosted flow that may OUTLIVE this process.
        ///
        /// Deliberately a separate slot from the in-memory `pkceVerifier`, which
        /// `resolveConfig()` regenerates on every launch. A magic link can relaunch
        /// a killed app minutes later; if the exchange used the rotating verifier
        /// it would never match the challenge bound when the link was requested,
        /// and every cold-start sign-in would fail. Two slots, no clobbering.
        static let flowVerifier = "flow_code_verifier"
        /// Origin (`https://host`) where Onelo hosts this app's surfaces.
        ///
        /// Persisted for the same reason as `flowVerifier` directly above: a
        /// magic link can relaunch a process that was killed, and the deep link
        /// arrives before anything has spoken to the backend. Without a stored
        /// value there is nothing to check an incoming gate URL against, and the
        /// only safe answer would be to refuse it.
        static let hostedOrigin = "hosted_origin"
        /// When `flowVerifier` was issued, as epoch seconds. Persisted beside it
        /// so a relaunch can still tell whether the outstanding verifier is
        /// inside its reuse window — see `_beginFlowPKCE`.
        static let flowVerifierIssuedAt = "flow_code_verifier_issued_at"
    }

    public convenience init(config: OneloConfig) {
        self.init(config: config, storage: OneloSessionStorageFactory.production())
    }

    /// Designated initializer: `storage` holds the session and launch caches.
    /// Apps go through `init(config:)` (the Keychain); tests pass an in-memory
    /// store so they never touch the real Keychain (#732).
    init(config: OneloConfig, storage: any OneloSessionStorage) {
        self.config = config
        self.keychain = storage
        self._urlSession = .shared
        let ctx = _OneloSecurityContext()
        #if os(macOS)
        // Seed the codesign fingerprint eagerly — it's static for the running
        // binary, so it's available synchronously at init (unlike the attest
        // token, which arrives async). This makes it ride the FIRST request on
        // every transport, before attestation completes.
        ctx.codesignFingerprint = OneloCodesignFallback.codesignFingerprint()
        #endif
        self.securityContext = ctx
        let httpClient = _OneloHTTPClient(publishableKey: config.publishableKey, baseURL: config.apiUrl, securityContext: ctx)
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
        // #635: this user's grant changed (purchase, switch, refund, pause…).
        // The backend sends it only to this user's streams, right after the
        // fresh `features_updated`; re-read the entitlement so
        // `hasActiveAccess` follows.
        self._eventStream.on("paywall.access_changed") { [weak self] _ in
            Task { @MainActor in _ = await self?.revalidateEntitlement() }
        }
        // A blocking legal version just took effect → bump the revision so
        // OneloAuthView re-checks consent and shows the gate immediately.
        self._eventStream.on("legal.consent_required") { [weak self] _ in
            Task { @MainActor in self?.consentRevision += 1 }
        }
        self._eventStream.userToken = self.userToken
        OneloAuth.validateCallbackSchemeRegistration(config.callbackScheme)
        // Seed the cached provider list so the loading skeleton draws the right
        // number of social pills on the FIRST paint, before resolveConfig lands.
        if let cached = try? keychain.get(forKey: KeychainKeys.oauthProviders), !cached.isEmpty {
            oauthProviders = cached.split(separator: ",").map(String.init)
        }
        // #26 — seed the cached branding background so the auth frame paints the
        // right colour on the FIRST paint (before resolveConfig lands), not a
        // system-colour flash.
        if let cachedBg = try? keychain.get(forKey: KeychainKeys.checkoutBgColor), !cachedBg.isEmpty {
            pageBackgroundColorHex = cachedBg
        }
        // #681 — seed the cached brand tokens for the same first-paint reason.
        if let cached = try? keychain.get(forKey: KeychainKeys.brandTokens),
           let t = try? JSONDecoder().decode(OneloBrandTokens.self, from: Data(cached.utf8)) {
            brandTokens = t
        }
        // #36 — seed `isRestoringSession` SYNCHRONOUSLY here, BEFORE the async
        // `initialize()`/`restoreSession()` Task starts and BEFORE `isReady=true`.
        // Otherwise `OneloAuthView.onReceive(restoringSessionPublisher)` gets the
        // default @Published value (false) on subscribe and clobbers the view's own
        // `hasStoredSessionSync()` seed → the sign-in skeleton flashes in the
        // `isReady=true → restore-done` window. `restoreSession()`'s `defer` still
        // clears it; the non-restore init paths clear it explicitly (below).
        isRestoringSession = hasStoredSessionSync()
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
    init(config: OneloConfig, urlSession: URLSession, skipInitialize: Bool, storage: any OneloSessionStorage) {
        self.config = config
        self.keychain = storage
        self._urlSession = urlSession
        self._skipInitialize = skipInitialize
        let ctx = _OneloSecurityContext()
        #if os(macOS)
        ctx.codesignFingerprint = OneloCodesignFallback.codesignFingerprint()
        #endif
        self.securityContext = ctx
        let httpClient = _OneloHTTPClient(publishableKey: config.publishableKey, baseURL: config.apiUrl, securityContext: ctx)
        self._httpClient = httpClient
        self._eventStream = OneloEventStream(httpClient: httpClient)
        self._eventStream.userToken = self.userToken
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

    /// The stored user's id, read synchronously from the Keychain (nil when none).
    /// Lets Features show that user's persisted snapshot on the first paint while
    /// the session is still being restored (onelo-swift-staging#1).
    nonisolated func storedUserIdSync() -> String? {
        guard let json = try? keychain.get(forKey: KeychainKeys.userJson),
              let data = json.data(using: .utf8),
              let user = try? JSONDecoder().decode(OneloUser.self, from: data),
              !user.id.isEmpty
        else { return nil }
        return user.id
    }

    /// Synchronous check for a restorable stored session — true iff the Keychain
    /// holds a COMPLETE, decodable session (the same fields `restoreSession()`
    /// requires), or only a refresh token, which `restoreSession()` turns into a
    /// session with one refresh (a session migrated from the legacy shared
    /// Keychain, #740). Nonisolated + synchronous, so a view can call it during
    /// construction to decide, on the FIRST paint, whether a cold start is an
    /// auto-login (paint a branded splash) or a genuine signed-out start (show
    /// the sign-in form). Without this the SDK can't tell the two apart until the
    /// async restore/verify resolves, so it flashes the sign-in skeleton (#36).
    public nonisolated func hasStoredSessionSync() -> Bool {
        if hasRefreshTokenOnlySync() { return true }
        guard
            (try? keychain.get(forKey: KeychainKeys.accessToken)) != nil,
            (try? keychain.get(forKey: KeychainKeys.refreshToken)) != nil,
            let expiresAtStr = try? keychain.get(forKey: KeychainKeys.expiresAt),
            TimeInterval(expiresAtStr) != nil,
            let userJsonStr = try? keychain.get(forKey: KeychainKeys.userJson),
            let userJson = userJsonStr.data(using: .utf8),
            let user = try? JSONDecoder().decode(OneloUser.self, from: userJson),
            !user.id.isEmpty
        else { return false }
        return true
    }

    /// True when the store holds a refresh token and no access token: the shape a
    /// session migrated from the legacy shared Keychain has (#740). Only the
    /// refresh token is migrated, so the legacy read can prompt at most once.
    private nonisolated func hasRefreshTokenOnlySync() -> Bool {
        (try? keychain.get(forKey: KeychainKeys.accessToken)) == nil
            && (try? keychain.get(forKey: KeychainKeys.refreshToken)) != nil
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
        // Refresh the SERVER'S ANSWER too, not just the ingredient. This call is
        // what runs right after a purchase, and `isAllowedIn` now reads
        // `allowedIn` — so updating only the entitlement would leave the stored
        // answer saying "no" for someone who had just paid, locked out by the
        // very refresh meant to let them in. Absent in the response keeps the
        // previous value rather than erasing it (older backend).
        // #819: allowedIn, emailVerified and accessReason move together.
        let updatedUser = session.user.mergingAccessAnswer(json, entitlement: ent)
        if ent != session.user.entitlement
            || updatedUser.allowedIn != session.user.allowedIn
            || updatedUser.emailVerified != session.user.emailVerified
            || updatedUser.accessReason != session.user.accessReason {
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

    /// Wait until the SDK has finished `initialize()`, or throw
    /// `OneloError.timeout` after `timeout` seconds.
    ///
    /// ── The timeout used to be decorative (fixed 2026-08-17) ────────────────
    /// The previous version checked the deadline INSIDE `for await ready in
    /// $isReady.values`, so the check only ran when the publisher emitted. A
    /// `@Published` publisher emits its current value on subscribe and then only
    /// on change — so when `isReady` never flips, the loop saw `false` once (0 s
    /// elapsed, deadline not passed) and then awaited an emission that never
    /// came. **It waited forever.** The 5 s only ever fired if something else
    /// was already republishing.
    ///
    /// That was not academic. It hung:
    ///   - `handleAuthCallback(_:)`, which awaits this before exchanging a code —
    ///     i.e. the magic-link / deep-link return, precisely the cold-start path
    ///     where `initialize()` may not have settled or may have failed;
    ///   - `OneloAuthModule.awaitReady(timeout:)`, the public facade the Monitor
    ///     snippet tells developers to call at startup ("default 5s timeout").
    ///     A tenant whose network was down got a permanently hung launch.
    /// It also hung `HandleAuthCallbackTests`, which builds an `OneloAuth` with
    /// `skipInitialize: true` — a process was found still running after 5 h 15 m,
    /// and the same hang on `macos-latest` ran to the 6-hour job limit and burned
    /// the month's Actions allowance. See docs/ci-cost-controls.md.
    ///
    /// The deadline now runs as its own task, so it fires whether or not the
    /// publisher ever emits again. Returning normally still means "ready".
    public func awaitReady(timeout: TimeInterval = 5) async throws {
        if isReady { return }

        let becameReady = await withTaskGroup(of: Bool.self) { group -> Bool in
            // Waiter: completes true the moment `isReady` turns true. Returns
            // false if the publisher finishes without that ever happening.
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                for await ready in self.$isReady.values where ready { return true }
                return false
            }
            // Deadline: independent of the publisher. This is the whole fix.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            // First finisher wins; cancel the loser so neither task outlives us.
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !becameReady {
            throw OneloError.timeout("awaitReady exceeded \(timeout)s")
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

        await _awaitAttestReady()  // #25: same gated /auth/initiate as _initiateAuthFlow — wait for the token

        // 1. Get one-time token + hosted URL
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/auth/initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
            // Binds the resulting code to THIS client. Optional server-side, so an
            // older backend simply ignores it. It is also what pairs a magic link
            // requested from this sheet: opened on another device, the link shows
            // a code screen and the sign-in completes here (#540/#541).
            URLQueryItem(name: "code_challenge", value: _beginFlowPKCE()),
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

        // 2. Open hosted page via ASWebAuthenticationSession, parked so that a
        //    return the OS delivers OUTSIDE the session (a magic link opened in
        //    Mail on this device → `handleAuthCallback`) settles it too.
        let hostedReturn = try await _awaitHostedReturn { complete in
            let session = ASWebAuthenticationSession(
                url: hostedUrl,
                callbackURLScheme: scheme
            ) { url, error in
                complete(Self._mapAuthSessionCompletion(url: url, error: error))
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            session.start()
            return { session.cancel() }
        }

        switch hostedReturn {
        case .session(let session):
            // `handleAuthCallback` already exchanged the code.
            return session
        case .callback(let callbackUrl):
            // 3. Extract code from callback URL
            guard
                let callbackComponents = URLComponents(url: callbackUrl, resolvingAgainstBaseURL: false),
                let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value
            else {
                throw OneloError.serverError("No code in callback URL")
            }
            // 4. Exchange with the FLOW verifier — the one whose challenge
            //    /auth/initiate bound above. This used to send `pkceVerifier`
            //    (the /api/sdk/config pair), which the backend refused with
            //    "PKCE verification failed" on every return (#541).
            return try await exchangeHostedCode(code)
        }
    }

    /// How a parked hosted sign-in ends: the session's own callback URL, or a
    /// session `handleAuthCallback` already produced from an OS deep link.
    enum _HostedSignInReturn {
        case callback(URL)
        case session(OneloSession)
    }

    /// The ASWebAuthenticationSession currently waiting in `presentHostedSignIn`.
    private var _parkedHostedSignIn: _ParkedHostedSignIn?

    /// Resumes its continuation exactly once. `cancel()` on the session can call
    /// the completion handler again with `.canceledLogin`; that second call is
    /// ignored.
    final class _ParkedHostedSignIn: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<_HostedSignInReturn, Error>?
        var cancel: (() -> Void)?

        init(_ continuation: CheckedContinuation<_HostedSignInReturn, Error>) {
            self.continuation = continuation
        }

        /// Returns false when it was already settled.
        @discardableResult
        func settle(_ result: Result<_HostedSignInReturn, Error>) -> Bool {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            guard let c else { return false }
            c.resume(with: result)
            return true
        }
    }

    /// Park a hosted presentation until it returns. `start` opens the container,
    /// hands it a completion callback and returns how to dismiss it.
    ///
    /// Internal so the park/settle contract can be tested without presenting a
    /// real ASWebAuthenticationSession.
    func _awaitHostedReturn(
        start: (@escaping (Result<URL, Error>) -> Void) -> (() -> Void)
    ) async throws -> _HostedSignInReturn {
        // A second presentation replaces the first: its sheet is gone for good.
        _settleParkedHostedSignIn(.failure(OneloError.cancelled))
        var mine: _ParkedHostedSignIn?
        defer {
            if let mine, _parkedHostedSignIn === mine { _parkedHostedSignIn = nil }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let parked = _ParkedHostedSignIn(continuation)
            mine = parked
            _parkedHostedSignIn = parked
            parked.cancel = start { result in
                parked.settle(result.map { .callback($0) })
            }
        }
    }

    /// Finish the parked hosted presentation, if one is waiting, and dismiss its
    /// sheet. Returns true when one was waiting.
    @discardableResult
    func _settleParkedHostedSignIn(_ result: Result<_HostedSignInReturn, Error>) -> Bool {
        guard let parked = _parkedHostedSignIn else { return false }
        _parkedHostedSignIn = nil
        let settled = parked.settle(result)
        // After settling, so the `.canceledLogin` this may trigger is ignored.
        parked.cancel?()
        return settled
    }

    /// ASWebAuthenticationSession's completion, as a result. The person closing
    /// the sheet is `.cancelled` — a clean state they can start again from, not
    /// an error to show.
    nonisolated static func _mapAuthSessionCompletion(url: URL?, error: Error?) -> Result<URL, Error> {
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return .failure(OneloError.cancelled)
        }
        if let error {
            return .failure(OneloError.serverError(error.localizedDescription))
        }
        guard let url else { return .failure(OneloError.serverError("No callback URL")) }
        return .success(url)
    }

    // MARK: - Hosted flow (WKWebView)


    /// Calls /api/sdk/paywall/store-initiate and returns a tokenized store URL for the WKWebView.
    /// The store page handles plan selection + payment + registration in one flow.
    /// After completion, it redirects to callbackScheme://callback?code=... — same as auth.
    public func initiateStoreFlow(lang: String = "en") async throws -> URL {
        // Fail here rather than at the server: the developer calling this from
        // their own UI on iOS gets the answer while building, not from an App
        // Review rejection weeks later. The backend 409 is still the real
        // enforcement — this only saves a round trip and reads better.
        guard inAppStoreAllowed else {
            _authLog.warning("""
                initiateStoreFlow: the in-app store is closed on Apple platforms \
                (App Review 3.1.1). Buyers purchase on your website and sign in \
                here. To take compliance on yourself, switch Paywall → Store → \
                Access Gate in the Onelo dashboard.
                """)
            throw OneloError.inAppStoreNotAllowed
        }
        await _awaitAttestReady()  // #25: /store-initiate is attestation-gated too (sdk_paywall.py)
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
            // Shared unwrapper: this endpoint's codes arrive nested inside
            // `detail`, which the flat lookup here used to miss entirely.
            let code = oneloErrorCode(from: json) ?? "store_initiate_failed"
            if code == "in_app_store_not_allowed" {
                throw OneloError.inAppStoreNotAllowed
            }
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
        adoptBrandTokens(fromJSON: json) // #681: store-initiate carries brand_tokens
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


    /// How long an issued flow verifier stays valid for REUSE.
    ///
    /// Matches the magic-link token TTL (`/magic-link`, 15 minutes): that is the
    /// longest a challenge minted here can still be waiting to come back.
    private static let flowVerifierLifetime: TimeInterval = 15 * 60

    /// The PKCE challenge for the flow being started, reusing the outstanding
    /// verifier when there still is one.
    ///
    /// ── Why this does not always mint a fresh pair (fixed 2026-08-19) ────────
    /// It used to, unconditionally — and every call OVERWROTE the persisted
    /// verifier. `OneloAuthView` calls `resolveFlow()` from 24 places (appear,
    /// ready, session change, retry, a settled exchange…), so a second flow
    /// resolving for any reason destroyed the verifier an OUTSTANDING magic link
    /// was bound to.
    ///
    /// That is not a rare race, it is the normal path: the link is requested,
    /// the user leaves for their inbox, the app re-resolves or is relaunched, and
    /// by the time they click the link the only verifier left cannot match the
    /// challenge. `/hosted-callback` correctly refuses, the app swallows it and
    /// waits on "Check your inbox" forever — exactly what Adrian hit on Turingo,
    /// with the deep link arriving and nothing happening after it.
    ///
    /// One verifier per 15-minute window is the fix. Rotating per flow was never
    /// a requirement: PKCE binds a code to THIS client, and every one of these
    /// flows is the same client on the same device. What it must not do is
    /// invalidate a credential that is still outstanding.
    ///
    /// The web SDK avoided this by giving magic link its OWN slot
    /// (`TOKEN_KEYS.MAGIC_LINK_VERIFIER`), because there `sendMagicLink()` is an
    /// SDK call. On native the hosted page requests the link, so the SDK never
    /// learns it happened and cannot set a slot aside — hence a window here.
    /// Internal, not private, so the reuse window can be tested directly — the
    /// defect it fixes is invisible from outside (a swallowed 401 much later).
    func _beginFlowPKCE() -> String {
        // Reuse while the outstanding one can still be needed. Reading the issue
        // time from the Keychain matters: a relaunch has nothing in memory.
        if let existing = _pendingFlowVerifier(), _flowVerifierIsFresh() {
            flowVerifier = existing
            return generateCodeChallenge(from: existing)
        }

        let verifier = generateCodeVerifier()
        flowVerifier = verifier
        try? keychain.set(verifier, forKey: KeychainKeys.flowVerifier)
        try? keychain.set(String(Date().timeIntervalSince1970), forKey: KeychainKeys.flowVerifierIssuedAt)
        return generateCodeChallenge(from: verifier)
    }

    /// Is the stored verifier still inside its reuse window?
    ///
    /// Fails CLOSED — an unreadable or unparsable timestamp answers false, so a
    /// fresh pair is minted. Getting this wrong in that direction costs one
    /// sign-in attempt; the other direction pins a verifier forever.
    private func _flowVerifierIsFresh() -> Bool {
        guard
            let raw = try? keychain.get(forKey: KeychainKeys.flowVerifierIssuedAt),
            let seconds = TimeInterval(raw ?? "")
        else { return false }
        let age = Date().timeIntervalSince1970 - seconds
        // A negative age means the clock moved backwards; treat it as stale
        // rather than trusting it.
        return age >= 0 && age < Self.flowVerifierLifetime
    }

    /// The verifier for the flow being completed: in memory when the app stayed
    /// alive, from the Keychain when a deep link relaunched it.
    private func _pendingFlowVerifier() -> String? {
        if let v = flowVerifier { return v }
        return try? keychain.get(forKey: KeychainKeys.flowVerifier)
    }

    /// Drop the pending verifier once it can no longer be needed. Called after a
    /// successful exchange and on sign-out — a stale one would be offered to the
    /// next flow, whose challenge it cannot match.
    func _clearFlowPKCE() {
        flowVerifier = nil
        try? keychain.delete(forKey: KeychainKeys.flowVerifier)
        // The stamp goes with it. Left behind, it would make the NEXT verifier
        // look older than it is and cut its window short.
        try? keychain.delete(forKey: KeychainKeys.flowVerifierIssuedAt)
    }

    /// Calls /api/sdk/auth/initiate and returns the raw auth URL (no routing).
    internal func _initiateAuthFlow() async throws -> URL {
        await _awaitAttestReady()  // #25: wait for the attest token before the gated initiate call
        let scheme = config.callbackScheme
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/auth/initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: scheme),
            // Every /auth/initiate caller must bind the challenge, not just the
            // one in `signInWithHostedFlow`: a code minted by an unbound call
            // could be exchanged by anyone holding it.
            URLQueryItem(name: "code_challenge", value: _beginFlowPKCE()),
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
        await _awaitAttestReady()  // #25: don't race the gated flow/init ahead of the attest token
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/flow/init"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: config.callbackScheme),
            URLQueryItem(name: "lang", value: lang),
            // Same binding as /auth/initiate — this endpoint mints the sign-in
            // token on the `present sign_in` branch, so it needs the challenge too.
            URLQueryItem(name: "code_challenge", value: _beginFlowPKCE()),
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
            // Remember WHERE Onelo hosts its surfaces for this app. The backend
            // just told us, so it is never assembled or assumed here — and it is
            // the only thing `handleAuthCallback` can check a deep-linked gate
            // URL against before loading it in a WebView.
            _rememberHostedOrigin(url)
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

    /// Mints a hosted Customer Portal URL. The portal lets the signed-in user
    /// manage subscriptions, request refunds (when within the app's
    /// `refund_window_days`), and view past invoices. Requires an active
    /// session — throws `OneloError.notAuthenticated` otherwise.
    ///
    /// Closes when the user taps "Return to app" inside the portal,
    /// which redirects to `<callbackScheme>://callback?source=portal`.
    ///
    /// - Parameter intent: `.changePlan` makes the portal open straight into
    ///   the plan picker (#606).
    public func initiateCustomerPortal(intent: OneloPortalIntent? = nil) async throws -> URL {
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
        adoptBrandTokens(fromJSON: json) // #681: portal-initiate carries brand_tokens
        if let name = json["app_name"] as? String { hostedAppName = name }
        if let logoStr = json["app_logo_url"] as? String { hostedAppLogoUrl = URL(string: logoStr) }
        return portalURL(url, intent: intent)
    }

    /// Opens the Customer Portal in the SDK's own window (#606) and returns
    /// when the user closes it: a standalone window on macOS (menu-bar and
    /// accessory apps included), a sheet over the top-most view controller on
    /// iOS. No SwiftUI host and no presentation anchor are needed.
    ///
    /// The portal renders in the embedded WebView of ``OneloCustomerPortalView``,
    /// so every hand-back reaches the app: the portal's Done, a hard account
    /// event (deletion / revoke / compromise clears the session through
    /// ``handlePortalCallback(_:)``), and a purchase or plan switch made in the
    /// store the portal opens. When the window closes, the entitlement is
    /// re-read so ``hasActiveAccess`` reflects a plan bought or changed there.
    ///
    /// - Parameter intent: `.changePlan` opens the portal straight into the
    ///   plan picker; the portal asks the backend where the change goes.
    ///   Parity with `@onelo/js` `customerPortal.open({ intent: 'change_plan' })`.
    /// - Throws: `OneloError.notAuthenticated` without a session.
    @MainActor
    public func openCustomerPortal(intent: OneloPortalIntent? = nil) async throws {
        // Mint before presenting: a signed-out user gets the error, not a window.
        let url = try await initiateCustomerPortal(intent: intent)
        await presentInPortalContainer(url)
    }

    /// Opens the Customer Portal. Since 3.93 this presents the SDK's own window
    /// exactly like ``openCustomerPortal(intent:)``; `context` is no longer
    /// used. It used ASWebAuthenticationSession, which never received the
    /// store's hand-back (#606).
    @available(*, deprecated, renamed: "openCustomerPortal(intent:)", message: "The portal opens in the SDK's own window; no presentation anchor is needed.")
    @MainActor
    public func openCustomerPortal(
        from context: ASWebAuthenticationPresentationContextProviding,
        intent: OneloPortalIntent? = nil
    ) async throws {
        try await openCustomerPortal(intent: intent)
    }

    /// Presents an already-minted hosted URL — a portal, or the store / plan
    /// switch `/upgrade-initiate` resolved — in the SDK's portal container and
    /// returns when it closes. Where nothing can be presented (iOS without a
    /// key window) it falls back to the system browser, whose return deep-link
    /// ``handlePortalCallback(_:)`` handles. Re-reads the entitlement at the end.
    @MainActor
    func presentInPortalContainer(_ url: URL) async {
        let presented = await OneloPortalPresenter.present(
            urlProvider: { url },
            renewProvider: { [weak self] in
                guard let self else { throw OneloError.notAuthenticated }
                return try await self.initiateCustomerPortal()
            },
            callbackScheme: config.callbackScheme,
            onPortalCallback: { [weak self] callbackUrl in self?.handlePortalCallback(callbackUrl) },
            brandTokens: { [weak self] in self?.brandTokens ?? .neutral }
        )
        if !presented {
            print("[Onelo] No window to present the Customer Portal in — opening the system browser.")
            #if canImport(AppKit) && os(macOS)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
            return
        }
        _ = await revalidateEntitlement()
    }

    /// Opens the hosted Customer Portal in the user's default browser
    /// via `NSWorkspace.shared.open` (macOS) / `UIApplication.shared.open`
    /// (iOS). No ASWebAuthenticationSession, no presentation context,
    /// no SwiftUI host required — just hands the URL off to the OS.
    ///
    /// Prefer ``openCustomerPortal(intent:)``: a browser tab cannot hand a
    /// finished purchase or plan switch back to the app. Wire
    /// ``handlePortalCallback(_:)`` to your URL handler when you use this.
    @MainActor
    public func openCustomerPortalInBrowser(intent: OneloPortalIntent? = nil) async throws {
        let url = try await initiateCustomerPortal(intent: intent)
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
    /// The in-app paths — `openCustomerPortal(intent:)` and
    /// `OneloCustomerPortalView` — route through this same method, so all three
    /// presentation styles behave identically. Mirrors the Electron SDK's
    /// `customerPortal.handlePortalCallback(url)`.
    @MainActor
    @discardableResult
    public func handlePortalCallback(_ url: URL) -> Bool {
        // The one Store Hand-back decoder (#615).
        guard let hb = classifyHandBack(url) else { return false }
        if case .portalClosed(let event) = hb {
            applyPortalEvent(event)
            return true
        }
        // A purchase or plan switch finished in the store the portal opened:
        // reconcile the plan now, not when the stream catches up (#659). No
        // code exchange — the buyer is already signed in.
        guard let change = OneloPlanChange(hb) else { return false }
        reportPlanChange(change)
        return true
    }

    /// Set by `Onelo` to its plan-change refresher (#659).
    var planChangeHandler: ((OneloPlanChange) -> Void)?

    /// A hosted container finished a purchase or a plan switch. Internal: the
    /// SDK's own containers call it; `Onelo` reconciles features + entitlement.
    func reportPlanChange(_ change: OneloPlanChange) {
        planChangeHandler?(change)
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
        // The FLOW verifier first: it is the one whose challenge was bound to the
        // token this code hangs off, and the only one that survives a relaunch.
        // `pkceVerifier` is the rotating /api/sdk/config pair and is kept as a
        // fallback purely for tokens minted before the flow binding existed.
        if let verifier = _pendingFlowVerifier() ?? pkceVerifier { body["code_verifier"] = verifier }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        addStandardHeaders(&request)
        // #38 — hosted-callback is replay-guarded → attach the assertion.
        await applyAuthAssertion(to: &request, body: bodyData)
        let (data, response) = try await _urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // One attempt, no retry. The verifier stays stored: the backend checks
            // PKCE before it spends the code, so the link is still usable after a
            // "code_verifier required" / "PKCE verification failed" refusal.
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw OneloError.serverError(Self._exchangeFailureMessage(json))
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
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        // The gate answer arrives with the session it belongs to.
        let user = OneloUser.fromWire(userData, id: userId)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        // The flow is finished, so the persisted verifier can only mismatch the
        // next one's challenge. Left behind it would be offered to that flow and
        // rejected, turning a fresh sign-in into an unexplained failure.
        _clearFlowPKCE()
        // A hosted flow can chain sign-in → store, so a code may carry a
        // purchase: reconcile the plan at once (#659). A plain sign-in costs
        // one extra resolve.
        reportPlanChange(.purchase)
        return session
    }

    /// The backend's reason for a refused exchange. FastAPI puts it in `detail`
    /// ("code_verifier required", "PKCE verification failed", "Code already
    /// used"); older handlers used `error`.
    nonisolated static func _exchangeFailureMessage(_ json: [String: Any]) -> String {
        let reason = (json["detail"] as? String) ?? (json["error"] as? String)
        guard let reason, !reason.isEmpty else { return "Code exchange failed" }
        return "Code exchange failed: \(reason)"
    }

    /// Record the origin serving this app's hosted surfaces, as told by the
    /// backend. Never parsed out of a value that arrived from outside.
    /// Internal, not private, so tests can prime the trust anchor the same way
    /// the backend does — the security guard below is meaningless without a test
    /// that proves a FOREIGN origin is refused.
    func _rememberHostedOrigin(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return }
        try? keychain.set("https://\(host)", forKey: KeychainKeys.hostedOrigin)
    }

    /// Is this URL one of Onelo's own hosted surfaces for this app?
    ///
    /// Fails CLOSED: an unknown origin, a non-https URL, or no remembered origin
    /// at all all answer false. The cost of a false negative is that the app
    /// re-resolves the flow and shows sign-in — recoverable in one tap. The cost
    /// of a false positive is loading an attacker's page inside the app's own
    /// sign-in window, which is not.
    private func _isOneloHostedSurface(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        // Any origin the backend has named for this app. `storeUrl`/`manageUrl`
        // are included because a cold start may have neither a remembered origin
        // nor a resolved flow yet, while config has already been restored.
        let known = [
            try? keychain.get(forKey: KeychainKeys.hostedOrigin),
            storeUrl?.absoluteString,
            manageUrl?.absoluteString,
        ]
        .compactMap { $0 }
        .compactMap { URL(string: $0)?.host?.lowercased() }

        return known.contains(host)
    }

    /// Complete a hosted sign-in from a deep link the OS handed your app.
    ///
    /// Needed for any flow that finishes OUTSIDE the SDK's WebView — a magic link
    /// is the reason it exists: the email opens in the browser, the browser hands
    /// the code back over your registered scheme, and the app may not even have
    /// been running. Wire it from SwiftUI's `.onOpenURL` or AppKit/UIKit's
    /// `application(_:open:options:)`:
    ///
    /// ```swift
    /// .onOpenURL { url in Task { try? await onelo.auth.handleAuthCallback(url) } }
    /// ```
    ///
    /// Returns the session on success, `nil` when the URL is not one of ours (so
    /// you can pass every incoming URL through without pre-filtering). Only the
    /// canonical `<scheme>://callback?code=…` shape is honoured — the same guard
    /// the WebView coordinator applies, so a crafted `myapp://anything?code=…`
    /// cannot smuggle a foreign code into the exchange.
    ///
    /// Safe on a cold start: it waits for session restoration to settle before
    /// exchanging, because a link can relaunch a killed process and the verifier
    /// it needs is read back from the Keychain.
    ///
    /// When `presentHostedSignIn` is waiting on its sheet, a successful exchange
    /// here also finishes that call with the same session and closes the sheet.
    @MainActor
    @discardableResult
    public func handleAuthCallback(_ url: URL) async throws -> OneloSession? {
        guard
            url.scheme?.lowercased() == config.callbackScheme.lowercased(),
            url.host?.lowercased() == "callback",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        // ── A refusal, not a sign-in ─────────────────────────────────────────
        // The person proved who they are and the Access Gate said no, so there
        // is deliberately no code to exchange: the backend withholds it rather
        // than letting the app decide. WHICH screen they are owed — the store or
        // "No active plan" — was decided server-side, and this SDK carries that
        // URL without reading, parsing or branching on it.
        //
        // Before this existed, the refusal could only be shown in the browser
        // tab the email opened, and the app was never told anything: the user
        // saw "No active plan" in Safari while the app sat on "Check your inbox"
        // forever (Turingo, 2026-08-19).
        if let gate = items.first(where: { $0.name == "gate" })?.value,
           let gateUrl = URL(string: gate),
           // Only ever an Onelo-hosted surface. This value arrives over a custom
           // scheme, which ANY app on the device can fire at us, and it goes on
           // to be loaded in a WebView — so an unchecked value here is a
           // phishing page wearing the app's own sign-in window.
           _isOneloHostedSurface(gateUrl) {
            #if os(macOS)
            NSApplication.shared.activate(ignoringOtherApps: true)
            #endif
            try? await awaitReady()
            pendingGateUrl = gateUrl
            return nil
        }

        // A store finished in the SYSTEM BROWSER with a plan switch and no
        // code: nothing to exchange, but the plan moved (#659).
        if case .switched(let reason)? = classifyHandBack(url) {
            reportPlanChange(.switched(reason: reason))
            return nil
        }

        guard
            let code = items.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else { return nil }

        #if os(macOS)
        // Bring the app forward. The OS delivers the URL but does NOT focus us, so
        // when the browser sits on another display or Space the user watches a
        // "returning you to the app" page while the app signs in silently
        // somewhere they cannot see (Adrian, 2026-08-17). Activating is legitimate
        // here and nowhere else: the user just clicked a link whose entire purpose
        // is to come back to this app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif

        // A relaunch reaches this before `initialize()` has settled. Exchanging
        // now would race the restore and could publish a session that the restore
        // then overwrites; waiting costs nothing on a warm app (already ready).
        try? await awaitReady()
        let session = try await exchangeHostedCode(code)
        // A same-device return arrives here, OUTSIDE a waiting
        // `presentHostedSignIn` sheet; finish that sheet with this session. A
        // failed exchange leaves the sheet open: the hosted page there can still
        // resend the link or finish another way.
        _settleParkedHostedSignIn(.success(.session(session)))
        return session
    }

    /// Sign in — goes through Onelo backend to track last_seen_at and validate app access.
    public func signIn(email: String, password: String) async throws -> OneloSession {
        isLoading = true
        defer { isLoading = false }

        return try await _signInAttempt(email: email, password: password, isRetry: false)
    }

    private func _signInAttempt(email: String, password: String, isRetry: Bool) async throws -> OneloSession {
        if !isRetry { await _awaitAttestReady() }  // #25: gated POST — wait for the attest token (retry already has it)
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

        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        // #819: the access answer (allowed_in / email_verified / access_reason)
        // travels with the user — dropping it fell back to the local rule.
        let user = OneloUser.fromWire(userData, id: userId)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    /// Sign up — registers via Onelo backend so the user is tracked in app_users.
    /// Returns `true` if email verification is required.
    ///
    /// `marketingConsent` (#818): the person ticked the Marketing Consent
    /// checkbox your screen showed with `signupMarketingConsent.text`. Never
    /// pre-tick it; sent only when true.
    public func signUp(email: String, password: String) async throws -> Bool {
        try await signUp(email: email, password: password, marketingConsent: false)
    }

    /// Sign up with the person's Marketing Consent choice (#818). See
    /// `signUp(email:password:)` and `signupMarketingConsent`.
    public func signUp(email: String, password: String, marketingConsent: Bool) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        return try await _signUpAttempt(
            email: email, password: password, marketingConsent: marketingConsent, isRetry: false
        )
    }

    private func _signUpAttempt(
        email: String, password: String, marketingConsent: Bool, isRetry: Bool
    ) async throws -> Bool {
        if !isRetry { await _awaitAttestReady() }  // #25: gated POST — wait for the attest token (retry already has it)
        if pkceVerifier == nil {
            guard !isRetry else { throw OneloError.serverError("SDK not ready — call after isReady") }
            try await refreshPKCE()
        }
        guard let verifier = pkceVerifier else {
            throw OneloError.serverError("SDK not ready — call after isReady")
        }

        var body: [String: Any] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
            "code_verifier": verifier,
        ]
        if marketingConsent {
            // #818: in the language of the text the screen showed.
            body["marketing_consent"] = true
            body["lang"] = signupMarketingConsent.language ?? OneloSignupMarketingConsent.deviceLanguage
        }

        let json: [String: Any]
        do {
            json = try await backendPost(path: "/api/sdk/auth/signup", body: body)
        } catch OneloError.serverError(let msg) where msg.contains("PKCE") && !isRetry {
            pkceVerifier = nil
            try await refreshPKCE()
            return try await _signUpAttempt(
                email: email, password: password, marketingConsent: marketingConsent, isRetry: true
            )
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
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            // #819: same as sign-in — the access answer travels with the user.
            let user = OneloUser.fromWire(userData, id: userId)
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

        // A pending flow verifier belongs to the session being ended. Keeping it
        // would hand the next sign-in a verifier that cannot match its challenge.
        _clearFlowPKCE()

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
        _refreshRetryAttempt = 0
        _refreshBackoffUntil = nil
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

    /// Send the signed-in user a fresh Email Verification link (#819).
    ///
    /// Only for apps with their own screen: when the parent App requires Email
    /// Verification, the hosted flow (`OneloAuthView`) already shows "check your
    /// inbox" with a resend button and hands the session back by itself. The
    /// previous link stops working; at most 3 e-mails an hour
    /// (`.verificationRateLimited`). Throws `.emailVerificationOff` when the App
    /// has Email verification Off.
    ///
    /// `redirectTo` — your own landing (an allowed web origin, or
    /// `<your-scheme>://…`); the link then carries `onelo_verify_token` for
    /// `confirmEmail(token:)`. `nil` opens Onelo's hosted page.
    @discardableResult
    public func resendVerificationEmail(redirectTo: String? = nil) async throws -> OneloVerificationResend {
        guard let session = currentSession else { throw OneloError.notAuthenticated }
        var body: [String: Any] = ["publishableKey": config.publishableKey]
        if let redirectTo { body["verify_redirect_to"] = redirectTo }
        let (status, json) = try await _postVerification(
            "/api/sdk/auth/verify-email/resend", body: body, bearer: session.accessToken
        )
        guard status == 200 else { throw verificationError(status: status, json: json) }
        return OneloVerificationResend(
            sent: json["sent"] as? Bool ?? false,
            emailVerified: json["email_verified"] as? Bool ?? false
        )
    }

    /// Confirm the user's address with the `onelo_verify_token` your own landing
    /// received from the verification link (#819). Single use. When a session
    /// is signed in on this device it is refreshed, so `isAllowedIn` opens the
    /// app without waiting — never by re-reading `/api/sdk/auth/user`, which
    /// caches its answer per token for 30 s.
    public func confirmEmail(token: String) async throws {
        let (status, json) = try await _postVerification(
            "/api/sdk/auth/verify-email/confirm",
            body: ["publishableKey": config.publishableKey, "token": token],
            bearer: nil
        )
        guard status == 200 else { throw verificationError(status: status, json: json) }
        if currentSession != nil {
            do {
                _ = try await refreshSession()
            } catch {
                // The address IS confirmed; the next scheduled refresh or
                // foreground revalidation carries the new answer.
                _authLog.warning("confirmEmail: session refresh after confirming failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func _postVerification(
        _ path: String, body: [String: Any], bearer: String?
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: config.apiUrl.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        addStandardHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await _urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneloError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, json)
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
    ///
    /// Single-flight: concurrent callers share one `/auth/refresh`, so a rotating
    /// refresh token is never presented twice.
    public func refreshSession() async throws -> OneloSession? {
        if let running = _refreshInFlight { return try await running.value }
        let task = Task { @MainActor in try await self._refreshOnce() }
        _refreshInFlight = task
        defer { if _refreshInFlight == task { _refreshInFlight = nil } }
        return try await task.value
    }

    /// The signed-in user's access token for a Features call, or nil when no
    /// Onelo user is signed in. A token at (or within 30 s of) expiry is
    /// refreshed first, so an expired one is not sent when a fresh one can be had.
    func _accessTokenForFeatures() async -> String? {
        guard let session = currentSession else { return nil }
        if session.expiresAt.timeIntervalSinceNow < 30, !_inRefreshBackoff {
            _ = try? await refreshSession()
        }
        return currentSession?.accessToken
    }

    private func _refreshOnce() async throws -> OneloSession? {
        #if DEBUG
        if let override = _refreshOverrideForTesting { return try await override() }
        #endif
        return try await _performRefreshSession()
    }

    #if DEBUG
    /// Test seam: replaces the `/auth/refresh` round trip (which reads the
    /// Keychain) so the single-flight wrapper around it can be tested.
    var _refreshOverrideForTesting: (@MainActor () async throws -> OneloSession?)?
    #endif

    private func _performRefreshSession() async throws -> OneloSession? {
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Offline, or the response was lost after the server rotated the
            // token. Keep the session; the retry re-reads the Keychain and lands
            // inside the server's 30 s grace window.
            if epoch == _signOutEpoch { _scheduleRefreshRetry() }
            throw error
        }
        // A signOut() landed while this refresh was in flight — abandon it.
        // Don't re-save tokens or republish the session; the user is signed out.
        guard epoch == _signOutEpoch else { return nil }
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 429 || http.statusCode >= 500 {
            // Transient — incl. 503 `refresh_unavailable`: the server could not
            // record the rotation and the presented token is STILL VALID. Never
            // clear the session for it; retry with backoff (#547/#548).
            _scheduleRefreshRetry()
            throw OneloError.networkError("Session refresh is temporarily unavailable (HTTP \(http.statusCode))")
        }

        if http.statusCode >= 400 {
            // The session is over whatever the reason — clear it, then say WHY
            // with the right words: only a ban is "suspended"; a replaced,
            // expired or unknown session is a neutral "session ended" (#548).
            let refusal = refreshRefusalError(status: http.statusCode, json: json)
            try? keychain.clear()
            currentSession = nil
            if case .userRevoked = refusal { isUserRevoked = true }
            throw refusal
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
                // Carried on every refresh for the same reason it is carried on
                // sign-in: the gate answer must never go stale while the session
                // lives on. Absent → nil → the legacy fallback, not a refusal.
                return OneloUser.fromWire(userData, id: userId)
            }
            return currentSession?.user ?? OneloUser(id: "", email: nil, role: .member, tenantId: nil)
        }()
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: refreshedUser)
        try saveSession(session)
        // #740 — the server accepted the stored token: a session migrated from
        // the legacy shared Keychain is this app's, so the legacy copy can go.
        keychain.sessionRefreshSucceeded(refreshToken: refreshToken)
        _refreshRetryAttempt = 0
        _refreshBackoffUntil = nil
        currentSession = session
        return session
    }

    private var _inRefreshBackoff: Bool {
        guard let until = _refreshBackoffUntil else { return false }
        return until > Date()
    }

    /// Delay before the retry after `attempt` consecutive transient failures.
    static func refreshRetryDelay(attempt: Int) -> TimeInterval {
        min(5 * pow(2, Double(attempt)), 60)
    }

    /// Re-arm the refresh after a transient failure, with backoff.
    private func _scheduleRefreshRetry() {
        let delay = OneloAuth.refreshRetryDelay(attempt: _refreshRetryAttempt)
        _refreshRetryAttempt += 1
        _refreshBackoffUntil = Date().addingTimeInterval(delay)
        _refreshTask?.cancel()
        _refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self._refreshBackoffUntil = nil
            _ = try? await self.refreshSession()
        }
    }

    private func refreshPKCE() async throws {
        let resolved = try await resolveConfig()
        // #818: the same fetch answers the sign-up question; keep it current.
        signupMarketingConsent = resolved.signupMarketingConsent
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
            inAppStoreAllowed = resolved.inAppStoreAllowed
            // #26 — MUST be set before `isReady = true` below: the view re-renders
            // on the `readyPublisher` (not on this property directly), so it reads
            // the already-populated hex when it flips ready. Keep this assignment
            // above the `isReady = true` line.
            pageBackgroundColorHex = resolved.checkoutBgColor
            brandPrimaryColorHex = resolved.primaryColor
            brandTokens = resolved.brandTokens
            waitlistMode = resolved.waitlistMode
            if let urlStr = resolved.sdkRedirectUrl { sdkRedirectUrl = URL(string: urlStr) }
            if let urlStr = resolved.storeUrl { storeUrl = URL(string: urlStr) }
            if let urlStr = resolved.manageUrl { manageUrl = URL(string: urlStr) }
            oauthProviders = resolved.oauthProviders
            signupMarketingConsent = resolved.signupMarketingConsent
            // Cache so the loading skeleton can draw the right social-pill count on
            // the NEXT launch's first paint, before this resolveConfig completes.
            try? keychain.set(oauthProviders.joined(separator: ","), forKey: KeychainKeys.oauthProviders)
            // #26 — cache the branding background for the NEXT launch's first paint.
            if let bg = resolved.checkoutBgColor, !bg.isEmpty {
                try? keychain.set(bg, forKey: KeychainKeys.checkoutBgColor)
            }
            // #681 — and the resolved tokens alongside it.
            if let json = try? JSONEncoder().encode(resolved.brandTokens), let s = String(data: json, encoding: .utf8) {
                try? keychain.set(s, forKey: KeychainKeys.brandTokens)
            }

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
            else { isRestoringSession = false }  // #36 — no restore → don't leave the splash stuck on
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
            // #732 — the stored session was just cleared, so no restore can
            // follow: end it. Otherwise `isRestoringSession` stays true for the
            // whole launch and Features wait for an identity that never comes;
            // ending it loads the signed-out identity.
            isRestoringSession = false
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
            else { isRestoringSession = false }  // #36 — no restore → don't leave the splash stuck on
            } else {
                // #740 — no cached config (a migrated session has only its
                // refresh token), so no restore can run this launch: end it
                // rather than leave Features waiting for an identity.
                isRestoringSession = false
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
            // #818: the sign-up Marketing Consent text in the device language.
            URLQueryItem(name: "lang", value: OneloSignupMarketingConsent.deviceLanguage),
        ]

        var configRequest = URLRequest(url: components.url!)
        addStandardHeaders(&configRequest)
        let (data, response) = try await URLSession.shared.data(for: configRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // #45 — only a DEFINITIVE key rejection means the key is actually bad
            // and the app should show "Invalid publishable key" (→ isRevoked). The
            // backend `/api/sdk/config` returns 400 "Invalid key format" / 404
            // "Invalid key" for that. ANY OTHER non-200 (5xx, 429, 403, a network
            // blip during the cold-start request burst) is TRANSIENT and must NOT
            // be misread as an invalid key — else a perfectly valid key flashes
            // "Invalid publishable key" whenever /config transiently fails (e.g.
            // racing a feedback/portal open at cold start). Throw a transient
            // serverError so the caller's generic catch keeps the key and falls
            // back to the cached config instead of flagging isRevoked.
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 400 || status == 404 {
                throw OneloError.invalidPublishableKey("Server rejected the key")
            }
            throw OneloError.serverError("Config request failed transiently (HTTP \(status))")
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
    /// X-Codesign-Fingerprint on macOS, X-Onelo-Instance-Id) to a request, plus
    /// the SDK's own identity (`User-Agent`, `X-SDK-Version`, `X-Onelo-Sdk-Name`;
    /// #122) — these are the requests the dashboard's version capture reads.
    private func addStandardHeaders(_ request: inout URLRequest) {
        _OneloSdkIdentity.apply(to: &request)
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")
        request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        // Read the shared context — the same source every other transport reads.
        // codesignFingerprint is only ever seeded on macOS (nil elsewhere), so no
        // platform guard is needed here.
        if let token = securityContext.attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
        if let fp = securityContext.codesignFingerprint {
            request.setValue(fp, forHTTPHeaderField: "X-Codesign-Fingerprint")
        }
    }

    /// Fetches a fresh App Attest token and caches it. No-op on unsupported platforms.
    /// Safe to call from a detached Task — internally hops to the cooperative pool
    /// for DCAppAttestService / network / keychain work, then writes back to
    /// `self.attestToken` on the main actor.
    // FAZA 3 — a SINGLE OneloAppAttest reused across the SDK's lifetime, so its
    // attested key + stateless-challenge cache persist between requests (a fresh
    // instance per call would re-fetch a challenge every time and lose the key
    // handle needed for generateAssertion). Boxed as AnyObject because the type
    // is availability-gated. Populated on first _refreshAttestToken.
    private var _sharedAppAttestBox: AnyObject?

    /// Per-request App Attest assertion headers for the transport (FAZA 3).
    /// Returns nil before attestation is set up or on unsupported platforms —
    /// the caller then falls back to the legacy X-Attest-Token bearer.
    func assertionHeaders(method: String, path: String, query: String, body: Data) async -> [String: String]? {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *), let attest = _sharedAppAttestBox as? OneloAppAttest {
            return await attest.assertionHeaders(method: method, path: path, query: query, body: body)
        }
        #endif
        return nil
    }

    /// Self-heal after a HARD attestation reject (#24 P4): drop the attested key
    /// and re-attest so the next request carries a fresh key + assertion. NOT
    /// called on counter_stale (retryable) nor on the refresh path (Filar 5).
    /// Single-flight guard (@MainActor → race-free). A storm of gated 403s (or a
    /// systematic invalid_assertion) must trigger exactly ONE re-attest, not N —
    /// Apple heavily rate-limits attestKey, so an un-debounced storm would BRICK
    /// attestation instead of healing it (D1).
    private var _isReattesting = false
    /// Windowed loop guard (#34): even single-flighted, self-heal can loop
    /// SEQUENTIALLY (403 → re-attest → 403 → …). If a systematic reject persists,
    /// cap re-attests per window and then STOP — a further storm can't fix a
    /// server-side reject and only DDoSes Apple + our backend and floods
    /// sdk_security_events. Recovery after the cap is the next app launch (init
    /// re-attests via _refreshAttestToken); there is no periodic attest refresh.
    /// In monitor mode (shipped) self-heal is dormant anyway — a failed assertion
    /// degrades to the bearer server-side, so the cap is only relevant post-flip.
    private var _selfHealCount = 0
    private var _selfHealWindowStart = Date.distantPast
    private let selfHealMaxPerWindow = 3
    private let selfHealWindow: TimeInterval = 300  // 5 min

    func resetAttestedKeyForSelfHeal() {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *), let attest = _sharedAppAttestBox as? OneloAppAttest {
            guard !_isReattesting else { return }
            let now = Date()
            if now.timeIntervalSince(_selfHealWindowStart) > selfHealWindow {
                _selfHealWindowStart = now
                _selfHealCount = 0
            }
            guard _selfHealCount < selfHealMaxPerWindow else {
                OneloAttestLog.error("self-heal cap reached (\(selfHealMaxPerWindow)/window) — a persistent assertion reject won't be fixed by re-attesting; backing off.")
                return
            }
            _selfHealCount += 1
            _isReattesting = true
            attest.resetAttestedKey()
            self.attestToken = nil
            Task {
                await self._refreshAttestToken()
                self._isReattesting = false
            }
        }
        #endif
    }

    func _refreshAttestToken() async {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *) {
            let attest: OneloAppAttest
            if let existing = _sharedAppAttestBox as? OneloAppAttest {
                attest = existing
            } else {
                attest = OneloAppAttest(
                    baseURL: config.apiUrl.absoluteString,
                    publishableKey: config.publishableKey
                )
                _sharedAppAttestBox = attest
            }
            do {
                let token = try await attest.getAttestToken()
                self.attestToken = token
                self.attestError = nil
            } catch {
                // Never swallow a security failure silently: the developer must be
                // able to tell "App Attest failed (and why)" apart from "the SDK
                // never attested". Log the concrete cause and surface it via
                // `attestError` so the app can react.
                let mapped = (error as? OneloAttestError) ?? .deviceCheckFailed("\(error)")
                OneloAttestLog.error("App Attest failed — \(mapped.diagnosticDescription)")
                self.attestError = mapped
            }
        }
        #endif
    }

    /// Returns the cached App Attest token, if any. Used by Onelo to copy the token
    /// to the features HTTP client after initialization completes.
    func cachedAttestToken() -> String? { attestToken }

    /// #25 — wait (bounded) for background App Attest to produce `attestToken`
    /// before the first gated request, so a cold-start hosted flow / sign-in
    /// doesn't race AHEAD of the ~1s attestation and get rejected with
    /// `attest_token_required` (403) — which then "works" a second later once the
    /// token exists. Called at the top of the gated entry points; the token is
    /// attached by `addStandardHeaders`.
    ///
    /// iOS-only by design: on macOS the backend accepts requests WITHOUT
    /// X-Attest-Token (codesign fallback) and `DCAppAttestService` can hang on
    /// Apple's servers when the App Attest entitlement is missing — waiting there
    /// would risk freezing the flow for no gain. Best-effort + bounded: polls
    /// until the token (or a terminal `attestError`) appears, or `attestWaitCapMs`
    /// elapses, then proceeds tokenless. The background `_refreshAttestToken`
    /// keeps running so its token rides later requests.
    func _awaitAttestReady() async {
        #if os(iOS)
        guard attestRequired, attestToken == nil, attestError == nil else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(Self.attestWaitCapMs) / 1000.0)
        while attestToken == nil && attestError == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        #endif
    }

    /// #37 — may the NON-interactive discovery batch-ping go out? True when
    /// attestation isn't required, the token has arrived, or attestation
    /// terminally failed (an error means it will never arrive — don't wait
    /// forever). False means "still pending" so the caller SKIPS the tokenless
    /// send and defers to the token-arrival re-ping. macOS has no App Attest →
    /// always ready (codesign path).
    func _discoveryAttestReady() -> Bool {
        #if os(iOS)
        return !attestRequired || attestToken != nil || attestError != nil
        #else
        return true
        #endif
    }

    private func restoreSession() async {
        // #36 — publish that an auto-login restore is in flight BEFORE the first
        // `await`, so the view paints a branded splash (not the sign-in skeleton)
        // for the whole verify/refresh window. `hasStoredSessionSync()` mirrors the
        // guard below, so this is true iff we're actually about to restore; `defer`
        // clears it on EVERY exit path (no stored session, corrupt data, verify
        // done — success or revoked).
        isRestoringSession = hasStoredSessionSync()
        defer { isRestoringSession = false }
        let epoch = _signOutEpoch
        // #740 — a session migrated from the legacy shared Keychain is only its
        // refresh token. One refresh turns it into a full session (saved, and
        // published as `currentSession`) and proves it is this app's: the
        // backend refuses another app's token, and the refusal clears it.
        if hasRefreshTokenOnlySync() {
            _ = try? await refreshSession()
            return
        }
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

    /// #38 — attach the per-request App Attest assertion (FAZA 3) to an
    /// auth-completer request. The completers (signin / signup / hosted-callback)
    /// hit REPLAY-GUARDED backend paths, but they build requests on `_urlSession`
    /// + `addStandardHeaders` — NOT the shared `_OneloHTTPClient` that applies the
    /// assertion for features/paywall/forms — so without this they'd send ONLY the
    /// legacy bearer and the assertion model would never be exercised on exactly
    /// the paths it most protects ("built, not called"). `assertionHeaders`
    /// returns nil when the device can't produce one (no attested key / offline /
    /// non-iOS) → bearer-only, fully backward compatible (monitor mode degrades).
    /// The signed clientDataHash binds METHOD + path?query + challenge + THIS body,
    /// so pass the EXACT bytes set as `httpBody`. Path/query are read from the
    /// request URL (`request.url?.path`) — NOT a literal — so it matches the shared
    /// `_OneloHTTPClient.applyAssertion` AND the backend's `request.url.path`
    /// byte-for-byte even if `apiUrl` ever carries a path prefix.
    private func applyAuthAssertion(to request: inout URLRequest, body: Data) async {
        guard let headers = await assertionHeaders(
            method: request.httpMethod ?? "POST",
            path: request.url?.path ?? "",
            query: request.url?.query ?? "",
            body: body
        ) else { return }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    }

    private func backendPost(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = config.apiUrl.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        addStandardHeaders(&request)
        // #38 — signin/signup go through here; both are replay-guarded → assert.
        await applyAuthAssertion(to: &request, body: bodyData)

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
    /// `storage` is required: a test must never fall back to the real Keychain (#732).
    convenience init(_testingConfig config: OneloConfig, storage: any OneloSessionStorage) {
        self.init(config: config, storage: storage)
        _skipInitialize = true
    }

    func _injectSessionForTesting(_ session: OneloSession) {
        currentSession = session
    }

    func _clearSessionForTesting() {
        currentSession = nil
    }

    /// Flip `isReady` without running `initialize()` (which needs the network).
    /// Used by `AwaitReadyTimeoutTests` to prove `awaitReady(timeout:)` still
    /// WAKES on the publisher, not just that its deadline fires — a fix that got
    /// the timeout right and broke the wake-up would otherwise look green.
    /// `DEBUG`-only, like the hooks above, so it cannot exist in a shipped build.
    func _setReadyForTesting(_ value: Bool) {
        isReady = value
    }

    /// Drive the gate inputs directly, so `isAllowedIn` can be asserted without a
    /// Keychain, a backend or a live session.
    ///
    /// Added because the one line that matters — reading the SERVER'S
    /// `allowed_in` instead of re-deriving the rule — was provably untested:
    /// reverting it to the old local derivation left all 147 tests green
    /// (measured 2026-08-19). A rule nothing asserts is a rule that comes back.
    /// `DEBUG`-only, like the hooks above, so it cannot exist in a shipped build.
    func _setGateInputsForTesting(session: OneloSession?, paywallEnabled: Bool) {
        self.paywallEnabled = paywallEnabled
        self.currentSession = session
        self.isReady = true
        _recomputeAllowedIn()
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
