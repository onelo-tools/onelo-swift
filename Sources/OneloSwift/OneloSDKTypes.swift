import Foundation

// MARK: - Feature types

public enum FeatureStatus: String, Sendable {
    case enabled
    case disabled
    case greyed
    case hidden
    case upsell
    case new
    case beta
    case coming_soon
}

public struct FeatureState: Sendable {
    public let name: String
    public let status: FeatureStatus
    public let reason: FeatureReason?
    public let requiredPlan: String?
    /// Human display name for `requiredPlan` (the product's name in the
    /// dashboard). `requiredPlan` is the machine key — render this instead.
    public let requiredPlanLabel: String?
    /// Developer enabled "tap the hint to upgrade" for this feature — UI may
    /// open the upgrade flow (`Onelo.openUpgrade(forPlan:)`) on tap.
    public let upgradeCta: Bool

    public init(
        name: String,
        status: FeatureStatus,
        reason: FeatureReason? = nil,
        requiredPlan: String? = nil,
        requiredPlanLabel: String? = nil,
        upgradeCta: Bool = false
    ) {
        self.name = name
        self.status = status
        self.reason = reason
        self.requiredPlan = requiredPlan
        self.requiredPlanLabel = requiredPlanLabel
        self.upgradeCta = upgradeCta
    }

    /// True only for `.enabled` / `.new` / `.beta` (feature is on AND usable).
    /// ⚠️ Do NOT gate menu/UI visibility with this. It is FALSE for `.greyed`
    /// (locked), `.coming_soon` and `.upsell`, so `if isEnabled { add }` HIDES
    /// those features instead of showing their padlock / badge. Decide visibility
    /// with `isVisible` (false only for `.hidden`); for macOS menus build items
    /// via `menuItem(title:action:)`, which renders every status correctly
    /// (greyed → disabled + 🔒, coming_soon → badge, upsell → "Available in …").
    public var isEnabled: Bool { status == .enabled || status == .new || status == .beta }
    public var isDisabled: Bool { status == .disabled }
    public var isVisible: Bool { status != .hidden }
    public var isGreyed: Bool { status == .greyed }
    public var isUpsell: Bool { status == .upsell }
    public var isNew: Bool { status == .new }
    public var isBeta: Bool { status == .beta }
    public var isComingSoon: Bool { status == .coming_soon }

    /// SwiftUI badge label for promotional statuses. Returns nil for non-badge statuses.
    /// For `upsell` the label carries the unlocking plan when the backend
    /// provided one ("Available in pro") — that's the per-plan gating fallback
    /// ("users on other plans see: upsell") surfacing in the UI.
    public var badgeLabel: String? {
        switch status {
        case .new: return "New"
        case .beta: return "Beta"
        case .coming_soon: return "Coming Soon"
        case .greyed:
            // Greyed = locked. Always render a padlock so the user sees the
            // feature exists but is unavailable — apps must not hide it.
            return "🔒"
        case .upsell:
            // Prefer the human product name; the bare key only as a stopgap
            // for older backends that don't send the label yet.
            if let label = requiredPlanLabel, !label.isEmpty { return "Available in \(label)" }
            if let plan = requiredPlan, !plan.isEmpty { return "Available in \(plan)" }
            return "Upgrade"
        default: return nil
        }
    }

    /// Non-nil when the feature is blocked by plan and the backend specified
    /// which plan unlocks it. Surface this in upgrade-prompt UI.
    public var upgradeHint: UpgradeHint? {
        guard reason == .plan,
              let plan = requiredPlan,
              [.greyed, .hidden, .upsell, .coming_soon].contains(status)
        else { return nil }
        return UpgradeHint(requiredPlan: plan, currentStatus: status)
    }
}

// MARK: - Form types

public struct OneloFormResult: Sendable {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String = "") {
        self.success = success
        self.message = message
    }
}

// MARK: - Waitlist types

public struct OneloWaitlistResult: Sendable {
    public let success: Bool
    public let position: Int?
    public let alreadyJoined: Bool

    public init(success: Bool, position: Int? = nil, alreadyJoined: Bool = false) {
        self.success = success
        self.position = position
        self.alreadyJoined = alreadyJoined
    }
}
