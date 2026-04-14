import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public final class OneloAuthModule {
    /// Exposed so developers can pass it to OneloAuthView directly:
    ///   OneloAuthView(auth: onelo.auth.authObject, ...)
    public let authObject: OneloAuth

    // Internal: instantiated by Onelo only.
    init(auth: OneloAuth) {
        self.authObject = auth
    }

    // MARK: - Programmatic presentation

    #if os(iOS)
    /// Present the auth UI modally from a UIViewController.
    /// The sheet dismisses automatically when the user signs in (session becomes non-nil).
    public func show(
        from viewController: UIViewController,
        config: OneloAuthConfig = .default
    ) {
        let host = UIHostingController(rootView: OneloAuthView(auth: authObject, config: config) {
            EmptyView()
        })
        host.modalPresentationStyle = .formSheet
        // Observe session to dismiss when signed in
        Task { @MainActor in
            for await session in authObject.$currentSession.values where session != nil {
                host.dismiss(animated: true)
                break
            }
        }
        viewController.present(host, animated: true)
    }
    #elseif os(macOS)
    /// Present the auth UI as a sheet from an NSViewController.
    /// The sheet dismisses automatically when the user signs in (session becomes non-nil).
    public func show(
        from viewController: NSViewController,
        config: OneloAuthConfig = .default
    ) {
        let host = NSHostingController(rootView: OneloAuthView(auth: authObject, config: config) {
            EmptyView()
        })
        // Observe session to dismiss when signed in
        Task { @MainActor in
            for await session in authObject.$currentSession.values where session != nil {
                host.dismiss(host)
                break
            }
        }
        viewController.presentAsSheet(host)
    }
    #endif
}
