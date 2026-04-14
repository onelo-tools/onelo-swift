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
    /// App name returned by /api/sdk/auth/initiate (populated after hosted flow is initiated).
    @Published public private(set) var hostedAppName: String = ""
    /// App logo URL returned by /api/sdk/auth/initiate.
    @Published public private(set) var hostedAppLogoUrl: URL? = nil

    private var client: AuthClient?
    private let keychain: KeychainStorage
    let config: OneloConfig
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
        pkceVerifier = nil

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
            return false
        }

        return true
    }

    // MARK: - Hosted flow (WKWebView)

    /// Calls /api/sdk/auth/initiate and returns the URL to load in the embedded web view.
    /// Also populates `hostedAppName` and `hostedAppLogoUrl`.
    public func initiateHostedFlow() async throws -> URL {
        var components = URLComponents(url: config.apiUrl.appendingPathComponent("/api/sdk/auth/initiate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.publishableKey),
            URLQueryItem(name: "callback_scheme", value: config.callbackScheme),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneloError.serverError("Failed to initiate hosted flow")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostedUrlStr = json["hosted_url"] as? String,
              let hostedUrl = URL(string: hostedUrlStr) else {
            throw OneloError.serverError("Invalid initiate response")
        }

        hostedAppName = json["app_name"] as? String ?? ""
        if let logoStr = json["app_logo_url"] as? String {
            hostedAppLogoUrl = URL(string: logoStr)
        }

        return hostedUrl
    }

    /// Exchanges the auth code returned by the hosted page for a session.
    public func exchangeHostedCode(_ code: String) async throws -> OneloSession {
        let json = try await backendPost(
            path: "/api/sdk/auth/hosted-callback",
            body: ["code": code, "publishableKey": config.publishableKey]
        )

        // hosted-callback returns tokens at the top level (not nested under "session")
        guard
            let accessToken = json["access_token"] as? String,
            let refreshToken = json["refresh_token"] as? String,
            let expiresIn = json["expires_in"] as? Int,
            let userData = json["user"] as? [String: Any],
            let userId = userData["id"] as? String
        else {
            let msg = json["error"] as? String ?? "Code exchange failed"
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

    public func signOut() async throws {
        isLoading = true
        defer { isLoading = false }

        if let client {
            try? await client.signOut()
        }
        try keychain.clear()
        currentSession = nil
        pkceVerifier = nil
        Task { await self.initialize() }
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

        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken,
            "publishableKey": config.publishableKey,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 403 {
            // Account deleted or suspended — treat as a hard revocation
            let detail = json["detail"] as? String ?? ""
            let isRevocation = detail.contains("account_deleted")
                || detail.contains("account_suspended")
                || detail.contains("account_payment_failed")
            if isRevocation {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return nil
            }
        }

        if http.statusCode >= 400 {
            let msg = json["error"] as? String ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
            try keychain.clear()
            currentSession = nil
            throw OneloError.serverError(msg)
        }

        if let errMsg = json["error"] as? String {
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

        let existingUser = currentSession?.user ?? OneloUser(id: "", email: nil, role: .member, tenantId: nil)
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let session = OneloSession(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt, user: existingUser)
        try saveSession(session)
        currentSession = session
        return session
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
            // Key was revoked or app deleted — clear session and signal to the UI
            try? keychain.clear()
            currentSession = nil
            isRevoked = true
        } catch {
            // Network offline or transient error — fall back to cached config so
            // the user can still use a valid existing session.
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
            // Verify session is still valid against the backend before exposing it to the app.
            // This catches users that were deleted or suspended while offline.
            let revoked = await verifySession(accessToken: accessToken)
            if !revoked {
                currentSession = session
            }
        }
    }

    /// Calls the backend /verify endpoint to check whether the account has been revoked.
    /// Returns `true` if the session was revoked (and has been cleared), `false` if it is valid.
    @discardableResult
    private func verifySession(accessToken: String) async -> Bool {
        let url = config.apiUrl.appendingPathComponent("/api/sdk/auth/verify")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-Publishable-Key")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Network error — fail open, let the app proceed with the cached session
            return false
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 200 {
            return false
        }

        if http.statusCode == 403 {
            let detail = json["detail"] as? String ?? ""
            let isRevocation = detail.contains("revoked")
                || detail.contains("deleted")
                || detail.contains("suspended")
            if isRevocation {
                try? keychain.clear()
                currentSession = nil
                isUserRevoked = true
                return true
            }
        }

        if http.statusCode == 401 {
            // Token expired — trigger normal refresh flow
            _ = try? await refreshSession()
            return false
        }

        // Unexpected error — fail open
        return false
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
            let msg = json["error"] as? String ?? json["detail"] as? String ?? "HTTP \(http.statusCode)"
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
