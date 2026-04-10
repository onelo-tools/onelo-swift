import Foundation
import CommonCrypto
import Supabase

/// OneloAuth — Swift SDK for Onelo authentication.
///
/// Initialize with just a publishable key from the Onelo dashboard:
/// ```swift
/// let auth = OneloAuth(config: OneloConfig(publishableKey: "onelo_pk_live_abc123"))
/// ```
@MainActor
public final class OneloAuth: ObservableObject {
    @Published public private(set) var currentSession: OneloSession?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isReady: Bool = false
    /// Set when the publishable key is revoked or the app is deleted.
    @Published public private(set) var isRevoked: Bool = false
    /// Set when the user account has been deleted or suspended by an admin.
    @Published public private(set) var isUserRevoked: Bool = false

    private var client: AuthClient?
    private let keychain: KeychainStorage
    private let config: OneloConfig
    private var pkceVerifier: String?

    private enum KeychainKeys {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expiresAt = "expires_at"
        static let userJson = "user_json"
        static let supabaseUrl = "supabase_url"
        static let supabaseAnonKey = "supabase_anon_key"
    }

    public init(config: OneloConfig) {
        self.config = config
        self.keychain = KeychainStorage()
        Task { await self.initialize() }
    }

    // MARK: - Public API

    /// Sign in — goes through Onelo backend to track last_seen_at and validate app access.
    public func signIn(email: String, password: String) async throws -> OneloSession {
        isLoading = true
        defer { isLoading = false }
        return try await _signInAttempt(email: email, password: password, isRetry: false)
    }

    private func _signInAttempt(email: String, password: String, isRetry: Bool) async throws -> OneloSession {
        if pkceVerifier == nil {
            guard !isRetry else { throw OneloError.serverError("SDK not ready — call after isReady") }
            try await refreshPKCE()
        }
        guard let verifier = pkceVerifier else {
            throw OneloError.serverError("SDK not ready — call after isReady")
        }

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
            "code_verifier": verifier,
        ]

        let json: [String: Any]
        do {
            json = try await backendPost(path: "/api/sdk/auth/signin", body: body)
        } catch OneloError.serverError(let msg) where msg.contains("PKCE") && !isRetry {
            pkceVerifier = nil
            try await refreshPKCE()
            return try await _signInAttempt(email: email, password: password, isRetry: true)
        }

        // New flat response: { access_token, refresh_token, token_type, expires_in, user }
        guard
            let accessToken = json["access_token"] as? String,
            let refreshToken = json["refresh_token"] as? String,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Sign in failed"
            throw OneloError.serverError(msg)
        }
        pkceVerifier = nil

        let expiresIn = json["expires_in"] as? Int ?? 900
        let userEmail = userData["email"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let user = OneloUser(id: userId, email: userEmail, role: .member, tenantId: nil)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    /// Sign up — registers via Onelo backend so the user is tracked in app_users.
    /// Returns `true` if the caller should show "check your email" (email verification required).
    /// Returns `false` if sign-up created a session directly (email+password, no verification).
    public func signUp(email: String, password: String) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }
        return try await _signUpAttempt(email: email, password: password, isRetry: false)
    }

    private func _signUpAttempt(email: String, password: String, isRetry: Bool) async throws -> Bool {
        if pkceVerifier == nil {
            guard !isRetry else { throw OneloError.serverError("SDK not ready — call after isReady") }
            try await refreshPKCE()
        }
        guard let verifier = pkceVerifier else {
            throw OneloError.serverError("SDK not ready — call after isReady")
        }

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
            "code_verifier": verifier,
        ]

        let json: [String: Any]
        do {
            json = try await backendPost(path: "/api/sdk/auth/signup", body: body)
        } catch OneloError.serverError(let msg) where msg.contains("PKCE") && !isRetry {
            pkceVerifier = nil
            try await refreshPKCE()
            return try await _signUpAttempt(email: email, password: password, isRetry: true)
        }

        if let errMsg = json["error"] as? String {
            throw OneloError.serverError(errMsg)
        }
        pkceVerifier = nil

        // New flat response: { access_token, refresh_token, token_type, expires_in, user }
        if let accessToken = json["access_token"] as? String,
           let refreshToken = json["refresh_token"] as? String,
           let userData = json["user"] as? [String: Any],
           let userId = userData["id"] as? String {
            let expiresIn = json["expires_in"] as? Int ?? 900
            let userEmail = userData["email"] as? String
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let user = OneloUser(id: userId, email: userEmail, role: .member, tenantId: nil)
            let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
            try saveSession(session)
            currentSession = session
            return false // session created, no email verification needed
        }

        return true // email verification required
    }

    public func signOut() async throws {
        isLoading = true
        defer { isLoading = false }

        // Send signout to backend (best-effort)
        if let accessToken = currentSession?.accessToken {
            let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/signout")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")
            _ = try? await URLSession.shared.data(for: request)
        } else if let client {
            // OAuth path
            try? await client.signOut()
        }

        try keychain.clear()
        currentSession = nil
        pkceVerifier = nil
        Task { await self.initialize() }
    }

    /// Request a password reset email.
    public func resetPassword(email: String) async throws {
        _ = try await backendPost(path: "/api/sdk/auth/reset-password/request", body: [
            "publishableKey": config.publishableKey,
            "email": email,
        ])
    }

    /// Confirm a password reset with the token from the email.
    public func confirmPasswordReset(token: String, newPassword: String) async throws {
        _ = try await backendPost(path: "/api/sdk/auth/reset-password/confirm", body: [
            "publishableKey": config.publishableKey,
            "token": token,
            "new_password": newPassword,
        ])
    }

    public func signInWithMagicLink(email: String, redirectTo: URL? = nil) async throws {
        let client = try requireClient()
        try await client.signInWithOTP(email: email, redirectTo: redirectTo)
    }

    /// Refreshes the session via Onelo backend — validates ban status and app membership.
    public func refreshSession() async throws -> OneloSession? {
        guard let refreshToken = try keychain.get(forKey: KeychainKeys.refreshToken) else { return nil }

        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken,
            "publishableKey": config.publishableKey,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            let detail = json["detail"] as? String ?? ""
            if detail.hasPrefix("account_") {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return nil
            }
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = json["detail"] as? String ?? json["error"] as? String ?? "HTTP \(http.statusCode)"
            try? keychain.clear()
            currentSession = nil
            throw OneloError.serverError(msg)
        }

        if let errMsg = json["error"] as? String {
            try keychain.clear()
            currentSession = nil
            throw OneloError.serverError(errMsg)
        }

        let existingUser = currentSession?.user ?? OneloUser(id: "", email: nil, role: .member, tenantId: nil)

        // SDK email+password path: flat response { access_token, refresh_token, expires_in }
        if let accessToken = json["access_token"] as? String,
           let newRefreshToken = json["refresh_token"] as? String {
            let expiresIn = json["expires_in"] as? Int ?? 900
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: existingUser)
            try saveSession(session)
            currentSession = session
            return session
        }

        // OAuth / Supabase path: nested { session: { access_token, refresh_token, expires_in } }
        if let sessionData = json["session"] as? [String: Any],
           let accessToken = sessionData["access_token"] as? String,
           let newRefreshToken = sessionData["refresh_token"] as? String,
           let expiresIn = sessionData["expires_in"] as? Int {
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: existingUser)
            try saveSession(session)
            currentSession = session
            return session
        }

        throw OneloError.serverError("Refresh failed")
    }

    private func refreshPKCE() async throws {
        let resolved = try await resolveConfig()
        let authURL = URL(string: resolved.supabaseUrl)!.appendingPathComponent("/auth/v1")
        client = AuthClient(
            url: authURL,
            headers: ["apikey": resolved.supabaseAnonKey],
            localStorage: AuthClient.Configuration.defaultLocalStorage
        )
        try? keychain.set(resolved.supabaseUrl, forKey: KeychainKeys.supabaseUrl)
        try? keychain.set(resolved.supabaseAnonKey, forKey: KeychainKeys.supabaseAnonKey)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Private

    private func initialize() async {
        do {
            let resolved = try await resolveConfig()

            try? keychain.set(resolved.supabaseUrl, forKey: KeychainKeys.supabaseUrl)
            try? keychain.set(resolved.supabaseAnonKey, forKey: KeychainKeys.supabaseAnonKey)

            let authURL = URL(string: resolved.supabaseUrl)!
                .appendingPathComponent("/auth/v1")
            client = AuthClient(
                url: authURL,
                headers: ["apikey": resolved.supabaseAnonKey],
                localStorage: AuthClient.Configuration.defaultLocalStorage
            )
            isReady = true
            await restoreSession()
        } catch OneloError.invalidPublishableKey {
            try? keychain.clear()
            currentSession = nil
            isRevoked = true
        } catch {
            // Network offline — fall back to cached config
            if let url = try? keychain.get(forKey: KeychainKeys.supabaseUrl),
               let key = try? keychain.get(forKey: KeychainKeys.supabaseAnonKey) {
                let authURL = URL(string: url)!.appendingPathComponent("/auth/v1")
                client = AuthClient(
                    url: authURL,
                    headers: ["apikey": key],
                    localStorage: AuthClient.Configuration.defaultLocalStorage
                )
                isReady = true
                await restoreSession()
            }
        }
    }

    private func resolveConfig() async throws -> ResolvedConfig {
        guard config.publishableKey.hasPrefix("onelo_pk_") else {
            throw OneloError.invalidPublishableKey("Key must start with onelo_pk_")
        }

        let verifier = generateCodeVerifier()
        pkceVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        let configRequest = URLRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: configRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.invalidPublishableKey("Server rejected the key")
        }

        return try JSONDecoder().decode(ResolvedConfig.self, from: data)
    }

    private func requireClient() throws -> AuthClient {
        guard let client else {
            throw OneloError.notAuthenticated
        }
        return client
    }

    private func restoreSession() async {
        guard
            let accessToken = try? keychain.get(forKey: KeychainKeys.accessToken),
            let refreshToken = try? keychain.get(forKey: KeychainKeys.refreshToken),
            let expiresAtStr = try? keychain.get(forKey: KeychainKeys.expiresAt),
            let expiresAtInterval = TimeInterval(expiresAtStr),
            let userJsonStr = try? keychain.get(forKey: KeychainKeys.userJson),
            let userJson = userJsonStr.data(using: .utf8),
            let user = try? JSONDecoder().decode(OneloUser.self, from: userJson)
        else { return }

        let expiresAt = Date(timeIntervalSince1970: expiresAtInterval)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)

        if session.isExpiringSoon {
            _ = try? await refreshSession()
        } else {
            let valid = await verifySession(accessToken: accessToken)
            if valid {
                currentSession = session
            }
        }
    }

    /// Calls /verify to check if the user account is still active.
    /// Returns true if valid, false if revoked/suspended (and sets isUserRevoked).
    /// Returns true on network errors (fail-open) to avoid false logouts.
    @discardableResult
    private func verifySession(accessToken: String) async -> Bool {
        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/verify")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return true // network error — fail open
        }

        if http.statusCode == 200 { return true }

        if http.statusCode == 403 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let detail = json["detail"] as? String ?? ""
            if detail.hasPrefix("account_") {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return false
            }
        }

        if http.statusCode == 401 {
            _ = try? await refreshSession()
            return false
        }

        return true
    }

    private func saveSession(_ session: OneloSession) throws {
        try keychain.set(session.accessToken, forKey: KeychainKeys.accessToken)
        try keychain.set(session.refreshToken, forKey: KeychainKeys.refreshToken)
        try keychain.set(String(session.expiresAt.timeIntervalSince1970), forKey: KeychainKeys.expiresAt)
        let userJson = try JSONEncoder().encode(session.user)
        try keychain.set(String(data: userJson, encoding: .utf8) ?? "", forKey: KeychainKeys.userJson)
    }

    private func backendPost(path: String, body: [String: String]) async throws -> [String: Any] {
        let url = config.apiUrl.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode >= 400 {
            let detailStr = json["detail"] as? String
            let detailDict = json["detail"] as? [String: Any]
            let msg = json["error"] as? String
                ?? detailStr
                ?? detailDict?["error"] as? String
                ?? "HTTP \(http.statusCode)"
            throw OneloError.serverError(msg)
        }

        return json
    }

    func backendPostAny(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = config.apiUrl.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode >= 400 {
            let msg = json["error"] as? String ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
            throw OneloError.serverError(msg)
        }

        return json
    }
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
