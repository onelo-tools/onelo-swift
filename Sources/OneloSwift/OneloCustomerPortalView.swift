// OneloCustomerPortalView — drop-in SwiftUI view for the in-app
// Customer Portal. Renders the hosted portal page inside a WKWebView
// embedded directly in the host app's window — same pattern as
// `OneloAuthView`, just for the post-sign-in portal flow.
//
// Why this exists in addition to `OneloAuth.openCustomerPortal(from:)`:
//
// `openCustomerPortal(from:)` uses ASWebAuthenticationSession, which on
// macOS shows a system consent prompt ("(App) Wants to Use … to Sign
// In"), needs CFBundleDisplayName, and detaches into a system-managed
// window. On Turingo dev builds (2026-05-21) it failed silently after
// the buyer clicked Continue — wrong screen / blank window / no
// content. The buyer wanted the SAME in-app rendering OneloAuthView
// already provides for sign-in.
//
// This view is purely additive — the legacy `openCustomerPortal(from:)`
// is kept for hosts that prefer the ASWebAuth path, and iOS apps that
// can't yet host an in-app WebView modal.
//
// Usage (macOS, in a SwiftUI host):
//   @State private var showPortal = false
//
//   Button("Manage subscription") { showPortal = true }
//     .sheet(isPresented: $showPortal) {
//       OneloCustomerPortalView(auth: auth) { showPortal = false }
//     }
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
    private let callbackScheme: String
    private let onDismiss: () -> Void
    /// Routes the portal's return deep-link (`<scheme>://callback?source=portal`)
    /// through `auth.handlePortalCallback`, so a hard account event (deletion /
    /// revoke / compromise) clears the local session — matching
    /// `openCustomerPortal(from:)`. No-op for the lower-level init that has no
    /// OneloAuth instance to clear.
    private let onPortalCallback: (URL) -> Void

    @State private var hostedUrl: URL? = nil
    @State private var errorMessage: String? = nil

    /// Convenience init that pulls everything off an OneloAuth instance.
    public init(auth: OneloAuth, onDismiss: @escaping () -> Void) {
        self.urlProvider = { try await auth.initiateCustomerPortal() }
        self.callbackScheme = auth.callbackScheme
        self.onDismiss = onDismiss
        self.onPortalCallback = { url in auth.handlePortalCallback(url) }
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
        self.callbackScheme = callbackScheme
        self.onDismiss = onDismiss
        self.onPortalCallback = { _ in }
    }

    public var body: some View {
        ZStack {
            // Same dark background OneloAuthView uses while the WebView
            // is in-flight, so the transition from sheet-presentation to
            // loaded portal page is seamless (no white flash).
            Color.black.ignoresSafeArea()

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
                    // exactly like openCustomerPortal(from:) does, then dismiss.
                    if let callbackUrl { onPortalCallback(callbackUrl) }
                    onDismiss()
                },
                onError: { msg in
                    errorMessage = msg
                }
            )
            .ignoresSafeArea()

            if let msg = errorMessage {
                VStack(spacing: 12) {
                    Text(msg)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Close") { onDismiss() }
                        .foregroundStyle(.white)
                }
                .padding(24)
            }

            // Unified Onelo close affordance — matches OneloFeedback's `✕`
            // (SF Symbol `xmark`, neutral, no Onelo branding), pinned TOP-RIGHT.
            // The portal body is a ZStack (no NavigationStack), so a `.toolbar`
            // wouldn't render — overlay the control directly and route it through
            // the EXISTING `onDismiss()`. Respects the safe area.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                    .padding(16)
                }
                Spacer()
            }
        }
        .frame(minWidth: 420, minHeight: 640)
        .task { await loadPortal() }
    }

    private func loadPortal() async {
        do {
            let url = try await urlProvider()
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
// HTML renders identically on macOS and iOS.
private let portalSkeletonHTML = """
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111111;font-family:-apple-system,sans-serif;overflow:hidden}
@keyframes onelo-shimmer{0%{background-position:-60vw 0}100%{background-position:100vw 0}}
.wrap{display:flex;flex-direction:column;align-items:center;width:100%;padding:48px 24px 0}
.col{width:100%;max-width:432px;display:flex;flex-direction:column;gap:14px}
.sk{background-color:rgba(255,255,255,0.04);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.12) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:8px}
.strong{background-color:rgba(255,255,255,0.08);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.18) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:9px}
.icon{width:64px;height:64px;border-radius:14px;margin-bottom:14px;background:rgba(255,255,255,0.06);border:1.5px solid rgba(255,255,255,0.1)}
.title{width:200px;height:22px;margin-bottom:10px;border-radius:6px}
.sub{width:80px;height:13px;opacity:0.7;margin-bottom:32px;border-radius:4px}
.c1{height:240px;border-radius:14px}
.c2{height:80px;border-radius:14px}
.c3{height:140px;border-radius:14px}
</style></head><body>
<div class="wrap">
<div class="sk icon"></div>
<div class="sk title"></div>
<div class="sk sub"></div>
<div class="col"><div class="strong c1"></div><div class="strong c2"></div><div class="strong c3"></div></div>
</div>
</body></html>
"""

// MARK: - WebView wrapper (per-platform)

#if canImport(AppKit) && os(macOS)
private struct PortalEmbeddedWebView: NSViewRepresentable {
    /// Optional so the WebView can mount and render the skeleton BEFORE the
    /// hosted URL resolves. Swapped to the real page in `updateNSView` once
    /// it becomes non-nil (guarded by the coordinator's `didLoadReal` flag so
    /// re-renders don't reload).
    let hostedUrl: URL?
    let callbackScheme: String
    let onDone: (URL?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> PortalWebCoordinator {
        PortalWebCoordinator(callbackScheme: callbackScheme, onDone: onDone, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        applyPortalWebViewHardening(cfg)
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
        v.loadHTMLString(portalSkeletonHTML, baseURL: nil)
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        loadRealIfNeeded(nsView, coordinator: context.coordinator)
    }
}
#elseif canImport(UIKit)
private struct PortalEmbeddedWebView: UIViewRepresentable {
    /// Optional so the WebView can mount and render the skeleton BEFORE the
    /// hosted URL resolves. Swapped to the real page in `updateUIView` once
    /// it becomes non-nil (guarded by the coordinator's `didLoadReal` flag so
    /// re-renders don't reload).
    let hostedUrl: URL?
    let callbackScheme: String
    let onDone: (URL?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> PortalWebCoordinator {
        PortalWebCoordinator(callbackScheme: callbackScheme, onDone: onDone, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        applyPortalWebViewHardening(cfg)
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
        v.loadHTMLString(portalSkeletonHTML, baseURL: nil)
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
    /// Set true the first time the real hosted URL is loaded, so SwiftUI
    /// re-renders (which re-invoke updateNSView/updateUIView) don't reload the
    /// page and stomp the user's in-portal navigation.
    var didLoadReal = false

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
        let scheme = url?.scheme
        let cb = callbackScheme
        Task { @MainActor in
            if let scheme, !cb.isEmpty, scheme == cb {
                decisionHandler(.cancel)
                self.onDone(url)
                return
            }
            decisionHandler(.allow)
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
