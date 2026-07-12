import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A breadcrumb is a small, structured trail entry — "user navigated to X",
/// "fetch to /api/login returned 401", "feature flag checkout-v2 evaluated
/// to true". Attached to the next captured error so devs can reconstruct
/// what happened before the failure.
public struct MonitorBreadcrumb: Encodable, Sendable {
    public enum Category: String, Encodable, Sendable {
        case navigation = "navigation"
        case http = "http"
        case feature = "feature"
        case lifecycle = "lifecycle"
        case user = "user"
        case info = "info"
        case error = "error"
    }

    public let category: Category
    public let message: String
    public let timestamp: Double  // unix seconds, fractional
    public let data: [String: String]?
}

/// Thread-safe ring buffer of breadcrumbs.
///
/// Sentry default capacity is 100. We use the same — anything smaller (e.g.
/// 10) is too small to reconstruct a non-trivial flow, and 100 still fits
/// comfortably in the 16 KB `meta` payload limit on the backend.
///
/// Locking: we use `os_unfair_lock` for hot-path performance. Compared to
/// `DispatchQueue.sync` it is ~5x faster and avoids context switches.
/// We expose `@unchecked Sendable` because the lock guarantees safety.
final class MonitorBreadcrumbBuffer: @unchecked Sendable {
    let capacity: Int
    private var storage: [MonitorBreadcrumb?]
    private var head = 0
    private var count = 0
    private var lock = os_unfair_lock()

    init(capacity: Int = 100) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Append a breadcrumb. If the buffer is full, the oldest entry is
    /// overwritten — never blocks, never throws.
    func add(_ crumb: MonitorBreadcrumb) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage[head] = crumb
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Snapshot of all current breadcrumbs in chronological order (oldest first).
    func snapshot() -> [MonitorBreadcrumb] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }

    /// Drop everything. Used on `OneloMonitor.destroy()`.
    func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<storage.count { storage[i] = nil }
        head = 0
        count = 0
    }
}

// MARK: - Convenience builders

extension MonitorBreadcrumb {
    /// Convenience for HTTP breadcrumbs. URL and headers are scrubbed
    /// before storage so we never keep a token in memory longer than needed.
    static func http(method: String, url: URL?, status: Int?, durationMs: Int?, headers: [String: String]? = nil) -> MonitorBreadcrumb {
        var data: [String: String] = [:]
        data["method"] = method.uppercased()
        if let scrubbed = MonitorScrubber.scrubURL(url) {
            data["url"] = scrubbed
        }
        if let status { data["status"] = String(status) }
        if let durationMs { data["durationMs"] = String(durationMs) }
        if let scrubbedHeaders = MonitorScrubber.scrubHeaders(headers), !scrubbedHeaders.isEmpty {
            // Flatten — JSON-stringify so it stays in the [String: String] shape.
            // Backend will see this as plain text in the breadcrumb data field.
            if let jsonData = try? JSONSerialization.data(withJSONObject: scrubbedHeaders),
               let json = String(data: jsonData, encoding: .utf8) {
                data["headers"] = json
            }
        }
        let msg = "\(method.uppercased()) \(MonitorScrubber.scrubURL(url) ?? "?")"
        return MonitorBreadcrumb(
            category: .http,
            message: msg,
            timestamp: Date().timeIntervalSince1970,
            data: data
        )
    }

    static func navigation(to view: String) -> MonitorBreadcrumb {
        MonitorBreadcrumb(
            category: .navigation,
            message: view,
            timestamp: Date().timeIntervalSince1970,
            data: nil
        )
    }

    static func feature(_ name: String, value: String) -> MonitorBreadcrumb {
        MonitorBreadcrumb(
            category: .feature,
            message: name,
            timestamp: Date().timeIntervalSince1970,
            data: ["value": value]
        )
    }

    static func info(_ message: String) -> MonitorBreadcrumb {
        MonitorBreadcrumb(
            category: .info,
            message: MonitorScrubber.scrubText(message) ?? message,
            timestamp: Date().timeIntervalSince1970,
            data: nil
        )
    }

    static func lifecycle(_ event: String) -> MonitorBreadcrumb {
        MonitorBreadcrumb(
            category: .lifecycle,
            message: event,
            timestamp: Date().timeIntervalSince1970,
            data: nil
        )
    }
}
