import Foundation

public enum OneloSDK {
    public static let sdkVersion = "3.3.1-staging"
}

public enum UserRole: String, Codable, Sendable {
    case platformOwner = "platform_owner"
    case creator = "creator"
    case member = "member"
}

public struct OneloUser: Codable, Sendable {
    public let id: String
    public let email: String?
    public let role: UserRole
    public let tenantId: String?

    public init(id: String, email: String?, role: UserRole, tenantId: String?) {
        self.id = id
        self.email = email
        self.role = role
        self.tenantId = tenantId
    }
}

public struct OneloSession: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let user: OneloUser

    public var isExpired: Bool { expiresAt < Date() }
    public var isExpiringSoon: Bool { expiresAt < Date().addingTimeInterval(60) }
}

public struct OneloConfig: Sendable {
    /// Publishable key from Onelo dashboard (onelo_pk_live_...)
    public let publishableKey: String
    /// API base URL — pre-filled by the Onelo dashboard snippet. No default; must be set explicitly.
    public let apiUrl: URL
    /// Custom URL scheme registered in your app target (e.g. "myapp").
    /// Must match the scheme registered via `app.setAsDefaultProtocolClient` (Electron)
    /// or Info.plist URL Types (Swift).
    public let callbackScheme: String

    public init(
        publishableKey: String,
        apiUrl: URL,
        callbackScheme: String
    ) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
        self.callbackScheme = callbackScheme
    }
}

/// Internal config resolved from publishable key
struct ResolvedConfig: Decodable {
    let supabaseUrl: String
    let supabaseAnonKey: String
    let tenantId: String

    enum CodingKeys: String, CodingKey {
        case supabaseUrl = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case tenantId = "tenant_id"
    }
}

public enum OneloError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidResponse
    case invalidPublishableKey(String)
    case keychainError(String)
    case networkError(String)
    case serverError(String)
    /// User dismissed the auth window without signing in.
    case cancelled
    /// App is on the Free plan — direct signIn()/signUp() calls are not allowed.
    case hostedFlowRequired
    /// User account has been suspended or deleted by an admin.
    case userRevoked

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "User is not authenticated"
        case .invalidResponse: return "Invalid response from server"
        case .invalidPublishableKey(let msg): return "Invalid publishable key: \(msg)"
        case .keychainError(let msg): return "Keychain error: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .serverError(let msg): return msg
        case .cancelled: return "Authentication was cancelled"
        case .hostedFlowRequired: return "This plan requires the hosted auth flow"
        case .userRevoked: return "Your account has been deactivated"
        }
    }
}
