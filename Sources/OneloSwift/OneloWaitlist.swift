import Foundation

public final class OneloWaitlist {
    private let client: _OneloHTTPClient

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    /// Join a waitlist.
    ///
    /// `consent` (#818): the checkboxes your form showed — Marketing Consent
    /// and the waitlist's custom checkbox. Omitted, no consent is sent.
    public func join(
        _ listId: String,
        email: String,
        slug: String? = nil,
        consent: OneloWaitlistConsent? = nil
    ) async -> OneloWaitlistResult {
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "email": email,
        ]
        if let slug { body["slug"] = slug }
        if let wire = consent?.wireValue { body["consent"] = wire }
        do {
            let resp = try await client.post(path: "/api/sdk/waitlist/join", body: body)
            return OneloWaitlistResult(
                success: true,
                position: resp["position"] as? Int,
                alreadyJoined: resp["alreadyJoined"] as? Bool ?? false
            )
        } catch {
            return OneloWaitlistResult(success: false)
        }
    }
}
