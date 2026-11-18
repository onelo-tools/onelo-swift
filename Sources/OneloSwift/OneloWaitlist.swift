import Foundation

public final class OneloWaitlist {
    private let client: _OneloHTTPClient
    /// #1074 — the App's language (`Onelo(language:)`), used when a join
    /// passes none.
    private let appLanguage: String?

    init(client: _OneloHTTPClient, language: String? = nil) {
        self.client = client
        self.appLanguage = language
    }

    /// Join a waitlist.
    ///
    /// `consent` (#818): the checkboxes your form showed — Marketing Consent
    /// and the waitlist's custom checkbox. Omitted, no consent is sent.
    /// `language` (#1038): the App's language for this sign-up. `nil` sends the
    /// App's language given to `Onelo(language:)`, else the device language
    /// (#1074); the backend stores the join's Page Language (one of the
    /// App Languages) for the waitlist emails.
    public func join(
        _ listId: String,
        email: String,
        slug: String? = nil,
        consent: OneloWaitlistConsent? = nil,
        language: String? = nil
    ) async -> OneloWaitlistResult {
        let body = Self.joinBody(
            publishableKey: client.publishableKey, email: email, slug: slug,
            consent: consent, language: language ?? appLanguage
        )
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

    /// The `/api/sdk/waitlist/join` body. Pure, so the wire is testable.
    static func joinBody(
        publishableKey: String,
        email: String,
        slug: String?,
        consent: OneloWaitlistConsent?,
        language: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "publishableKey": publishableKey,
            "email": email,
            // #1038: the App's language, else the device language.
            "language": language ?? OneloSignupMarketingConsent.deviceLanguage,
        ]
        if let slug { body["slug"] = slug }
        if let wire = consent?.wireValue { body["consent"] = wire }
        return body
    }
}
