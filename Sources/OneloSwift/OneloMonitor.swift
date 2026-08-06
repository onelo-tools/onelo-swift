import Foundation
import os

private let _monitorLog = Logger(subsystem: "com.onelo.sdk", category: "monitor")

// Delivery policy — 1:1 with @onelo/js's monitor transport: ONE attempt per
// flush. A batch the server did not accept goes back in the buffer and rides
// the next 15s tick — the flush timer IS the retry. An in-flight retry loop
// tripled inbound request volume during a backend outage (the worst possible
// moment) and made every "bounded" teardown path aspirational rather than real:
// with one attempt a drain is a single request, so `flush(timeout:)`'s deadline
// is achievable instead of a hope.
private let _maxRetryAfter: TimeInterval = 3600

/// What ONE delivery attempt means for the batch.
///
/// - `.done`    — the server ACCEPTED it. Settled; never send again.
/// - `.requeue` — the server did NOT take it (429, 5xx, network, timeout). Put
///                it back and let the next flush carry it.
/// - `.drop`    — permanently rejected (4xx other than 429: bad key, malformed
///                payload). Re-sending would fail identically forever, so we
///                discard it — but LOUDLY, never silently.
private enum _SendOutcome {
    case done
    case requeue
    case drop
}

/// Classify one URLSession result. Never throws — a `503` must be
/// distinguishable from success, which is exactly what the old
/// `{ _, _, _ in }` completion handler made impossible.
/// Returns the outcome, the 429 `Retry-After` hold-off in seconds, and the HTTP
/// status (0 when there was no response) so a drop can be logged with its cause.
private func _classify(response: URLResponse?, error: Error?) -> (_SendOutcome, TimeInterval, Int) {
    if error != nil { return (.requeue, 0, 0) } // network / DNS / TLS / timeout
    guard let http = response as? HTTPURLResponse else { return (.requeue, 0, 0) }
    let status = http.statusCode
    if (200..<300).contains(status) { return (.done, 0, status) }
    if status == 429 {
        // Rate limited — hammering it now only makes it worse. But the server
        // did NOT accept these events, so they must be re-queued and go out
        // after the hold-off.
        let raw = http.value(forHTTPHeaderField: "Retry-After")
        let seconds = raw.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        guard seconds.isFinite, seconds > 0 else { return (.requeue, 0, status) }
        return (.requeue, min(seconds, _maxRetryAfter), status)
    }
    // 401 bad key / 403 forbidden / 422 malformed — identical every time, so
    // re-queueing would wedge the buffer forever. Drop, but say so.
    if (400..<500).contains(status) { return (.drop, 0, status) }
    return (.requeue, 0, status) // 5xx and anything unrecognised — try next flush
}

/// ISO-8601 UTC stamp for an event's `ts`. Built once — `ISO8601DateFormatter`
/// is expensive to construct and this is on the hot event path.
private let _eventTsFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

/// ISO-8601 UTC for "right now" — the moment an event HAPPENED.
internal func _monitorEventTs(_ date: Date = Date()) -> String {
    _eventTsFormatter.string(from: date)
}

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
    /// ISO-8601 UTC, stamped when the event HAPPENED — not when it is sent.
    ///
    /// The backend clamps this to a 1h staleness window and falls back to ingest
    /// time when it is absent (`_resolve_event_ts` in sdk_monitor.py), so without
    /// it a batch that waited out an outage is recorded as having happened the
    /// moment the outage ENDED — calm during the failure, phantom spike after.
    /// Parity with onelo-python / node / php, which have always sent it.
    ///
    /// NOTE: unrelated to the `ts` on a BREADCRUMB (unix seconds, inside meta).
    let ts: String
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

    /// Number of events evicted because the buffer was full. Bounded dropping
    /// is fine; silence is not — we log the running total (see `_noteDrop`).
    private var droppedEventCount = 0

    /// While a drain is in flight no second drain may start: two overlapping
    /// drains would interleave batches, and the second would observe an empty
    /// buffer and report success. Honoured by the async drain AND `_flushSync`.
    private var isDraining = false

    /// Server told us to back off (429 `Retry-After`). Until this instant,
    /// flushes leave the events buffered instead of sending.
    private var retryAfterUntil: Date = .distantPast

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
    //
    // `firstTs` is the moment the FIRST call in the current window happened, so
    // the summary event carries an event time from when the calls actually
    // occurred rather than from the drain that shipped them — the same reason
    // per-event `ts` exists.
    private var summaryBuffer: [String: (count: Int, firstTs: String)] = [:]

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

        // Auto-emit one unconditional event per construction. An app that gates
        // every instrumented operation behind sign-in/paywall/consent would
        // otherwise emit NOTHING on a cold start — the dashboard would look
        // "not integrated" even though every line of the snippet was followed
        // correctly. This event needs no gate to exist: it fires the moment the
        // SDK is constructed, so Feature Health always has at least one row.
        // Mirrors @onelo/js's `session_opened` (monitor.ts).
        _push(featureName: "session_opened", ok: true, durationMs: nil, error: nil, source: "event")
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

    /// Test-only: number of events currently buffered (including any batch
    /// handed back by `_requeue`). Drains the serial queue first so pending
    /// writes are visible. Internal — exposed via `@testable import`.
    internal func _bufferedCountForTesting() -> Int {
        var result = 0
        queue.sync { result = self.buffer.count }
        return result
    }

    /// Test-only: running total of events evicted because the buffer was full.
    internal func _droppedCountForTesting() -> Int {
        var result = 0
        queue.sync { result = self.droppedEventCount }
        return result
    }

    /// Test-only: discard whatever is currently buffered (including the
    /// auto-emitted `session_opened` event from construction) so tests can
    /// assert on exact counts/payloads for events THEY push, without the
    /// unconditional cold-start event throwing off the numbers. Drains the
    /// serial queue first so the init-time push (dispatched via `queue.async`)
    /// is guaranteed to have landed before it is cleared.
    internal func _clearBufferForTesting() {
        queue.sync {
            self.buffer.removeAll()
            self.summaryBuffer.removeAll()
        }
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
        // Stamp NOW, on the caller's side of the hop — this is when the call
        // happened. Only the first call of a window sets it.
        let now = _monitorEventTs()
        queue.async { [weak self] in
            guard let self else { return }
            if let existing = self.summaryBuffer[featureName] {
                self.summaryBuffer[featureName] = (existing.count + 1, existing.firstTs)
            } else {
                self.summaryBuffer[featureName] = (1, now)
            }
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

        // Stamp the event time HERE, on the caller's thread, before the hop onto
        // `queue` and long before the flush that ships it.
        let ts = _monitorEventTs()

        let work: () -> Void = { [weak self] in
            guard let self else { return }
            if self.buffer.count >= self.maxBufferSize {
                // Newest events win — evict the oldest (same policy as
                // `_requeue`). Drops are counted and logged, never silent.
                self.buffer.removeFirst()
                self._noteDrop(1)
            }
            let encodableMeta: [String: AnyEncodable]? = scrubbedMeta.map { dict in
                Dictionary(uniqueKeysWithValues: dict.map { ($0.key, AnyEncodable(value: $0.value)) })
            }
            self.buffer.append(BufferedEvent(
                ts: ts,
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
    //
    // ONE attempt per flush. A batch the server did not accept (429, 5xx,
    // network, timeout) is re-queued (capped, newest-wins) and the NEXT flush
    // carries it — the 15s timer IS the retry, so an outage never multiplies
    // inbound request volume. Every drop is logged.
    // Still deferred: persisting the queue to disk + retrying on the NEXT
    // LAUNCH (BGTaskScheduler). Events buffered when the process dies are
    // therefore still lost — that is a separate, larger piece of work.

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
            self?._drain()
        }
    }

    // MARK: - Internal: buffer drain (must run on `queue`)

    /// Take everything pending — buffered events plus the feature-call summary
    /// counters — out of the buffers and return it as one batch.
    ///
    /// The caller owns the batch from here on: if delivery fails it MUST hand
    /// the events back via `_requeue`. Nothing is discarded on the way out.
    private func _takePendingBatch() -> [BufferedEvent] {
        var events = self.buffer
        self.buffer.removeAll()
        // Drain summary counters into the outgoing batch as one BufferedEvent
        // per feature. After the drain the counters reset — next window starts
        // fresh. The aggregated events travel with the batch, so a failed send
        // re-queues them like any other event instead of losing the count.
        for (featureName, entry) in self.summaryBuffer where entry.count > 0 {
            events.append(BufferedEvent(
                // When the first call of this window happened — NOT drain time.
                ts: entry.firstTs,
                featureName: featureName,
                ok: true,
                durationMs: nil,
                error: nil,
                source: "feature_call_summary",
                platform: "swift",
                sessionId: self.sessionId,
                userId: self.currentUserId,
                meta: ["calls": AnyEncodable(value: entry.count)]
            ))
        }
        self.summaryBuffer.removeAll()
        return events
    }

    /// Async drain: serialised, non-blocking, ONE attempt. Runs on `queue`.
    private func _drain() {
        // Never let the 15s timer, an error auto-flush and an explicit flush()
        // overlap: two drains would interleave batches and the second would see
        // an empty buffer and report success.
        guard !isDraining else { return }
        // Honour a 429 hold-off: leave the events buffered, they go out on the
        // next flush after the hold-off expires.
        guard Date() >= retryAfterUntil else { return }

        let events = _takePendingBatch()
        guard !events.isEmpty else { return }
        guard let request = _makeRequest(events: events) else {
            // Serialisation failed. The batch is already OUT of the buffer, so
            // returning here would annihilate it silently — hand it back.
            _requeue(events)
            return
        }

        isDraining = true
        // ONE attempt. Anything the server did not accept goes straight back in
        // the buffer and rides the next 15s tick — the flush timer IS the retry.
        _sendOnce(request: request) { [weak self] outcome in
            // Back on `queue` (see `_sendOnce`).
            guard let self else { return }
            self.isDraining = false
            if outcome == .requeue { self._requeue(events) }
        }
    }

    /// One POST, fully asynchronous: no caller's thread is ever blocked.
    /// `completion` is invoked on `queue`.
    private func _sendOnce(request: URLRequest, completion: @escaping (_SendOutcome) -> Void) {
        transport.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let (outcome, holdOff, status) = _classify(response: response, error: error)
            self.queue.async {
                if holdOff > 0 {
                    self.retryAfterUntil = max(self.retryAfterUntil, Date().addingTimeInterval(holdOff))
                    _monitorLog.warning("event quota exhausted; holding off ~\(Int(holdOff))s before the next flush")
                }
                if outcome == .drop {
                    _monitorLog.warning("batch rejected with HTTP \(status) — dropping it (retrying would fail identically)")
                }
                completion(outcome)
            }
        }.resume()
    }

    /// Put an undelivered batch back at the FRONT of the buffer so the next
    /// flush retries it, then re-apply the cap. Runs on `queue`.
    ///
    /// Priority policy under a sustained outage: NEWEST EVENTS WIN. The buffer
    /// is trimmed from the front, so the oldest re-queued events go first. That
    /// matches `_push`'s eviction, keeps memory bounded at `maxBufferSize`
    /// however long the backend is down, and stops a stuck batch from starving
    /// live telemetry.
    private func _requeue(_ events: [BufferedEvent]) {
        buffer.insert(contentsOf: events, at: 0)
        var dropped = 0
        while buffer.count > maxBufferSize {
            buffer.removeFirst()
            dropped += 1
        }
        _monitorLog.warning(
            "batch not delivered — \(events.count) event(s) re-queued\(dropped > 0 ? ", \(dropped) oldest dropped (buffer cap \(self.maxBufferSize))" : "")"
        )
        if dropped > 0 { _noteDrop(dropped) }
    }

    /// Count a dropped event and log the running total. Logging is throttled
    /// (first drop, then every 50th) so a sustained outage cannot turn the
    /// device log into a firehose — but a drop is never silent.
    private func _noteDrop(_ count: Int) {
        let before = droppedEventCount
        droppedEventCount += count
        if before == 0 || (droppedEventCount / 50) > (before / 50) {
            _monitorLog.warning("buffer full (cap \(self.maxBufferSize)) — \(self.droppedEventCount) event(s) dropped so far")
        }
    }

    private func _makeRequest(events: [BufferedEvent]) -> URLRequest? {
        struct Payload: Encodable {
            let publishableKey: String
            let events: [BufferedEvent]
        }
        guard let url = URL(string: "\(apiUrl)/api/sdk/monitor/events/batch"),
              let body = try? JSONEncoder().encode(Payload(publishableKey: publishableKey, events: events)) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySecurityHeaders(to: &request)
        request.httpBody = body
        return request
    }

    /// Synchronous best-effort flush for the crash path. Drains the buffer on the
    /// caller's thread and blocks up to `timeout` waiting for ONE HTTP response.
    /// The process may still die before the semaphore signals — a disk-persisted
    /// queue (TODO v2) would eliminate that residual loss.
    ///
    /// ONE attempt, so `timeout` is a genuine ceiling on how long a terminating
    /// app is delayed rather than a budget a retry loop tries to fit inside.
    ///
    /// Unlike before, this respects BOTH the `isDraining` guard (so it cannot run
    /// alongside an async drain and interleave batches) and the `retryAfterUntil`
    /// hold-off (so a crash cannot bypass the rate limit the server asked for).
    /// An undelivered batch is handed back to the buffer, so if the process
    /// survives (a non-fatal `flush(timeout:)` call) the events go out on the
    /// next flush instead of being destroyed.
    private func _flushSync(timeout: TimeInterval = 2.0) {
        var events: [BufferedEvent] = []
        var proceed = false
        queue.sync {
            // Same two gates the async drain honours.
            guard !self.isDraining, Date() >= self.retryAfterUntil else { return }
            // A crash should not discard accumulated call counts either.
            events = self._takePendingBatch()
            guard !events.isEmpty else { return }
            self.isDraining = true
            proceed = true
        }
        guard proceed else { return }

        // From here the batch is OUT of the buffer and we own it: every exit
        // path below must either deliver it or hand it back.
        func settle(_ delivered: Bool) {
            queue.async {
                self.isDraining = false
                if !delivered { self._requeue(events) }
            }
        }

        guard let request = _makeRequest(events: events) else {
            _monitorLog.warning("crash-path batch could not be serialised — \(events.count) event(s) re-queued")
            settle(false)
            return
        }

        var outcome: _SendOutcome = .requeue
        var holdOff: TimeInterval = 0
        var status = 0
        let semaphore = DispatchSemaphore(value: 0)
        transport.dataTask(with: request) { _, response, error in
            (outcome, holdOff, status) = _classify(response: response, error: error)
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // No answer inside the budget — treat it as undelivered and let the
            // next flush carry the batch.
            settle(false)
            return
        }

        if holdOff > 0 {
            queue.async { self.retryAfterUntil = max(self.retryAfterUntil, Date().addingTimeInterval(holdOff)) }
        }
        if outcome == .drop {
            _monitorLog.warning("batch rejected with HTTP \(status) — dropping it (retrying would fail identically)")
        }
        settle(outcome != .requeue)
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
