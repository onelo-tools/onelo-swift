import XCTest
@testable import OneloSwift

/// Regression: the monitor transport used to clear the buffer BEFORE sending
/// and discard the URLSession result entirely (`{ _, _, _ in }`), so a 503 was
/// indistinguishable from success and silently destroyed the batch.
///
/// Policy under test (parity with @onelo/js): ONE attempt per flush. 2xx →
/// settled. 429 / 5xx / network → the batch goes back in the buffer and the
/// next 15s tick carries it (the flush timer IS the retry, so an outage never
/// multiplies request volume). 4xx other than 429 → dropped loudly. The buffer
/// stays capped — newest events win — and every event carries a `ts` stamped
/// when it HAPPENED, not when it was finally shipped.
final class MonitorRetryTests: XCTestCase {

    /// Scripted URLProtocol: replies with a fixed status, a network error, or
    /// hangs forever — and counts every attempt.
    final class ScriptedProtocol: URLProtocol {
        enum Behaviour {
            case status(Int, headers: [String: String]?)
            case networkError
            case hang
        }

        nonisolated(unsafe) private static var _behaviour: Behaviour = .status(200, headers: nil)
        nonisolated(unsafe) private static var _attempts = 0
        nonisolated(unsafe) private static var _bodies: [String] = []
        private static let lock = NSLock()

        static func configure(_ behaviour: Behaviour) {
            lock.lock(); _behaviour = behaviour; _attempts = 0; _bodies = []; lock.unlock()
        }

        /// Change the reply WITHOUT resetting the attempt counter or the
        /// captured bodies — lets one test script 429-then-200.
        static func setBehaviour(_ behaviour: Behaviour) {
            lock.lock(); _behaviour = behaviour; lock.unlock()
        }

        static var attempts: Int {
            lock.lock(); defer { lock.unlock() }
            return _attempts
        }

        /// Bodies of every POST the transport actually made, in order.
        static var bodies: [String] {
            lock.lock(); defer { lock.unlock() }
            return _bodies
        }

        /// `URLProtocol` sees the body as a stream once URLSession has taken the
        /// request, so read whichever form is present.
        private static func extractBody(_ request: URLRequest) -> String {
            if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
            guard let stream = request.httpBodyStream else { return "" }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&chunk, maxLength: chunk.count)
                if read <= 0 { break }
                data.append(contentsOf: chunk[0..<read])
            }
            return String(decoding: data, as: UTF8.self)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.extractBody(request)
            Self.lock.lock()
            Self._attempts += 1
            Self._bodies.append(body)
            let behaviour = Self._behaviour
            Self.lock.unlock()

            switch behaviour {
            case .hang:
                return // never completes — exercises the deadline
            case .networkError:
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            case let .status(code, headers):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    private func makeMonitor() -> OneloMonitor {
        let monitor = OneloMonitor(
            publishableKey: "pk_live_test",
            apiUrl: "https://example.invalid",
            securityContext: _OneloSecurityContext()
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self] + (config.protocolClasses ?? [])
        monitor.transport = URLSession(configuration: config)
        // Construction auto-emits an unconditional `session_opened` event (see
        // OneloMonitor.init). Strip it here so these tests' exact buffer-count /
        // attempt-count / payload assertions stay about the events THEY push.
        monitor._clearBufferForTesting()
        return monitor
    }

    /// Busy-wait on a condition without blocking the run loop indefinitely.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Retry classification

    func test_serverError_isOneAttempt_andTheNextFlushDelivers() {
        ScriptedProtocol.configure(.status(503, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))
        monitor.flush()
        waitUntil(4.0) { ScriptedProtocol.attempts >= 1 && monitor._bufferedCountForTesting() > 0 }
        // Give any (incorrect) in-flight retry ample time to fire.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        XCTAssertEqual(ScriptedProtocol.attempts, 1, "a 503 costs exactly ONE request — no in-flight retry loop")
        XCTAssertEqual(monitor._bufferedCountForTesting(), 1, "and the event survived")

        // The NEXT flush is the retry.
        ScriptedProtocol.setBehaviour(.status(200, headers: nil))
        monitor.flush()
        // Both conditions matter: the buffer is TRANSIENTLY empty while a send is
        // in flight, so `count == 0` alone can pass before the request even lands.
        waitUntil(4.0) { ScriptedProtocol.attempts >= 2 && monitor._bufferedCountForTesting() == 0 }
        XCTAssertEqual(ScriptedProtocol.attempts, 2)
        XCTAssertEqual(monitor._bufferedCountForTesting(), 0)
    }

    /// The load property that motivated deleting the retry loop: an outage must
    /// cost the backend the SAME number of requests as healthy operation. The
    /// old 3-attempt loop turned N flushes into 3N requests at the exact moment
    /// the backend could least afford it.
    func test_outage_neverMultipliesRequestVolume() {
        ScriptedProtocol.configure(.status(503, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))

        for expected in 1...5 {
            monitor.flush()
            waitUntil(4.0) { ScriptedProtocol.attempts >= expected && monitor._bufferedCountForTesting() > 0 }
        }
        // Let anything extra surface before counting.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(ScriptedProtocol.attempts, 5, "5 flushes must be 5 requests, not 15")
    }

    func test_clientError_isDropped_andLogged() {
        ScriptedProtocol.configure(.status(400, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))
        monitor.flush()

        waitUntil(3.0) { ScriptedProtocol.attempts >= 1 }
        // Give any (incorrect) retry time to fire before asserting.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        XCTAssertEqual(ScriptedProtocol.attempts, 1, "a 400 will not fix itself — do not retry")
        XCTAssertEqual(monitor._bufferedCountForTesting(), 0, "a settled batch must not be re-queued")
    }

    func test_networkError_isRequeued_andTheNextFlushDelivers() {
        ScriptedProtocol.configure(.networkError)
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))
        monitor.flush()
        waitUntil(4.0) { monitor._bufferedCountForTesting() > 0 }
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        XCTAssertEqual(ScriptedProtocol.attempts, 1, "a network failure costs ONE request, not three")
        XCTAssertEqual(monitor._bufferedCountForTesting(), 1)

        ScriptedProtocol.setBehaviour(.status(200, headers: nil))
        monitor.flush()
        waitUntil(4.0) { ScriptedProtocol.attempts >= 2 && monitor._bufferedCountForTesting() == 0 }
        XCTAssertEqual(monitor._bufferedCountForTesting(), 0)
    }

    func test_rateLimited_isNotRetried_andHoldsOffNextFlush() {
        ScriptedProtocol.configure(.status(429, headers: ["Retry-After": "60"]))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))
        monitor.flush()
        waitUntil(3.0) { ScriptedProtocol.attempts >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        XCTAssertEqual(ScriptedProtocol.attempts, 1, "429 must stop immediately, not hammer the backend")
        // A 429 means the server did NOT take the batch. The event that was
        // rate-limited must be back in the buffer, not incinerated.
        XCTAssertEqual(
            monitor._bufferedCountForTesting(), 1,
            "a rate-limited batch must be re-queued — 429 is not a delivery"
        )

        // Hold-off active: a subsequent flush must not send.
        monitor.event("unit-test-2", options: MonitorEventOptions(ok: true))
        monitor.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(ScriptedProtocol.attempts, 1, "Retry-After must hold off the next flush")
        XCTAssertEqual(
            monitor._bufferedCountForTesting(), 2,
            "held-off events stay buffered — the re-queued one AND the new one"
        )
    }

    /// Regression (data loss): a 429 used to be classified as `.done`, so the
    /// drain treated the batch as delivered and the events — already removed
    /// from the buffer before sending — were destroyed. Under sustained rate
    /// limiting that discarded 100% of telemetry while looking healthy.
    ///
    /// Asserts on the PAYLOAD, not on call counts: the exact event must survive
    /// the 429 and appear in the body of the send that follows the hold-off.
    func test_rateLimitedBatch_isRedeliveredAfterHoldOff() {
        ScriptedProtocol.configure(.status(429, headers: ["Retry-After": "1"]))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("survives-429", options: MonitorEventOptions(ok: true))
        monitor.flush()
        waitUntil(3.0) { ScriptedProtocol.attempts >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(ScriptedProtocol.attempts, 1, "429 must not be retried in-loop")
        XCTAssertEqual(
            monitor._bufferedCountForTesting(), 1,
            "the rate-limited event must still be buffered"
        )

        // Wait out the 1s hold-off, then let the backend accept.
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        ScriptedProtocol.setBehaviour(.status(200, headers: nil))
        monitor.flush()
        waitUntil(4.0) { ScriptedProtocol.attempts >= 2 && monitor._bufferedCountForTesting() == 0 }

        XCTAssertEqual(ScriptedProtocol.attempts, 2, "the hold-off must expire and the batch go out")
        let lastBody = ScriptedProtocol.bodies.last ?? ""
        XCTAssertTrue(
            lastBody.contains("survives-429"),
            "the re-queued event must be in the delivered payload, got: \(lastBody)"
        )
        XCTAssertEqual(monitor._bufferedCountForTesting(), 0, "an accepted batch is gone for good")
    }

    func test_success_clearsBuffer() {
        ScriptedProtocol.configure(.status(200, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))
        monitor.flush()
        waitUntil(3.0) { ScriptedProtocol.attempts >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(ScriptedProtocol.attempts, 1)
        XCTAssertEqual(monitor._bufferedCountForTesting(), 0, "an accepted batch is gone for good")
    }

    // MARK: - Bounded memory

    func test_bufferStaysCappedUnderSustainedOutage() {
        ScriptedProtocol.configure(.status(503, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        for i in 0..<500 {
            monitor.event("evt-\(i)", options: MonitorEventOptions(ok: true))
        }
        monitor.flush()
        waitUntil(8.0) { monitor._bufferedCountForTesting() > 0 && ScriptedProtocol.attempts >= 1 }

        // Keep producing while the backend stays down.
        for i in 500..<800 {
            monitor.event("evt-\(i)", options: MonitorEventOptions(ok: true))
        }
        monitor.flush()
        waitUntil(8.0) { ScriptedProtocol.attempts >= 2 }

        XCTAssertLessThanOrEqual(
            monitor._bufferedCountForTesting(), 200,
            "buffer must stay capped however long the backend is down"
        )
        XCTAssertGreaterThan(monitor._droppedCountForTesting(), 0, "drops must be counted, not silent")
    }

    // MARK: - Event time survives a delay

    /// Pull the `events` array out of a captured request body.
    private func events(in body: String) -> [[String: Any]] {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return [] }
        return events
    }

    /// A batch that waits out an outage must still report WHEN it happened.
    /// Without a client `ts` the backend falls back to ingest time
    /// (`_resolve_event_ts`), so an outage reads as calm during the failure and
    /// a phantom spike the moment it ENDS.
    ///
    /// Covers BOTH paths: a normal pushed event and a `feature_call_summary`.
    func test_ts_isStampedWhenTheEventHappened_notWhenItIsSent() {
        ScriptedProtocol.configure(.status(503, headers: nil))
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        let happenedAt = Date()
        monitor.event("checkout", options: MonitorEventOptions(ok: true))
        monitor._trackFeatureCall("summarised")

        monitor.flush() // fails — batch is held
        waitUntil(4.0) { monitor._bufferedCountForTesting() > 0 }

        // The outage lasts; the batch sits in the buffer meanwhile.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        ScriptedProtocol.setBehaviour(.status(200, headers: nil))
        monitor.flush()
        waitUntil(4.0) { ScriptedProtocol.attempts >= 2 && monitor._bufferedCountForTesting() == 0 }

        let sentAt = Date()
        let delivered = events(in: ScriptedProtocol.bodies.last ?? "")
        XCTAssertFalse(delivered.isEmpty, "the delayed batch must actually be delivered")

        let parser = ISO8601DateFormatter()
        for event in delivered {
            let name = event["featureName"] as? String ?? "?"
            guard let raw = event["ts"] as? String else {
                XCTFail("event \(name) carries no ts — the backend would fall back to ingest time")
                continue
            }
            guard let parsed = parser.date(from: raw) else {
                XCTFail("ts for \(name) is not ISO-8601: \(raw)")
                continue
            }
            // 1s of slack for the stamp being taken just after `happenedAt`.
            XCTAssertLessThanOrEqual(
                parsed.timeIntervalSince(happenedAt), 1.0,
                "ts for \(name) must be the event's own time, got \(raw)"
            )
            XCTAssertLessThan(
                parsed.timeIntervalSince(sentAt), -1.0,
                "ts for \(name) must be clearly EARLIER than the send, got \(raw)"
            )
        }
        XCTAssertTrue(
            delivered.contains { ($0["source"] as? String) == "feature_call_summary" },
            "the summary-drain path must be covered too"
        )
    }

    // MARK: - Terminate path

    func test_synchronousFlush_isBoundedByItsDeadline() {
        ScriptedProtocol.configure(.hang) // server never answers
        let monitor = makeMonitor()
        defer { monitor.destroy() }

        monitor.event("unit-test", options: MonitorEventOptions(ok: true))

        let start = Date()
        monitor.flush(timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "a terminating app must never be delayed by a retrying monitor")
        // The batch was not delivered, so it goes back into the buffer.
        waitUntil(2.0) { monitor._bufferedCountForTesting() > 0 }
        XCTAssertEqual(monitor._bufferedCountForTesting(), 1)
    }
}
