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
    private let baseURL: URL
    private var heartbeatTimer: Timer?

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
        self.baseURL = baseURL
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for OneloAuth to finish initializing (it handles attestation internally)
            for await ready in self.auth.authObject.$isReady.values {
                guard ready else { continue }
                // Copy attest token from OneloAuth to the features HTTP client
                if let token = self.auth.authObject.cachedAttestToken() {
                    self.httpClient.attestToken = token
                }
                await self.features._load(userId: nil)
                break
            }
        }

        // Re-identify features when auth session changes
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await session in self.auth.authObject.$currentSession.values {
                await self.features._load(userId: session?.user.id)
                if let session {
                    self.startHeartbeat(accessToken: session.accessToken)
                } else {
                    self.stopHeartbeat()
                }
            }
        }
    }

    /// Set user context for feature targeting. Call once after login.
    /// Only needed when NOT using Onelo Auth — Onelo Auth sets this automatically.
    public func identify(_ userId: String) async {
        await features._load(userId: userId)
    }

    // MARK: - Heartbeat

    private func startHeartbeat(accessToken: String) {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 780, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let session = self.auth.authObject.currentSession else { return }
                var request = URLRequest(url: self.baseURL.appendingPathComponent("/api/sdk/presence/heartbeat"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                try? await URLSession.shared.data(for: request)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}

