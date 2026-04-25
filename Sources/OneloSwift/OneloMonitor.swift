import Foundation

public struct MonitorEventOptions {
    public let ok: Bool
    public let durationMs: Int?
    public let error: String?
    public let meta: [String: Any]?

    public init(ok: Bool, durationMs: Int? = nil, error: String? = nil, meta: [String: Any]? = nil) {
        self.ok = ok
        self.durationMs = durationMs
        self.error = error
        self.meta = meta
    }
}

private struct BufferedEvent: Encodable {
    let featureName: String
    let ok: Bool
    let durationMs: Int?
    let error: String?
    let source: String
    let platform: String
    // meta omitted — [String: Any] is not directly Encodable; skip for V1
}

public class OneloMonitor {
    private let publishableKey: String
    private let apiUrl: String
    private var buffer: [BufferedEvent] = []
    private var flushTimer: Timer?
    private let lock = NSLock()

    public init(publishableKey: String, apiUrl: String) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    private func _push(featureName: String, ok: Bool, durationMs: Int?, error: String?, source: String) {
        lock.lock()
        buffer.append(BufferedEvent(
            featureName: featureName,
            ok: ok,
            durationMs: durationMs,
            error: error,
            source: source,
            platform: "swift"
        ))
        lock.unlock()
    }

    public func event(_ featureName: String, options: MonitorEventOptions) {
        _push(featureName: featureName, ok: options.ok, durationMs: options.durationMs,
              error: options.error, source: "event")
    }

    public func _trackFeatureCall(_ featureName: String) {
        _push(featureName: featureName, ok: true, durationMs: nil, error: nil, source: "feature_call")
    }

    @discardableResult
    public func track<T>(_ featureName: String, _ fn: () throws -> T) rethrows -> T {
        let start = Date()
        do {
            let result = try fn()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: true, durationMs: ms, error: nil, source: "track")
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: false, durationMs: ms, error: error.localizedDescription, source: "track")
            throw error
        }
    }

    @discardableResult
    public func track<T>(_ featureName: String, _ fn: () async throws -> T) async rethrows -> T {
        let start = Date()
        do {
            let result = try await fn()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: true, durationMs: ms, error: nil, source: "track")
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: false, durationMs: ms, error: error.localizedDescription, source: "track")
            throw error
        }
    }

    public func flush() {
        lock.lock()
        let events = buffer
        buffer.removeAll()
        lock.unlock()

        guard !events.isEmpty else { return }

        struct Payload: Encodable {
            let publishableKey: String
            let events: [BufferedEvent]
        }

        guard let url = URL(string: "\(apiUrl)/api/sdk/monitor/events/batch"),
              let body = try? JSONEncoder().encode(Payload(publishableKey: publishableKey, events: events)) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // silently drop — monitoring must never crash the app
        }.resume()
    }

    public func destroy() {
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
    }

    deinit {
        destroy()
    }
}
