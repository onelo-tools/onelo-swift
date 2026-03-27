import Foundation

// MARK: - Waitlist

public struct WaitlistResult: Sendable {
    public let position: Int?
    public let status: String
    public let alreadyJoined: Bool
}

// MARK: - Forms

public struct FormFieldDef: Sendable {
    public let id: String
    public let type: String
    public let label: String
    public let required: Bool
}

public struct FormSchema: Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let fields: [FormFieldDef]
    public let formType: String
}

// MARK: - OneloAuth extensions

public extension OneloAuth {

    // MARK: Waitlist

    /// Join the waitlist for this app.
    func joinWaitlist(
        email: String,
        name: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> WaitlistResult {
        var body: [String: Any] = [
            "publishableKey": config.publishableKey,
            "email": email,
            "_hp": "",   // honeypot — always empty from real SDK calls
        ]
        if let name { body["name"] = name }
        if !metadata.isEmpty { body["metadata"] = metadata }

        let json = try await backendPostAny(path: "/api/sdk/waitlist/join", body: body)

        if let err = json["error"] as? String { throw OneloError.serverError(err) }
        let position = json["position"] as? Int
        let alreadyJoined = json["alreadyJoined"] as? Bool ?? false
        return WaitlistResult(position: position, status: "waiting", alreadyJoined: alreadyJoined)
    }

    /// Check waitlist status for an email.
    func waitlistStatus(email: String) async throws -> WaitlistResult? {
        var components = URLComponents(
            url: config.apiUrl.appendingPathComponent("/api/sdk/waitlist/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "publishableKey", value: config.publishableKey),
            URLQueryItem(name: "email", value: email),
        ]
        let request = URLRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneloError.serverError("No response") }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw OneloError.serverError(json["detail"] as? String ?? "HTTP \(http.statusCode)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let position = json["position"] as? Int
        let status = json["status"] as? String ?? "waiting"
        return WaitlistResult(position: position, status: status, alreadyJoined: status == "joined")
    }

    /// Redeem an invite token before signup.
    func redeemInvite(token: String, email: String) async throws {
        let body: [String: Any] = [
            "publishableKey": config.publishableKey,
            "token": token,
            "email": email,
        ]
        let json = try await backendPostAny(path: "/api/sdk/waitlist/redeem", body: body)
        if let err = json["error"] as? String { throw OneloError.serverError(err) }
    }

    // MARK: Forms

    /// Fetch form schema for dynamic rendering.
    func fetchFormSchema(slug: String) async throws -> FormSchema {
        var components = URLComponents(
            url: config.apiUrl.appendingPathComponent("/api/sdk/forms/schema"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "publishableKey", value: config.publishableKey),
            URLQueryItem(name: "formSlug", value: slug),
        ]
        let request = URLRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.serverError("Form not found")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let rawFields = json["schema"] as? [[String: Any]] ?? []
        let fields = rawFields.map { f in
            FormFieldDef(
                id: f["id"] as? String ?? "",
                type: f["type"] as? String ?? "text",
                label: f["label"] as? String ?? "",
                required: f["required"] as? Bool ?? false
            )
        }
        return FormSchema(
            id: json["id"] as? String ?? "",
            name: json["name"] as? String ?? "",
            description: json["description"] as? String,
            fields: fields,
            formType: json["formType"] as? String ?? "custom"
        )
    }

    /// Submit a form. Honeypot and timestamp are added automatically.
    func submitForm(
        slug: String,
        data: [String: String],
        submitterEmail: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "publishableKey": config.publishableKey,
            "formSlug": slug,
            "data": data,
            "_hp": "",
            "_ts": 5000,  // realistic time-to-submit
        ]
        if let submitterEmail { body["submitterEmail"] = submitterEmail }
        let json = try await backendPostAny(path: "/api/sdk/forms/submit", body: body)
        if let err = json["error"] as? String { throw OneloError.serverError(err) }
        return json["submissionId"] as? String ?? ""
    }

    /// Submit a contact form (name, email, message).
    func submitContactForm(name: String, email: String, message: String) async throws -> String {
        return try await submitForm(
            slug: "contact",
            data: ["name": name, "email": email, "message": message],
            submitterEmail: email
        )
    }
}
