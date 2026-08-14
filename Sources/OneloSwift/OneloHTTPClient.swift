import Foundation

/// Single source of truth for the SDK's per-request security headers — the
/// App Attest bearer (`X-Attest-Token`) and the macOS codesign fingerprint
/// (`X-Codesign-Fingerprint`).
///
/// ONE instance is created by `OneloAuth` (the producer of the attest token)
/// and shared BY REFERENCE across EVERY transport: the auth URLSession
/// (`addStandardHeaders`), the shared REST/features client, the SSE stream
/// client, and the monitor transport. A value written once by the producer is
/// therefore visible to all readers with no per-transport copy to keep in sync.
///
/// This replaces the previous "mirror the token into each transport's own
/// field" model, where the features/stream SSE transport was silently left
/// unmirrored and 403'd `attest_invalid` in a permanent loop (#34). Because the
/// context is a REQUIRED init parameter on every transport, a NEW transport
/// cannot be constructed without being handed the shared context — the #34
/// class of bug is now impossible by construction.
///
/// `nonisolated(unsafe)` mirrors the transports it feeds: `attestToken` is
/// written by the producer on `@MainActor` and `codesignFingerprint` is seeded
/// once at init; reads happen on background URLSession queues at request-build
/// time. Writes complete before the first request that would observe them.
/// Public only because it appears in `OneloMonitor`'s public initializer
/// signature; the `_` prefix marks it as an internal SDK implementation detail,
/// not a supported API surface — host apps never construct or touch it.
public final class _OneloSecurityContext: @unchecked Sendable {
    nonisolated(unsafe) var attestToken: String? = nil
    nonisolated(unsafe) var codesignFingerprint: String? = nil
    public init() {}
}

/// Internal HTTP client for SDK modules (features, forms, waitlist).
/// Injects X-Bundle-Id and security attestation headers on every request.
final class _OneloHTTPClient: @unchecked Sendable {
    let publishableKey: String
    let baseURL: URL
    private let bundleId: String

    /// Shared security context — the single source of truth for the attest
    /// bearer + codesign fingerprint. Required (non-optional) so this transport
    /// can never be constructed without the shared state (#34 class fix). Read
    /// on every request in `applySecurityHeaders`.
    let securityContext: _OneloSecurityContext

    // FAZA 3 (assertion model) — per-request App Attest assertion. Wired by
    // Onelo.swift to OneloAppAttest.assertionHeaders. Returns the X-Attest-*
    // headers for THIS request, or nil (no attested key / offline) → the legacy
    // X-Attest-Token bearer above still applies (backward compatible).
    nonisolated(unsafe) var assertionProvider: ((_ method: String, _ path: String, _ query: String, _ body: Data) async -> [String: String]?)? = nil
    // Called with the backend's attest error code on a HARD attestation reject so
    // the SDK can self-heal (drop the key → re-attest). Never fired for the
    // retryable counter_stale nor for the session-refresh path (Filar 5).
    nonisolated(unsafe) var onAttestReject: ((String) -> Void)? = nil

    init(publishableKey: String, baseURL: URL, securityContext: _OneloSecurityContext) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
        self.bundleId = Bundle.main.bundleIdentifier ?? ""
        self.securityContext = securityContext
    }

    // MARK: - Platform

    /// Which Apple platform this build is running on.
    ///
    /// The backend cannot infer it: every Swift build sends the same
    /// `onelo-swift/<version>` User-Agent, so iOS and macOS were
    /// indistinguishable. They are not the same situation at all — App Review
    /// guideline 3.1.1 governs iOS and the Mac App Store, while a macOS app
    /// shipped as a DMG is outside Apple's reach entirely. `/api/sdk/config`
    /// uses this to decide whether the "Require plan on sign-up" gate applies
    /// (see applications.paywall_gate_on_apple, migration 20260814000001).
    ///
    /// Deliberately NOT a Mac-App-Store detection: a receipt check would tell
    /// us more, but it is unreliable across sandbox/TestFlight/notarised builds
    /// and getting it wrong silently changes a money flow. The developer's own
    /// setting is the authority; this header only says which platform is asking.
    static let osHeader: String = {
        #if os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }()

    // MARK: - Security headers

    private func applySecurityHeaders(to request: inout URLRequest) {
        request.setValue("onelo-swift/\(OneloSDK.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.osHeader, forHTTPHeaderField: "X-Onelo-OS")
        request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        if !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        if let token = securityContext.attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
        if let fp = securityContext.codesignFingerprint {
            request.setValue(fp, forHTTPHeaderField: "X-Codesign-Fingerprint")
        }
    }

    // MARK: - HTTP methods

    /// FastAPI ships error `detail` as either a bare string or an
    /// `{error, message}` object — unwrap both so callers see the actual
    /// reason (e.g. "This test key is bound to a different device") instead
    /// of an opaque "HTTP 403".
    private func errorDetail(_ json: [String: Any], statusCode: Int) -> String {
        if let s = json["detail"] as? String { return s }
        if let m = (json["detail"] as? [String: Any])?["message"] as? String { return m }
        return "HTTP \(statusCode)"
    }

    /// Attach the per-request App Attest assertion headers (FAZA 3), if the
    /// device can produce them. Called AFTER applySecurityHeaders so the
    /// assertion sits alongside (and the backend prefers it over) the bearer.
    private func applyAssertion(to request: inout URLRequest) async {
        guard let provider = assertionProvider else { return }
        let headers = await provider(
            request.httpMethod ?? "GET",
            request.url?.path ?? "",
            request.url?.query ?? "",
            request.httpBody ?? Data()
        )
        if let headers { for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) } }
    }

    /// On a HARD attestation reject, trigger self-heal (drop key → re-attest).
    /// counter_stale is retryable (re-sign, not a key problem) and the 503 store
    /// error is transient, so neither resets the key.
    private func handleAttestReject(_ json: [String: Any]) {
        guard let code = (json["detail"] as? [String: Any])?["error"] as? String else { return }
        if ["attest_key_unknown", "attest_key_revoked", "invalid_assertion"].contains(code) {
            onAttestReject?(code)
        }
    }

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)
        await applyAssertion(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            handleAttestReject(json)
            throw OneloError.serverError(errorDetail(json, statusCode: http.statusCode))
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Like `post(path:body:)` but returns the raw `(statusCode, json)` pair
    /// instead of throwing on non-2xx. Used by entitlement endpoints (Task 4.5)
    /// where the caller needs to discriminate 401 vs 403 vs 200 to map to
    /// typed `OneloFeaturesError` cases — the default `post` collapses every
    /// non-2xx into `OneloError.serverError(String)`, losing the structure.
    func postRaw(path: String, body: [String: Any]) async throws -> (Int, [String: Any]) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)
        await applyAssertion(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(http.statusCode) { handleAttestReject(json) }
        return (http.statusCode, json)
    }

    func get(path: String, queryItems: [URLQueryItem] = [], headers: [String: String] = [:]) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw OneloError.serverError("Invalid URL components")
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw OneloError.serverError("Invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)
        await applyAssertion(to: &request)
        // Caller-supplied headers (e.g. Authorization for user-scoped endpoints)
        // are applied AFTER the security set so they can never be clobbered.
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            handleAttestReject(json)
            throw OneloError.serverError(errorDetail(json, statusCode: http.statusCode))
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - SSE
    //
    // Server-Sent Events stream. Yields one event at a time as they arrive. The
    // task that calls this is responsible for cancellation; closing the parent
    // Task tears down the underlying URLSession data task automatically.
    //
    // Protocol parsing follows the WHATWG EventSource spec at the level we need:
    // accumulate `event:` and `data:` lines, flush on empty line, ignore `:`
    // comment lines (used by the server for heartbeats).
    struct SSEEvent: Sendable {
        let type: String           // "" if no `event:` line was sent (default `message`)
        let data: String           // raw payload (usually JSON we'll decode in callers)
    }

    func stream(
        path: String,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval = .infinity
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                guard var components = URLComponents(
                    url: self.baseURL.appendingPathComponent(path),
                    resolvingAgainstBaseURL: false
                ) else {
                    throw OneloError.serverError("Invalid URL components")
                }
                if !queryItems.isEmpty { components.queryItems = queryItems }
                guard let url = components.url else { throw OneloError.serverError("Invalid URL") }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                // SSE connections are long-lived. We rely on the server
                // sending `:keepalive` comments so the connection stays
                // alive through proxies and corporate firewalls.
                request.timeoutInterval = timeout
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                self.applySecurityHeaders(to: &request)

                // URLSession.shared.bytes(for:) + bytes.lines buffers received
                // bytes until an internal threshold is reached, swallowing small
                // SSE events (heartbeats, session.revoked ~120 B) for tens of
                // seconds. Using a dedicated URLSession with URLSessionDataDelegate
                // and parsing didReceive(data:) chunks ourselves flushes per TCP
                // packet — same pattern curl uses, matches WHATWG EventSource.
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout
                let delegate = SSEDelegate(continuation: continuation)
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)

                continuation.onTermination = { _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
                task.resume()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// URLSessionDataDelegate that parses SSE lines from raw didReceive(data:) chunks.
/// State (buffer + event accumulators) is mutated only on the delegate queue,
/// which URLSession serializes for a single task — no explicit locking needed.
private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>.Continuation
    private var buffer = Data()
    private var currentEvent = ""
    private var dataLines: [String] = []

    init(continuation: AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: OneloError.serverError("No HTTP response"))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            continuation.finish(throwing: OneloError.serverError("SSE stream rejected: HTTP \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Drain complete lines (terminated by \n; strip trailing \r per EventSource spec).
        while let nlIdx = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer[buffer.startIndex..<nlIdx]
            buffer.removeSubrange(buffer.startIndex...nlIdx)
            var line = String(data: Data(lineBytes), encoding: .utf8) ?? ""
            if line.hasSuffix("\r") { line.removeLast() }
            processLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Flush any final line without trailing newline.
        if !buffer.isEmpty {
            var line = String(data: buffer, encoding: .utf8) ?? ""
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { processLine(line) }
            buffer.removeAll()
        }
        if let nsErr = error as NSError?, nsErr.domain == NSURLErrorDomain, nsErr.code == NSURLErrorCancelled {
            continuation.finish()
        } else if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }

    private func processLine(_ line: String) {
        if line.isEmpty {
            // Empty line = dispatch accumulated event.
            if !dataLines.isEmpty {
                let payload = dataLines.joined(separator: "\n")
                continuation.yield(_OneloHTTPClient.SSEEvent(type: currentEvent, data: payload))
            }
            currentEvent = ""
            dataLines = []
            return
        }
        if line.hasPrefix(":") {
            // SSE comment / heartbeat — ignore.
            return
        }
        guard let colonIdx = line.firstIndex(of: ":") else { return }
        let field = String(line[..<colonIdx])
        var value = String(line[line.index(after: colonIdx)...])
        // Per spec: a single leading space after the colon is stripped.
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": currentEvent = value
        case "data":  dataLines.append(value)
        default:      break  // id/retry — not used by Onelo today
        }
    }
}
