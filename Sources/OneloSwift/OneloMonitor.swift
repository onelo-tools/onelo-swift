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

    public func event(_ featureName: String, options: MonitorEventOptions) {
        lock.lock()
        buffer.append(BufferedEvent(
            featureName: featureName,
            ok: options.ok,
            durationMs: options.durationMs,
            error: options.error
        ))
        lock.unlock()
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
