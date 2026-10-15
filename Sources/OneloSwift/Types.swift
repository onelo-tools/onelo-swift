import Foundation

public enum OneloSDK {
    public static let sdkVersion = "3.104.0"
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
    /// **May this person see the app?** Computed by Onelo, never here.
    ///
    /// The rule — no paywall, or a live grant — used to be re-derived in every
    /// SDK from two raw settings. Three languages, three copies, and each was
    /// found wrong on a different day. The server now ships the conclusion.
    ///
    /// `nil` means the backend did not send it (an older server), NOT "no".
    /// Only then may the legacy derivation stand in — see `_recomputeAllowedIn`.
    public let allowedIn: Bool?
    /// Has this user proved their address receives mail (Email Verification,
    /// #819)? From the backend's `email_verified`; `nil` when an older backend
    /// did not send it. OAuth, Magic Link and an e-mailed password reset count
    /// as verified.
    public let emailVerified: Bool?
    /// Why `allowedIn` is `false`, when the server named a reason the app may
    /// branch on. Today only `"email_unverified"`: the parent App requires Email
    /// Verification and this user has not opened the link yet. `nil` when
    /// allowed in or when the reason is the paywall. Tolerate unknown values.
    public let accessReason: String?

    public init(
        id: String,
        email: String?,
        role: UserRole,
        tenantId: String?,
        entitlement: OneloEntitlement = .none,
        allowedIn: Bool? = nil,
        emailVerified: Bool? = nil,
        accessReason: String? = nil
    ) {
        self.id = id
        self.email = email
        self.role = role
        self.tenantId = tenantId
        self.entitlement = entitlement
        self.allowedIn = allowedIn
        self.emailVerified = emailVerified
        self.accessReason = accessReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, role, tenantId, entitlement
        case allowedIn = "allowed_in"
        case emailVerified = "email_verified"
        case accessReason = "access_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try? c.decode(String.self, forKey: .email)
        role = (try? c.decode(UserRole.self, forKey: .role)) ?? .member
        tenantId = try? c.decode(String.self, forKey: .tenantId)
        entitlement = (try? c.decode(OneloEntitlement.self, forKey: .entitlement)) ?? .none
        // Absent stays nil — "the server did not say" and "the server said no"
        // are different answers, and only the first may fall back.
        allowedIn = try? c.decode(Bool.self, forKey: .allowedIn)
        emailVerified = try? c.decode(Bool.self, forKey: .emailVerified)
        accessReason = try? c.decode(String.self, forKey: .accessReason)
    }

    /// A user from a backend `user` payload (sign-in, sign-up, refresh,
    /// hosted-callback). The ONE place the wire becomes an `OneloUser`, so no
    /// path can drop the server's access answer (`allowed_in`, `email_verified`,
    /// `access_reason`) — the custom-UI sign-in and sign-up paths did (#819
    /// review), which let an unverified user into a free app through the
    /// local fallback. Absent fields stay nil.
    static func fromWire(_ userData: [String: Any], id: String) -> OneloUser {
        OneloUser(
            id: id,
            email: userData["email"] as? String,
            role: .member,
            tenantId: nil,
            entitlement: OneloEntitlement(rawValue: (userData["entitlement"] as? String) ?? "") ?? .none,
            allowedIn: userData["allowed_in"] as? Bool,
            emailVerified: userData["email_verified"] as? Bool,
            accessReason: userData["access_reason"] as? String
        )
    }

    /// The server's access answer from a `/api/sdk/auth/user` body merged over
    /// this user (#819): `allowedIn`, `emailVerified` and `accessReason` move
    /// together. A field the body does not carry keeps its stored value; when
    /// the body carries `allowed_in`, `accessReason` is taken from the body even
    /// when absent — the answer is complete and an old reason must not outlive it.
    func mergingAccessAnswer(_ json: [String: Any], entitlement: OneloEntitlement) -> OneloUser {
        let answered = json["allowed_in"] is Bool
        return OneloUser(
            id: id, email: email, role: role, tenantId: tenantId, entitlement: entitlement,
            allowedIn: answered ? json["allowed_in"] as? Bool : allowedIn,
            emailVerified: (json["email_verified"] as? Bool) ?? emailVerified,
            accessReason: answered ? json["access_reason"] as? String : accessReason
        )
    }
}

/// The result of `OneloAuth.resendVerificationEmail(redirectTo:)` (#819).
public struct OneloVerificationResend: Sendable, Equatable {
    /// A new e-mail went out; the previous link stopped working.
    public let sent: Bool
    /// The address was already verified, so nothing was sent.
    public let emailVerified: Bool
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

/// #818 — whether your own sign-up screen should show the optional Marketing
/// Consent checkbox, and with what text. Set on the parent App in Auth →
/// Sign-up; an App that sells asks at Checkout instead (`asked` false). Show
/// `text` unticked and pass the person's choice to
/// `signUp(email:password:marketingConsent:)`.
public struct OneloSignupMarketingConsent: Decodable, Equatable, Sendable {
    public let asked: Bool
    /// The checkbox label, already filled in. Nil when not asked.
    public let text: String?
    /// The language `text` is in; sent back with the consent.
    public let language: String?

    public static let notAsked = OneloSignupMarketingConsent(asked: false, text: nil, language: nil)

    public init(asked: Bool, text: String?, language: String?) {
        self.asked = asked
        self.text = text
        self.language = language
    }

    enum CodingKeys: String, CodingKey { case asked, text, language }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asked = (try? c.decode(Bool.self, forKey: .asked)) ?? false
        text = try? c.decode(String.self, forKey: .text)
        language = try? c.decode(String.self, forKey: .language)
    }

    /// The device's preferred language as a BCP 47 tag, `en` when unknown.
    static var deviceLanguage: String { Locale.preferredLanguages.first ?? "en" }
}

/// #818 — the waitlist checkboxes your form showed. Only the reserved purposes.
public struct OneloWaitlistConsent: Equatable, Sendable {
    /// Marketing Consent — optional, never pre-ticked.
    public var marketing: Bool?
    /// The waitlist's custom checkbox, when it has one.
    public var custom: Bool?

    public init(marketing: Bool? = nil, custom: Bool? = nil) {
        self.marketing = marketing
        self.custom = custom
    }

    /// The `consent` field of the join body, or nil when nothing was given.
    var wireValue: [String: Bool]? {
        var out: [String: Bool] = [:]
        if let marketing { out["marketing"] = marketing }
        if let custom { out["custom"] = custom }
        return out.isEmpty ? nil : out
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
    /// False when this build runs on an Apple-store platform and the developer
    /// has NOT opted into showing the store in-app. `paywallEnabled` stays TRUE
    /// — the gate exists, it just cannot be satisfied inside the app, because
    /// App Review guideline 3.1.1 requires digital purchases to go through
    /// Apple's own in-app purchase. The buyer purchases on the developer's
    /// website and signs in here.
    ///
    /// Absent on older backends → defaults to `true`, i.e. previous behaviour.
    let inAppStoreAllowed: Bool
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
    /// Branding "Brand color" (`primary_color`); nil when the app has none. SDK-drawn
    /// controls shown before a hosted page loads use it, neutral when nil (#601).
    let primaryColor: String?
    /// Resolved brand tokens (#681): `brand_tokens`, or the shape the two legacy
    /// colours imply on an older backend (`OneloBrandTokens.fromLegacy`).
    let brandTokens: OneloBrandTokens
    /// #818 — the sign-up Marketing Consent question; not asked on an older backend.
    let signupMarketingConsent: OneloSignupMarketingConsent

    enum CodingKeys: String, CodingKey {
        case supabaseUrl = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case tenantId = "tenant_id"
        case allowCustomBranding = "allow_custom_branding"
        case attestRequired = "attest_required"
        case appName = "app_name"
        case appLogoUrl = "app_logo_url"
        case paywallEnabled = "paywall_enabled"
        case inAppStoreAllowed = "in_app_store_allowed"
        case waitlistMode = "waitlist_mode"
        case sdkRedirectUrl = "sdk_redirect_url"
        case storeUrl = "store_url"
        case manageUrl = "manage_url"
        case oauthProviders = "oauth_providers"
        case checkoutBgColor = "checkout_bg_color"
        case primaryColor = "primary_color"
        case brandTokens = "brand_tokens"
        case signupMarketingConsent = "signup_marketing_consent"
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
        // Absent on a backend that predates the Apple in-app-store constraint →
        // true, i.e. behave exactly as before. Never fail decoding over it.
        inAppStoreAllowed = (try? c.decode(Bool.self, forKey: .inAppStoreAllowed)) ?? true
        waitlistMode = (try? c.decode(Bool.self, forKey: .waitlistMode)) ?? false
        sdkRedirectUrl = try? c.decode(String.self, forKey: .sdkRedirectUrl)
        storeUrl = try? c.decode(String.self, forKey: .storeUrl)
        manageUrl = try? c.decode(String.self, forKey: .manageUrl)
        oauthProviders = (try? c.decode([String].self, forKey: .oauthProviders)) ?? []
        checkoutBgColor = try? c.decode(String.self, forKey: .checkoutBgColor)
        primaryColor = try? c.decode(String.self, forKey: .primaryColor)
        let legacy = OneloBrandTokens.fromLegacy(primaryColor: primaryColor, pageBg: checkoutBgColor)
        if let bt = try? c.nestedContainer(keyedBy: OneloBrandTokens.CodingKeys.self, forKey: .brandTokens) {
            brandTokens = OneloBrandTokens.decode(bt, fallback: legacy)
        } else {
            brandTokens = legacy
        }
        signupMarketingConsent = (try? c.decode(OneloSignupMarketingConsent.self, forKey: .signupMarketingConsent))
            ?? .notAsked
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
/// (`.notEntitled`, `.notAuthenticated`) without having to pattern-match on
/// string-bearing `OneloError.serverError`.
public enum OneloFeaturesError: Error, Equatable, Sendable {
    /// No user is signed in (entitlement endpoints are user-scoped —
    /// anonymous callers can't request a module token), or the signed-in
    /// user's access token was refused even after a refresh.
    case notAuthenticated
    /// Backend returned 403 not_entitled. The current user does not have
    /// access to the requested feature slug.
    case notEntitled
    /// Never thrown: Secure Mode is retired and the server no longer answers
    /// with `secure_mode_required`. Kept so existing code compiles.
    @available(*, deprecated, message: "Secure Mode is retired; the server no longer returns this.")
    case secureModeRequired
    /// Never thrown: Secure Mode is retired and the server no longer answers
    /// with `invalid_user_hash`. Kept so existing code compiles.
    @available(*, deprecated, message: "Secure Mode is retired; the server no longer returns this.")
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
    /// The app runs on an Apple platform and the developer has not taken on
    /// App Store compliance themselves, so the in-app store is closed
    /// (App Review guideline 3.1.1 — a purchase of content used inside an
    /// iOS or Mac App Store app has to go through Apple's own in-app
    /// purchase, and Onelo sells on the developer's Stripe).
    ///
    /// Buyers purchase on the developer's website and sign in here. The switch
    /// is Paywall → Store → Access Gate in the Onelo dashboard, on the app
    /// itself (it is per platform, never on a parent).
    case inAppStoreNotAllowed
    /// The session is over: it expired, was replaced (`session_compromised` —
    /// the same refresh token was presented again outside the server's grace
    /// window) or is not recognised. NOT an account action — the user just
    /// signs in again. The SDK has already cleared `currentSession`.
    case sessionEnded
    /// The account was banned. The only refusal that says "suspended";
    /// `isUserRevoked` is set alongside it.
    case userRevoked
    /// The user's plan lapsed and this app has no free tier — route them to
    /// the store / upgrade flow (`OneloAuthView` does). Not a revocation.
    case noActivePlan
    /// Email Verification (#819): at most 3 verification e-mails an hour.
    case verificationRateLimited
    /// Email Verification is Off for this App (Auth → Sign-up on the parent App).
    case emailVerificationOff
    /// The verification link was used, replaced by a newer one, or expired.
    case invalidVerificationToken
    /// The `redirectTo` given for the verification link is not one of the App's
    /// allowed web origins nor `<registered-scheme>://…`.
    case invalidVerifyRedirect

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
        case .inAppStoreNotAllowed:
            return "Plans can't be purchased inside this app. Buyers purchase on the web and sign in here."
        case .sessionEnded: return "Your session ended — please sign in again"
        case .userRevoked: return "This user account has been suspended"
        case .noActivePlan: return "No active subscription — the plan has expired or was cancelled."
        case .verificationRateLimited: return "At most 3 verification emails an hour — try again later"
        case .emailVerificationOff: return "Email verification is off for this app — turn it on in Auth → Sign-up"
        case .invalidVerificationToken:
            return "This verification link is invalid, already used, replaced by a newer one, or expired"
        case .invalidVerifyRedirect:
            return "redirectTo must be one of this app's allowed web origins or <your-scheme>://…"
        }
    }
}

/// Pull Onelo's error code out of a FastAPI error body.
///
/// The backend raises `HTTPException(detail={"error": …, "message": …})`, so the
/// code sits INSIDE `detail` — while a few older endpoints send `detail` as a
/// bare string. Both shapes have to work, and a body with neither must yield
/// nil rather than a guess, so callers keep their generic handling.
func oneloErrorCode(from json: [String: Any]) -> String? {
    if let code = json["error"] as? String { return code }
    if let code = (json["detail"] as? [String: Any])?["error"] as? String { return code }
    if let code = json["detail"] as? String { return code }
    return nil
}

/// What a refused `/api/sdk/auth/refresh` means for the app (#548). The
/// backend answers `{"detail": {"error" | "error_code": …}}`; only a ban is an
/// account action — every other refusal just ends the session.
func refreshRefusalError(status: Int, json: [String: Any]) -> OneloError {
    let detail = json["detail"] as? [String: Any]
    let code = oneloErrorCode(from: json) ?? (detail?["error_code"] as? String)
    switch code {
    case "banned":
        return .userRevoked
    case "no_plan_available":
        return .noActivePlan
    default:
        // Pre-dict backends sent a bare string detail on a 403 account action.
        if status == 403, let legacy = json["detail"] as? String,
           ["account_deleted", "account_suspended", "account_payment_failed"].contains(where: legacy.contains) {
            return .userRevoked
        }
        // session_compromised / session_expired / session_invalid / anything else.
        return .sessionEnded
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

/// What a refused Email Verification call means (#819).
func verificationError(status: Int, json: [String: Any]) -> OneloError {
    let code = oneloErrorCode(from: json)
    if status == 429 || code == "verification_rate_limited" { return .verificationRateLimited }
    if status == 409 || code == "email_verification_off" { return .emailVerificationOff }
    if status == 400 && code == "invalid_verify_redirect_to" { return .invalidVerifyRedirect }
    if status == 400 && code == "invalid_token" { return .invalidVerificationToken }
    if status == 401 { return .notAuthenticated }
    return .serverError("Email verification request failed: HTTP \(status)")
}
