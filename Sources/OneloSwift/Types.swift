import Foundation

public enum OneloSDK {
    public static let sdkVersion = "2.1.0"
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
    /// Override API base URL (default: https://api.onelo.com)
    public let apiUrl: URL

    public init(
        publishableKey: String,
        apiUrl: URL = URL(string: "https://api.onelo.com")!
    ) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
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

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "User is not authenticated"
        case .invalidResponse: return "Invalid response from server"
        case .invalidPublishableKey(let msg): return "Invalid publishable key: \(msg)"
        case .keychainError(let msg): return "Keychain error: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .serverError(let msg): return msg
        }
    }
}
