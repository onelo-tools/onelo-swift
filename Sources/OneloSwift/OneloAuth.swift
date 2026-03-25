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

    public func signIn(email: String, password: String) async throws -> OneloSession {
        let client = try requireClient()
        isLoading = true
        defer { isLoading = false }

        let session = try await client.signIn(email: email, password: password)
        let oneloSession = try mapSession(session)
        try saveSession(oneloSession)
        currentSession = oneloSession
        return oneloSession
    }

    public func signUp(email: String, password: String) async throws -> Bool {
        let client = try requireClient()
        isLoading = true
        defer { isLoading = false }

        let response = try await client.signUp(email: email, password: password)
        return response.session == nil
    }

    public func signOut() async throws {
        let client = try requireClient()
        isLoading = true
        defer { isLoading = false }

        try await client.signOut()
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

    public func refreshSession() async throws -> OneloSession? {
        let client = try requireClient()
        guard let refreshToken = try keychain.get(forKey: KeychainKeys.refreshToken) else { return nil }

        let session = try await client.refreshSession(refreshToken: refreshToken)
        let oneloSession = try mapSession(session)
        try saveSession(oneloSession)
        currentSession = oneloSession
        return oneloSession
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

    private func mapSession(_ session: Session) throws -> OneloSession {
        let meta = session.user.appMetadata
        let roleRaw = meta["user_role"]?.stringValue ?? "member"
        let role = UserRole(rawValue: roleRaw) ?? .member
        let tenantId = meta["tenant_id"]?.stringValue

        let oneloUser = OneloUser(
            id: session.user.id.uuidString,
            email: session.user.email,
            role: role,
            tenantId: tenantId
        )
        return OneloSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt),
            user: oneloUser
        )
    }

    private func saveSession(_ session: OneloSession) throws {
        try keychain.set(session.accessToken, forKey: KeychainKeys.accessToken)
        try keychain.set(session.refreshToken, forKey: KeychainKeys.refreshToken)
        try keychain.set(String(session.expiresAt.timeIntervalSince1970), forKey: KeychainKeys.expiresAt)
        let userJson = try JSONEncoder().encode(session.user)
        try keychain.set(String(data: userJson, encoding: .utf8) ?? "", forKey: KeychainKeys.userJson)
    }
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
