import Foundation

public final class OneloForms {
    private let client: _OneloHTTPClient

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    /// Submit a form.
    public func submit(
        _ formSlug: String,
        data: [String: Any],
        submitterEmail: String? = nil
    ) async -> OneloFormResult {
        var body: [String: Any] = [
            "publishableKey": client.publishableKey,
            "formSlug": formSlug,
            "data": data,
        ]
        if let email = submitterEmail {
            body["submitterEmail"] = email
        }
        do {
            let resp = try await client.post(path: "/api/sdk/forms/submit", body: body)
            let message = resp["message"] as? String ?? ""
            return OneloFormResult(success: true, message: message)
        } catch {
            return OneloFormResult(success: false)
        }
    }
}
