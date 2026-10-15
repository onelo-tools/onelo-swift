// OneloPortalPresenter — the SDK's own container for the Customer Portal and
// the upgrade flow (#606).
//
// `openCustomerPortal(from:)` used ASWebAuthenticationSession and
// `openUpgrade(forPlan:)` the system browser. Both behave like a plain browser
// tab: the hosted store never finds an app to hand back to, so a purchase or a
// plan switch finished there never closed anything and never reached the app
// (#592 / #599). This presents `OneloCustomerPortalView` — the embedded
// WKWebView that decodes every hand-back — in a window the SDK owns, so the
// callers need no SwiftUI host and no presentation anchor.

import SwiftUI
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Where the Customer Portal opens. `.changePlan` lands straight in the plan
/// picker; the hosted portal asks the backend where the change goes (a plan
/// switch, the store for a user without a paid plan, or an explanation when
/// plan changes are off). Parity with `@onelo/js`
/// `customerPortal.open({ intent: 'change_plan' })`.
public enum OneloPortalIntent: String, Sendable {
    case changePlan = "change_plan"
}

/// The hosted portal URL with `intent` as a query param — the same param the
/// web SDK sets. `nil` → the URL unchanged. Pure, so it is unit-testable.
func portalURL(_ url: URL, intent: OneloPortalIntent?) -> URL {
    guard let intent,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var items = (components.queryItems ?? []).filter { $0.name != "intent" }
    items.append(URLQueryItem(name: "intent", value: intent.rawValue))
    components.queryItems = items
    return components.url ?? url
}

/// Presents `OneloCustomerPortalView` in an SDK-owned window (macOS) or a modal
/// sheet over the top-most view controller (iOS) and returns when it closes.
@MainActor
enum OneloPortalPresenter {
    /// Sessions still on screen — retained here until their window closes.
    private static var live: [ObjectIdentifier: PortalPresentation] = [:]

    /// - Returns: false when there was nowhere to present (iOS without a key
    ///   window). The caller decides the fallback.
    @discardableResult
    static func present(
        urlProvider: @escaping () async throws -> URL,
        renewProvider: @escaping () async throws -> URL,
        callbackScheme: String,
        onPortalCallback: @escaping (URL) -> Void,
        brandTokens: @escaping () -> OneloBrandTokens = { .neutral }
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let presentation = PortalPresentation()
            let key = ObjectIdentifier(presentation)
            presentation.onFinish = { presented in
                live[key] = nil
                continuation.resume(returning: presented)
            }
            live[key] = presentation
            let view = OneloCustomerPortalView(
                urlProvider: urlProvider,
                renewProvider: renewProvider,
                callbackScheme: callbackScheme,
                onPortalCallback: onPortalCallback,
                brandTokens: brandTokens,
                onDismiss: { [weak presentation] in presentation?.close() }
            )
            presentation.show(view, pageBg: brandTokens().pageBg)
        }
    }
}

/// One on-screen portal: the window / hosting controller and the single-shot
/// finish that resumes the caller.
@MainActor
private final class PortalPresentation {
    var onFinish: ((Bool) -> Void)?
    private var finished = false
    #if canImport(AppKit) && os(macOS)
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    #elseif canImport(UIKit)
    private weak var host: UIViewController?
    #endif

    private func finish(presented: Bool) {
        guard !finished else { return }
        finished = true
        let done = onFinish
        onFinish = nil
        done?(presented)
    }

    #if canImport(AppKit) && os(macOS)
    func show(_ view: OneloCustomerPortalView, pageBg: String) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Manage Account"
        win.minSize = NSSize(width: 560, height: 680)
        win.isReleasedWhenClosed = false
        // #681 — the brand page_bg, so the window matches the skeleton + page.
        win.backgroundColor = Color(oneloCSS: pageBg).map { NSColor($0) } ?? .windowBackgroundColor
        win.contentViewController = NSHostingController(rootView: view)
        win.setContentSize(NSSize(width: 780, height: 720))
        win.center()
        // The window's own close button ends the session the same way the
        // portal's ✕ does.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        window = win
        // Accessory / menu-bar apps have no active window to attach to; bring
        // the app forward so the portal is not hidden behind another app.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window else { finish(presented: true); return }
        window.close() // → willClose → didClose
    }

    private func didClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentViewController = nil
        window = nil
        finish(presented: true)
    }
    #elseif canImport(UIKit)
    func show(_ view: OneloCustomerPortalView, pageBg: String) {
        guard let top = Self.topViewController() else {
            finish(presented: false)
            return
        }
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        // A swipe-down would drop the sheet without telling the SDK; the
        // portal's own ✕ (or the fail-safe ✕) closes it instead.
        controller.isModalInPresentation = true
        host = controller
        top.present(controller, animated: true)
    }

    func close() {
        guard let host else { finish(presented: true); return }
        host.dismiss(animated: true) { [weak self] in
            MainActor.assumeIsolated { self?.finish(presented: true) }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif
}
