import Foundation
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

    private var client: AuthClient?
    private let keychain: KeychainStorage
    private let config: OneloConfig

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

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
        ]
        let json = try await backendPost(path: "/api/sdk/auth/signin", body: body)

        guard
            let sessionData = json["session"] as? [String: Any],
            let accessToken = sessionData["access_token"] as? String,
            let refreshToken = sessionData["refresh_token"] as? String,
            let expiresIn = sessionData["expires_in"] as? Int,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Sign in failed"
            throw OneloError.serverError(msg)
        }

        let userEmail = userData["email"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let user = OneloUser(id: userId, email: userEmail, role: .member, tenantId: nil)
        let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
        try saveSession(session)
        currentSession = session
        return session
    }

    /// Sign up — registers via Onelo backend so the user is tracked in app_users.
    /// Returns `true` if email verification is required.
    public func signUp(email: String, password: String) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        let body: [String: String] = [
            "email": email,
            "password": password,
            "publishableKey": config.publishableKey,
        ]
        let json = try await backendPost(path: "/api/sdk/auth/signup", body: body)

        if let errMsg = json["error"] as? String {
            throw OneloError.serverError(errMsg)
        }

        // If backend returned a session, store it and sign in immediately
        if let sessionData = json["session"] as? [String: Any],
           let accessToken = sessionData["access_token"] as? String,
           let refreshToken = sessionData["refresh_token"] as? String,
           let expiresIn = sessionData["expires_in"] as? Int,
           let userData = json["user"] as? [String: Any],
           let userId = userData["id"] as? String {
            let userEmail = userData["email"] as? String
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let user = OneloUser(id: userId, email: userEmail, role: .member, tenantId: nil)
            let session = OneloSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
            try saveSession(session)
            currentSession = session
            return false // already signed in
        }

        return true // needs email verification
    }

    public func signOut() async throws {
        isLoading = true
        defer { isLoading = false }

        // Best-effort revoke with Supabase (non-fatal if offline)
        if let client {
            try? await client.signOut()
        }
        try keychain.clear()
        currentSession = nil
    }

    public func resetPassword(email: String, redirectTo: URL? = nil) async throws {
        let client = try requireClient()
        try await client.resetPasswordForEmail(email, redirectTo: redirectTo)
    }

    public func signInWithMagicLink(email: String, redirectTo: URL? = nil) async throws {
        let client = try requireClient()
        try await client.signInWithOTP(email: email, redirectTo: redirectTo)
    }

    /// Refreshes the session via Onelo backend — validates ban status and app membership.
    public func refreshSession() async throws -> OneloSession? {
        guard let refreshToken = try keychain.get(forKey: KeychainKeys.refreshToken) else { return nil }

        let body: [String: String] = [
            "refresh_token": refreshToken,
            "publishableKey": config.publishableKey,
        ]
        let json = try await backendPost(path: "/api/sdk/auth/refresh", body: body)

        if let errMsg = json["error"] as? String {
            // Account deleted or banned — force sign out
            try keychain.clear()
            currentSession = nil
            throw OneloError.serverError(errMsg)
        }

        guard
            let sessionData = json["session"] as? [String: Any],
            let accessToken = sessionData["access_token"] as? String,
            let newRefreshToken = sessionData["refresh_token"] as? String,
            let expiresIn = sessionData["expires_in"] as? Int
        else {
            throw OneloError.serverError("Refresh failed")
        }

        // Preserve existing user info
        let existingUser = currentSession?.user ?? OneloUser(id: "", email: nil, role: .member, tenantId: nil)
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: existingUser)
        try saveSession(session)
        currentSession = session
        return session
    }

    // MARK: - Private

    private func initialize() async {
        do {
            let resolved = try await resolveConfig()

            // Cache credentials in Keychain for offline init next launch
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
        } catch {
            // Try offline fallback from Keychain
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

        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/sdk/config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: config.publishableKey)]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
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
            currentSession = session
        }
    }

    private func saveSession(_ session: OneloSession) throws {
        try keychain.set(session.accessToken, forKey: KeychainKeys.accessToken)
        try keychain.set(session.refreshToken, forKey: KeychainKeys.refreshToken)
        try keychain.set(String(session.expiresAt.timeIntervalSince1970), forKey: KeychainKeys.expiresAt)
        let userJson = try JSONEncoder().encode(session.user)
        try keychain.set(String(data: userJson, encoding: .utf8) ?? "", forKey: KeychainKeys.userJson)
    }

    /// POST JSON to the Onelo backend and return parsed response dictionary.
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
            let msg = json["error"] as? String ?? "HTTP \(http.statusCode)"
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
