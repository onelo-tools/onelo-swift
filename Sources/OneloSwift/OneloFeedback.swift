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
    /// The resolved hosted URL — available after `open()` resolves.
    /// AppKit apps can read this directly instead of using `.feedbackSheet()`.
    public private(set) var hostedURL: URL?

#if os(macOS)
    private weak var feedbackWindow: NSWindow?
#endif

    init(client: _OneloHTTPClient, features: OneloFeatures) {
        self.client = client
        self.features = features
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

        // userId is sent as a HEADER (X-Onelo-User-Id), not a query param, so the
        // developer's user id never appears in the access-logged initiate URL.
        let headers = options.userId.map { ["X-Onelo-User-Id": $0] } ?? [:]
        let json = try await client.get(path: "/api/sdk/feedback/initiate", queryItems: items, headers: headers)
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
        hostedURL   = try await fetchHostedURL(options: options)
        isPresented = true
    }

    func makeWebView() -> OneloBrowserFeedbackView? {
        guard let url = hostedURL else { return nil }
        return OneloBrowserFeedbackView(url: url) { [weak self] in
            Task { @MainActor [weak self] in self?.isPresented = false }
        }
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

        let webConfig = WKWebViewConfiguration()
        webConfig.userContentController.addUserScript(FeedbackWebCoordinator.relayScript)

        let webView = WKWebView(frame: win.contentRect(forFrameRect: win.frame), configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        // Dark background while loading so there's no white flash
        webView.setValue(false, forKey: "drawsBackground")

        let coordinator = FeedbackWebCoordinator { [weak win] in win?.close() }
        // Retry from the error screen re-runs the fetch in the same window
        // instead of leaving the user stuck (or silently closing — see below).
        coordinator.onRetry = { [weak self, weak webView, weak win] in
            guard let self, let webView, let win else { return }
            self.loadHostedForm(into: webView, window: win, options: options)
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
        webView.loadHTMLString(Self.skeletonHTML, baseURL: nil)

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
                    webView?.loadHTMLString(Self.errorHTML(message: message), baseURL: nil)
                    win?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    // Skeleton screen shown while the hosted URL is being fetched.
    // Mirrors the rough layout of the feedback form with a shimmer animation.
    private static let skeletonHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        background: #111;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        padding: 40px 36px 32px;
        overflow: hidden;
      }
      @keyframes shimmer {
        0%   { background-position: -600px 0; }
        100% { background-position: 600px 0; }
      }
      .sk {
        border-radius: 10px;
        background: linear-gradient(90deg, #1e1e1e 25%, #2a2a2a 50%, #1e1e1e 75%);
        background-size: 600px 100%;
        animation: shimmer 1.4s infinite linear;
      }
      /* App icon */
      .icon  { width: 64px; height: 64px; border-radius: 14px; margin: 0 auto 16px; }
      /* Title line */
      .title { width: 220px; height: 22px; margin: 0 auto 40px; border-radius: 6px; }
      /* Type selector cards */
      .cards { display: flex; gap: 12px; margin-bottom: 32px; }
      .card  { flex: 1; height: 76px; border-radius: 12px; }
      /* Field labels + inputs */
      .label { width: 60px; height: 13px; border-radius: 4px; margin-bottom: 8px; }
      .input { width: 100%; height: 44px; border-radius: 10px; margin-bottom: 24px; }
      .textarea { width: 100%; height: 110px; border-radius: 10px; margin-bottom: 32px; }
      /* Submit button */
      .btn   { width: 100%; height: 48px; border-radius: 12px; }
    </style>
    </head>
    <body>
      <div class="sk icon"></div>
      <div class="sk title"></div>
      <div class="cards">
        <div class="sk card"></div>
        <div class="sk card"></div>
        <div class="sk card"></div>
      </div>
      <div class="sk label"></div>
      <div class="sk input"></div>
      <div class="sk label"></div>
      <div class="sk textarea"></div>
      <div class="sk btn"></div>
    </body>
    </html>
    """

    // Error screen shown when the hosted URL can't be resolved. Includes a
    // Retry button that navigates to the `onelo://feedback_retry` sentinel,
    // which the coordinator intercepts to re-run the fetch.
    private static func errorHTML(message: String) -> String {
        let safe = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          html, body { height: 100%; }
          body {
            background: #111; color: #e5e5e5;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            display: flex; flex-direction: column; align-items: center;
            justify-content: center; text-align: center; padding: 40px 36px;
          }
          .title { font-size: 17px; font-weight: 600; margin-bottom: 10px; }
          .msg   { font-size: 13px; color: #9a9a9a; line-height: 1.5; max-width: 320px; margin-bottom: 28px; }
          .btn {
            appearance: none; border: 0; cursor: pointer;
            background: #fff; color: #111; font-size: 14px; font-weight: 600;
            padding: 11px 22px; border-radius: 10px;
          }
          .btn:active { opacity: 0.8; }
        </style>
        </head>
        <body>
          <div class="title">Couldn't load feedback</div>
          <div class="msg">\(safe)</div>
          <button class="btn" onclick="window.location.href='onelo://feedback_retry'">Try again</button>
        </body>
        </html>
        """
    }
#endif
}

// MARK: - Navigation coordinator

final class FeedbackWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let onDismiss: () -> Void
    /// Invoked when the in-window error screen's Retry button fires.
    var onRetry: (() -> Void)?
    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    // JS relay: forward onelo:feedback_submitted postMessage → sentinel navigation.
    static let relayScript = WKUserScript(
        source: """
        (function() {
          window.addEventListener('message', function(e) {
            if (e.data && e.data.type === 'onelo:feedback_submitted') {
              window.location.href = 'onelo://feedback_submitted';
            }
          });
        })();
        """,
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
            case "feedback_submitted":
                decisionHandler(.cancel)
                Task { @MainActor in self.onDismiss() }
                return
            case "feedback_retry":
                decisionHandler(.cancel)
                Task { @MainActor in self.onRetry?() }
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
        FeedbackWebCoordinator(onDismiss: onDismiss)
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

    var body: some View {
        NavigationStack {
            Group {
                if let webView = feedback.makeWebView() {
                    webView.ignoresSafeArea()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Unified Onelo close affordance: an `✕` (SF Symbol `xmark`)
                // pinned TOP-RIGHT, neutral/system-colored, no Onelo branding —
                // identical across every Onelo modal on every SDK. `.confirmationAction`
                // renders TRAILING on both iOS and macOS (cross-platform-safe;
                // `.topBarTrailing` is iOS-only). Same close action as before.
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        feedback.isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
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
