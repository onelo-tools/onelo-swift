import Foundation

public enum OneloSDK {
    public static let sdkVersion = "3.74.1"
}

public enum UserRole: String, Codable, Sendable {
    case platformOwner = "platform_owner"
    case creator = "creator"
    case member = "member"
}

/// Whether the user currently has an active paid grant for this app.
/// Canonical source of truth is `paywall_access` on the backend — `OneloUser.entitlement`
/// is a snapshot from the last `/signin`, `/signup`, `/refresh`, `/user`, or `/hosted-callback`
/// response. Re-validate via `OneloAuth.revalidateEntitlement()` if you need a fresher read.
public enum OneloEntitlement: String, Codable, Sendable {
    case active
    case none
}

public struct OneloUser: Codable, Sendable {
    public let id: String
    public let email: String?
    public let role: UserRole
    public let tenantId: String?
    /// `.none` when the backend didn't return the field (pre-3.37 servers, or session restored
    /// from a keychain blob saved before the SDK started persisting it). Treat absence as `.none`
    /// for gating purposes — never as `.active`.
    public let entitlement: OneloEntitlement

    public init(
        id: String,
        email: String?,
        role: UserRole,
        tenantId: String?,
        entitlement: OneloEntitlement = .none
    ) {
        self.id = id
        self.email = email
        self.role = role
        self.tenantId = tenantId
        self.entitlement = entitlement
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, role, tenantId, entitlement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try? c.decode(String.self, forKey: .email)
        role = (try? c.decode(UserRole.self, forKey: .role)) ?? .member
        tenantId = try? c.decode(String.self, forKey: .tenantId)
        entitlement = (try? c.decode(OneloEntitlement.self, forKey: .entitlement)) ?? .none
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
    /// Suppresses the "no userId — call onelo.identify()" warning that fires when
    /// features resolve in anonymous mode while targeted features exist. Set to true
    /// if your app is intentionally anonymous. Default: false.
    public let suppressIdentifyWarning: Bool

    public init(
        publishableKey: String,
        apiUrl: URL,
        callbackScheme: String = "",
        suppressIdentifyWarning: Bool = false
    ) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
        self.callbackScheme = callbackScheme
        self.suppressIdentifyWarning = suppressIdentifyWarning
    }
}

/// Internal config resolved from publishable key
struct ResolvedConfig: Decodable {
    let supabaseUrl: String
    let supabaseAnonKey: String
    let tenantId: String
    let allowCustomBranding: Bool
    let attestRequired: Bool
    let appName: String?
    let appLogoUrl: String?
    let paywallEnabled: Bool
    let waitlistMode: Bool
    let sdkRedirectUrl: String?
    let storeUrl: String?
    let manageUrl: String?
    /// Plan-gated enabled OAuth providers (google/github/apple). Empty when the
    /// plan or the developer disables social. Drives whether the loading skeleton
    /// draws social pills so it matches what the hosted form will render.
    let oauthProviders: [String]
    /// Branding page background (`checkout_bg_color`, default `#111111` server-side
    /// when no custom branding). The auth view paints it so the pre-auth / loading
    /// frame matches the hosted page instead of flashing a system colour (#26).
    let checkoutBgColor: String?

    enum CodingKeys: String, CodingKey {
        case supabaseUrl = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case tenantId = "tenant_id"
        case allowCustomBranding = "allow_custom_branding"
        case attestRequired = "attest_required"
        case appName = "app_name"
        case appLogoUrl = "app_logo_url"
        case paywallEnabled = "paywall_enabled"
        case waitlistMode = "waitlist_mode"
        case sdkRedirectUrl = "sdk_redirect_url"
        case storeUrl = "store_url"
        case manageUrl = "manage_url"
        case oauthProviders = "oauth_providers"
        case checkoutBgColor = "checkout_bg_color"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supabaseUrl = try c.decode(String.self, forKey: .supabaseUrl)
        supabaseAnonKey = try c.decode(String.self, forKey: .supabaseAnonKey)
        tenantId = try c.decode(String.self, forKey: .tenantId)
        // Default false — safe fallback if backend doesn't send the field yet
        allowCustomBranding = (try? c.decode(Bool.self, forKey: .allowCustomBranding)) ?? false
        attestRequired = (try? c.decode(Bool.self, forKey: .attestRequired)) ?? false
        appName = try? c.decode(String.self, forKey: .appName)
        appLogoUrl = try? c.decode(String.self, forKey: .appLogoUrl)
        paywallEnabled = (try? c.decode(Bool.self, forKey: .paywallEnabled)) ?? false
        waitlistMode = (try? c.decode(Bool.self, forKey: .waitlistMode)) ?? false
        sdkRedirectUrl = try? c.decode(String.self, forKey: .sdkRedirectUrl)
        storeUrl = try? c.decode(String.self, forKey: .storeUrl)
        manageUrl = try? c.decode(String.self, forKey: .manageUrl)
        oauthProviders = (try? c.decode([String].self, forKey: .oauthProviders)) ?? []
        checkoutBgColor = try? c.decode(String.self, forKey: .checkoutBgColor)
    }
}

/// Canonical reason-code constants for cancellation and response flows.
/// Pass these via ``CancelSubscriptionOptions/reasonCode`` when calling
/// ``OneloPaywall/cancelSubscription(token:options:)``.
public enum OneloResponseReasonCode {
    public static let tooExpensive      = "too_expensive"
    public static let missingFeatures   = "missing_features"
    public static let notWorking        = "not_working"
    public static let notUsingAnymore   = "not_using_anymore"
    public static let foundAlternative  = "found_alternative"
    public static let boughtByMistake   = "bought_by_mistake"
    public static let preferNotToSay    = "prefer_not_to_say"
    public static let other             = "other"
    public static let skipped           = "skipped"
}

/// Errors raised by the Features module's entitlement-aware APIs (Task 4.5+).
/// Separate from `OneloError` so callers can catch entitlement failures
/// (`.notEntitled`, `.secureModeRequired`, `.invalidUserHash`) without
/// having to pattern-match on string-bearing `OneloError.serverError`.
public enum OneloFeaturesError: Error, Equatable, Sendable {
    /// `_load(userId:)` has not been called yet (or `userId` was nil).
    /// Entitlement endpoints are user-scoped — anonymous callers can't
    /// request a module token.
    case notAuthenticated
    /// Backend returned 403 not_entitled. The current user does not have
    /// access to the requested feature slug.
    case notEntitled
    /// Backend returned 401 secure_mode_required. The app is configured to
    /// require a userIdHash but the SDK was called without one.
    case secureModeRequired
    /// Backend returned 401 invalid_user_hash. The HMAC supplied as
    /// `userIdHash` did not verify against the userId.
    case invalidUserHash
    /// Network failure or malformed response.
    case networkError
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
    case timeout(String)
    /// Returned from `initiateStoreFlow()` when the application has
    /// `paywall_enabled = true` but no visible `paywall_store_options`
    /// rows have been configured. The SDK refuses to open a WebView in
    /// this case so the buyer never sees an empty store. Host apps
    /// should surface this as a "store not configured" message.
    case storeNotConfigured

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
        case .timeout(let msg): return "Timed out: \(msg)"
        case .storeNotConfigured: return "The store hasn't been configured for this app yet."
        }
    }
}

/// Why the resolver assigned this status.
///
/// FORWARD-COMPATIBLE: an unrecognized reason decodes to `.unknown` instead of
/// throwing. This is load-bearing — `FeatureState.reason` is optional, but a
/// PRESENT-but-unknown enum value used to throw and drop the ENTIRE feature from
/// the `/resolve` snapshot (every feature with that reason vanished → all
/// `.hidden`). New backend reasons (`paywall_no_plan`, `paywall_off`,
/// `suspended`, …) must never break older SDKs again.
public enum FeatureReason: String, Codable, Sendable {
    case userOverride = "user_override"
    case plan
    case `default`
    case `static`
    case paywallNoPlan = "paywall_no_plan"
    case paywallOff = "paywall_off"
    case suspended
    /// Any reason value this SDK build doesn't recognize (newer backend).
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeatureReason(rawValue: raw) ?? .unknown
    }
}

/// Upgrade affordance derived from reason+requiredPlan. nil when feature is available
/// or when reason is not plan-driven.
public struct UpgradeHint: Sendable, Equatable {
    public let requiredPlan: String
    public let currentStatus: FeatureStatus
    public init(requiredPlan: String, currentStatus: FeatureStatus) {
        self.requiredPlan = requiredPlan
        self.currentStatus = currentStatus
    }
}

/// Wire shape of /resolve per-feature entry. Forward-compatible: ignores unknown fields,
/// reason/requiredPlan/upgradeCta are optional so older responses still decode.
struct FeatureStateWire: Decodable {
    let status: String
    let reason: FeatureReason?
    let requiredPlan: String?
    /// Human display name for requiredPlan (product name from the dashboard).
    /// requiredPlan itself is the canonical machine key — never render it raw.
    let requiredPlanLabel: String?
    /// Backend signals the developer enabled "tap the hint to upgrade" for
    /// this feature — the SDK may open the upgrade flow on tap.
    let upgradeCta: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case reason
        case requiredPlan = "required_plan"
        case requiredPlanLabel = "required_plan_label"
        case upgradeCta = "upgrade_cta"
    }
}

