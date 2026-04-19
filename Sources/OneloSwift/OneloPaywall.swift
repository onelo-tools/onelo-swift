import Foundation

private let planTiers: [String: Int] = [
    "free": 0,
    "pro": 1,
    "business": 2,
    "enterprise": 3,
]

public final class OneloPaywall {
    init() {}

    /// Returns true if `userPlan` meets or exceeds `requiredPlan`.
    /// Pass the user's billing plan from your backend or Onelo session.
    public func check(_ requiredPlan: String, userPlan: String = "free") -> Bool {
        let userTier = planTiers[userPlan.lowercased()] ?? 0
        let requiredTier = planTiers[requiredPlan.lowercased()] ?? 0
        return userTier >= requiredTier
    }
}
