import Foundation

private let planTiers: [String: Int] = [
    "free": 0,
    "pro": 1,
    "business": 2,
    "enterprise": 3,
]

public final class OneloPaywall {
    private let client: _OneloHTTPClient

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    public func check(_ requiredPlan: String) -> Bool {
        let userTier = planTiers[client.userPlan ?? "free"] ?? 0
        let requiredTier = planTiers[requiredPlan] ?? 0
        return userTier >= requiredTier
    }
}
