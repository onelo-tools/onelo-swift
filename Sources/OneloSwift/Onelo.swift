import Foundation

/// Main entry point for the Onelo SDK.
///
/// ```swift
/// let onelo = Onelo(publishableKey: "pk_live_...")
/// await onelo.identify(userId, plan: "pro")
///
/// if onelo.features.isEnabled("export-button") {
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

    public init(
        publishableKey: String,
        callbackScheme: String = "",
        baseURL: URL
    ) {
        let client = _OneloHTTPClient(publishableKey: publishableKey, baseURL: baseURL)
        self.httpClient = client
        self.features = OneloFeatures(client: client)
        self.paywall = OneloPaywall(client: client)
        self.forms = OneloForms(client: client)
        self.waitlist = OneloWaitlist(client: client)
        let oneloAuth = OneloAuth(config: OneloConfig(
            publishableKey: publishableKey,
            apiUrl: baseURL,
            callbackScheme: callbackScheme
        ))
        self.auth = OneloAuthModule(auth: oneloAuth)
    }

    /// Set user context. Call once after login.
    /// Loads feature states from the server.
    public func identify(_ userId: String, plan: String? = nil) async {
        httpClient.userPlan = plan
        await features._load()
        let names = Array(features._cache.keys)
        await features._ping(names: names)
    }
}
