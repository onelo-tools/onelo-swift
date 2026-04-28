import Foundation

/// Internal HTTP client for SDK modules (features, forms, waitlist).
/// Injects X-Bundle-Id and security attestation headers on every request.
final class _OneloHTTPClient: @unchecked Sendable {
    let publishableKey: String
    let baseURL: URL
    private let bundleId: String

    // Written once at SDK startup, read on every request. Safe as nonisolated(unsafe)
    // because the write always completes before the first SDK request is made.
    nonisolated(unsafe) var attestToken: String? = nil
    nonisolated(unsafe) var codesignFingerprint: String? = nil
    nonisolated(unsafe) var integrityToken: String? = nil

    init(publishableKey: String, baseURL: URL) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
        self.bundleId = Bundle.main.bundleIdentifier ?? ""
    }

    // MARK: - Security headers

    private func applySecurityHeaders(to request: inout URLRequest) {
        if !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        if let token = attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
        if let fp = codesignFingerprint {
            request.setValue(fp, forHTTPHeaderField: "X-Codesign-Fingerprint")
        }
        if let it = integrityToken {
            request.setValue(it, forHTTPHeaderField: "X-Integrity-Token")
        }
    }

    // MARK: - HTTP methods

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)

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

    func get(path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw OneloError.serverError("Invalid URL components")
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw OneloError.serverError("Invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)

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
