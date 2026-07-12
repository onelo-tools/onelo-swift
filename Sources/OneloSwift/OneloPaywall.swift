import Foundation

public final class OneloPaywall {
    private let client: _OneloHTTPClient?

    /// Designated init — receives the shared HTTP client so network calls work.
    init(client: _OneloHTTPClient) {
        self.client = client
    }

    /// Fallback init kept for backward-compatibility; network methods will throw
    /// `.networkError("SDK not configured")` when used this way.
    init() {
        self.client = nil
    }

    // MARK: - Subscription management

    /// Cancels an active subscription on behalf of the signed-in user.
    ///
    /// This is a Paid-plan, developer-facing API for apps that build their own
    /// cancellation UI instead of using the hosted customer portal. The `token`
    /// must be a valid Onelo access token for the subscriber.
    ///
    /// - Parameters:
    ///   - token: Access token of the subscriber whose subscription to cancel.
    ///   - options: Optional reason data (reason code + free-text).  Defaults to empty.
    /// - Returns: A ``CancelSubscriptionResult`` indicating success and any server message.
    @discardableResult
    public func cancelSubscription(
        token: String,
        options: CancelSubscriptionOptions = .init()
    ) async throws -> CancelSubscriptionResult {
        guard let client else {
            throw OneloError.networkError("SDK not configured — use Onelo(publishableKey:baseURL:)")
        }
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "token": token,
        ]
        if let code = options.reasonCode {
            body["reason_code"] = code
        }
        if let text = options.reasonText {
            body["reason_text"] = String(text.prefix(500))
        }
        let resp = try await client.post(path: "/api/sdk/paywall/portal-cancel", body: body)
        let message = resp["message"] as? String
        return CancelSubscriptionResult(message: message)
    }
}

// MARK: - Supporting types

/// Options for ``OneloPaywall/cancelSubscription(token:options:)``.
public struct CancelSubscriptionOptions: Sendable {
    /// A reason-code constant from ``OneloResponseReasonCode``.
    public var reasonCode: String?
    /// Free-text explanation (truncated to 500 characters before sending).
    public var reasonText: String?

    public init(reasonCode: String? = nil, reasonText: String? = nil) {
        self.reasonCode = reasonCode
        self.reasonText = reasonText
    }
}

/// Result returned by ``OneloPaywall/cancelSubscription(token:options:)``.
public struct CancelSubscriptionResult: Sendable {
    /// Human-readable message from the server, if any.
    public let message: String?
}
