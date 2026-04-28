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
    public let feedback: OneloFeedback

    public init(
        publishableKey: String,
        callbackScheme: String = "",
        baseURL: URL
    ) {
        let client = _OneloHTTPClient(publishableKey: publishableKey, baseURL: baseURL)
        self.httpClient = client
        let monitorInstance = OneloMonitor(publishableKey: publishableKey, apiUrl: baseURL.absoluteString)
        self.monitor = monitorInstance
        let featuresModule = OneloFeatures(client: client, monitor: monitorInstance)
        self.features = featuresModule
        self.paywall = OneloPaywall()
        self.forms = OneloForms(client: client)
        self.waitlist = OneloWaitlist(client: client)
        self.feedback = OneloFeedback(publishableKey: publishableKey, baseURL: baseURL, features: featuresModule)
        let oneloAuth = OneloAuth(config: OneloConfig(
            publishableKey: publishableKey,
            apiUrl: baseURL,
            callbackScheme: callbackScheme
        ))
        self.auth = OneloAuthModule(auth: oneloAuth)

        Task {
            await _ensureSecurityHeaders(
                publishableKey: publishableKey,
                baseURL: baseURL,
                client: client
            )
            await features._load(userId: nil)
        }

        // Re-identify features when auth session changes
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await session in self.auth.authObject.$currentSession.values {
                await self.features._load(userId: session?.user.id)
            }
        }
    }

    /// Set user context for feature targeting. Call once after login.
    /// Only needed when NOT using Onelo Auth — Onelo Auth sets this automatically.
    public func identify(_ userId: String) async {
        await features._load(userId: userId)
    }
}

// MARK: - Security attestation

/// Checks attest_required from /api/sdk/config, then runs platform-appropriate attestation.
/// Writes result directly to httpClient so all subsequent requests carry the header.
@MainActor
private func _ensureSecurityHeaders(
    publishableKey: String,
    baseURL: URL,
    client: _OneloHTTPClient
) async {
    guard let attestRequired = await _fetchAttestRequired(publishableKey: publishableKey, baseURL: baseURL),
          attestRequired else {
        return // not required — skip entirely
    }

    #if os(macOS)
    if #available(macOS 14.0, *) {
        await _runAppAttest(publishableKey: publishableKey, baseURL: baseURL, client: client)
    } else {
        // macOS 11–13: use codesign fingerprint fallback
        if let fp = OneloCodesignFallback.codesignFingerprint() {
            client.codesignFingerprint = fp
        }
    }
    #elseif os(iOS)
    if #available(iOS 14.0, *) {
        await _runAppAttest(publishableKey: publishableKey, baseURL: baseURL, client: client)
    }
    #endif
}

@available(iOS 14.0, macOS 14.0, *)
private func _runAppAttest(publishableKey: String, baseURL: URL, client: _OneloHTTPClient) async {
    let attester = OneloAppAttest(baseURL: baseURL.absoluteString, publishableKey: publishableKey)
    guard let token = try? await attester.getAttestToken() else { return }
    client.attestToken = token
}

private func _fetchAttestRequired(publishableKey: String, baseURL: URL) async -> Bool? {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/sdk/config"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "key", value: publishableKey)]
    guard let url = components?.url else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["attest_required"] as? Bool
}
