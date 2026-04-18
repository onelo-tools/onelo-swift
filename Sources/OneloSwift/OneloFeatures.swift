import Foundation

@MainActor
public final class OneloFeatures {
    private let client: _OneloHTTPClient
    private var cache: [String: FeatureStatus] = [:]
    private var discoveredNames: Set<String> = []
    private var configVersion: Int = 0
    private var pollTask: Task<Void, Never>?

    static let pollInterval: TimeInterval = 60

    init(client: _OneloHTTPClient) {
        self.client = client
    }

    // MARK: - Public API

    /// Returns the feature state for the given name.
    /// Registers the name for auto-discovery on next batch-ping.
    public func feature(_ name: String) -> FeatureState {
        discoveredNames.insert(name)
        let status = cache[name] ?? .hidden
        return FeatureState(name: name, status: status)
    }

    // MARK: - Internal

    func _load(userId: String?) async {
        await _batchPing()
        await _resolve(userId: userId)
        _startPolling(userId: userId)
    }

    func _stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func _batchPing() async {
        let names = Array(discoveredNames)
        guard !names.isEmpty else { return }
        do {
            _ = try await client.post(
                path: "/api/sdk/features/batch-ping",
                body: ["publishableKey": client.publishableKey, "features": names]
            )
        } catch {
            // best-effort
        }
    }

    private func _resolve(userId: String?) async {
        do {
            var body: [String: Any] = ["publishableKey": client.publishableKey]
            if let uid = userId { body["userId"] = uid }
            let data = try await client.post(path: "/api/sdk/features/resolve", body: body)
            if let features = data["features"] as? [String: [String: Any]] {
                cache = features.compactMapValues { state in
                    guard let s = state["status"] as? String else { return nil }
                    return FeatureStatus(rawValue: s)
                }
            }
            if let v = data["config_version"] as? Int { configVersion = v }
        } catch {
            // keep existing cache
        }
    }

    private func _poll(userId: String?) async {
        do {
            var components = URLComponents(url: client.baseURL.appendingPathComponent("/api/sdk/features/poll"), resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "key", value: client.publishableKey),
                URLQueryItem(name: "version", value: String(configVersion)),
            ]
            if let uid = userId { queryItems.append(URLQueryItem(name: "userId", value: uid)) }
            components.queryItems = queryItems

            guard let url = components.url else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let changed = json["changed"] as? Bool, !changed { return }

            if let features = json["features"] as? [String: [String: Any]] {
                cache = features.compactMapValues { state in
                    guard let s = state["status"] as? String else { return nil }
                    return FeatureStatus(rawValue: s)
                }
            }
            if let v = json["config_version"] as? Int { configVersion = v }

            if let discoveryRequested = json["discovery_requested"] as? Bool, discoveryRequested {
                await _batchPing()
            }
        } catch {
            // ignore network errors — will retry on next poll
        }
    }

    private func _startPolling(userId: String?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(OneloFeatures.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?._poll(userId: userId)
            }
        }
    }
}
