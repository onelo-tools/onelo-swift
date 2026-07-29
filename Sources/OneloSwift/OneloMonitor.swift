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
        case let v as Int64:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Float:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [String]:
            try container.encode(v)
        case let v as Date:
            // ISO-8601 keeps the value human-readable in the dashboard.
            try container.encode(ISO8601DateFormatter().string(from: v))
        case let v as UUID:
            try container.encode(v.uuidString)
        case let v as URL:
            try container.encode(v.absoluteString)
        case let v as [String: Any]:
            let dict = Dictionary(uniqueKeysWithValues: v.map { ($0.key, AnyEncodable(value: $0.value)) })
            try container.encode(dict)
        case let v as [Any]:
            try container.encode(v.map { AnyEncodable(value: $0) })
        default:
            // Last resort: stringify via `String(describing:)` so the value
            // survives in the dashboard instead of silently turning into null.
            // This catches custom enums, NSNumber subclasses, Decimal, etc.
            if let v = value {
                try container.encode(String(describing: v))
            } else {
                try container.encodeNil()
            }
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

/// Onelo monitoring SDK — captures errors, performance, and contextual
/// breadcrumbs from the host app and forwards them to the Onelo backend.
///
/// Thread model: a single serial `DispatchQueue` (.utility) for buffer
/// mutation + flush. Breadcrumb / flag buffers have their own `os_unfair_lock`
/// internally so callers from any context (UI, background task, completion
/// handler) can safely add data.
///
/// All event data passes through `MonitorScrubber` *before* it leaves the
/// device — secrets in URLs, headers, and error strings are redacted.
public class OneloMonitor {
    private let publishableKey: String
    private let apiUrl: String

    // Hot-path serial queue. Used for buffer mutation and flush dispatch.
    // Marked `.utility` because monitoring must never preempt UI work.
    private let queue = DispatchQueue(label: "com.onelo.monitor", qos: .utility)
    private var buffer: [BufferedEvent] = []
    private let maxBufferSize = 200

    // Summary buffer for `_trackFeatureCall` — every `feature("name")`
    // lookup goes through that path, and on a busy app that's hundreds
    // of identical ok=true events per minute, each consuming a row in
    // `monitor_events` server-side. We aggregate them per feature name
    // and emit a single BufferedEvent at flush time tagged
    // `source = "feature_call_summary"` with `meta.calls = N`. The
    // backend interprets that as N events for the aggregate roll-up
    // while only inserting one event row — same LaunchDarkly summary
    // events pattern (audit 2026-05-20).
    //
    // Errors / explicit `event()` calls / `track()` durations are NOT
    // aggregated — they still go through the regular per-event buffer
    // because each carries unique data (error text, duration, meta).
    private var summaryBuffer: [String: Int] = [:]

    // Dedicated URLSession with a tight timeout. Monitoring must never hold
    // network resources hostage if the API is slow / offline. Default 5s for
    // a single request; semaphore-blocked crash-path uses its own ceiling.
    //
    // Internal so tests can inject a mock session that captures requests.
    internal lazy var transport: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // Security headers — must match what `validate_sdk_request_security` on the
    // backend expects, otherwise live mobile/desktop requests get 403
    // `invalid_bundle_id`. `X-Bundle-Id` is captured eagerly at init so it is
    // always available on the crash path. The attest bearer + codesign
    // fingerprint are read from the SHARED `_OneloSecurityContext` (produced by
    // OneloAuth) at request-build time — this transport holds the same context
    // instance as every other, so there is nothing to mirror in: whatever the
    // producer wrote is already visible here.
    private let bundleId: String = MonitorAppContext.bundleId
    /// Shared source of truth for the attest bearer + codesign fingerprint —
    /// the SAME instance the other transports read (see `_OneloSecurityContext`).
    private let securityContext: _OneloSecurityContext

    private var flushTimer: Timer?

    /// Persistent install identifier — survives app launches, resets on
    /// reinstall. Used as `sessionId` so dashboard can group events per
    /// install instead of per launch.
    private let sessionId: String
    private var currentUserId: String? = nil

    // Auxiliary buffers — see their respective files for design notes.
    private let breadcrumbs = MonitorBreadcrumbBuffer(capacity: 100)
    private let flagBuffer = MonitorFeatureFlagBuffer(capacity: 100)
    private let deviceContext = MonitorDeviceContextProvider()
    private var crashCapture: MonitorCrashCapture?

    /// Optional environment tag ("production" / "staging" / "dev" / custom).
    /// Auto-attached to every event meta as `environment` so the dashboard can
    /// facet by it. Pass via `Onelo(environment:)`.
    private let environment: String?

    public init(publishableKey: String, apiUrl: String, environment: String? = nil, securityContext: _OneloSecurityContext) {
        self.publishableKey = publishableKey
        self.apiUrl = apiUrl
        self.environment = environment
        self.securityContext = securityContext
        self.sessionId = MonitorInstallID.get()

        flushTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
        _registerGlobalHandlers()
    }

    // MARK: - Internal: security header wiring
    //
    // Apply the same security headers the rest of the SDK uses
    // (`_OneloHTTPClient.applySecurityHeaders`). The attest bearer + codesign
    // fingerprint come from the SHARED `securityContext` — no setter to call,
    // no value to mirror: whatever OneloAuth (the producer) wrote is already
    // visible here. Without these tokens, live iOS apps are rejected with HTTP
    // 403 by the backend (`validate_sdk_request_security`); macOS apps fall back
    // to bundle ID + codesign fingerprint. Any new header added to the
    // `_OneloHTTPClient` helper should be added here too.
    private func applySecurityHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("onelo-swift/\(MonitorAppContext.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        if !bundleId.isEmpty && bundleId != "unknown" {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        if let token = securityContext.attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
        if let fp = securityContext.codesignFingerprint {
            request.setValue(fp, forHTTPHeaderField: "X-Codesign-Fingerprint")
        }
    }

    // MARK: - Public API: identification

    /// Sets the current user ID attached to all subsequent monitor events.
    /// Call after login/logout if not using Onelo Auth.
    public func setUserId(_ userId: String?) {
        queue.async { [weak self] in
            self?.currentUserId = userId
        }
    }

    /// Test-only synchronous accessor for the user id mirrored from
    /// `OneloAuth`. Drains the serial monitor queue first so any pending
    /// `setUserId` writes are visible. Internal — exposed via
    /// `@testable import OneloSwift`.
    internal func _currentUserIdForTesting() -> String? {
        var result: String?
        queue.sync { result = self.currentUserId }
        return result
    }

    // MARK: - Public API: events

    public func event(_ featureName: String, options: MonitorEventOptions) {
        _push(
            featureName: featureName,
            ok: options.ok,
            durationMs: options.durationMs,
            error: options.error,
            source: "event",
            meta: options.meta
        )
    }

    /// Internal hook — used by `OneloFeatures` on every lookup of a name.
    /// High-volume path: every `feature("name")` evaluation in the host app
    /// hits this. To keep server-side write amplification sane, calls land
    /// in a per-feature counter and only emit one summary event at flush
    /// time. Server-side aggregation gets the full N via `meta.calls`,
    /// only one row lands in `monitor_events`.
    public func _trackFeatureCall(_ featureName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.summaryBuffer[featureName, default: 0] += 1
        }
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
            _pushError(featureName: featureName, durationMs: ms, error: error, source: "track", meta: meta)
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
            _pushError(featureName: featureName, durationMs: ms, error: error, source: "track", meta: meta)
            throw error
        }
    }

    /// Manually capture an error you've already caught. Attaches the current
    /// stack trace (live capture of `Thread.callStackReturnAddresses`),
    /// breadcrumbs, and flag state.
    public func capture(_ error: Error, featureName: String = "manual", meta: [String: Any]? = nil) {
        _pushError(featureName: featureName, durationMs: nil, error: error, source: "event", meta: meta)
    }

    // MARK: - Public API: breadcrumbs

    /// Append a breadcrumb. The next captured error will include up to 100
    /// most-recent breadcrumbs so devs can see what happened before failure.
    public func breadcrumb(_ crumb: MonitorBreadcrumb) {
        breadcrumbs.add(crumb)
    }

    /// Convenience: log a free-form info breadcrumb.
    public func breadcrumb(info message: String) {
        breadcrumbs.add(.info(message))
    }

    /// Convenience: log a navigation breadcrumb (typically called from a
    /// SwiftUI `.onAppear` or UIKit `viewDidAppear`).
    public func breadcrumb(navigationTo view: String) {
        breadcrumbs.add(.navigation(to: view))
    }

    // MARK: - Public API: feature flags

    /// Record a feature-flag evaluation. Wired automatically by
    /// `OneloFeatures.feature(_:)`; devs rarely call this directly.
    public func recordFlag(_ key: String, value: String) {
        flagBuffer.record(key, value: value)
    }

    // MARK: - Public API: networking

    /// A `URLSession` that automatically captures HTTP requests as
    /// breadcrumbs. Use this for any traffic you want auto-traced.
    /// Sensitive headers (`Authorization`, `Cookie`, etc.) and query params
    /// (`token`, `key`, `secret`, etc.) are scrubbed before storage.
    public func urlSession() -> URLSession {
        MonitorURLSessionFactory.makeSession(breadcrumbs: breadcrumbs)
    }

    // MARK: - Internal: push events

    private func _push(featureName: String, ok: Bool, durationMs: Int?, error: String?, source: String, meta: [String: Any]? = nil) {
        let scrubbedError = MonitorScrubber.scrubText(error)
        let mergedMeta = enrichMeta(meta, includeContext: !ok || source == "global_error")
        let scrubbedMeta = MonitorScrubber.scrubMeta(mergedMeta)

        // Crash path must run synchronously: process may terminate before any
        // async work can complete. For normal events we keep the async serial
        // queue for performance.
        let isCrashPath = source == "global_error"

        let work: () -> Void = { [weak self] in
            guard let self else { return }
            if self.buffer.count >= self.maxBufferSize {
                self.buffer.removeFirst()
            }
            let encodableMeta: [String: AnyEncodable]? = scrubbedMeta.map { dict in
                Dictionary(uniqueKeysWithValues: dict.map { ($0.key, AnyEncodable(value: $0.value)) })
            }
            self.buffer.append(BufferedEvent(
                featureName: featureName,
                ok: ok,
                durationMs: durationMs,
                error: scrubbedError,
                source: source,
                platform: "swift",
                sessionId: self.sessionId,
                userId: self.currentUserId,
                meta: encodableMeta
            ))
            if !ok && !isCrashPath {
                // Non-crash error — schedule async flush (caller's thread continues).
                self.flush()
            }
        }

        if isCrashPath {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    /// Specialised push for thrown errors — captures stack trace, breadcrumbs,
    /// and flag state and packs them into the meta payload.
    private func _pushError(featureName: String, durationMs: Int?, error: Error, source: String, meta: [String: Any]?) {
        let frames = MonitorBacktrace.capture(skip: 3)
        var enriched: [String: Any] = meta ?? [:]
        enriched["stack"] = encodeFrames(frames)
        enriched["errorType"] = String(describing: type(of: error))

        // Breadcrumbs and flags are heavy — only attach to error events,
        // never to success path (would bloat the 16KB meta limit).
        let crumbs = breadcrumbs.snapshot()
        if !crumbs.isEmpty {
            enriched["breadcrumbs"] = encodeBreadcrumbs(crumbs)
        }
        let flags = flagBuffer.snapshot()
        if !flags.isEmpty {
            enriched["flags"] = encodeFlags(flags)
        }

        _push(
            featureName: featureName,
            ok: false,
            durationMs: durationMs,
            error: error.localizedDescription,
            source: source,
            meta: enriched
        )
    }

    /// Adds always-on context (app/sdk version, device info) to event meta.
    /// Heavy fields (breadcrumbs, flags, stack) are added separately by
    /// `_pushError` only on failure paths.
    private func enrichMeta(_ meta: [String: Any]?, includeContext: Bool) -> [String: Any] {
        var out: [String: Any] = meta ?? [:]
        out["sdk"] = [
            "name": MonitorAppContext.sdkName,
            "version": MonitorAppContext.sdkVersion,
        ]
        out["app"] = [
            "version": MonitorAppContext.appVersion,
            "build": MonitorAppContext.appBuild,
            "bundleId": MonitorAppContext.bundleId,
        ]
        if let environment, out["environment"] == nil {
            out["environment"] = environment
        }
        // Lightweight device fields (model/os/locale/timezone) on every event —
        // cached at init, no syscalls after the first call. Heavy fields
        // (memory, lowPower, connection) only on the includeContext path below.
        let stat = deviceContext.staticSnapshot
        out["device"] = [
            "model": stat.model,
            "os": stat.os,
            "locale": stat.locale,
            "timezone": stat.timezone,
        ] as [String: Any]
        if includeContext {
            // Device snapshot is moderately expensive (utsname, ProcessInfo).
            // Only attach to errors / global crashes — success events stay light.
            let dev = deviceContext.snapshot()
            out["device"] = [
                "model": dev.model,
                "os": dev.os,
                "locale": dev.locale,
                "timezone": dev.timezone,
                "memoryMB": dev.memoryMB,
                "lowPowerMode": dev.lowPowerMode,
                "connection": dev.connection,
            ] as [String: Any]
        }
        return out
    }

    // MARK: - Encoding helpers (Stack/Breadcrumbs/Flags into JSON-shape dicts)

    private func encodeFrames(_ frames: [MonitorStackFrame]) -> [[String: Any]] {
        frames.map { f in
            var d: [String: Any] = ["address": f.address]
            if let s = f.symbol { d["symbol"] = s }
            if let m = f.module { d["module"] = m }
            if let o = f.offset { d["offset"] = o }
            return d
        }
    }

    private func encodeBreadcrumbs(_ crumbs: [MonitorBreadcrumb]) -> [[String: Any]] {
        crumbs.map { c in
            var d: [String: Any] = [
                "category": c.category.rawValue,
                "message": c.message,
                "ts": c.timestamp,
            ]
            if let data = c.data, !data.isEmpty {
                d["data"] = data
            }
            return d
        }
    }

    private func encodeFlags(_ flags: [MonitorFlagSnapshot]) -> [[String: Any]] {
        flags.map { ["key": $0.key, "value": $0.value] }
    }

    // MARK: - Crash handlers

    private func _registerGlobalHandlers() {
        let cap = MonitorCrashCapture { [weak self] message, frames, data in
            guard let self else { return }
            // Convert stack frames + crash metadata into a meta dict; reuse
            // the same enrichment path so app/sdk/device context is present.
            var meta: [String: Any] = [
                "stack": self.encodeFrames(frames),
            ]
            for (k, v) in data { meta[k] = v }

            // Attach last breadcrumbs + flag state — context for triage.
            let crumbs = self.breadcrumbs.snapshot()
            if !crumbs.isEmpty { meta["breadcrumbs"] = self.encodeBreadcrumbs(crumbs) }
            let flags = self.flagBuffer.snapshot()
            if !flags.isEmpty { meta["flags"] = self.encodeFlags(flags) }

            // _push with source="global_error" runs synchronously (queue.sync).
            self._push(
                featureName: "unhandled",
                ok: false,
                durationMs: nil,
                error: message,
                source: "global_error",
                meta: meta
            )
            // Block up to 2s waiting for network — best chance of payload
            // arriving before process terminates. Process may still die
            // mid-request; disk-persisted queue is the proper v2 fix.
            self._flushSync()
        }
        cap.install()
        self.crashCapture = cap
    }

    // MARK: - Transport

    /// Blocking flush: drains the buffer on the caller's thread and waits up to
    /// `timeout` seconds for the HTTP send to complete. Use this before a
    /// short-lived process exits (CLI / XPC service / script / unit test): the
    /// no-arg `flush()` is fire-and-forget and can return before the POST lands,
    /// losing the batch if the process terminates right after. Mirrors the
    /// Python SDK's `flush(timeout=…)`.
    public func flush(timeout: TimeInterval) {
        _flushSync(timeout: timeout)
    }

    public func flush() {
        queue.async { [weak self] in
            guard let self else { return }
            var events = self.buffer
            self.buffer.removeAll()
            // Drain summary counters into the outgoing batch as one
            // BufferedEvent per feature. After flush the counters reset
            // to zero — next window starts fresh. If the network send
            // fails we lose the aggregated count (no retry queue today,
            // same fate as the rest of the buffer).
            for (featureName, count) in self.summaryBuffer where count > 0 {
                events.append(BufferedEvent(
                    featureName: featureName,
                    ok: true,
                    durationMs: nil,
                    error: nil,
                    source: "feature_call_summary",
                    platform: "swift",
                    sessionId: self.sessionId,
                    userId: self.currentUserId,
                    meta: ["calls": AnyEncodable(value: count)]
                ))
            }
            self.summaryBuffer.removeAll()
            guard !events.isEmpty else { return }
            self._send(events: events)
        }
    }

    /// Synchronous best-effort flush for crash path. Drains the buffer on the
    /// caller's thread and blocks up to `timeout` waiting for the HTTP response.
    /// Process may still die before semaphore signals — disk-persisted queue
    /// (TODO v2) would eliminate that residual loss. For now this maximises
    /// the chance of crash payloads arriving before terminate.
    private func _flushSync(timeout: TimeInterval = 2.0) {
        var events: [BufferedEvent] = []
        queue.sync {
            events = self.buffer
            self.buffer.removeAll()
            // Drain feature_call summary counters too — crash should not
            // discard accumulated call counts. Same shape as flush().
            for (featureName, count) in self.summaryBuffer where count > 0 {
                events.append(BufferedEvent(
                    featureName: featureName,
                    ok: true,
                    durationMs: nil,
                    error: nil,
                    source: "feature_call_summary",
                    platform: "swift",
                    sessionId: self.sessionId,
                    userId: self.currentUserId,
                    meta: ["calls": AnyEncodable(value: count)]
                ))
            }
            self.summaryBuffer.removeAll()
        }
        guard !events.isEmpty else { return }

        struct Payload: Encodable {
            let publishableKey: String
            let events: [BufferedEvent]
        }

        guard let url = URL(string: "\(apiUrl)/api/sdk/monitor/events/batch"),
              let body = try? JSONEncoder().encode(Payload(publishableKey: publishableKey, events: events)) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySecurityHeaders(to: &request)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        transport.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func _send(events: [BufferedEvent]) {
        struct Payload: Encodable {
            let publishableKey: String
            let events: [BufferedEvent]
        }

        guard let url = URL(string: "\(apiUrl)/api/sdk/monitor/events/batch"),
              let body = try? JSONEncoder().encode(Payload(publishableKey: publishableKey, events: events)) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySecurityHeaders(to: &request)
        request.httpBody = body

        transport.dataTask(with: request) { _, _, _ in
            // Silently drop — monitoring must never crash the app.
            // Future: persist to disk + retry on next launch (BGTaskScheduler).
        }.resume()
    }

    public func destroy() {
        flushTimer?.invalidate()
        flushTimer = nil
        // Tear down crash capture so MetricKit subscriber is unsubscribed and
        // any prior NSException handler is restored. Otherwise a multi-instance
        // host (rare but legal) leaks observers across init/deinit cycles.
        crashCapture?.uninstall()
        crashCapture = nil
        // Best-effort async flush on teardown (kept non-blocking so deinit never
        // stalls). A short-lived process that must NOT lose the final batch
        // should call the blocking `flush(timeout:)` before exiting — that's the
        // explicit delivery-before-return guarantee (parity with Python's
        // flush(timeout=)). Making destroy() itself block risked a multi-second
        // deinit stall when the network is unreachable.
        flush()
    }

    deinit {
        destroy()
    }
}
