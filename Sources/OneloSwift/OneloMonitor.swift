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

private struct AnyEncodable: Encodable {
    let value: Any?
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [String: Any]:
            let dict = Dictionary(uniqueKeysWithValues: v.map { ($0.key, AnyEncodable(value: $0.value)) })
            try container.encode(dict)
        case let v as [Any]:
            try container.encode(v.map { AnyEncodable(value: $0) })
        default:
            try container.encodeNil()
        }
    }
}

private struct BufferedEvent: Encodable {
    let featureName: String
    let ok: Bool
    let durationMs: Int?
    let error: String?
    let source: String
    let platform: String
    let sessionId: String
    let userId: String?
    let meta: [String: AnyEncodable]?
}

public class OneloMonitor {
    private let publishableKey: String
    private let apiUrl: String
    private var buffer: [BufferedEvent] = []
    private var flushTimer: Timer?
    private let lock = NSLock()
    private let sessionId: String = UUID().uuidString
    private var currentUserId: String? = nil

    public init(publishableKey: String, apiUrl: String) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
        _registerGlobalHandlers()
    }

    /// Sets the current user ID attached to all subsequent monitor events. Call after login/logout if not using Onelo Auth.
    public func setUserId(_ userId: String?) {
        currentUserId = userId
    }

    private static weak var _shared: OneloMonitor? = nil

    private func _registerGlobalHandlers() {
        OneloMonitor._shared = self
        NSSetUncaughtExceptionHandler { exception in
            OneloMonitor._shared?._push(
                featureName: "unhandled",
                ok: false,
                durationMs: nil,
                error: exception.reason ?? exception.name.rawValue,
                source: "global_error"
            )
            OneloMonitor._shared?.flush()
        }
    }

    private let maxBufferSize = 200

    private func _push(featureName: String, ok: Bool, durationMs: Int?, error: String?, source: String, meta: [String: Any]? = nil) {
        lock.lock()
        if buffer.count >= maxBufferSize {
            buffer.removeFirst()
        }
        let encodableMeta: [String: AnyEncodable]? = meta.map { dict in
            Dictionary(uniqueKeysWithValues: dict.map { ($0.key, AnyEncodable(value: $0.value)) })
        }
        buffer.append(BufferedEvent(
            featureName: featureName,
            ok: ok,
            durationMs: durationMs,
            error: error,
            source: source,
            platform: "swift",
            sessionId: sessionId,
            userId: currentUserId,
            meta: encodableMeta
        ))
        lock.unlock()
        if !ok || source == "global_error" {
            flush()
        }
    }

    public func event(_ featureName: String, options: MonitorEventOptions) {
        _push(featureName: featureName, ok: options.ok, durationMs: options.durationMs,
              error: options.error, source: "event", meta: options.meta)
    }

    public func _trackFeatureCall(_ featureName: String) {
        _push(featureName: featureName, ok: true, durationMs: nil, error: nil, source: "feature_call")
    }

    @discardableResult
    public func track<T>(_ featureName: String, meta: [String: Any]? = nil, _ fn: () throws -> T) rethrows -> T {
        let start = Date()
        do {
            let result = try fn()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: true, durationMs: ms, error: nil, source: "track", meta: meta)
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: false, durationMs: ms, error: error.localizedDescription, source: "track", meta: meta)
            throw error
        }
    }

    @discardableResult
    public func track<T>(_ featureName: String, meta: [String: Any]? = nil, _ fn: () async throws -> T) async rethrows -> T {
        let start = Date()
        do {
            let result = try await fn()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: true, durationMs: ms, error: nil, source: "track", meta: meta)
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            _push(featureName: featureName, ok: false, durationMs: ms, error: error.localizedDescription, source: "track", meta: meta)
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
