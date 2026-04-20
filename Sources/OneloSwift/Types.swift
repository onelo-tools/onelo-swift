import Foundation

public enum OneloSDK {
    public static let sdkVersion = "3.5.0-staging"
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
    /// Onelo API base URL — required. Get this from your Onelo dashboard snippet.
    public let apiUrl: URL
    /// Callback scheme for hosted auth flow (e.g., "myapp://")
    public let callbackScheme: String

    public init(
        publishableKey: String,
        apiUrl: URL,
        callbackScheme: String = ""
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
    let allowCustomBranding: Bool
    let appName: String?
    let appLogoUrl: String?

    enum CodingKeys: String, CodingKey {
        case supabaseUrl = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case tenantId = "tenant_id"
        case allowCustomBranding = "allow_custom_branding"
        case appName = "app_name"
        case appLogoUrl = "app_logo_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supabaseUrl = try c.decode(String.self, forKey: .supabaseUrl)
        supabaseAnonKey = try c.decode(String.self, forKey: .supabaseAnonKey)
        tenantId = try c.decode(String.self, forKey: .tenantId)
        // Default false — safe fallback if backend doesn't send the field yet
        allowCustomBranding = (try? c.decode(Bool.self, forKey: .allowCustomBranding)) ?? false
        appName = try? c.decode(String.self, forKey: .appName)
        appLogoUrl = try? c.decode(String.self, forKey: .appLogoUrl)
    }
}

public enum OneloError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidResponse
    case invalidPublishableKey(String)
    case keychainError(String)
    case networkError(String)
    case serverError(String)
    case cancelled
    case requiresHostedFlow

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "User is not authenticated"
        case .invalidResponse: return "Invalid response from server"
        case .invalidPublishableKey(let msg): return "Invalid publishable key: \(msg)"
        case .keychainError(let msg): return "Keychain error: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .serverError(let msg): return msg
        case .cancelled: return "Sign in was cancelled"
        case .requiresHostedFlow: return "This app requires the hosted sign-in flow. Use presentHostedSignIn()."
        }
    }
}

