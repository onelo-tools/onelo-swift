import Foundation

/// Internal HTTP client for SDK modules (features, forms, waitlist).
/// Does NOT use Supabase — plain URLSession with publishable key.
final class _OneloHTTPClient: Sendable {
    let publishableKey: String
    let baseURL: URL
    nonisolated(unsafe) var userPlan: String?

    init(publishableKey: String, baseURL: URL = URL(string: "https://api.onelo.tools")!) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
    }

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw OneloError.serverError(json["detail"] as? String ?? "HTTP \(http.statusCode)")
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
