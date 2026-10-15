// OneloCustomerPortalView — drop-in SwiftUI view for the in-app
// Customer Portal. Renders the hosted portal page inside a WKWebView
// embedded directly in the host app's window — same pattern as
// `OneloAuthView`, just for the post-sign-in portal flow.
//
// Present it yourself (below), or let the SDK present it in its own window:
// `auth.openCustomerPortal(intent:)` and `onelo.openUpgrade(forPlan:)` both
// render this view (#606). It replaced ASWebAuthenticationSession, which on
// macOS showed a system consent prompt, detached into a system-managed window
// and — like any browser tab — never received the store's hand-back.
//
// Usage (macOS, in a SwiftUI host):
//   @State private var showPortal = false
//
//   Button("Manage subscription") { showPortal = true }
//     .sheet(isPresented: $showPortal) {
//       OneloCustomerPortalView(auth: auth) { showPortal = false }
//     }
//
// Straight into the plan picker (#606):
//   OneloCustomerPortalView(auth: auth, intent: .changePlan) { showPortal = false }
//
// iOS: same — works via `.sheet`, `.fullScreenCover`, or
// `NavigationStack` push.

import SwiftUI
import WebKit
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
public struct OneloCustomerPortalView: View {
    /// Closure that fetches the hosted URL — typically
    /// `{ try await auth.initiateCustomerPortal() }`. Taking a closure
    /// instead of the OneloAuth instance keeps this view decoupled from
    /// the auth module's internal types (notably its `config` is
    /// internal); the convenience init below wires this up for callers.
    private let urlProvider: () async throws -> URL
    /// Mints a fresh PORTAL when the page's token dies (#613 / #614). The same
    /// as `urlProvider` for a portal; for an upgrade (whose first page is the
    /// store) it is still the portal, never the upgrade URL again.
    private let renewProvider: () async throws -> URL
    private let callbackScheme: String
    private let onDismiss: () -> Void
    /// Routes the portal's return deep-link (`<scheme>://callback?source=portal`)
    /// through `auth.handlePortalCallback`, so a hard account event (deletion /
    /// revoke / compromise) clears the local session — matching
    /// every other portal presentation. No-op for the lower-level init that has no
    /// OneloAuth instance to clear.
    private let onPortalCallback: (URL) -> Void
    /// Reads the app's current brand tokens (#681) — `OneloAuth.brandTokens`,
    /// which portal-initiate refreshes. Neutral for the provider-only init.
    private let brandTokens: () -> OneloBrandTokens
    @State private var tokens: OneloBrandTokens

    @State private var hostedUrl: URL? = nil
    @State private var errorMessage: String? = nil
    /// #40 Phase 2 — true once the hosted portal posts `onelo:ready`; hides the
    /// native fail-safe ✕ so the hosted page's canonical ✕ owns the affordance.
    @State private var hostedReady = false
    /// #44 — armed ~3.5s after appear (see `.task`); the fail-safe ✕ shows only
    /// after this OR on error, so a normal fast load never flashes it.
    @State private var failsafeTimedOut = false

    /// Convenience init that pulls everything off an OneloAuth instance.
    ///
    /// - Parameter intent: `.changePlan` opens the portal straight into the
    ///   plan picker (#606). `nil` opens the management home.
    public init(auth: OneloAuth, intent: OneloPortalIntent? = nil, onDismiss: @escaping () -> Void) {
        self.urlProvider = { try await auth.initiateCustomerPortal(intent: intent) }
        self.renewProvider = { try await auth.initiateCustomerPortal() }
        self.callbackScheme = auth.callbackScheme
        self.onDismiss = onDismiss
        self.onPortalCallback = { url in auth.handlePortalCallback(url) }
        self.brandTokens = { auth.brandTokens }
        self._tokens = State(initialValue: auth.brandTokens)
    }

    /// The SDK presenter's init (#606): any first page (a portal, or the store /
    /// plan switch `openUpgrade` resolved), a portal for renewal, and the
    /// session-clearing callback.
    init(
        urlProvider: @escaping () async throws -> URL,
        renewProvider: @escaping () async throws -> URL,
        callbackScheme: String,
        onPortalCallback: @escaping (URL) -> Void,
        brandTokens: @escaping () -> OneloBrandTokens,
        onDismiss: @escaping () -> Void
    ) {
        self.urlProvider = urlProvider
        self.renewProvider = renewProvider
        self.callbackScheme = callbackScheme
        self.onPortalCallback = onPortalCallback
        self.onDismiss = onDismiss
        self.brandTokens = brandTokens
        self._tokens = State(initialValue: brandTokens())
    }

    /// Lower-level init for hosts that want to inject a custom URL
    /// provider (e.g. tests, preview environments). No session-clearing on
    /// hard events — there's no OneloAuth instance here to clear.
    public init(
        urlProvider: @escaping () async throws -> URL,
        callbackScheme: String,
        onDismiss: @escaping () -> Void
    ) {
        self.urlProvider = urlProvider
        self.renewProvider = urlProvider
        self.callbackScheme = callbackScheme
        self.onDismiss = onDismiss
        self.onPortalCallback = { _ in }
        self.brandTokens = { .neutral }
        self._tokens = State(initialValue: .neutral)
    }

    public var body: some View {
        let palette = OneloBrandPalette(tokens)
        return ZStack {
            // The brand page_bg (#681) — what OneloAuthView and the hosted
            // portal paint — so the transition is seamless (no white flash).
            palette.pageBg.ignoresSafeArea()

            // WebView mounts UP FRONT and renders the shimmer skeleton
            // immediately (mirrors OneloFeedback's loadHTMLString→swap
            // idiom). Once `hostedUrl` resolves it swaps to the real
            // portal page — no ProgressView spinner, no black flash.
            PortalEmbeddedWebView(
                hostedUrl: hostedUrl,
                callbackScheme: callbackScheme,
                onDone: { callbackUrl in
                    // Hard account events (deletion / revoke / compromise)
                    // ride back on the callback URL — route them through the
                    // shared handler so the embedded view clears the session
                    // exactly like every other portal presentation, then dismiss.
                    if let callbackUrl { onPortalCallback(callbackUrl) }
                    onDismiss()
                },
                onError: { msg in
                    errorMessage = msg
                },
                onReady: { hostedReady = true },
                // #613 / #614 — the page's portal token died; mint a fresh
                // portal with the user's session and hand it back.
                onRenew: { [renewProvider] requestId in
                    do {
                        let url = try await renewProvider()
                        return portalRenewReplyScript(requestId: requestId, hostedUrl: url.absoluteString, reason: "")
                    } catch {
                        return portalRenewReplyScript(requestId: requestId, hostedUrl: nil, reason: portalRenewFailureReason(error))
                    }
                }
            )
            .ignoresSafeArea()

            if let msg = errorMessage {
                VStack(spacing: 12) {
                    Text(msg)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                    Button("Close") { onDismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.buttonText)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(palette.buttonBg)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius))
                }
                .padding(24)
            }

            // Unified Onelo close affordance (`OneloCloseButton`) — identical to
            // OneloFeedback's `✕`. The portal body is a ZStack (no NavigationStack),
            // so a `.toolbar` wouldn't render — overlay the SAME control directly and
            // route it through the EXISTING `onDismiss()`. Respects the safe area.
            // (#35: this was a bare `Button` without `.buttonStyle(.plain)`, so iOS
            // tinted the `✕` accent-blue; the shared component carries `.plain`.)
            // #40 Phase 2 + #44 — native ✕ is a FAIL-SAFE only, and must NOT flash
            // during a normal fast load. Show it ONLY after a load error OR once a
            // ~3.5s grace has elapsed without the hosted page mounting. A fast load
            // posts `onelo:ready` (`hostedReady`) well before the grace, so the ✕
            // never appears; a stuck/failed load still gets a way out. Once the
            // hosted page mounts its own canonical ✕ owns the affordance.
            if !hostedReady && (failsafeTimedOut || errorMessage != nil) {
                VStack {
                    HStack {
                        Spacer()
                        OneloCloseButton(style: .overlay) { onDismiss() }
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 640)
        .environment(\.oneloBrandTokens, tokens)
        .task { await loadPortal() }
        .task {
            // #44 — arm the fail-safe ✕ only after a grace period, so a normal fast
            // load never flashes it. Cancelled automatically if the view goes away.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !hostedReady { failsafeTimedOut = true }
        }
    }

    private func loadPortal() async {
        do {
            let url = try await urlProvider()
            tokens = brandTokens() // portal-initiate may have refreshed them (#681)
            hostedUrl = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pre-connect loading skeleton
//
// Rendered inside the WKWebView via `loadHTMLString` the instant the view
// mounts — before the hosted URL resolves — then swapped for the real portal
// page. Canonical skeleton shared across all Onelo SDKs, mirroring
// `frontend/app/customer/portal/PortalSkeleton.tsx` and the shipped React
// Native portal skeleton. Cross-platform (no `#if os` gate): the same static
// HTML renders identically on macOS and iOS. #681: painted from the brand tokens.
func oneloPortalSkeletonHTML(_ t: OneloBrandTokens) -> String {
    """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{background:\(t.pageBg);font-family:\(t.bodyFont);overflow:hidden}
    \(t.skeletonCSS)
    .wrap{display:flex;flex-direction:column;align-items:center;width:100%;padding:48px 24px 0}
    .col{width:100%;max-width:432px;display:flex;flex-direction:column;gap:14px}
    .icon{width:64px;height:64px;border-radius:\(Int(t.cardRadius))px;margin-bottom:14px;border:1.5px solid \(t.border)}
    .title{width:200px;height:22px;margin-bottom:10px}
    .sub{width:80px;height:13px;opacity:0.7;margin-bottom:32px}
    .c1{height:240px;border-radius:\(Int(t.cardRadius))px}
    .c2{height:80px;border-radius:\(Int(t.cardRadius))px}
    .c3{height:140px;border-radius:\(Int(t.cardRadius))px}
    </style></head><body>
    <div class="wrap">
    <div class="sk icon"></div>
    <div class="sk title"></div>
    <div class="sk sub"></div>
    <div class="col"><div class="strong c1"></div><div class="strong c2"></div><div class="strong c3"></div></div>
    </div>
    </body></html>
    """
}

// MARK: - Navigation routing

/// What the embedded portal WebView does with a navigation. Pure so the rule is
/// unit-testable without a WKWebView.
enum PortalNavigation: Equatable {
    /// `onelo://ready` — the hosted page mounted; hide the native fail-safe ✕.
    case ready
    /// A store purchase (#592) or a code-less plan switch (#599) finished in the
    /// portal WebView — a portal "Change plan" or `openUpgrade`. Dismiss: the
    /// buyer is already signed in; the portal callback reports the change so
    /// the plan is reconciled at once (#659).
    case checkoutComplete
    /// The store link is spent and the buyer tapped "Return to app" (#627).
    /// Dismiss; nothing finished.
    case storeCancel
    /// `<callbackScheme>://…` — the portal's own return deep-link.
    case done
    /// `onelo://renew-portal?request_id=…` — the hosted page's portal token died
    /// and it asks for a fresh portal (#613 / #614). Not a close.
    case renew(requestId: String)
    case allow
}

func routePortalNavigation(_ url: URL?, callbackScheme: String) -> PortalNavigation {
    guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
    if scheme == "onelo" {
        switch url.host {
        case "ready": return .ready
        case "callback":
            // The store's hand-back, relayed from its postMessage in the
            // deep-link wire format (see `portalRelayScriptSource`) and decoded
            // by the one Store Hand-back decoder (#615 / #627).
            switch classifyHandBack(url) {
            case .purchase?, .switched?: return .checkoutComplete
            case .error?: return .storeCancel
            case .portalClosed?: return .done
            case nil: return .allow
            }
        case "renew-portal":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "request_id" })?.value
            guard let id, !id.isEmpty else { return .allow }
            return .renew(requestId: id)
        default: return .allow
        }
    }
    if !callbackScheme.isEmpty, scheme == callbackScheme.lowercased() { return .done }
    return .allow
}

/// Injected at document-start into the embedded portal WebView (see
/// `PortalWebCoordinator.relayScript`). Internal so the contract is testable.
///
/// The store's hand-back postMessage is only re-expressed here, in the
/// deep-link wire format of frontend/lib/store-hand-back.ts `handBackDeepLink`
/// (`onelo://callback?code=` | `?source=store&event=` | `?error=`), so that
/// `classifyHandBack` stays the one decoder (#627). The relay decides nothing.
let portalRelayScriptSource = """
(function() {
  window.OneloPortalHost = true;
  function handBack(query) { window.location.href = 'onelo://callback?' + query; }
  window.addEventListener('message', function(e) {
    var d = e.data;
    if (!d) return;
    if (d.type === 'onelo:ready') {
      window.location.href = 'onelo://ready';
    } else if (d.type === 'onelo:code' && typeof d.code === 'string') {
      handBack('code=' + encodeURIComponent(d.code));
    } else if (d.type === 'onelo:done') {
      handBack('source=store&event=' + encodeURIComponent(typeof d.reason === 'string' ? d.reason : ''));
    } else if (d.type === 'onelo:cancel') {
      handBack('error=' + encodeURIComponent(d.reason === 'expired' ? 'token_expired' : 'cancelled'));
    } else if (e.source === window && e.data.type === 'onelo:renew_request'
               && e.data.kind === 'portal' && typeof e.data.request_id === 'string') {
      window.location.href = 'onelo://renew-portal?request_id=' + encodeURIComponent(e.data.request_id);
    }
  });
})();
"""

/// The script that answers a renew request inside the page (#613 / #614): a
/// self-post the page trusts (`event.source === window`). `hostedUrl` nil →
/// `renew_failed` with `reason`. Internal so the contract is testable.
func portalRenewReplyScript(requestId: String, hostedUrl: String?, reason: String) -> String {
    var reply: [String: String] = ["request_id": requestId]
    if let hostedUrl {
        reply["type"] = "onelo:renewed"
        reply["hosted_url"] = hostedUrl
    } else {
        reply["type"] = "onelo:renew_failed"
        reply["reason"] = reason
    }
    let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
    let literal = String(data: data, encoding: .utf8) ?? "{}"
    return "window.postMessage(\(literal), '*');"
}

/// `scheme://host[:port]` of a URL, lowercased. A fresh portal is a bearer
/// credential, so the coordinator answers a renew request only while the WebView
/// is still on the portal's own origin (#614).
func portalOrigin(of url: URL?) -> String? {
    guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    if let port = url.port { return "\(scheme)://\(host):\(port)" }
    return "\(scheme)://\(host)"
}

/// The reason the page shows when renewal fails: signed out, or anything else.
func portalRenewFailureReason(_ error: Error) -> String {
    if case OneloError.notAuthenticated = error { return "not_authenticated" }
    return "renew_failed"
}

// MARK: - WebView wrapper (per-platform)

#if canImport(AppKit) && os(macOS)
private struct PortalEmbeddedWebView: NSViewRepresentable {
    @Environment(\.oneloBrandTokens) private var tokens
    /// Optional so the WebView can mount and render the skeleton BEFORE the
    /// hosted URL resolves. Swapped to the real page in `updateNSView` once
    /// it becomes non-nil (guarded by the coordinator's `didLoadReal` flag so
    /// re-renders don't reload).
    let hostedUrl: URL?
    let callbackScheme: String
    let onDone: (URL?) -> Void
    let onError: (String) -> Void
    var onReady: (() -> Void)? = nil
    var onRenew: ((String) async -> String)? = nil

    func makeCoordinator() -> PortalWebCoordinator {
        let c = PortalWebCoordinator(callbackScheme: callbackScheme, onDone: onDone, onError: onError)
        c.onReady = onReady
        c.onRenew = onRenew
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        applyPortalWebViewHardening(cfg)
        cfg.userContentController.addUserScript(PortalWebCoordinator.relayScript)
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        // uiDelegate: the Receipts list uses target="_blank" links (Stripe
        // invoice PDF / hosted receipt). Without a WKUIDelegate that handles
        // createWebViewWith, WKWebView SILENTLY IGNORES target="_blank" → the
        // Download links do nothing. Mirror OneloAuthView: open them in the
        // system browser.
        v.uiDelegate = context.coordinator
        // Show the shimmer skeleton immediately (static HTML, no navigation, so
        // the navigation delegate won't fire spuriously). The real portal page
        // is swapped in by updateNSView once the hosted URL resolves.
        v.loadHTMLString(oneloPortalSkeletonHTML(tokens), baseURL: nil)
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        loadRealIfNeeded(nsView, coordinator: context.coordinator)
    }
}
#elseif canImport(UIKit)
private struct PortalEmbeddedWebView: UIViewRepresentable {
    @Environment(\.oneloBrandTokens) private var tokens
    /// Optional so the WebView can mount and render the skeleton BEFORE the
    /// hosted URL resolves. Swapped to the real page in `updateUIView` once
    /// it becomes non-nil (guarded by the coordinator's `didLoadReal` flag so
    /// re-renders don't reload).
    let hostedUrl: URL?
    let callbackScheme: String
    let onDone: (URL?) -> Void
    let onError: (String) -> Void
    var onReady: (() -> Void)? = nil
    var onRenew: ((String) async -> String)? = nil

    func makeCoordinator() -> PortalWebCoordinator {
        let c = PortalWebCoordinator(callbackScheme: callbackScheme, onDone: onDone, onError: onError)
        c.onReady = onReady
        c.onRenew = onRenew
        return c
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        applyPortalWebViewHardening(cfg)
        cfg.userContentController.addUserScript(PortalWebCoordinator.relayScript)
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        // uiDelegate: Receipts use target="_blank" links (Stripe PDF / receipt).
        // Without createWebViewWith, WKWebView silently ignores them → the
        // Download links do nothing. Open them in the system browser (mirror
        // OneloAuthView).
        v.uiDelegate = context.coordinator
        // Show the shimmer skeleton immediately (static HTML, no navigation, so
        // the navigation delegate won't fire spuriously). The real portal page
        // is swapped in by updateUIView once the hosted URL resolves.
        v.loadHTMLString(oneloPortalSkeletonHTML(tokens), baseURL: nil)
        return v
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        loadRealIfNeeded(uiView, coordinator: context.coordinator)
    }
}
#endif

// Swap the skeleton for the real portal page exactly once, the first time the
// hosted URL is available. Shared by the macOS/iOS representables above; the
// `didLoadReal` coordinator flag makes it a no-op on subsequent re-renders.
extension PortalEmbeddedWebView {
    @MainActor
    fileprivate func loadRealIfNeeded(_ webView: WKWebView, coordinator: PortalWebCoordinator) {
        guard let url = hostedUrl, !coordinator.didLoadReal else { return }
        coordinator.didLoadReal = true
        coordinator.portalOrigin = OneloSwift.portalOrigin(of: url)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(req)
    }
}

// MARK: - Navigation delegate

@MainActor
private final class PortalWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let callbackScheme: String
    private let onDone: (URL?) -> Void
    private let onError: (String) -> Void
    /// #40 Phase 2 — fired when the hosted portal posts `onelo:ready`, so the
    /// native fail-safe ✕ hides and the hosted page's canonical ✕ takes over.
    var onReady: (() -> Void)?
    /// #613 / #614 — answers the page's renew request; returns the reply script.
    var onRenew: ((String) async -> String)?
    /// The hosted portal's origin, set when the real page loads.
    var portalOrigin: String?
    /// Set true the first time the real hosted URL is loaded, so SwiftUI
    /// re-renders (which re-invoke updateNSView/updateUIView) don't reload the
    /// page and stomp the user's in-portal navigation.
    var didLoadReal = false

    // JS relay: forward the hosted page's postMessages → sentinel navigations
    // this coordinator intercepts. (Portal CLOSE stays on the existing
    // `<scheme>://callback?source=portal` deep-link that the hosted ✕'s
    // `returnToApp()` fires — already handled below.)
    //   onelo:ready → onelo://ready
    //   onelo:code / onelo:done / onelo:cancel → onelo://callback?… in the
    //     deep-link wire format, decoded by `classifyHandBack` (#592 / #599 /
    //     #627). The portal's "Change plan" and `openUpgrade` load
    //     /store/hosted here. This WebView registers no `oneloNative` bridge,
    //     so the store reports a finished purchase, a code-less plan switch or
    //     "Return to app" on a spent link with a postMessage to its own window;
    //     without the relay the portal sat on "You're in!". The code itself is
    //     not needed: the buyer is already signed in.
    //   window.OneloPortalHost = true — tells /store/hosted it runs inside an
    //     app (so its success screen says "Taking you back…" and holds ~1.5 s
    //     before handing back) without claiming a deep-link bridge.
    static let relayScript = WKUserScript(
        source: portalRelayScriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    init(callbackScheme: String, onDone: @escaping (URL?) -> Void, onError: @escaping (String) -> Void) {
        self.callbackScheme = callbackScheme
        self.onDone = onDone
        self.onError = onError
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Buyer-finished signal — the portal page redirects here when
        // the user taps Done or after a successful refund/cancel. Same
        // contract OneloAuthView relies on for sign-in completion.
        let url = navigationAction.request.url
        let route = routePortalNavigation(url, callbackScheme: callbackScheme)
        Task { @MainActor in
            switch route {
            case .ready:
                // #40 Phase 2 — hosted page mounted → hide the native fail-safe ✕.
                decisionHandler(.cancel)
                self.onReady?()
            case .checkoutComplete:
                // Hand the relayed hand-back to the portal callback, which
                // reports the purchase / switch so the plan is reconciled at
                // once (#659), then dismiss.
                decisionHandler(.cancel)
                self.onDone(url)
            case .storeCancel:
                decisionHandler(.cancel)
                self.onDone(nil)
            case .done:
                decisionHandler(.cancel)
                self.onDone(url)
            case .renew(let requestId):
                decisionHandler(.cancel)
                guard let onRenew = self.onRenew,
                      let expected = self.portalOrigin,
                      OneloSwift.portalOrigin(of: webView.url) == expected else { return }
                let script = await onRenew(requestId)
                // Completion-handler form: the async overload traps when the
                // script evaluates to undefined, which a postMessage does.
                webView.evaluateJavaScript(script, completionHandler: nil)
            case .allow:
                decisionHandler(.allow)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.onError(msg) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.onError(msg) }
    }

    // Handle target="_blank" links (Stripe invoice PDF / hosted receipt in the
    // Receipts list) — open in the system browser instead of a new WKWebView
    // (which WKWebView won't create on its own → the link would do nothing).
    // Mirrors OneloAuthView.createWebViewWith.
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // WebKit invokes UI-delegate callbacks on the main thread; assume that
        // isolation so we can read the main-actor navigationAction and open the
        // external link in the system browser. (This class is @MainActor, so the
        // requirement is satisfied nonisolated — mirror the other delegate
        // methods here.)
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #elseif os(iOS)
                UIApplication.shared.open(url)
                #endif
            }
        }
        return nil
    }
}

// MARK: - WebView hardening (mirror of OneloAuthView's applyOneloWebViewHardening)

private func applyPortalWebViewHardening(_ config: WKWebViewConfiguration) {
    let appBoundDomains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String] ?? []
    if !appBoundDomains.isEmpty {
        if #available(iOS 14.0, macOS 11.0, *) {
            config.limitsNavigationsToAppBoundDomains = true
        }
    }
    if #available(iOS 14.5, macOS 11.3, *) {
        config.preferences.isFraudulentWebsiteWarningEnabled = true
    }
}
