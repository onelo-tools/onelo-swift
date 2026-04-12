import Foundation

public final class OneloFeatures {
    private let client: _OneloHTTPClient
    var _cache: [String: FeatureStatus] = [:]

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    func _load() async {
        do {
            var body: [String: Any] = ["publishableKey": client.publishableKey]
            if let plan = client.userPlan { body["userPlan"] = plan }
            let data = try await client.post(path: "/api/sdk/features/resolve", body: body)
            if let features = data["features"] as? [String: [String: Any]] {
                _cache = features.compactMapValues { state in
                    guard let statusStr = state["status"] as? String else { return nil }
                    return FeatureStatus(rawValue: statusStr)
                }
            }
        } catch {
            // Network error — keep existing cache
        }
    }

    func _ping(names: [String]) async {
        guard !names.isEmpty else { return }
        do {
            _ = try await client.post(
                path: "/api/sdk/features/batch-ping",
                body: ["publishableKey": client.publishableKey, "features": names]
            )
        } catch {
            // ping is best-effort
        }
    }

    public func isEnabled(_ name: String) -> Bool {
        _cache[name] == .enabled
    }

    public func status(_ name: String) -> FeatureStatus {
        _cache[name] ?? .hidden
    }
}
