// Sources/OneloSwift/OneloAuthView.swift
import SwiftUI
import WebKit
import Combine
import AuthenticationServices
import os
private let _viewLog = Logger(subsystem: "com.onelo.sdk", category: "authview")

#if os(macOS)
/// Window size used when the hosted page asks for the wide layout
/// (e.g. plan store after Sign-up). Matches the breakpoint at which the
/// hosted store renders plans side-by-side.
private let kWidePresetSize  = NSSize(width: 1024, height: 720)
/// Fallback window size for the default narrow auth flow.
private let kNarrowPresetSize = NSSize(width: 440, height: 640)
#endif

/// Skeleton variant to show during a WebView navigation transition.
/// `.auth` covers re-loads of the hosted sign-in page (e.g. after a
/// session-expired redirect). `.store` covers Sign-Up → /store/hosted
/// when paywall is enabled. Lets the SwiftUI overlay draw the right
/// shape (single column vs 3-card grid) before the new page paints.
enum NavigationKind {
    case auth
    case store
}

/// Inspect a URL and decide which skeleton variant should cover the
/// transition. `/store/...` → store grid. Anything else (incl. the
/// hosted auth page reload) → auth column. We match on path prefix
/// rather than the whole URL so query strings / token params don't
/// affect classification.
private func navigationKind(for url: URL) -> NavigationKind {
    if url.path.hasPrefix("/store/") { return .store }
    return .auth
}

/// Build a URLRequest that forces a fresh fetch from the network and
/// bypasses any WKWebView / NSURLCache layer.
///
/// Why: the hosted auth + store pages are SSR'd by Next.js with token-
/// bound query params, so the HTML body changes per-request. WKWebView's
/// default cache policy (`useProtocolCachePolicy`) honors HTTP `Cache-Control`
/// headers and the underlying disk cache, which has burned us before:
/// after a hosted-page deploy on staging, devs kept seeing the OLD
/// skeleton because WKWebView returned its cached HTML. Marking the
/// request as `reloadIgnoringLocalCacheData` makes WKWebView issue a
/// fresh GET each time the embedded auth view mounts, while still
/// respecting cookies / Set-Cookie for session handling. Pairs with
/// `export const dynamic = 'force-dynamic'` on the Next.js routes so
/// neither side caches the skeleton.
private func oneloHostedURLRequest(_ url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return req
}

/// Apply hardening to a WKWebViewConfiguration before mounting the
/// hosted page. Defense-in-depth: even if a hosted Onelo page is
/// compromised or open-redirects somewhere, these settings limit what
/// the WebView can do.
///
/// - `limitsNavigationsToAppBoundDomains`: only honored if the host app
///   declares `WKAppBoundDomains` in Info.plist. We opt-in only when
///   the host has done that — without app-bound domains, setting this
///   to true would block ALL navigation (including the initial load).
/// - `isFraudulentWebsiteWarningEnabled`: surfaces Safari's anti-phishing
///   block page if the WebView ever lands on a flagged origin.
///
/// We do NOT disable `javaScriptCanOpenWindowsAutomatically` because
/// the store flow relies on `window.open(checkout_url)` getting routed
/// through `createWebViewWith` → system browser. Disabling that would
/// kill paywall checkout on Free plans.
private func applyOneloWebViewHardening(_ config: WKWebViewConfiguration) {
    let appBoundDomains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String] ?? []
    if !appBoundDomains.isEmpty {
        // Only safe to enable when host has declared at least one
        // app-bound domain. Otherwise WebView refuses to load anything.
        if #available(iOS 14.0, macOS 11.0, *) {
            config.limitsNavigationsToAppBoundDomains = true
        }
    }
    if #available(iOS 14.5, macOS 11.3, *) {
        config.preferences.isFraudulentWebsiteWarningEnabled = true
    }
}

/// Drop-in SwiftUI authentication view.
///
/// ```swift
/// OneloAuthView(auth: onelo.auth.authObject, config: .default) { session in
///     // user signed in
/// }
/// ```
public struct OneloAuthView<Content: View>: View {
    @StateObject private var vm: OneloAuthViewModel
    private let requestedConfig: OneloAuthConfig
    private let auth: any OneloAuthProtocol
    private let content: () -> Content
    private let sessionPublisher: AnyPublisher<OneloSession?, Never>
    private let readyPublisher: AnyPublisher<Bool, Never>
    /// Emits when the backend pushes legal.consent_required (a blocking version
    /// took effect) — drives an immediate consent re-check on a running app.
    private let consentRevisionPublisher: AnyPublisher<Int, Never>
    /// Emits when the single-owner consent-gate claim changes — lets this view
    /// re-attempt a claim the moment another presenter releases the gate.
    private let consentGateOwnerPublisher: AnyPublisher<UUID?, Never>
    /// Plan-gated enabled OAuth providers — drives the loading skeleton's social
    /// pill count so it matches what the hosted form renders, and updates LIVE the
    /// moment config resolves (the view reads it via @State below, not a one-shot).
    private let oauthProvidersPublisher: AnyPublisher<[String], Never>
    /// Emits while a hosted-callback code exchange runs (true) and when it settles
    /// (false). The external-browser payment-return path calls
    /// `OneloAuth.exchangeHostedCode` DIRECTLY from the host app's `onOpenURL` —
    /// it never routes through this view's `handleCode`, so a FAILED exchange
    /// there publishes no session change. Without this, `loadHostedUrl`'s
    /// in-flight guard would have bailed and left the view resting on a bare
    /// skeleton with no retry. On the true→false edge with still no session, we
    /// re-run `loadHostedUrl` to present the correct surface (sign-in / retry).
    private let exchangingPublisher: AnyPublisher<Bool, Never>
    /// #36 — mirrors `OneloAuth.isRestoringSession`. True while a stored session
    /// is being restored/verified on cold-start auto-login, so the pre-auth frame
    /// shows a branded splash instead of the sign-in skeleton.
    private let restoringSessionPublisher: AnyPublisher<Bool, Never>
    @State private var isAuthenticated: Bool = false
    @State private var isReady: Bool = false
    /// Seeded synchronously at init from `hasStoredSessionSync()` so the FIRST
    /// paint of an auto-login already suppresses the sign-in skeleton (#36).
    @State private var isRestoringSession: Bool = false
    /// True when the user is signed in but `paywall_enabled=true` and their
    /// entitlement is not active. Drives a switch from showing `content()`
    /// to opening the hosted store inside the same WKWebView.
    @State private var needsPaywall: Bool = false
    @State private var hostedUrl: URL? = nil
    @State private var showRetry: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isOnExternalPage: Bool = false
    @State private var reloadWebView: Bool = false
    @State private var isLoadingUrl: Bool = false
    /// One-shot latch for the waitlist redirect. readyPublisher + onAppear can
    /// both fire loadHostedUrl on a cold start; without this the redirect would
    /// open the system browser twice (two tabs). Separate from isLoadingUrl so
    /// it never wedges the normal auth/store path.
    @State private var didWaitlistRedirect: Bool = false
    /// Single-flight guard for the hosted code exchange. The WebView can deliver
    /// `onCode` more than once for a single sign-in (callback redirect plus a
    /// reload re-hitting the URL), and a duplicate exchange could mint a fresh
    /// session right after a sign-out. Set while an exchange is in flight; reset
    /// on completion so a genuine retry (after failure) still works.
    @State private var isExchangingCode: Bool = false
    /// Tracks the previous value of `oneloAuth.isExchangingCode` so the
    /// `exchangingPublisher` handler can fire on the true→false EDGE only (a
    /// just-settled exchange), not on every emission. See that handler for why
    /// this recovers the external-browser payment-return failure path.
    @State private var wasExchanging: Bool = false
    /// Drives a full-bounds skeleton overlay rendered ON TOP of the
    /// WKWebView during any post-first-load navigation. Today this covers
    /// the Sign Up flow (auth page → /store/hosted) where the host window
    /// also widens to the store preset — without the overlay there's a
    /// visible empty strip on the right while the store page is still
    /// reflowing. WebAuthCoordinator flips this true on
    /// didStartProvisionalNavigation (post-first-load) and false on
    /// didFinish / didFail.
    @State private var isNavigating: Bool = false
    /// Which skeleton variant the navigation overlay should draw —
    /// updated atomically with `isNavigating` from
    /// `onNavigationLoading(true, kind:)`. Persists across the
    /// "false" event so the overlay can fade out without flickering
    /// to a different variant during its exit animation.
    @State private var navigationKind: NavigationKind = .auth
    /// Legal consent gate. While `consentResolved` is false we hold the content
    /// reveal so a blocking Terms update can't be bypassed by a flash of the
    /// app. `blockingConsent` is the document to gate on, if any.
    @State private var consentResolved: Bool = false
    @State private var blockingConsent: OneloConsentRequirement? = nil
    /// Stable per-instance identity for the single-owner gate claim. Lets this
    /// view present the hosted gate only while it holds the claim, so it can't
    /// duplicate a gate already shown by a `.oneloConsentGate` modifier or by
    /// this same view in another window.
    @State private var gateToken = UUID()
    /// Number of social-login pills the loading skeleton should draw. Mirrors the
    /// plan-gated provider list; fed by `oauthProvidersPublisher` so the skeleton
    /// re-renders the instant config resolves instead of being stuck on the value
    /// it had at first paint (which caused a wrong skeleton until an unrelated
    /// re-render). Seeded from OneloAuth's cached value for a correct first paint.
    @State private var oauthProviderCount: Int = 0

    private var effectiveConfig: OneloAuthConfig {
        // #26 — paint the branding page background (checkout_bg_color) so the
        // pre-auth / loading frame matches the hosted page instead of flashing a
        // system colour. Falls back to the developer's config (default
        // .systemBackground) until config resolves or if the value is malformed.
        guard let hex = (auth as? OneloAuth)?.pageBackgroundColorHex,
              let color = Color(oneloHex: hex) else { return requestedConfig }
        var c = requestedConfig
        c.backgroundColor = color
        return c
    }

    /// True once sign-in (and any paywall) is satisfied — the point at which a
    /// blocking legal consent must be resolved before `content()` is shown.
    private var inApp: Bool { isAuthenticated && !needsPaywall }

    /// Create an auth view. The `content` closure is shown after successful sign-in.
    ///
    /// ```swift
    /// OneloAuthView(auth: auth) {
    ///     ContentView().environmentObject(auth)
    /// }
    /// ```
    public init(
        auth: any OneloAuthProtocol,
        config: OneloAuthConfig = .default,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
        self.requestedConfig = config
        self.auth = auth
        _vm = StateObject(wrappedValue: OneloAuthViewModel(auth: auth, onSuccess: nil))
        if let oneloAuth = auth as? OneloAuth {
            sessionPublisher = oneloAuth.$currentSession.eraseToAnyPublisher()
            readyPublisher = oneloAuth.$isReady.eraseToAnyPublisher()
            consentRevisionPublisher = oneloAuth.$consentRevision.eraseToAnyPublisher()
            consentGateOwnerPublisher = oneloAuth.$consentGateOwner.eraseToAnyPublisher()
            oauthProvidersPublisher = oneloAuth.$oauthProviders.eraseToAnyPublisher()
            exchangingPublisher = oneloAuth.$isExchangingCode.eraseToAnyPublisher()
            restoringSessionPublisher = oneloAuth.$isRestoringSession.eraseToAnyPublisher()
            // Seed the flag synchronously so the FIRST paint of an auto-login
            // already suppresses the sign-in skeleton (#36) — before the
            // publisher has had a chance to deliver.
            _isRestoringSession = State(initialValue: oneloAuth.hasStoredSessionSync())
        } else {
            sessionPublisher = Just(Optional<OneloSession>.none).eraseToAnyPublisher()
            readyPublisher = Just(false).eraseToAnyPublisher()
            consentRevisionPublisher = Just(0).eraseToAnyPublisher()
            consentGateOwnerPublisher = Just(nil).eraseToAnyPublisher()
            oauthProvidersPublisher = Just([String]()).eraseToAnyPublisher()
            exchangingPublisher = Just(false).eraseToAnyPublisher()
            restoringSessionPublisher = Just(false).eraseToAnyPublisher()
        }
    }

    public var body: some View {
        Group {
            if inApp {
                if let consent = blockingConsent, let gateUrl = consent.consentUrl {
                    // Hosted consent gate — the legal page in ?gate=1 mode,
                    // loaded in the SAME auth WebView. The page emits
                    // onelo:consent; we record the accept (or sign the user
                    // out) here. Mirrors the auth flow: page emits, SDK acts.
                    EmbeddedWebAuthView(
                        url: gateUrl,
                        callbackScheme: callbackScheme,
                        onCode: { _ in },
                        onError: { _ in /* keep the gate up; user can retry */ },
                        onSessionExpired: {
                            Task { await loadHostedUrl() }
                        },
                        onConsent: { action in
                            Task { await handleConsent(action, requirement: consent) }
                        },
                        shouldReload: $reloadWebView
                    )
                    #if os(macOS)
                    .frame(minWidth: 440)
                    .ignoresSafeArea()
                    #endif
                    #if os(iOS)
                    // #32 — Same branding backing as the sign-in WebView: the
                    // consent gate shares the now-transparent iOS WKWebView, so
                    // without this it would flash the system background during its
                    // load. Keep the branded color continuous here too.
                    .background(effectiveConfig.backgroundColor.ignoresSafeArea())
                    #endif
                } else if consentResolved {
                    content()
                } else {
                    // #46 — POST-auth consent check (inApp==true, session already
                    // restored, awaiting the async consent gate). This was the LAST
                    // AuthSkeletonView firing on cold-start AUTO-LOGIN: #36 killed
                    // the pre-auth ones, but a returning user still hit THIS branch
                    // and saw a SIGN-IN skeleton — wrong, they're already signed in.
                    // Show ONLY the neutral branded splash while consent resolves;
                    // content() reveals immediately after. (Rule: the sign-in
                    // skeleton belongs solely to the signed-OUT loading state —
                    // isReady && !isAuthenticated && !needsPaywall &&
                    // !isRestoringSession && hostedUrl==nil — never post-auth.)
                    effectiveConfig.backgroundColor.ignoresSafeArea()
                }
            } else if let url = hostedUrl, !showRetry {
                // Hosted page embedded in the app window via WKWebView
                ZStack(alignment: .topLeading) {
                    EmbeddedWebAuthView(
                        url: url,
                        callbackScheme: callbackScheme,
                        onCode: { code in
                            Task { await handleCode(code) }
                        },
                        onError: { err in
                            hostedUrl = nil
                            errorMessage = err
                            showRetry = true
                        },
                        onSessionExpired: {
                            hostedUrl = nil
                            Task { await loadHostedUrl() }
                        },
                        onExternalNavigation: { isExternal in
                            isOnExternalPage = isExternal
                        },
                        onNavigationLoading: { loading, kind in
                            // Latch the kind BEFORE animating the overlay
                            // in, so it paints the right variant the
                            // moment it appears. We only update the kind
                            // on a "true" event — the "false" event
                            // shouldn't switch variants mid-fade.
                            if loading {
                                navigationKind = kind
                                // No animation on the "true" event — the
                                // overlay must cover the old content
                                // instantly so the user never sees a
                                // half-faded auth form while the window
                                // is widening.
                                isNavigating = true
                            } else {
                                // Hide with a short fade so the new page
                                // doesn't pop in abruptly.
                                withAnimation(.easeOut(duration: 0.22)) {
                                    isNavigating = false
                                }
                            }
                        },
                        shouldReload: $reloadWebView
                    )
                    #if os(macOS)
                    .frame(minWidth: 440)
                    .ignoresSafeArea()
                    #endif
                    #if os(iOS)
                    // #32 — Paint the branding color BEHIND the (now transparent)
                    // WebView so the branded color is continuous from the skeleton
                    // through the load, with no white/system flash. macOS gets this
                    // from its NSWindow background; iOS has none, so it's explicit.
                    .background(effectiveConfig.backgroundColor.ignoresSafeArea())
                    #endif

                    // Transition skeleton — full-bounds overlay, painted
                    // ON TOP of the WebView during a navigation. Sits on
                    // an opaque background so any in-flight reflow inside
                    // the WebView (window-widening for the store page)
                    // is hidden until the new page finishes loading.
                    if isNavigating {
                        ZStack {
                            effectiveConfig.backgroundColor.ignoresSafeArea()
                            switch navigationKind {
                            case .auth:  AuthSkeletonView(providerCount: oauthProviderCount)
                            case .store: StoreSkeletonView()
                            }
                        }
                        .transition(.opacity)
                    }

                    if isOnExternalPage {
                        Button(action: {
                            isOnExternalPage = false
                            reloadWebView = true
                        }) {
                            Label("Use a different method", systemImage: "chevron.left")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                    }
                }
            } else {
                // Loading state or retry after cancel/error
                ZStack {
                    effectiveConfig.backgroundColor.ignoresSafeArea()

                    if showRetry {
                        VStack(spacing: 16) {
                            if let err = errorMessage {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Sign In") {
                                showRetry = false
                                errorMessage = nil
                                Task { await loadHostedUrl() }
                            }
                            .buttonStyle(.plain)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(oneloOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    } else if isRestoringSession {
                        // #36 — auto-login in flight: a stored session is being
                        // restored/verified. Show ONLY the branded background (the
                        // ZStack above already paints it) — NO sign-in skeleton — so
                        // a returning user sees "opening, already signed in", not a
                        // flash of the login form. Falls through to the skeleton via
                        // `restoringSessionPublisher` if restore resolves with no
                        // valid session.
                        EmptyView()
                    } else if isReady {
                        // Only paint the skeleton AFTER config has resolved — at
                        // that point `oauthProviderCount` is the fresh, plan-gated
                        // value, so the social shape is correct on the FIRST paint.
                        // Before isReady the count is a stale keychain seed (the
                        // previous launch's value); drawing the skeleton then would
                        // show the wrong social shape and visibly flip once config
                        // lands. The plain background above is the only pre-resolve
                        // state — matches the "no branded pre-auth screen" rule.
                        //
                        // #B — the skeleton is now Onelo-authored HTML rendered in a
                        // bare WebView (single-source across SDKs, pixel-identical to
                        // the hosted page's own SSR skeleton), not a native SwiftUI
                        // reimplementation. Transparent → the ZStack's branded base
                        // shows through, continuous into the loaded hosted page.
                        AuthSkeletonWebView(socialCount: oauthProviderCount)
                            #if os(macOS)
                            .frame(minWidth: 440)
                            #endif
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .onReceive(sessionPublisher) { session in
            let wasAuthenticated = isAuthenticated
            let wasNeedsPaywall = needsPaywall
            isAuthenticated = session != nil
            let paywallOn = (auth as? OneloAuth)?.paywallEnabled ?? false
            needsPaywall = session != nil && paywallOn && session?.user.entitlement != .active
            #if DEBUG
            _viewLog.debug("sessionPublisher: session=\(session != nil ? "non-nil" : "nil"), wasAuthenticated=\(wasAuthenticated), isReady=\(isReady), needsPaywall=\(needsPaywall)")
            #endif
            if wasAuthenticated && session == nil {
                hostedUrl = nil
                showRetry = false
                errorMessage = nil
                if isReady {
                    #if DEBUG
                    _viewLog.debug("signOut detected → loadHostedUrl()")
                    #endif
                    Task { await loadHostedUrl() }
                } else {
                    #if DEBUG
                    _viewLog.debug("signOut detected but isReady=false, waiting for readyPublisher")
                    #endif
                }
            } else if wasNeedsPaywall != needsPaywall {
                // Entitlement just changed (purchase completed → reveal content;
                // or subscription lapsed → show store). Drop any stale WebView URL
                // so the next loadHostedUrl() picks the right flow.
                hostedUrl = nil
                showRetry = false
                errorMessage = nil
                if needsPaywall && isReady {
                    Task { await loadHostedUrl() }
                }
            }
            // Entered the in-app state (just signed in, or paywall just cleared)
            // → resolve any blocking legal consent before content() is shown.
            // Left it (sign out / lapsed) → reset so re-entry re-checks.
            let nowInApp = isAuthenticated && !needsPaywall
            let wasInApp = wasAuthenticated && !wasNeedsPaywall
            if nowInApp && !wasInApp {
                consentResolved = false
                blockingConsent = nil
                Task { await checkConsent() }
            } else if !nowInApp {
                consentResolved = false
                blockingConsent = nil
                // Signed out / lapsed → drop any gate claim so a future session
                // (or another presenter) can re-acquire it cleanly.
                (auth as? OneloAuth)?.releaseConsentGate(gateToken)
            }
        }
        .onReceive(readyPublisher) { ready in
            isReady = ready
            #if DEBUG
            _viewLog.debug("readyPublisher: ready=\(ready), isAuthenticated=\(isAuthenticated), hostedUrl=\(hostedUrl != nil ? "set" : "nil")")
            #endif
            if ready && (!isAuthenticated || needsPaywall) && hostedUrl == nil && !showRetry && !isRestoringSession {
                #if DEBUG
                _viewLog.debug("readyPublisher trigger → loadHostedUrl()")
                #endif
                Task { await loadHostedUrl() }
            }
        }
        .onReceive(restoringSessionPublisher) { restoring in
            // #36 — auto-login gate. While a stored session is being verified we
            // hold the branded splash and DON'T load the hosted sign-in page. On
            // the true→false edge with STILL no session (restore found nothing /
            // the session was revoked), present the sign-in surface now.
            let settled = isRestoringSession && !restoring
            isRestoringSession = restoring
            if settled && isReady && !isAuthenticated && hostedUrl == nil && !showRetry {
                #if DEBUG
                _viewLog.debug("restore settled without session → loadHostedUrl()")
                #endif
                Task { await loadHostedUrl() }
            }
        }
        .onReceive(exchangingPublisher) { exchanging in
            // Recover the view when an EXTERNAL-browser code exchange settles
            // without a session. Only the true→false edge matters (a just-finished
            // exchange), and only the FAILURE outcome: on success `sessionPublisher`
            // already owns routing (isAuthenticated flips true here → guard drops),
            // and an in-app WebView failure is owned by `handleCode` (which sets
            // showRetry → guard drops). What's left is precisely the external path,
            // where a thrown exchange publishes nothing and would otherwise strand
            // the view on the loading skeleton.
            let settled = wasExchanging && !exchanging
            wasExchanging = exchanging
            guard settled, isReady, !isAuthenticated, hostedUrl == nil, !showRetry, !isLoadingUrl else { return }
            #if DEBUG
            _viewLog.debug("exchangingPublisher settled without session → loadHostedUrl()")
            #endif
            Task { await loadHostedUrl() }
        }
        .onReceive(consentRevisionPublisher) { rev in
            // Backend pushed legal.consent_required (a blocking version took
            // effect). Re-check consent NOW so a running, logged-in app shows
            // the gate immediately. rev==0 is the initial value — ignore it.
            guard rev > 0, inApp else { return }
            consentResolved = false
            Task { await checkConsent() }
        }
        .onReceive(consentGateOwnerPublisher) { owner in
            // The gate just became free (another presenter released it). If we
            // still have a blocking consent pending, re-check to claim and show
            // it. Only fires on free→ (owner == nil); claiming sets a non-nil
            // owner, so this never loops.
            guard inApp, owner == nil else { return }
            Task { await checkConsent() }
        }
        .onReceive(oauthProvidersPublisher) { providers in
            // Keep the skeleton's social-pill count in sync with config. Fires with
            // the current value on subscribe (cached) AND again when resolveConfig
            // lands the plan-gated list — so the skeleton flips to the right shape
            // automatically, not only on an unrelated re-render.
            oauthProviderCount = providers.count
        }
        .onAppear {
            guard let oneloAuth = auth as? OneloAuth else { return }
            #if DEBUG
            _viewLog.debug("onAppear: isReady=\(oneloAuth.isReady), isAuthenticated=\(isAuthenticated)")
            #endif
            // Session restored straight into the in-app state (no sign-in this
            // launch): still resolve consent before revealing content.
            if inApp && !consentResolved {
                Task { await checkConsent() }
            }
            guard oneloAuth.isReady && (!isAuthenticated || needsPaywall) && hostedUrl == nil && !showRetry else { return }
            #if DEBUG
            _viewLog.debug("onAppear trigger → loadHostedUrl()")
            #endif
            Task { await loadHostedUrl() }
        }
        .onDisappear {
            // Releasing on teardown is what lets a `.oneloConsentGate` modifier
            // take over after this view unmounts (e.g. an app that uses
            // OneloAuthView only for sign-in then swaps to its own UI).
            (auth as? OneloAuth)?.releaseConsentGate(gateToken)
        }
    }

    private var callbackScheme: String {
        (auth as? OneloAuth)?.config.callbackScheme ?? ""
    }

    /// Resolve whether a blocking legal consent must gate the app. Always sets
    /// `consentResolved` so the content reveal is never held indefinitely (a
    /// failed/empty check reveals the app — fail-open, since the gate exists to
    /// surface real blocking updates, not to lock users out on a network blip).
    @MainActor
    private func checkConsent() async {
        guard let oneloAuth = auth as? OneloAuth else {
            consentResolved = true
            return
        }
        let items = await oneloAuth.requiredConsents()
        if let blocker = items.first(where: { $0.blocking }) {
            // Present ONLY while we hold the single-owner claim. If another
            // presenter owns it (a `.oneloConsentGate` modifier, or this view in
            // another window), stand down — reveal content; that presenter's
            // full-cover gate blocks the app. Prevents duplicate gate windows.
            blockingConsent = oneloAuth.claimConsentGate(gateToken) ? blocker : nil
        } else {
            blockingConsent = nil
            oneloAuth.releaseConsentGate(gateToken)
        }
        consentResolved = true
    }

    /// Handle the hosted gate's result. "accept" records consent and re-checks
    /// (there may be more than one blocking document); anything else signs out.
    @MainActor
    private func handleConsent(_ action: String, requirement: OneloConsentRequirement) async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        if action == "accept" {
            try? await oneloAuth.acceptConsent(versionId: requirement.versionId)
            consentResolved = false
            blockingConsent = nil
            await checkConsent()
        } else {
            try? await oneloAuth.signOut()
        }
    }

    @MainActor
    private func loadHostedUrl() async {
        #if DEBUG
        _viewLog.debug("loadHostedUrl() called: isLoadingUrl=\(isLoadingUrl), hostedUrl=\(hostedUrl != nil ? "set" : "nil")")
        #endif
        guard !isLoadingUrl, hostedUrl == nil else {
            #if DEBUG
            _viewLog.debug("loadHostedUrl() SKIPPED by guard")
            #endif
            return
        }
        guard let oneloAuth = auth as? OneloAuth else {
            #if DEBUG
            _viewLog.debug("loadHostedUrl() SKIPPED — auth cast failed")
            #endif
            return
        }
        // A login is completing — a hosted-callback code is being exchanged (in-app
        // WebView OR external-browser deep-link return). Do NOT present a fresh
        // sign-in WebView, or it flashes on screen while the app foregrounds and
        // then vanishes once the session lands. The session publisher will reveal
        // content() (or re-route to store) when the exchange resolves.
        guard !oneloAuth.isExchangingCode else {
            #if DEBUG
            _viewLog.debug("loadHostedUrl() SKIPPED — code exchange in flight")
            #endif
            return
        }

        // Waitlist mode: the app isn't live yet — send the user to the developer's
        // configured redirect URL in the system browser, not the auth page. Mirrors
        // the JS SDK's loadAuthView; this WebView path previously skipped the
        // waitlist check (a JS↔Swift divergence, now closed).
        if oneloAuth.waitlistMode, let redirect = oneloAuth.sdkRedirectUrl {
            // One-shot: readyPublisher + onAppear can both reach here on a cold
            // start — without the latch the redirect opens twice (two tabs).
            guard !didWaitlistRedirect else { return }
            didWaitlistRedirect = true
            #if os(macOS)
            NSWorkspace.shared.open(redirect)
            #elseif os(iOS)
            // async context (loadHostedUrl) → open(_:) resolves to the async
            // overload on Swift 6 / Xcode 26 and must be awaited.
            await UIApplication.shared.open(redirect)
            #endif
            return
        }

        // The sign-in ↔ store ↔ content routing now lives BEHIND ONELO'S WALLS:
        // /api/sdk/flow/init makes the decision ONCE, server-side. The SDK just
        // opens whatever URL it is told, or shows content when the backend says
        // we're already authorized. This replaces the old SDK-side
        // `needsPaywall ? store : auth` branch (kept in parity with the JS SDK).
        isLoadingUrl = true
        defer { isLoadingUrl = false }
        do {
            switch try await oneloAuth.resolveFlow() {
            case .authorized:
                // Backend confirms access — do NOT open a WebView. Reconcile the
                // local entitlement so `needsPaywall` flips false and the reactive
                // body reveals content() (revalidateEntitlement republishes the
                // session on change).
                //
                // Defense-in-depth against a permanent hang: if /flow/init said
                // authorized but the local session STILL doesn't grant access
                // (inconsistency between /flow/init and /auth/user, or authorized
                // returned for a signed-out caller), no republish happens →
                // needsPaywall stays true, hostedUrl stays nil → the view would
                // sit in the loading skeleton forever. Surface a retry instead.
                if oneloAuth.paywallEnabled {
                    let ent = await oneloAuth.revalidateEntitlement()
                    if ent != .active {
                        errorMessage = "Couldn't confirm your access. Please try again."
                        showRetry = true
                    }
                } else if oneloAuth.currentSession == nil {
                    errorMessage = "Couldn't confirm your access. Please try again."
                    showRetry = true
                }
            case let .present(_, url, _, _):
                // Post-await re-check: /flow/init decided present() from the state
                // that existed when it was CALLED. If a hosted-callback exchange
                // began while it was in flight (external-browser payment return
                // deep-linking back in), presenting now would flash the WebView on
                // screen only to be torn down the instant the session publishes and
                // `inApp` wins. `isExchangingCode` — not `currentSession != nil` —
                // is the right gate: a signed-in-but-unentitled user legitimately
                // gets present(store) while a session already exists. This is the
                // main-actor-atomic partner to the top-of-function guard, closing
                // the window that opens across the awaited resolveFlow().
                if oneloAuth.isExchangingCode {
                    #if DEBUG
                    _viewLog.debug("resolveFlow present() dropped — code exchange started mid-flight")
                    #endif
                } else {
                    hostedUrl = url
                }
            }
            #if DEBUG
            _viewLog.debug("resolveFlow OK")
            #endif
        } catch OneloError.storeNotConfigured {
            // Dev has paywall_enabled=true but no visible store options. Surface a
            // clear message instead of opening a blank WebView.
            errorMessage = "The store hasn't been configured yet. Please contact support."
            showRetry = true
        } catch {
            #if DEBUG
            _viewLog.debug("loadHostedUrl error: \(error.localizedDescription)")
            #endif
            errorMessage = error.localizedDescription
            showRetry = true
        }
    }

    @MainActor
    private func handleCode(_ code: String) async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        // Drop duplicate deliveries of the same sign-in's code (see isExchangingCode).
        guard !isExchangingCode else { return }
        isExchangingCode = true
        defer { isExchangingCode = false }
        do {
            _ = try await oneloAuth.exchangeHostedCode(code)
            // Login succeeded — tear down the sign-in/store WebView immediately.
            // The session publisher then reveals content() when entitled, or the
            // next loadHostedUrl re-routes to the store when a paywall still
            // applies (now WITH a session, so no sign-in flash).
            hostedUrl = nil
        } catch {
            hostedUrl = nil
            errorMessage = error.localizedDescription
            showRetry = true
        }
    }
}

// MARK: - Embedded web auth view (WKWebView)

private final class WebAuthCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let callbackScheme: String
    let originalHost: String?
    let originalPath: String?
    let onCode: (String) -> Void
    let onError: (String) -> Void
    let onSessionExpired: () -> Void
    var onExternalNavigation: ((Bool) -> Void)?
    var onContentHeight: ((CGFloat) -> Void)?
    /// Emitted on every WebView transition AFTER the first successful
    /// load. The Bool says "loading vs idle", the kind tells the parent
    /// which skeleton variant to draw underneath (auth vs store).
    ///
    /// The "true" event fires in decidePolicyFor — i.e. BEFORE the
    /// WebView begins the network round-trip — so the skeleton overlay
    /// can paint instantly on the user's click and hide the previous
    /// page before the window starts its resize animation. The "false"
    /// event fires from didFinish / didFail once the new page is ready
    /// to be revealed.
    var onNavigationLoading: ((Bool, NavigationKind) -> Void)?
    /// Flips once didFinish fires for the first time. After that, every
    /// new didStartProvisionalNavigation is treated as a real transition.
    private var hasFinishedFirstLoad: Bool = false
    var onNativeOAuth: ((String, String) -> Void)?
    /// Fires when the hosted legal page (loaded in gate mode) emits
    /// `onelo:consent`. The String is the action: "accept" or "decline".
    var onConsent: ((String) -> Void)?
    /// Last WKWebView that called us through a navigation delegate method.
    /// Used by the store OAuth flow to reload the same WebView with an
    /// `?oauth_preauth=…` param after ASWebAuthenticationSession returns —
    /// no callback plumbing back up to the SwiftUI view needed.
    weak var lastSeenWebView: WKWebView?
    /// Fires when the page requests a window resize via postMessage.
    /// Either `preset` ("wide" / "narrow") or explicit width/height in
    /// CSS pixels may be supplied. Explicit dimensions take precedence
    /// and are what the store page sends after measuring its rendered
    /// content height.
    var onResize: ((String?, CGFloat?, CGFloat?) -> Void)?
    /// Once a manual resize has been applied, the auto-height callback
    /// is suppressed — otherwise scrollHeight readings from the wider
    /// store page would fight the explicit setFrame.
    var manualResizeActive: Bool = false
    /// Pending resize work, debounced. Hosted pages typically post TWO
    /// resize messages in quick succession on transition:
    ///   1. an initial preset (e.g. "wide") sent during mount
    ///   2. an explicit width/height once layout has measured its
    ///      rendered scrollHeight
    /// Without debouncing, the window animates to (1) and then animates
    /// to (2) — visible jiggle where the window overshoots the final
    /// store size and snaps back. Coalescing them to the LATEST message
    /// after a short quiet period produces a single smooth resize.
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var _appleAuthSession: ASWebAuthenticationSession?
    /// True after a WebContent crash has triggered a silent reload. A second
    /// termination surfaces the error rather than spinning indefinitely.
    private var _hasReloadedAfterCrash: Bool = false

    init(callbackScheme: String, originalHost: String?, originalPath: String?, onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void, onSessionExpired: @escaping () -> Void) {
        self.callbackScheme = callbackScheme
        self.originalHost = originalHost
        self.originalPath = originalPath
        self.onCode = onCode
        self.onError = onError
        self.onSessionExpired = onSessionExpired
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "oneloNative",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        // Defense-in-depth: drop any message coming from a frame whose host
        // does not match the hosted page we originally loaded. The
        // navigation delegate already blocks third-party navigation, so an
        // origin mismatch should not normally happen — but if it ever does
        // (e.g. an open-redirect lands the WebView on another host), we
        // refuse to act on its scripted requests.
        let frameHost = message.frameInfo.securityOrigin.host
        if let expected = originalHost, !expected.isEmpty,
           !frameHost.isEmpty, frameHost != expected {
            return
        }
        if type == "onelo:session_expired" {
            DispatchQueue.main.async { self.onSessionExpired() }
        } else if type == "onelo:consent",
                  let action = body["action"] as? String {
            DispatchQueue.main.async { self.onConsent?(action) }
        } else if type == "onelo:native_oauth",
                  let provider = body["provider"] as? String,
                  let token = body["token"] as? String {
            DispatchQueue.main.async { self.onNativeOAuth?(provider, token) }
        } else if type == "onelo:native_oauth_url",
                  let urlStr = body["url"] as? String,
                  let url = URL(string: urlStr) {
            // Store flow: hosted page already built the provider auth URL
            // via POST /store-oauth-init (state carries flow=store + productId).
            // We just hand it to ASWebAuthenticationSession — Apple OAuth
            // refuses embedded WebViews, so this MUST go through a real
            // system browser context.
            DispatchQueue.main.async { self.startNativeOAuth(oauthUrl: url) }
        } else if type == "onelo:resize" {
            let preset = body["preset"] as? String
            let width  = (body["width"]  as? NSNumber).map  { CGFloat(truncating: $0) }
            let height = (body["height"] as? NSNumber).map  { CGFloat(truncating: $0) }
            // Debounce: cancel any prior pending resize and schedule this
            // one for 120ms out. If another resize arrives in the
            // meantime it replaces this work item, so only the LAST
            // message in a burst actually triggers setFrame. 120ms is
            // long enough to absorb the typical preset → explicit width
            // pair (which arrives within ~30-50 ms of each other) and
            // short enough that the user perceives the resize as
            // immediate. Burst-followed-by-idle is the dominant pattern
            // for hosted-page transitions.
            self.pendingResizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onResize?(preset, width, height)
            }
            self.pendingResizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func startNativeOAuth(oauthUrl: URL) {
        guard !callbackScheme.isEmpty else { return }
        let session = ASWebAuthenticationSession(
            url: oauthUrl,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            self._appleAuthSession = nil
            guard error == nil, let callbackURL else { return }
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
            if let code = items?.first(where: { $0.name == "code" })?.value {
                DispatchQueue.main.async { self.onCode(code) }
            } else if let preauth = items?.first(where: { $0.name == "preauth" })?.value {
                // Paid product store flow — OAuth succeeded, account is provisioned,
                // but the buyer still owes payment. Reload the hosted store page
                // with ?oauth_preauth=… — StoreClient.tsx already has a useEffect
                // for that param which drives the Stripe Checkout step.
                DispatchQueue.main.async { [weak self] in
                    guard let webView = self?.lastSeenWebView,
                          let currentURL = webView.url,
                          var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
                    else { return }
                    var qi = components.queryItems ?? []
                    qi.removeAll(where: { $0.name == "oauth_preauth" || $0.name == "oauth_code" || $0.name == "oauth_error" })
                    qi.append(URLQueryItem(name: "oauth_preauth", value: preauth))
                    components.queryItems = qi
                    if let newURL = components.url {
                        webView.load(oneloHostedURLRequest(newURL))
                    }
                }
            } else if let err = items?.first(where: { $0.name == "error" })?.value {
                DispatchQueue.main.async { self.onError(err) }
            }
        }
        session.presentationContextProvider = self
        // Non-ephemeral on purpose — the "logout must be authoritative" problem
        // (a live provider SSO session silently re-issuing a code, so sign-out
        // bounces right back) is solved SERVER-SIDE instead: the Google authorize
        // URL now carries `prompt=select_account`, forcing the account chooser on
        // every authorize regardless of shared cookies. We do NOT set
        // `prefersEphemeralWebBrowserSession = true` here because on macOS an
        // ephemeral ASWebAuthenticationSession detaches into a separate
        // system-managed window outside the app's window manager — the same
        // regression documented in `openCustomerPortal(from:)` ("auth window opens
        // on another screen and nothing happens"). prompt=select_account achieves
        // authoritative logout without that macOS hazard. (GitHub/Apple authorize
        // endpoints don't honor prompt=select_account; their re-auth is governed by
        // the provider session and is out of scope of this lever.)
        session.prefersEphemeralWebBrowserSession = false
        _appleAuthSession = session
        session.start()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        self.lastSeenWebView = webView
        guard let url = navigationAction.request.url else {
            _viewLog.notice("[nav] decidePolicy: nil url → ALLOW")
            decisionHandler(.allow)
            return
        }
        _viewLog.notice("[nav] decidePolicy: type=\(navigationAction.navigationType.rawValue, privacy: .public) targetFrame=\(navigationAction.targetFrame == nil ? "nil" : "set", privacy: .public) url=\(url.absoluteString, privacy: .public)")
        // Intercept auth callback — REQUIRE both the scheme AND a
        // `callback` host. Without the host check, a stored XSS on the
        // hosted page could navigate to `myapp://anything?code=XXX` and
        // smuggle an arbitrary auth code into exchangeHostedCode. Code
        // exchange is single-use + PKCE-bound so the attack surface is
        // narrow, but defense in depth: only honour the canonical
        // `<scheme>://callback?code=…` shape that /store/return and
        // /auth callback both emit.
        if url.scheme?.lowercased() == callbackScheme.lowercased() {
            guard url.host?.lowercased() == "callback" else {
                DispatchQueue.main.async {
                    self.onError("Auth callback URL has unexpected host")
                }
                decisionHandler(.cancel)
                return
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems
            if let code = items?.first(where: { $0.name == "code" })?.value {
                DispatchQueue.main.async { self.onCode(code) }
            } else if let error = items?.first(where: { $0.name == "error" })?.value,
                      error == "expired_token" || error == "invalid_token" || error == "token_expired" {
                // Token expired while user was idle — reload hosted page silently
                DispatchQueue.main.async { self.onSessionExpired() }
            } else {
                DispatchQueue.main.async { self.onError("Auth callback missing code parameter") }
            }
            _viewLog.notice("[nav] decidePolicy: CANCEL (callback scheme handled)")
            decisionHandler(.cancel)
            return
        }
        // OAuth provider hand-off — defense in depth.
        //
        // The happy path on iOS/macOS is that the hosted page detects the
        // WKWebView bridge (window.webkit.messageHandlers.oneloNative) and
        // posts an `onelo:native_oauth` message, which we route through
        // startNativeOAuth → ASWebAuthenticationSession. But if the
        // bridge detection ever misfires (older hosted page bundle,
        // injected script error, etc.), the page falls back to a plain
        // window.location.href navigation. Without this guard the
        // WKWebView would happily load github.com / accounts.google.com
        // / appleid.apple.com itself — and:
        //   • Apple App Store Review Guideline 4.5.4 forbids embedded
        //     webviews for third-party OAuth; ships rejected on review.
        //   • Google and Apple actively block known WebView UAs and
        //     show a "this browser is not secure" error.
        //   • Even when it works, the WKWebView has no shared SSO
        //     cookies with Safari, so the user re-enters credentials
        //     and 2FA every time.
        // So we catch the URL ourselves and divert to
        // ASWebAuthenticationSession, which is the canonical native
        // OAuth surface (uses the user's real Safari session, presents
        // chromed system UI, satisfies App Review).
        if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            let host = url.host?.lowercased() ?? ""
            let path = url.path
            let isProviderHost =
                host == "github.com" ||
                host == "accounts.google.com" ||
                host == "appleid.apple.com"
            // Our own init endpoint that 302s to a provider — catching
            // it here means ASWebAuthenticationSession handles the
            // entire redirect chain, including any SSO cookies on the
            // provider side.
            let isOneloOAuthInit = path.range(
                of: #"^/api/sdk/auth/oauth/(github|google|apple)(/|$)"#,
                options: .regularExpression
            ) != nil
            if isProviderHost || isOneloOAuthInit {
                _viewLog.notice("[nav] decidePolicy: CANCEL (OAuth provider, routing to ASWebAuthenticationSession)")
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self] in
                    self?.startNativeOAuth(oauthUrl: url)
                }
                return
            }
        }
        // Open external links (e.g. onelo.tools) in the system browser
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme, (scheme == "https" || scheme == "http"),
           url.host != webView.url?.host {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
            _viewLog.notice("[nav] decidePolicy: CANCEL (external link, opened in system browser)")
            decisionHandler(.cancel)
            return
        }
        // Raise the transition-skeleton overlay BEFORE the WebView starts
        // its network round-trip. Two conditions:
        //   1. This is a main-frame navigation (subframes don't visually
        //      replace the page — overlaying them would be wrong).
        //   2. We've already had at least one successful load, so this
        //      isn't the very first paint (which the SwiftUI skeleton
        //      already covers from before the WebView even existed).
        //
        // The kind (auth / store) is classified from the URL so the
        // overlay paints the right skeleton — single-column for auth
        // re-load, 3-card grid for store. This eliminates the perceived
        // delay between Sign-Up click and skeleton showing up.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if hasFinishedFirstLoad && isMainFrame {
            let kind = navigationKind(for: url)
            DispatchQueue.main.async { self.onNavigationLoading?(true, kind) }
        }
        _viewLog.notice("[nav] decidePolicy: ALLOW")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        _viewLog.notice("[nav] didStartProvisional: url=\(webView.url?.absoluteString ?? "nil", privacy: .public)")
        // The skeleton overlay is raised in decidePolicyFor BEFORE the
        // network round-trip even starts — see the `.allow` path there.
        // This delegate just fires for telemetry purposes.
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        _viewLog.notice("[nav] didCommit: url=\(webView.url?.absoluteString ?? "nil", privacy: .public)")
    }

    // Handle target="_blank" links — open in system browser instead of new WKWebView
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let urlStr = navigationAction.request.url?.absoluteString ?? "nil"
        _viewLog.notice("[nav] createWebViewWith (window.open): url=\(urlStr, privacy: .public)")
        if let url = navigationAction.request.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _viewLog.notice("[nav] didFinish: url=\(webView.url?.absoluteString ?? "nil", privacy: .public) originalPath=\(self.originalPath ?? "nil", privacy: .public)")
        // First successful load arms the transition-skeleton overlay for
        // subsequent navigations. Also drop the overlay if it was raised
        // by didStartProvisionalNavigation a moment ago.
        hasFinishedFirstLoad = true
        DispatchQueue.main.async { self.onNavigationLoading?(false, .auth) }
        // A successful navigation means the WebContent process is healthy again.
        // Re-arm the one-shot recovery so any unrelated crash later gets its own
        // silent reload instead of immediately surfacing an error.
        _hasReloadedAfterCrash = false

        webView.evaluateJavaScript(
            "document.documentElement.style.overflowX='hidden';" +
            "document.body.style.overflowX='hidden';"
        )
        guard let currentURL = webView.url else { return }
        let currentHost = currentURL.host
        let isExternal = currentHost != nil && currentHost != originalHost
        DispatchQueue.main.async { self.onExternalNavigation?(isExternal) }

        // Detect OAuth error redirect to root (e.g. /?error=... after failed OAuth)
        // — reload the hosted auth page silently instead of showing blank/wrong content.
        // Only triggers for root redirects; intentional navigation to /store/hosted etc. is allowed.
        if !isExternal, let path = originalPath, !currentURL.path.hasPrefix(path) {
            let isRootRedirect = currentURL.path == "/" || currentURL.path.isEmpty
            if isRootRedirect {
                DispatchQueue.main.async { self.onSessionExpired() }
            }
            return
        }

        if onContentHeight != nil {
            // Small delay to let Next.js finish rendering before measuring height
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                    let h: CGFloat
                    if let n = result as? CGFloat { h = n }
                    else if let n = result as? Int { h = CGFloat(n) }
                    else if let n = result as? Double { h = CGFloat(n) }
                    else { return }
                    DispatchQueue.main.async { self.onContentHeight?(h) }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        _viewLog.notice("[nav] didFail: url=\(webView.url?.absoluteString ?? "nil", privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(error.localizedDescription, privacy: .public)")
        // Always drop the transition-skeleton overlay on nav failure, even
        // for benign WebKit cancellations (e.g. user clicked a deep-link
        // before HTML finished). Otherwise the overlay would freeze on.
        DispatchQueue.main.async { self.onNavigationLoading?(false, .auth) }
        guard nsError.domain != "WebKitErrorDomain" else { return }
        DispatchQueue.main.async { self.onError(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        _viewLog.notice("[nav] didFailProvisional: url=\(webView.url?.absoluteString ?? "nil", privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { self.onNavigationLoading?(false, .auth) }
        guard nsError.domain != "WebKitErrorDomain" else { return }
        DispatchQueue.main.async { self.onError(error.localizedDescription) }
    }

    /// Recover from a WebContent process crash. WKWebView silently goes blank
    /// when its child process terminates (sandbox kill, OOM, system pressure);
    /// without this delegate the user sees an empty window with no path forward.
    /// Strategy: try one silent reload, then surface the error if the new process
    /// also dies. A healthy didFinish resets the counter so unrelated future
    /// crashes get the same one-shot recovery.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        _viewLog.notice("[nav] WebContent PROCESS TERMINATED: url=\(webView.url?.absoluteString ?? "nil", privacy: .public) alreadyReloaded=\(self._hasReloadedAfterCrash)")
        if _hasReloadedAfterCrash {
            DispatchQueue.main.async {
                self.onError("The sign-in window lost its connection. Please try again.")
            }
            return
        }
        _hasReloadedAfterCrash = true
        webView.reload()
    }
}

// MARK: - ASWebAuthenticationSession presentation context

extension WebAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first ?? NSWindow()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? UIWindow()
        #endif
    }
}

// JS relay: forward selected window.postMessage events → WKScriptMessage handler
private let sessionExpiredRelayScript = WKUserScript(
    source: """
    window.addEventListener('message', function(e) {
        if (!e.data || !e.data.type) return;
        if (e.data.type === 'onelo:session_expired') {
            window.webkit.messageHandlers.oneloNative.postMessage({ type: 'onelo:session_expired' });
        } else if (e.data.type === 'onelo:resize') {
            window.webkit.messageHandlers.oneloNative.postMessage({
                type: 'onelo:resize',
                preset: e.data.preset || null,
                width: typeof e.data.width === 'number' ? e.data.width : null,
                height: typeof e.data.height === 'number' ? e.data.height : null
            });
        }
    });
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true
)

// MARK: - Pre-auth loading skeleton (HTML, single-source)
//
// Rendered inside a bare WKWebView via `loadHTMLString` the instant the
// pre-auth state appears — while `loadHostedUrl()` fetches the hosted-page URL
// from the backend — then torn down when the real hosted WebView mounts.
//
// This is the auth twin of `portalSkeletonHTML` (OneloCustomerPortalView) and
// OneloFeedback's `skeletonHTML`: the skeleton is Onelo-authored HTML, not a
// per-SDK native reimplementation, so it looks identical across every Onelo SDK
// and — critically — is pixel-for-pixel identical to the hosted page's OWN SSR
// skeleton (`frontend/app/auth/hosted/HostedAuthSkeleton.tsx`). Because the
// hosted page re-renders the same skeleton on load, the sequence is
// `Swift-skel → hosted-skel (identical) → form`, so the WebView swap is
// invisible even though two WebView instances are involved.
//
// Body is TRANSPARENT (the branded `checkout_bg_color` is painted BEHIND by the
// container — macOS window background / iOS `.background(...)`), mirroring both
// the real hosted page and `EmbeddedWebAuthView`'s #32 transparency so the
// branded colour is continuous from the skeleton through the loaded page with
// no white/system flash. Layout mirrors HostedAuthSkeleton.tsx EXACTLY
// (top-aligned `48px 24px 0`, 300px column) — the native `AuthSkeletonView`
// centred vertically, which drifted from the hosted skeleton; this removes that
// mismatch. Shimmer uses the same CSS-keyframe sweep as `portalSkeletonHTML`
// (`background-attachment: fixed` is safe here — a bare loadHTMLString WebView
// has no transformed ancestors to re-anchor it).
private func authSkeletonHTML(socialCount: Int) -> String {
    // Social pills + "or" divider are drawn ONLY when the caller knows social
    // will appear (socialCount = plan-gated provider count). Default 0 → none,
    // matching apps where social is disabled (developer OR plan) instead of
    // flashing pills that never load. Mirrors HostedAuthSkeleton's socialCount.
    let socialBlock: String
    if socialCount > 0 {
        let pills = String(repeating: "<div class=\"strong pill\"></div>", count: socialCount)
        socialBlock = pills + "<div class=\"divider\"><div class=\"sk ln\"></div><div class=\"sk wd\"></div><div class=\"sk ln\"></div></div>"
    } else {
        socialBlock = ""
    }
    return """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{background:transparent;font-family:-apple-system,sans-serif;overflow:hidden}
    @keyframes onelo-shimmer{0%{background-position:-60vw 0}100%{background-position:100vw 0}}
    .wrap{display:flex;flex-direction:column;align-items:center;width:100%;padding:48px 24px 0}
    .col{width:100%;max-width:300px;display:flex;flex-direction:column;gap:10px}
    .sk{background-color:rgba(255,255,255,0.04);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.12) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:8px}
    .strong{background-color:rgba(255,255,255,0.08);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.18) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:9px}
    .logo{width:64px;height:64px;border-radius:14px;background:rgba(255,255,255,0.06);border:1.5px solid rgba(255,255,255,0.1);margin-bottom:14px}
    .head{width:200px;height:22px;margin-bottom:10px;border-radius:6px}
    .sub{width:140px;height:13px;opacity:0.7;margin-bottom:28px;border-radius:4px}
    .pill{height:44px;border-radius:9px}
    .divider{display:flex;align-items:center;gap:12px;margin:16px 0 4px}
    .divider .ln{flex:1;height:1px;opacity:0.5;border-radius:0}
    .divider .wd{width:14px;height:11px;opacity:0.5}
    .lbl-e{width:38px;height:11px}
    .input{height:44px}
    .pwrow{display:flex;justify-content:space-between;align-items:center}
    .lbl-p{width:58px;height:11px}
    .forgot{width:90px;height:11px;opacity:0.7}
    .cta{height:48px;margin-top:6px;border-radius:10px}
    .signup{width:200px;height:12px;opacity:0.6;margin-top:6px;align-self:center}
    </style></head><body>
    <div class="wrap">
    <div class="sk logo"></div>
    <div class="sk head"></div>
    <div class="sk sub"></div>
    <div class="col">
    \(socialBlock)
    <div class="sk lbl-e"></div>
    <div class="strong input" style="margin-bottom:2px"></div>
    <div class="pwrow"><div class="sk lbl-p"></div><div class="sk forgot"></div></div>
    <div class="strong input"></div>
    <div class="strong cta"></div>
    <div class="sk signup"></div>
    </div>
    </div>
    </body></html>
    """
}

// Bare, read-only WebView that renders `authSkeletonHTML` and nothing else — no
// coordinator, no message handlers, no navigation delegate. Deliberately
// isolated from the rich `EmbeddedWebAuthView`/`WebAuthCoordinator` so the
// pre-auth skeleton can never trip that machinery. Transparent so the branded
// backing shows through (mirrors EmbeddedWebAuthView's #32 setup).
// Tracks the social-pill count last rendered into the WebView so a live change
// to `oauthProviderCount` (if `readyPublisher` flips `isReady` BEFORE
// `oauthProvidersPublisher` emits the plan-gated list) reloads the skeleton with
// the right pill shape instead of freezing on a stale count. Mirrors Flutter's
// `_skeletonSocials` guard (auth_view.dart) — restores the reactivity the native
// `AuthSkeletonView` had for free.
private final class AuthSkeletonCoordinator {
    var loadedCount: Int = -1
}

#if os(macOS)
private struct AuthSkeletonWebView: NSViewRepresentable {
    let socialCount: Int

    func makeCoordinator() -> AuthSkeletonCoordinator { AuthSkeletonCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        applyOneloWebViewHardening(config)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.verticalScrollElasticity = .none
        context.coordinator.loadedCount = socialCount
        webView.loadHTMLString(authSkeletonHTML(socialCount: socialCount), baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload ONLY when the count actually changed — a no-op on identical
        // re-renders keeps the shimmer from restarting.
        guard context.coordinator.loadedCount != socialCount else { return }
        context.coordinator.loadedCount = socialCount
        nsView.loadHTMLString(authSkeletonHTML(socialCount: socialCount), baseURL: nil)
    }
}
#elseif os(iOS)
private struct AuthSkeletonWebView: UIViewRepresentable {
    let socialCount: Int

    func makeCoordinator() -> AuthSkeletonCoordinator { AuthSkeletonCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        applyOneloWebViewHardening(config)
        let webView = WKWebView(frame: .zero, configuration: config)
        // #32 transparency trio — branded backing shows through (painted behind
        // by the container's `.background(...)`); without it iOS flashes white.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        if #available(iOS 15.0, *) { webView.underPageBackgroundColor = .clear }
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.showsVerticalScrollIndicator = false
        context.coordinator.loadedCount = socialCount
        webView.loadHTMLString(authSkeletonHTML(socialCount: socialCount), baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload ONLY when the count actually changed — see makeNSView twin.
        guard context.coordinator.loadedCount != socialCount else { return }
        context.coordinator.loadedCount = socialCount
        uiView.loadHTMLString(authSkeletonHTML(socialCount: socialCount), baseURL: nil)
    }
}
#endif

#if os(macOS)
private struct EmbeddedWebAuthView: NSViewRepresentable {
    let url: URL
    let callbackScheme: String
    let onCode: (String) -> Void
    let onError: (String) -> Void
    let onSessionExpired: () -> Void
    var onExternalNavigation: ((Bool) -> Void)? = nil
    var onNavigationLoading: ((Bool, NavigationKind) -> Void)? = nil
    var onConsent: ((String) -> Void)? = nil
    @Binding var shouldReload: Bool

    func makeCoordinator() -> WebAuthCoordinator {
        let c = WebAuthCoordinator(callbackScheme: callbackScheme, originalHost: url.host, originalPath: url.path, onCode: onCode, onError: onError, onSessionExpired: onSessionExpired)
        c.onExternalNavigation = onExternalNavigation
        c.onNavigationLoading = onNavigationLoading
        c.onConsent = onConsent
        c.onContentHeight = { [weak c] contentHeight in
            // Skip auto-height once an explicit window size was applied
            // (e.g. after onResize('wide') for the plan store page).
            if c?.manualResizeActive == true { return }
            guard let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first else { return }
            let titleBarHeight = window.frame.height - (window.contentView?.frame.height ?? 0)
            let newWindowHeight = contentHeight + titleBarHeight
            guard abs(window.frame.height - newWindowHeight) > 4 else { return }
            window.minSize = NSSize(width: 440, height: newWindowHeight)
            var frame = window.frame
            frame.origin.y -= (newWindowHeight - frame.height)
            frame.size.height = newWindowHeight
            window.setFrame(frame, display: true, animate: false)
        }
        c.onResize = { [weak c] preset, width, height in
            guard let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first else { return }
            // Explicit dimensions (sent by the store page after measuring
            // its rendered scrollHeight) take precedence over presets.
            // Account for window chrome — the WebView reports CSS content
            // height; the window needs the title bar on top of that.
            let titleBarHeight = window.frame.height - (window.contentView?.frame.height ?? 0)
            var target: NSSize
            if let w = width, let h = height {
                target = NSSize(width: w, height: h + titleBarHeight)
            } else if preset == "wide" {
                target = kWidePresetSize
            } else {
                target = kNarrowPresetSize
            }
            // Cap to the visible screen so we never produce an off-screen
            // or oversized window on small displays.
            if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                target.width  = min(target.width,  visible.width)
                target.height = min(target.height, visible.height)
            }
            // Lock against further auto-height changes from scrollHeight
            // readings (otherwise they'd fight this explicit setFrame).
            c?.manualResizeActive = true
            // Window sizing is fully Onelo-driven: the hosted store page
            // picks a width that fits its current step + plan count and
            // posts onelo:resize on every transition. We deny the user
            // the ability to drag-resize because manual sizes produce
            // ugly text-wrapping states (e.g. shrinking a 3-plan layout
            // below the breakpoint mid-purchase). Removing .resizable
            // hides the resize cursor on edges; pinning min == max == target
            // is a belt-and-suspenders in case styleMask is restored
            // elsewhere.
            window.styleMask.remove(.resizable)
            window.minSize = target
            window.maxSize = target
            var frame = window.frame
            let dx = target.width  - frame.size.width
            let dy = target.height - frame.size.height
            frame.origin.x -= dx / 2
            frame.origin.y -= dy
            frame.size = target
            if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.size.width }
                if frame.minX < visible.minX { frame.origin.x = visible.minX }
                if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.size.height }
                if frame.minY < visible.minY { frame.origin.y = visible.minY }
            }
            window.setFrame(frame, display: true, animate: true)
        }
        c.onNativeOAuth = { [weak c] provider, token in
            guard let c else { return }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = "/api/sdk/auth/oauth/\(provider)"
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
            components?.fragment = nil
            guard let oauthUrl = components?.url else { return }
            c.startNativeOAuth(oauthUrl: oauthUrl)
        }
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral cookie/storage jar for the hosted-login WebView: an auth
        // session must NOT survive sign-out. The default store
        // (WKWebsiteDataStore.default()) is persistent AND shared across every
        // WebView + app launch, so a session/provider cookie set at login
        // lingered and could silently re-authenticate after signOut ("logged
        // out but bounced right back"). A non-persistent store dies with the
        // view and never touches disk or the host app's other WebViews.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "oneloNative")
        config.userContentController.addUserScript(sessionExpiredRelayScript)
        applyOneloWebViewHardening(config)
        let webView = WKWebView(frame: .zero, configuration: config)
        // Transparent background so the dark app background shows through WHILE the
        // hosted page is still loading. Without this the WKWebView paints its default
        // WHITE, flashing a white panel between the skeleton and the loaded page.
        // `drawsBackground=false` is the macOS-supported way to make it see-through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.verticalScrollElasticity = .none
        webView.load(oneloHostedURLRequest(url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if shouldReload {
            nsView.load(oneloHostedURLRequest(url))
            DispatchQueue.main.async { shouldReload = false }
        }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.appearance = nil // follow system
        }
    }
}
#elseif os(iOS)
private struct EmbeddedWebAuthView: UIViewRepresentable {
    let url: URL
    let callbackScheme: String
    let onCode: (String) -> Void
    let onError: (String) -> Void
    let onSessionExpired: () -> Void
    var onExternalNavigation: ((Bool) -> Void)? = nil
    var onNavigationLoading: ((Bool, NavigationKind) -> Void)? = nil
    var onConsent: ((String) -> Void)? = nil
    @Binding var shouldReload: Bool

    func makeCoordinator() -> WebAuthCoordinator {
        let c = WebAuthCoordinator(callbackScheme: callbackScheme, originalHost: url.host, originalPath: url.path, onCode: onCode, onError: onError, onSessionExpired: onSessionExpired)
        c.onExternalNavigation = onExternalNavigation
        c.onNavigationLoading = onNavigationLoading
        c.onConsent = onConsent
        c.onNativeOAuth = { [weak c] provider, token in
            guard let c else { return }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = "/api/sdk/auth/oauth/\(provider)"
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
            components?.fragment = nil
            guard let oauthUrl = components?.url else { return }
            c.startNativeOAuth(oauthUrl: oauthUrl)
        }
        return c
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral cookie/storage jar — see makeNSView for the full rationale.
        // An auth session must not outlive sign-out; the default store is
        // persistent + shared, which let a stale cookie silently re-auth.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "oneloNative")
        config.userContentController.addUserScript(sessionExpiredRelayScript)
        applyOneloWebViewHardening(config)
        let noZoomScript = WKUserScript(
            source: """
            var meta = document.querySelector('meta[name=viewport]');
            if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(noZoomScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        // #32 — Transparent background so the branded container color shows
        // through WHILE the hosted page is still loading. This is the iOS mirror
        // of macOS makeNSView's `drawsBackground=false`: without it the iOS
        // WKWebView paints its default WHITE, flashing a white panel between the
        // branded skeleton and the loaded sign-in page. On iOS `isOpaque=false`
        // is REQUIRED for `backgroundColor` to take effect, and the underlying
        // scrollView paints its own background so it must be cleared too — all
        // three are needed. The branding color itself is painted BEHIND the
        // WebView by the container (see body: `.background(effectiveConfig
        // .backgroundColor)` on the iOS EmbeddedWebAuthView) — unlike macOS,
        // iOS has no window background to fall back on, so transparency alone
        // would otherwise reveal the system (white/black) background.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Belt-and-suspenders for the overscroll/rubber-band region (iOS 15+):
        // `underPageBackgroundColor` defaults to the page background and can
        // momentarily surface the system color during a bounce. Clearing it keeps
        // the branded container color continuous to the very edges.
        if #available(iOS 15.0, *) { webView.underPageBackgroundColor = .clear }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.load(oneloHostedURLRequest(url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if shouldReload {
            uiView.load(oneloHostedURLRequest(url))
            DispatchQueue.main.async { shouldReload = false }
        }
    }
}
#endif

// MARK: - Inline auth view (paid plan) — matches hosted page design

private struct InlineAuthView: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig
    let appName: String
    let appLogoUrl: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                config.backgroundColor.ignoresSafeArea()

                ScrollView {
                    VStack {
                        Spacer(minLength: 0)

                        VStack(spacing: 0) {
                            // Logo
                            Group {
                                if let url = appLogoUrl {
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image {
                                            img.resizable().scaledToFill()
                                                .frame(width: 64, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                        } else {
                                            OneloLogoMark(size: 64)
                                        }
                                    }
                                } else {
                                    OneloLogoMark(size: 64)
                                }
                            }
                            .padding(.bottom, 16)

                            // Title — matches hosted page: "Sign in to AppName"
                            (Text("Sign in to ")
                                .foregroundStyle(config.textColor)
                            + Text(appName)
                                .foregroundStyle(oneloOrange))
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 6)

                            Text("Secure authentication powered by Onelo")
                                .font(.subheadline)
                                .foregroundStyle(config.subtitleColor)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 32)

                            // Form
                            switch vm.screen {
                            case .signIn:
                                InlineSignInForm(vm: vm, config: config)
                            case .signUp:
                                InlineSignUpForm(vm: vm, config: config)
                            case .forgotPassword:
                                InlineForgotPasswordForm(vm: vm, config: config)
                            }
                        }
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 420)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geo.size.height)
                    .frame(maxWidth: .infinity)
                }

                // Footer pinned bottom-center
                VStack {
                    Spacer()
                    OneloFooter()
                        .padding(.bottom, 20)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct InlineSignInForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            AuthTextField("you@example.com", text: $vm.email, config: config)
            AuthSecureField("Password", text: $vm.password, config: config)

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Sign In", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignIn() }
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Text("Don't have an account?").foregroundStyle(config.subtitleColor)
                Button("Sign up") { vm.showSignUp() }
                    .buttonStyle(.plain).foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
    }
}

private struct InlineSignUpForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            AuthTextField("you@example.com", text: $vm.email, config: config)
            AuthSecureField("Password", text: $vm.password, config: config)
            AuthSecureField("Confirm password", text: $vm.confirmPassword, config: config)

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if vm.signUpVerificationSent {
                Text("Check your email to verify your account.")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Create Account", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignUp() }
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Text("Already have an account?").foregroundStyle(config.subtitleColor)
                Button("Sign in") { vm.showSignIn() }
                    .buttonStyle(.plain).foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
    }
}

private struct InlineForgotPasswordForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            Text("Enter your email and we'll send you a reset link.")
                .font(.subheadline).foregroundStyle(config.subtitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            if vm.forgotPasswordSent {
                Text("Check your email for the reset link.")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AuthTextField("you@example.com", text: $vm.email, config: config)

                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AuthButton("Send Reset Link", config: config, isLoading: vm.isLoading) {
                    Task { await vm.submitForgotPassword() }
                }
                .padding(.top, 4)
            }

            Button("Back to sign in") { vm.showSignIn() }
                .buttonStyle(.plain).font(.subheadline).foregroundStyle(config.accentColor)
                .padding(.top, 4)
        }
    }
}

// MARK: - Sign In Screen

private struct SignInScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("Sign in")
                .font(.title2.bold())
                .foregroundStyle(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, config.itemSpacing + 4)

            // Fields group
            VStack(spacing: config.itemSpacing) {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                    .textContentType(.password)
#endif
            }

            // Error
            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            // Primary action
            AuthButton("Sign In", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignIn() }
            }
            .padding(.top, config.itemSpacing + 8)

            // Secondary actions
            VStack(spacing: 8) {
                Button("Forgot password?") { vm.showForgotPassword() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(config.accentColor)

                HStack(spacing: 4) {
                    Text("Don't have an account?")
                        .foregroundStyle(config.subtitleColor)
                    Button("Sign up") { vm.showSignUp() }
                        .buttonStyle(.plain)
                        .foregroundStyle(config.accentColor)
                }
                .font(.subheadline)
            }
            .padding(.top, config.itemSpacing + 4)
        }
    }
}

// MARK: - Sign Up Screen

private struct SignUpScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("Create account")
                .font(.title2.bold())
                .foregroundStyle(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, config.itemSpacing + 4)

            // Fields group
            VStack(spacing: config.itemSpacing) {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                    .textContentType(.newPassword)
#endif

                AuthSecureField("Confirm password", text: $vm.confirmPassword, config: config)
#if os(iOS)
                    .textContentType(.newPassword)
#endif
            }

            // Error / success
            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            if vm.signUpVerificationSent {
                Text("Check your email to verify your account.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            // Primary action
            AuthButton("Create Account", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignUp() }
            }
            .padding(.top, config.itemSpacing + 8)

            // Secondary action
            HStack(spacing: 4) {
                Text("Already have an account?")
                    .foregroundStyle(config.subtitleColor)
                Button("Sign in") { vm.showSignIn() }
                    .buttonStyle(.plain)
                    .foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, config.itemSpacing + 4)
        }
    }
}

// MARK: - Forgot Password Screen

private struct ForgotPasswordScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            VStack(spacing: 6) {
                Text("Reset password")
                    .font(.title2.bold())
                    .foregroundStyle(config.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Enter your email and we'll send you a reset link.")
                    .font(.subheadline)
                    .foregroundStyle(config.subtitleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, config.itemSpacing + 4)

            if vm.forgotPasswordSent {
                Text("Check your email for the reset link.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }

                AuthButton("Send Reset Link", config: config, isLoading: vm.isLoading) {
                    Task { await vm.submitForgotPassword() }
                }
                .padding(.top, config.itemSpacing + 8)
            }

            Button("Back to sign in") { vm.showSignIn() }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(config.accentColor)
                .padding(.top, config.itemSpacing + 4)
        }
    }
}

// MARK: - Reusable components

private struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    let config: OneloAuthConfig

    init(_ placeholder: String, text: Binding<String>, config: OneloAuthConfig) {
        self.placeholder = placeholder
        self._text = text
        self.config = config
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .padding(.horizontal, 12)
            .frame(height: config.inputHeight)
            .background(config.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius)
                    .strokeBorder(config.inputBorderColor, lineWidth: config.inputBorderWidth)
            )
            .foregroundStyle(config.textColor)
    }
}

private struct AuthSecureField: View {
    let placeholder: String
    @Binding var text: String
    let config: OneloAuthConfig

    init(_ placeholder: String, text: Binding<String>, config: OneloAuthConfig) {
        self.placeholder = placeholder
        self._text = text
        self.config = config
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .padding(.horizontal, 12)
            .frame(height: config.inputHeight)
            .background(config.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius)
                    .strokeBorder(config.inputBorderColor, lineWidth: config.inputBorderWidth)
            )
            .foregroundStyle(config.textColor)
    }
}

private struct AuthButton: View {
    let label: String
    let config: OneloAuthConfig
    let isLoading: Bool
    let action: () -> Void

    init(_ label: String, config: OneloAuthConfig, isLoading: Bool, action: @escaping () -> Void) {
        self.label = label
        self.config = config
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(config.buttonForegroundColor)
                } else {
                    Text(label).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: config.buttonHeight)
            .background(config.accentColor)
            .foregroundStyle(config.buttonForegroundColor)
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Skeleton shimmer primitive

/// Shared skeleton shimmer primitive used by BOTH `AuthSkeletonView` and
/// `StoreSkeletonView` (single source of truth — no copy-pasted shimmer).
///
/// One soft, WIDE highlight that drifts left → right → left (ping-pong) with an
/// ease-in-out curve. Deliberately "gentle": low-contrast and slow (≈4.9s
/// round-trip), chosen in design review over the earlier fast linear scan —
/// the swept band there read as a hard bright bar; this reads as a calm,
/// barely-there breathing glow. Each box owns its own `phase`, but they all
/// share the same duration + start (onAppear), so the whole skeleton pulses in
/// unison.
///
/// Size it from the caller with `.frame(...)`. `strong` = the slightly lighter
/// base used for "filled" elements (OAuth pills, inputs, CTA, plan cards).
///
/// **Why neutral grey only:** an earlier orange tint on the CTA placeholder
/// read as a broken brown bar against the dark background and pulled focus to
/// one element. Netflix/YouTube/Apple all use a single greyscale shimmer family
/// across every placeholder — a per-element colour reads as "broken UI".
private struct OneloShimmerFill: View {
    let radius: CGFloat
    var strong: Bool = false
    @State private var phase: CGFloat = 0

    /// Half of the ≈4.9s round-trip — `autoreverses: true` plays it back, so
    /// the full there-and-back cycle is 2× this.
    private static let legDuration: Double = 2.45

    var body: some View {
        let baseFill = Color(white: strong ? 0.14 : 0.10)
        // Near-white highlight kept at very low alpha so the sweep only just
        // brushes the surface (matches the "delikatność 0.20" design pick).
        let highlight = Color(white: strong ? 0.80 : 0.73)
        RoundedRectangle(cornerRadius: radius)
            .fill(baseFill)
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    // Band 2.6× the element so only its soft middle is ever in
                    // view — the element never goes fully dark at the turns.
                    let bandWidth = w * 2.6
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: highlight.opacity(strong ? 0.10 : 0.095), location: 0.5),
                            .init(color: .clear, location: 1.0),
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth, height: geo.size.height)
                    // Drift: the bright middle travels across and eases back.
                    // −1.6·w matches the (2.6 − 1.0) overscan so the sweep stays
                    // symmetric around centre.
                    .offset(x: -1.6 * w * phase)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
            )
            .onAppear {
                phase = 0
                withAnimation(.easeInOut(duration: Self.legDuration).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Auth Skeleton View

/// Netflix-style loading skeleton shown while OneloAuthView fetches the
/// hosted-page URL from the backend.
///
/// **Layout matches the real hosted page** (HostedAuthForm.tsx +
/// HostedAuthSkeleton.tsx on the Next.js side): logo → heading →
/// subheading → 3 OAuth pills → "or" divider → email field → password field →
/// primary CTA → sign-up link. Same order, same vertical rhythm, same column
/// width (300pt max). When the WebView mounts and the Next.js skeleton paints,
/// the swap is invisible. Each placeholder is a `OneloShimmerFill` (shared
/// drift shimmer).
struct AuthSkeletonView: View {
    /// Number of social-login pills to draw. Default 0 = none — matches apps where
    /// social is disabled by the developer OR by plan. The hosted sign-in form
    /// plan-gates social, so unconditionally drawing 3 pills made the skeleton flash
    /// buttons that then vanish on swap-in (jarring). Callers that KNOW social will
    /// appear can pass the real count; today no caller does, so it stays 0.
    var providerCount: Int = 0
    var body: some View {
        VStack(spacing: 0) {
            // Flexible top spacer (paired with the flexible bottom Spacer) so the
            // content is VERTICALLY CENTERED, matching the hosted form's
            // `justify-content: center`. A fixed top pin made the skeleton sit too
            // high vs the real fields once the social pills were removed. minLength
            // keeps a little breathing room on very short windows.
            Spacer(minLength: 24)

            // Logo box — fixed 64×64, mirrors hosted-page logo container.
            shimmerRect(width: 64, height: 64, radius: 14)

            Spacer().frame(height: 14)

            // Heading ("Sign in to <App>") — fixed 200×22.
            shimmerRect(width: 200, height: 22, radius: 6)

            Spacer().frame(height: 10)

            // Subheading ("Secure authentication") — fixed 140×13.
            shimmerRect(width: 140, height: 13, radius: 4)
                .opacity(0.7)

            Spacer().frame(height: 28)

            // Form column — capped at 300pt, matches HostedAuthForm.tsx.
            // `.frame(maxWidth: 300)` reliably constrains the children
            // now that we use full-width modifiers instead of
            // GeometryReader (which used to silently override this cap).
            VStack(spacing: 10) {
                // OAuth provider pills + "or" divider — drawn ONLY when we know
                // social will appear (providerCount > 0). Default 0 → none, so the
                // skeleton matches apps where social is disabled (by the developer
                // OR by plan) instead of flashing pills that then vanish on swap-in.
                if providerCount > 0 {
                    ForEach(0..<providerCount, id: \.self) { _ in
                        shimmerBar(height: 44, radius: 9, strong: true)
                    }

                    // "or" divider — two thin grey lines + small placeholder
                    // for the word itself.
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .frame(height: 1)
                        shimmerRect(width: 14, height: 11, radius: 3)
                            .opacity(0.6)
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .frame(height: 1)
                    }
                    .padding(.vertical, 6)
                }

                // Email label (38×11, left-aligned via HStack+Spacer)
                HStack(spacing: 0) {
                    shimmerRect(width: 38, height: 11, radius: 3)
                    Spacer()
                }
                shimmerBar(height: 44, radius: 9, strong: true)

                // Password label + "Forgot password?" link row.
                HStack(spacing: 0) {
                    shimmerRect(width: 58, height: 11, radius: 3)
                    Spacer()
                    shimmerRect(width: 90, height: 11, radius: 3)
                        .opacity(0.7)
                }
                shimmerBar(height: 44, radius: 9, strong: true)

                // Primary CTA (Sign In) — neutral grey, slightly taller
                // (48pt vs 44pt OAuth pills) so the swap-in to the brand-
                // coloured button feels like a "fill-in", not a re-layout.
                shimmerBar(height: 48, radius: 10, strong: true)
                    .padding(.top, 4)

                // "Don't have an account? Sign up" row — centered.
                HStack {
                    Spacer()
                    shimmerRect(width: 200, height: 12, radius: 4)
                        .opacity(0.6)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 300)

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shimmer primitives (thin wrappers over the shared OneloShimmerFill)

    /// Fixed-width shimmer (logo, heading, labels). Width and height in pt.
    private func shimmerRect(width: CGFloat, height: CGFloat, radius: CGFloat, strong: Bool = false) -> some View {
        OneloShimmerFill(radius: radius, strong: strong)
            .frame(width: width, height: height)
    }

    /// Full-width shimmer (OAuth pills, inputs, CTA). Stretches to fill
    /// the parent constraint — pair with `.frame(maxWidth: 300)` on a
    /// containing VStack to cap the column width.
    private func shimmerBar(height: CGFloat, radius: CGFloat, strong: Bool = false) -> some View {
        OneloShimmerFill(radius: radius, strong: strong)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Store skeleton (paywall sign-up transition)

/// Skeleton variant used when the auth WebView is navigating to the
/// /store/hosted page (the "Choose your plan" view). Mirrors the real
/// store layout: app logo + heading + subheading on the left, then a
/// 3-card price grid below. Showing the auth skeleton during this
/// transition was wrong — the user clicks "Sign up" expecting a plan
/// picker, not another sign-in form.
///
/// Shares the shimmer primitive look with AuthSkeletonView so the
/// brand language stays consistent across both transitions.
struct StoreSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            // App logo (matches store header logo container — 56×56 with
            // soft border, slightly smaller than the auth-view logo).
            shimmerRect(width: 56, height: 56, radius: 12)

            Spacer().frame(height: 18)

            // "Choose your plan" heading
            shimmerRect(width: 280, height: 32, radius: 6)

            Spacer().frame(height: 10)

            // App name subheading
            shimmerRect(width: 90, height: 14, radius: 4)
                .opacity(0.7)

            Spacer().frame(height: 28)

            // Plan grid — 3 cards side-by-side. Equal spacing matches the
            // real Store layout's `gridTemplateColumns: repeat(3, 1fr)`.
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    planCard
                }
            }

            Spacer()

            // "Powered by Onelo" footer placeholder, dim.
            HStack {
                Spacer()
                shimmerRect(width: 130, height: 14, radius: 4)
                    .opacity(0.4)
                Spacer()
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// One plan card. Title bar + price bar + spacer + CTA button. Min
    /// height keeps cards uniform regardless of placeholder text length.
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Plan name
            shimmerRect(width: 100, height: 28, radius: 6, strong: true)
            // Price line
            shimmerRect(width: 130, height: 26, radius: 6, strong: true)
            Spacer().frame(height: 4)
            // Description line (optional, dim)
            shimmerRect(width: 160, height: 12, radius: 4)
                .opacity(0.55)
            Spacer().frame(minHeight: 24)
            // CTA button — full-width inside the card.
            shimmerBar(height: 44, radius: 10, strong: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.14), lineWidth: 1)
        )
    }

    // MARK: - Shimmer primitives (thin wrappers over the shared OneloShimmerFill)

    private func shimmerRect(width: CGFloat, height: CGFloat, radius: CGFloat, strong: Bool = false) -> some View {
        OneloShimmerFill(radius: radius, strong: strong)
            .frame(width: width, height: height)
    }

    private func shimmerBar(height: CGFloat, radius: CGFloat, strong: Bool = false) -> some View {
        OneloShimmerFill(radius: radius, strong: strong)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Onelo brand color

private let oneloOrange = Color(red: 0.976, green: 0.451, blue: 0.086) // #f97316

// MARK: - Onelo Logo (with dark background — used in hosted flow button)

private struct OneloLogo: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(red: 0.067, green: 0.067, blue: 0.067))
                .frame(width: size, height: size)
            OneloLogoMark(size: size * 0.72)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Onelo Logo Mark (just the white symbol, no background)

private struct OneloLogoMark: View {
    var size: CGFloat = 56

    var body: some View {
        Image("onelo-logo-white", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

// MARK: - Onelo Footer (with logo, left-aligned)

private struct OneloFooter: View {
    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            HStack(spacing: 4) {
                Image("onelo-logo-white", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .opacity(0.4)
                Text("Powered by ")
                    .foregroundStyle(Color.primary.opacity(0.35))
                + Text("Onelo")
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hosted Sign In Button (legacy — no longer used by OneloAuthView)
// Kept for reference only. OneloAuthView now uses EmbeddedWebAuthView (WKWebView).

private struct HostedSignInButton: View {
    let auth: any OneloAuthProtocol
    let config: OneloAuthConfig
    let onSuccess: ((OneloSession) -> Void)?

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appName: String = "App"
    @State private var appLogoUrl: URL? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                config.backgroundColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // App / Onelo branding block
                    VStack(spacing: 16) {
                        // Show app logo if available, otherwise Onelo logo
                        if let logoUrl = appLogoUrl {
                            AsyncImage(url: logoUrl) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                } else {
                                    OneloLogo(size: 72)
                                }
                            }
                        } else {
                            OneloLogo(size: 72)
                        }

                        VStack(spacing: 4) {
                            (Text("Sign in to ")
                                .foregroundStyle(config.textColor)
                            + Text(appName)
                                .foregroundStyle(oneloOrange))
                            .font(.title2.bold())

                            Text("Secure authentication powered by Onelo")
                                .font(.subheadline)
                                .foregroundStyle(config.subtitleColor)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.bottom, 40)

                    // Sign In button
                    VStack(spacing: 12) {
                        if isLoading {
                            ProgressView()
                                .tint(oneloOrange)
                                .frame(height: config.buttonHeight)
                        } else {
                            Button {
                                Task { await signIn() }
                            } label: {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: config.buttonHeight)
                                    .background(oneloOrange)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
                            }
                            .buttonStyle(.plain)
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, config.contentPadding.leading)

                    Spacer()

                    // Footer — left aligned
                    HStack {
                        OneloFooter()
                        Spacer()
                    }
                    .padding(.horizontal, config.contentPadding.leading)
                    .padding(.bottom, 24)
                }
                .frame(width: geo.size.width)
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await name in oneloAuth.$hostedAppName.values {
                appName = name
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await logoUrl in oneloAuth.$hostedAppLogoUrl.values {
                appLogoUrl = logoUrl
            }
        }
    }

    @MainActor
    private func signIn() async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let url = try await oneloAuth.initiateHostedFlow()
            // Legacy path — callers should use OneloAuthView (WKWebView) instead
            _ = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Standalone consent gate (.oneloConsentGate)

/// Enforces blocking legal-consent updates on a view you control — for apps
/// that use `OneloAuthView` only for the sign-in flow and switch to their own
/// UI after login (so `OneloAuthView` is no longer mounted to host the gate).
///
/// Apply it to your post-login root:
/// ```swift
/// HomeView()
///     .environmentObject(auth)
///     .oneloConsentGate(auth: auth)
/// ```
/// While a blocking version is pending (e.g. updated Terms past its effective
/// date), a full-cover hosted gate is shown OVER your UI — the user must tap
/// "Accept & Continue" or "Sign out"; there is no dismiss, so the app can't be
/// used until consent is given. Re-checks on appear, on app-foreground, and on
/// the real-time `legal.consent_required` SSE push (instant on a running app).
public extension View {
    func oneloConsentGate(auth: OneloAuth) -> some View {
        modifier(OneloConsentGateModifier(auth: auth))
    }
}

struct OneloConsentGateModifier: ViewModifier {
    @ObservedObject var auth: OneloAuth
    @State private var blocking: OneloConsentRequirement?
    /// Per-instance identity for the single-owner gate claim — keeps this
    /// modifier from duplicating a gate already shown by OneloAuthView's
    /// built-in gate or by this modifier in another window.
    @State private var gateToken = UUID()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
            if let req = blocking, let url = req.consentUrl {
                // Opaque full-cover gate — blocks the app behind it. Only
                // "Accept & Continue" or "Sign out" (emitted via onConsent)
                // exit it; there is no dismiss affordance.
                ZStack {
                    Color(.sRGB, white: 0.98, opacity: 1).ignoresSafeArea()
                    EmbeddedWebAuthView(
                        url: url,
                        callbackScheme: auth.callbackScheme,
                        onCode: { _ in },
                        onError: { _ in },
                        onSessionExpired: { },
                        onConsent: { action in
                            Task { await handleConsent(action, requirement: req) }
                        },
                        shouldReload: .constant(false)
                    )
                    .ignoresSafeArea()
                }
                .transition(.opacity)
            }
        }
        .task { await checkConsent() }
        .onChange(of: auth.consentRevision) { _ in
            // Real-time push: a blocking version just took effect.
            Task { await checkConsent() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await checkConsent() } }
        }
        .onChange(of: auth.currentSession?.user.id) { _ in
            // Signed out / switched user → drop any stale gate.
            if auth.currentSession == nil { blocking = nil; auth.releaseConsentGate(gateToken) }
        }
        .onChange(of: auth.consentGateOwner) { owner in
            // Gate freed by another presenter → re-check to claim it if we still
            // have a blocking consent pending. Claiming sets a non-nil owner, so
            // this won't loop.
            if owner == nil { Task { await checkConsent() } }
        }
        .onDisappear {
            auth.releaseConsentGate(gateToken)
        }
    }

    @MainActor
    private func checkConsent() async {
        guard auth.currentSession != nil else {
            blocking = nil
            auth.releaseConsentGate(gateToken)
            return
        }
        let items = await auth.requiredConsents()
        if let blocker = items.first(where: { $0.blocking }) {
            // Show only while we own the claim — otherwise OneloAuthView's gate
            // (or another window) already presents it. No duplicate gates.
            blocking = auth.claimConsentGate(gateToken) ? blocker : nil
        } else {
            blocking = nil
            auth.releaseConsentGate(gateToken)
        }
    }

    @MainActor
    private func handleConsent(_ action: String, requirement: OneloConsentRequirement) async {
        if action == "accept" {
            try? await auth.acceptConsent(versionId: requirement.versionId)
            await checkConsent()   // clears the gate if nothing else blocks
        } else {
            try? await auth.signOut()
            blocking = nil
        }
    }
}
