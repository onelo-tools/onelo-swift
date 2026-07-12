import Foundation

/// `URLSessionTaskDelegate` that records HTTP requests as breadcrumbs.
///
/// We deliberately do NOT swizzle global `URLSession` methods. Swizzling:
///   1. Adds App Store review risk.
///   2. Has known data-race issues in 2025+ (see Sentry's swizzling notes).
///   3. Surprises devs who expect their custom URLSession config to be
///      independent.
///
/// Two opt-in paths instead:
///
///   - `OneloMonitor.urlSession()` — returns a configured URLSession that
///     records breadcrumbs automatically. Use this for app-wide networking.
///   - `OneloMonitor.attach(to: existing URLSession)` — not yet implemented;
///     would require either swizzling or session config replacement.
///
/// All recorded URLs and headers are scrubbed via `MonitorScrubber` before
/// landing in the breadcrumb buffer.
final class MonitorNetworkObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let breadcrumbs: MonitorBreadcrumbBuffer

    init(breadcrumbs: MonitorBreadcrumbBuffer) {
        self.breadcrumbs = breadcrumbs
    }

    // Captures DNS / connect / TLS / request / response / total durations
    // from URLSessionTaskMetrics. Apple gives us this for free.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let req = task.originalRequest
        let response = task.response as? HTTPURLResponse
        let durationMs = Int(metrics.taskInterval.duration * 1000)

        let crumb = MonitorBreadcrumb.http(
            method: req?.httpMethod ?? "GET",
            url: req?.url,
            status: response?.statusCode,
            durationMs: durationMs,
            headers: req?.allHTTPHeaderFields
        )
        breadcrumbs.add(crumb)
    }
}

/// Vended URLSession factory.
enum MonitorURLSessionFactory {
    /// Build a new URLSession that automatically records HTTP breadcrumbs
    /// into the supplied buffer. Use the returned session for any traffic
    /// you want auto-traced.
    static func makeSession(breadcrumbs: MonitorBreadcrumbBuffer) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let observer = MonitorNetworkObserver(breadcrumbs: breadcrumbs)
        let session = URLSession(configuration: config, delegate: observer, delegateQueue: nil)
        return session
    }
}
