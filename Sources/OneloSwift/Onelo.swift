import Foundation

/// Main entry point for the Onelo SDK.
///
/// ```swift
/// let onelo = Onelo(publishableKey: "pk_live_...", baseURL: URL(string: "https://...")!)
/// await onelo.identify(userId)   // only needed when NOT using Onelo Auth
///
/// if onelo.features.feature("export-button").isEnabled {
///     showExportButton()
/// }
/// ```
@MainActor
public final class Onelo {
    private let httpClient: _OneloHTTPClient

    public let features: OneloFeatures
    public let paywall: OneloPaywall
    public let forms: OneloForms
    public let waitlist: OneloWaitlist
    public let auth: OneloAuthModule
    public let monitor: OneloMonitor

    public init(
        publishableKey: String,
        callbackScheme: String = "",
        baseURL: URL
    ) {
        let client = _OneloHTTPClient(publishableKey: publishableKey, baseURL: baseURL)
        self.httpClient = client
        self.features = OneloFeatures(client: client)
        self.paywall = OneloPaywall()
        self.forms = OneloForms(client: client)
        self.waitlist = OneloWaitlist(client: client)
        let oneloAuth = OneloAuth(config: OneloConfig(
            publishableKey: publishableKey,
            apiUrl: baseURL,
            callbackScheme: callbackScheme
        ))
        self.auth = OneloAuthModule(auth: oneloAuth)
        self.monitor = OneloMonitor(publishableKey: publishableKey, apiUrl: baseURL.absoluteString)

        print("[OneloBridge] SDK initialized — features._load(nil)") // TODO: remove debug
        Task { await features._load(userId: nil) }

        // Auto-identify features when Onelo Auth session changes
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await session in self.auth.authObject.$currentSession.values {
                let userId = session?.user.id
                print("[OneloBridge] Auth state changed → userId: \(userId ?? "nil")") // TODO: remove debug
                print("[OneloBridge] features._load(userId: \(userId ?? "nil"))") // TODO: remove debug
                await self.features._load(userId: userId)
            }
        }
    }

    /// Set user context for feature targeting. Call once after login.
    /// Only needed when NOT using Onelo Auth — Onelo Auth sets this automatically.
    public func identify(_ userId: String) async {
        print("[OneloBridge] identify(userId: \(userId)) → features._load") // TODO: remove debug
        await features._load(userId: userId)
    }
}
