import SwiftUI
import WebKit

#if os(macOS)
private var _coordinatorKey: UInt8 = 0
#endif

// MARK: - Options

public struct OpenFeedbackOptions {
    public var type: String?   // "bug" | "feature_request" | "general"
    public var area: String?
    public var userId: String?

    public init(type: String? = nil, area: String? = nil, userId: String? = nil) {
        self.type = type
        self.area = area
        self.userId = userId
    }
}

// MARK: - OneloFeedback

@MainActor
public final class OneloFeedback: NSObject, ObservableObject {
    private let client: _OneloHTTPClient
    private let features: OneloFeatures

    @Published public var isPresented = false
    /// #40 Phase 2 — true once the hosted feedback page posts `onelo:ready`. While
    /// false (pre-load / load-error) the native toolbar ✕ shows as a fail-safe;
    /// once true the hosted page's own canonical ✕ owns the affordance and the
    /// native one is hidden (so there's never a double ✕, and it's identical to
    /// every other SDK).
    @Published var hostedReady = false
    /// The resolved hosted URL — available after `open()` resolves.
    /// AppKit apps can read this directly instead of using `.feedbackSheet()`.
    public private(set) var hostedURL: URL?
    /// The options of the open form, initiated again to renew its `ft` (#622).
    private var lastOptions = OpenFeedbackOptions()
    /// The app's brand tokens (#681) the sheet / window chrome paints with —
    /// kept in step with `OneloAuth.brandTokens` by `Onelo`.
    public internal(set) var brandTokens: OneloBrandTokens = .neutral

#if os(macOS)
    private weak var feedbackWindow: NSWindow?
#endif

    /// The signed-in Onelo user's access token (#820). Wired by `Onelo` to
    /// `OneloAuth.userToken`; with a session the initiate call carries it and
    /// the report names a verified reporter. Nil, the call is exactly as before.
    private let userToken: _OneloUserToken?

    init(client: _OneloHTTPClient, features: OneloFeatures, userToken: _OneloUserToken? = nil) {
        self.client = client
        self.features = features
        self.userToken = userToken
    }

    // MARK: - Initiate (shared)

    /// Fetches the hosted URL and stores it. Call this before opening any UI.
    /// `open()` and `openAsWindow()` both call this internally.
    ///
    /// Routed through the shared `_OneloHTTPClient` so the request carries the
    /// same security headers (`X-Bundle-Id`, App Attest / codesign / integrity
    /// tokens) as every other SDK module. A hand-rolled `URLRequest` here used
    /// to send only `X-Onelo-Instance-Id`, so on a live mobile/desktop app with
    /// a registered bundle ID the backend rejected `/initiate` with
    /// `403 invalid_bundle_id` — the window opened and immediately closed.
    public func fetchHostedURL(options: OpenFeedbackOptions = OpenFeedbackOptions()) async throws -> URL {
        var items = [URLQueryItem(name: "key", value: client.publishableKey)]
        if let t = options.type   { items.append(.init(name: "type",   value: t)) }
        if let a = options.area   { items.append(.init(name: "area",   value: a)) }

        let active = features.getActiveFeatures()
        if !active.isEmpty,
           let jsonData = try? JSONSerialization.data(withJSONObject: active),
           let jsonStr  = String(data: jsonData, encoding: .utf8) {
            items.append(.init(name: "session", value: jsonStr))
        }

        // Signed in (#820): `Authorization: Bearer <access token>` makes the
        // server sign the token's user as a VERIFIED reporter. A refused token is
        // refreshed and retried once; refused again, the form still opens without
        // it (as a signed-out call would), so feedback never fails on identity.
        // userId is sent as a HEADER (X-Onelo-User-Id), not a query param, so the
        // developer's user id never appears in the access-logged initiate URL.
        // Without a session it is the developer's unverified label.
        let userIdHeader = options.userId.map { ["X-Onelo-User-Id": $0] } ?? [:]
        let (status, json) = try await _sendWithUserToken(userToken, onRefused: {}) { [client] attempt in
            try await client.getRaw(
                path: "/api/sdk/feedback/initiate",
                queryItems: items,
                headers: userIdHeader.merging(_OneloUserTokenWire.headers(attempt.token)) { _, new in new }
            )
        }
        guard (200..<300).contains(status) else { throw client.httpError(json, statusCode: status) }
        guard
            let urlStr = json["hosted_url"] as? String,
            let url    = URL(string: urlStr)
        else { throw OneloError.serverError("Invalid feedback initiate response") }

        return url
    }

    // MARK: - SwiftUI path

    /// Fetches the hosted URL and sets `isPresented = true`.
    /// Use with `.feedbackSheet(onelo.feedback)` in SwiftUI apps.
    public func open(options: OpenFeedbackOptions = OpenFeedbackOptions()) async throws {
        lastOptions = options
        hostedURL   = try await fetchHostedURL(options: options)
        hostedReady = false   // fail-safe ✕ visible until the hosted page mounts
        isPresented = true
    }

    /// #622 — answers the hosted form's `onelo:renew_request` (kind `feedback`).
    /// The form's reporter token `ft` lives 30 minutes; a form left open longer
    /// asks for a fresh one on submit. The open form's options are initiated
    /// again, so the report keeps its reporter, type, area and session. Returns
    /// the script that delivers the reply into the page.
    func renewReplyScript(requestId: String) async -> String {
        do {
            let url = try await fetchHostedURL(options: lastOptions)
            return portalRenewReplyScript(requestId: requestId, hostedUrl: url.absoluteString, reason: "")
        } catch {
            return portalRenewReplyScript(requestId: requestId, hostedUrl: nil, reason: "renew_failed")
        }
    }

    func makeWebView() -> OneloBrowserFeedbackView? {
        guard let url = hostedURL else { return nil }
        return OneloBrowserFeedbackView(
            url: url,
            onDismiss: { [weak self] in
                Task { @MainActor [weak self] in self?.isPresented = false }
            },
            onHostedReady: { [weak self] in
                Task { @MainActor [weak self] in self?.hostedReady = true }
            },
            onRenew: { [weak self] requestId in
                guard let self else {
                    return portalRenewReplyScript(requestId: requestId, hostedUrl: nil, reason: "renew_failed")
                }
                return await self.renewReplyScript(requestId: requestId)
            }
        )
    }

#if os(macOS)
    // MARK: - AppKit path (macOS)

    /// Opens the feedback form in a standalone NSWindow.
    /// The window appears immediately with a dark background; the form loads inside once the
    /// initiate request resolves — no blocking wait before the window is visible.
    public func openAsWindow(options: OpenFeedbackOptions = OpenFeedbackOptions()) {
        // Reuse existing window if still open
        if let existing = feedbackWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // 1. Create window and WebView immediately — show before any network call
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Send Feedback"
        win.minSize = NSSize(width: 480, height: 680)
        win.isReleasedWhenClosed = false
        win.appearance = nil
        // #681 — the brand page ground behind the (transparent) web view.
        win.backgroundColor = Color(oneloCSS: brandTokens.pageBg).map { NSColor($0) } ?? .windowBackgroundColor

        let webConfig = WKWebViewConfiguration()
        webConfig.userContentController.addUserScript(FeedbackWebCoordinator.relayScript)

        let webView = WKWebView(frame: win.contentRect(forFrameRect: win.frame), configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        // Dark background while loading so there's no white flash
        webView.setValue(false, forKey: "drawsBackground")

        lastOptions = options
        let coordinator = FeedbackWebCoordinator { [weak win] in win?.close() }
        // Retry from the error screen re-runs the fetch in the same window
        // instead of leaving the user stuck (or silently closing — see below).
        coordinator.onRetry = { [weak self, weak webView, weak win] in
            guard let self, let webView, let win else { return }
            self.loadHostedForm(into: webView, window: win, options: options)
        }
        // #622 — the form's `ft` expired; answer only while on the hosted origin.
        coordinator.hostedOrigin = { [weak self] in portalOrigin(of: self?.hostedURL) }
        coordinator.onRenew = { [weak self] requestId in
            guard let self else {
                return portalRenewReplyScript(requestId: requestId, hostedUrl: nil, reason: "renew_failed")
            }
            return await self.renewReplyScript(requestId: requestId)
        }
        objc_setAssociatedObject(win, &_coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        win.contentView = webView
        win.center()
        win.makeKeyAndOrderFront(nil)
        feedbackWindow = win

        // 2. Fetch hosted URL in background — navigate WebView when ready
        loadHostedForm(into: webView, window: win, options: options)
    }

    /// Shows the skeleton, resolves the hosted URL, and navigates the WebView.
    /// On failure it renders an in-window error screen with a Retry button —
    /// never closes the window silently. A silent `win.close()` here used to
    /// make a backend rejection look like "the window opened and instantly
    /// closed", hiding the actual error from both the user and the developer
    /// (violates the no-silent-swallows rule).
    private func loadHostedForm(into webView: WKWebView, window win: NSWindow, options: OpenFeedbackOptions) {
        // Load skeleton screen immediately — shimmer animation while network resolves
        webView.loadHTMLString(oneloFeedbackSkeletonHTML(self.brandTokens), baseURL: nil)

        Task { [weak self, weak webView, weak win] in
            guard let self else { return }
            do {
                let url = try await self.fetchHostedURL(options: options)
                self.hostedURL = url
                await MainActor.run {
                    webView?.load(URLRequest(url: url))
                    win?.makeKeyAndOrderFront(nil)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    webView?.loadHTMLString(oneloErrorPageHTML(self.brandTokens, title: "Couldn't load feedback", message: message, retryHref: "onelo://feedback_retry"), baseURL: nil)
                    win?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

#endif
}

// MARK: - Navigation coordinator

final class FeedbackWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let onDismiss: () -> Void
    /// #40 Phase 2 — fired when the hosted page posts `onelo:ready`, so the host
    /// can hide its native fail-safe ✕ (the hosted ✕ takes over). No-op until wired.
    var onHostedReady: (() -> Void)?
    /// Invoked when the in-window error screen's Retry button fires.
    var onRetry: (() -> Void)?
    /// #622 — answers the form's renew request; returns the reply script.
    var onRenew: ((String) async -> String)?
    /// #622 — the hosted form's origin; only a page on it is answered.
    var hostedOrigin: () -> String? = { nil }
    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    /// The request id of a `onelo://feedback_renew?request_id=…` sentinel (#622).
    static func renewRequestId(from url: URL) -> String? {
        guard url.scheme == "onelo", url.host == "feedback_renew" else { return nil }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "request_id" })?.value
        return (id?.isEmpty == false) ? id : nil
    }

    // JS relay: forward the hosted page's postMessages → sentinel navigations the
    // coordinator intercepts. `onelo:feedback_submitted` (done) and — from the
    // canonical hosted ✕ (Phase 2) — `onelo:feedback_close` (user cancelled) both
    // dismiss; `onelo:ready` tells the native side the hosted page mounted (so it
    // hides its fail-safe ✕, shown only during the pre-load/error window).
    //
    // #622 — `window.OneloFeedbackHost` tells the hosted form it runs inside an
    // SDK that can renew its reporter token `ft`; a renew request the page
    // posts to itself becomes the `onelo://feedback_renew` sentinel.
    static let relaySource = """
        (function() {
          window.OneloFeedbackHost = true;
          window.addEventListener('message', function(e) {
            if (!e.data || !e.data.type) return;
            if (e.source === window && e.data.type === 'onelo:renew_request'
                && e.data.kind === 'feedback' && typeof e.data.request_id === 'string') {
              window.location.href = 'onelo://feedback_renew?request_id=' + encodeURIComponent(e.data.request_id);
            } else if (e.data.type === 'onelo:feedback_submitted') {
              window.location.href = 'onelo://feedback_submitted';
            } else if (e.data.type === 'onelo:feedback_close') {
              window.location.href = 'onelo://feedback_close';
            } else if (e.data.type === 'onelo:ready') {
              window.location.href = 'onelo://ready';
            }
          });
        })();
        """

    static let relayScript = WKUserScript(
        source: relaySource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.scheme == "onelo" {
            switch url.host {
            case "feedback_submitted", "feedback_close":
                // Both dismiss: submit auto-closes; the canonical hosted ✕ (#40
                // Phase 2) cancels. Same native teardown.
                decisionHandler(.cancel)
                Task { @MainActor in self.onDismiss() }
                return
            case "ready":
                // Hosted page mounted → hide the native fail-safe ✕ (the hosted ✕
                // now owns the affordance). No-op if the host didn't wire it.
                decisionHandler(.cancel)
                Task { @MainActor in self.onHostedReady?() }
                return
            case "feedback_retry":
                decisionHandler(.cancel)
                Task { @MainActor in self.onRetry?() }
                return
            case "feedback_renew":
                // #622 — not a close: answer into the page and keep it open.
                decisionHandler(.cancel)
                guard let requestId = Self.renewRequestId(from: url),
                      let onRenew = self.onRenew,
                      let expected = self.hostedOrigin(),
                      portalOrigin(of: webView.url) == expected else { return }
                Task { @MainActor [weak webView] in
                    let script = await onRenew(requestId)
                    // Completion-handler form: the async overload traps when the
                    // script evaluates to undefined, which a postMessage does.
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                }
                return
            default:
                break
            }
        }
        decisionHandler(.allow)
    }

    /// Open external links in the system browser (mirrors OneloAuthView behaviour).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
        return nil
    }
}

// MARK: - WKWebView wrapper (cross-platform)

/// Internal SwiftUI view that hosts the feedback WKWebView.
struct OneloBrowserFeedbackView {
    let url: URL
    let onDismiss: () -> Void
    var onHostedReady: (() -> Void)? = nil
    var onRenew: ((String) async -> String)? = nil

    func makeWebView(coordinator: FeedbackWebCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(FeedbackWebCoordinator.relayScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func makeCoordinator() -> FeedbackWebCoordinator {
        let c = FeedbackWebCoordinator(onDismiss: onDismiss)
        c.onHostedReady = onHostedReady
        c.onRenew = onRenew
        let origin = portalOrigin(of: url)
        c.hostedOrigin = { origin }
        return c
    }
}

#if os(macOS)
extension OneloBrowserFeedbackView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.appearance = nil // follow system
        }
    }
}
#elseif os(iOS)
extension OneloBrowserFeedbackView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Sheet container

private struct FeedbackSheetView: View {
    @ObservedObject var feedback: OneloFeedback
    /// #44 — armed ~3.5s after appear; the fail-safe ✕ shows only after this, so a
    /// normal fast load never flashes it.
    @State private var failsafeTimedOut = false

    var body: some View {
        // #42 — full-bleed ZStack, IDENTICAL to OneloCustomerPortalView. The old
        // `NavigationStack { … }.toolbar` reserved a nav bar whose top edge became
        // the origin for the hosted page's CSS `position:fixed` ✕ — so the hosted
        // ✕ hung well BELOW the corner (fine while the native toolbar ✕ was still
        // shown, but once #40 Phase 2 hides the native one the mis-placed hosted ✕
        // was the only affordance, inconsistent with the flush-corner portal ✕).
        // A bare ZStack + `.ignoresSafeArea()` webview makes the webview top =
        // surface top, so the hosted ✕ is flush top-right in feedback AND portal.
        ZStack(alignment: .topLeading) {
            // #681 — brand page ground + brand-tinted spinner.
            OneloBrandPalette(feedback.brandTokens).pageBg.ignoresSafeArea()
            if let webView = feedback.makeWebView() {
                webView.ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(OneloBrandPalette(feedback.brandTokens).brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // #40 Phase 2 + #44 — native ✕ is a FAIL-SAFE only, and must NOT flash
            // during a normal fast load: it appears only after a ~3.5s grace
            // without the hosted page mounting. A fast load posts `onelo:ready`
            // (`hostedReady`) first, so the ✕ never shows; a stuck load still gets
            // a way out. Once the hosted page mounts its own canonical ✕ takes over.
            if !feedback.hostedReady && failsafeTimedOut {
                VStack {
                    HStack {
                        Spacer()
                        OneloCloseButton(style: .overlay) { feedback.isPresented = false }
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .environment(\.oneloBrandTokens, feedback.brandTokens)
        .task {
            // #44 — arm the fail-safe ✕ only after the grace period (auto-cancels
            // when the sheet dismisses).
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !feedback.hostedReady { failsafeTimedOut = true }
        }
    }
}

// MARK: - View modifier

public struct FeedbackSheetModifier: ViewModifier {
    @ObservedObject var feedback: OneloFeedback

    public func body(content: Content) -> some View {
        content.sheet(isPresented: $feedback.isPresented) {
            FeedbackSheetView(feedback: feedback)
        }
    }
}

public extension View {
    /// Attaches the Onelo feedback sheet to this view.
    ///
    /// ```swift
    /// ContentView()
    ///     .feedbackSheet(onelo.feedback)
    /// ```
    func feedbackSheet(_ feedback: OneloFeedback) -> some View {
        modifier(FeedbackSheetModifier(feedback: feedback))
    }
}
