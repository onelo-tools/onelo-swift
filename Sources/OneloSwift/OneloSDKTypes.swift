import Foundation

// MARK: - Feature types

public enum FeatureStatus: String, Sendable {
    case enabled
    case disabled
    case greyed
    case hidden
    case upsell
}

public struct FeatureState: Sendable {
    public let name: String
    public let status: FeatureStatus

    public var isEnabled: Bool { status == .enabled }
    public var isDisabled: Bool { status == .disabled }
    public var isVisible: Bool { status != .hidden }
    public var isGreyed: Bool { status == .greyed }
    public var isUpsell: Bool { status == .upsell }
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
