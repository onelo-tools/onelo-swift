import Foundation

/// Internal HTTP client for SDK modules (features, forms, waitlist).
/// Injects X-Bundle-Id and security attestation headers on every request.
final class _OneloHTTPClient: @unchecked Sendable {
    let publishableKey: String
    let baseURL: URL
    private let bundleId: String

    // Written once at SDK startup, read on every request. Safe as nonisolated(unsafe)
    // because the write always completes before the first SDK request is made.
    nonisolated(unsafe) var attestToken: String? = nil
    nonisolated(unsafe) var codesignFingerprint: String? = nil
    nonisolated(unsafe) var integrityToken: String? = nil

    init(publishableKey: String, baseURL: URL) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
        self.bundleId = Bundle.main.bundleIdentifier ?? ""
    }

    // MARK: - Security headers

    private func applySecurityHeaders(to request: inout URLRequest) {
        request.setValue("onelo-swift/\(OneloSDK.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        if !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        }
        if let token = attestToken {
            request.setValue(token, forHTTPHeaderField: "X-Attest-Token")
        }
        if let fp = codesignFingerprint {
            request.setValue(fp, forHTTPHeaderField: "X-Codesign-Fingerprint")
        }
        if let it = integrityToken {
            request.setValue(it, forHTTPHeaderField: "X-Integrity-Token")
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

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        applySecurityHeaders(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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
        // Caller-supplied headers (e.g. Authorization for user-scoped endpoints)
        // are applied AFTER the security set so they can never be clobbered.
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneloError.serverError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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
