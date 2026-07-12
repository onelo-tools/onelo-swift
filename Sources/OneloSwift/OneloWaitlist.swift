import Foundation

public final class OneloWaitlist {
    private let client: _OneloHTTPClient

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    /// Join a waitlist.
    public func join(
        _ listId: String,
        email: String,
        slug: String? = nil
    ) async -> OneloWaitlistResult {
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "email": email,
        ]
        if let slug { body["slug"] = slug }
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
