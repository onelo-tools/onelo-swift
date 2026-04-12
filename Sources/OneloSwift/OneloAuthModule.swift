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
    public func show(
        from viewController: UIViewController,
        config: OneloAuthConfig = .default,
        completion: @escaping (OneloSession) -> Void
    ) {
        var host: UIHostingController<OneloAuthView>?
        let view = OneloAuthView(auth: authObject, config: config) { [weak host] session in
            host?.dismiss(animated: true) {
                completion(session)
            }
        }
        host = UIHostingController(rootView: view)
        guard let host else { return }
        host.modalPresentationStyle = .formSheet
        viewController.present(host, animated: true)
    }
    #elseif os(macOS)
    /// Present the auth UI as a sheet from an NSViewController.
    public func show(
        from viewController: NSViewController,
        config: OneloAuthConfig = .default,
        completion: @escaping (OneloSession) -> Void
    ) {
        var host: NSHostingController<OneloAuthView>?
        let view = OneloAuthView(auth: authObject, config: config) { [weak host] session in
            if let host { host.dismiss(host) }
            completion(session)
        }
        host = NSHostingController(rootView: view)
        guard let host else { return }
        viewController.presentAsSheet(host)
    }
    #endif
}
