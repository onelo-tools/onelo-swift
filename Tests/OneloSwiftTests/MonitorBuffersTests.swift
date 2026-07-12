import XCTest
@testable import OneloSwift

final class MonitorBreadcrumbBufferTests: XCTestCase {

    func test_addAndSnapshot_chronological() {
        let buf = MonitorBreadcrumbBuffer(capacity: 5)
        buf.add(.info("first"))
        buf.add(.info("second"))
        buf.add(.info("third"))

        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap[0].message, "first")
        XCTAssertEqual(snap[1].message, "second")
        XCTAssertEqual(snap[2].message, "third")
    }

    func test_ringOverwrite_keepsMostRecent() {
        let buf = MonitorBreadcrumbBuffer(capacity: 3)
        for i in 1...10 {
            buf.add(.info("msg \(i)"))
        }
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap[0].message, "msg 8")
        XCTAssertEqual(snap[1].message, "msg 9")
        XCTAssertEqual(snap[2].message, "msg 10")
    }

    func test_clearEmptiesBuffer() {
        let buf = MonitorBreadcrumbBuffer(capacity: 5)
        buf.add(.info("a"))
        buf.add(.info("b"))
        buf.clear()
        XCTAssertTrue(buf.snapshot().isEmpty)
    }

    func test_concurrentAdds_doNotCrash() {
        let buf = MonitorBreadcrumbBuffer(capacity: 100)
        let exp = expectation(description: "concurrent")
        exp.expectedFulfillmentCount = 4
        for thread in 0..<4 {
            DispatchQueue.global().async {
                for i in 0..<200 {
                    buf.add(.info("t\(thread)-\(i)"))
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5.0)
        // Buffer must contain exactly capacity items.
        XCTAssertEqual(buf.snapshot().count, 100)
    }

    func test_httpBreadcrumb_scrubsAuthorizationHeader() {
        let url = URL(string: "https://api.example.com/u?token=secret")!
        let crumb = MonitorBreadcrumb.http(
            method: "POST",
            url: url,
            status: 401,
            durationMs: 230,
            headers: ["Authorization": "Bearer abc"]
        )
        // URL is scrubbed in the message string and data.url.
        XCTAssertFalse(crumb.message.contains("token=secret"))
        XCTAssertEqual(crumb.data?["status"], "401")
        XCTAssertEqual(crumb.data?["method"], "POST")
        // Headers serialized as JSON; Authorization must be redacted.
        if let headersJSON = crumb.data?["headers"] {
            XCTAssertTrue(headersJSON.contains("[REDACTED]"))
            XCTAssertFalse(headersJSON.contains("Bearer abc"))
        } else {
            XCTFail("expected headers in breadcrumb data")
        }
    }
}

final class MonitorFeatureFlagBufferTests: XCTestCase {

    func test_recordAndSnapshot_returnsLatestValue() {
        let buf = MonitorFeatureFlagBuffer(capacity: 10)
        buf.record("checkout-v2", value: "enabled")
        buf.record("ai-summary", value: "disabled")
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 2)
        let dict = Dictionary(uniqueKeysWithValues: snap.map { ($0.key, $0.value) })
        XCTAssertEqual(dict["checkout-v2"], "enabled")
        XCTAssertEqual(dict["ai-summary"], "disabled")
    }

    func test_overwrite_updatesValue() {
        let buf = MonitorFeatureFlagBuffer(capacity: 10)
        buf.record("flag", value: "off")
        buf.record("flag", value: "on")
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].value, "on")
    }

    func test_capacityEvictsOldest_deterministicWithoutSleep() {
        // Regression: pre-fix the buffer used `Date()` for ordering, which
        // can produce identical timestamps in tight loops and makes eviction
        // non-deterministic. The fix uses a monotonic insertion counter.
        let buf = MonitorFeatureFlagBuffer(capacity: 3)
        buf.record("a", value: "1")
        buf.record("b", value: "1")
        buf.record("c", value: "1")
        buf.record("d", value: "1")  // must push "a" out

        let keys = buf.snapshot().map { $0.key }
        XCTAssertFalse(keys.contains("a"))
        XCTAssertEqual(Set(keys), Set(["b", "c", "d"]))
    }

    func test_concurrentRecords_doNotCrash() {
        let buf = MonitorFeatureFlagBuffer(capacity: 50)
        let exp = expectation(description: "concurrent flag records")
        exp.expectedFulfillmentCount = 4
        for thread in 0..<4 {
            DispatchQueue.global().async {
                for i in 0..<200 {
                    buf.record("flag-\(thread)-\(i % 25)", value: "v\(i)")
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertLessThanOrEqual(buf.snapshot().count, 50)
    }

    func test_clearEmptiesBuffer() {
        let buf = MonitorFeatureFlagBuffer(capacity: 10)
        buf.record("x", value: "y")
        buf.clear()
        XCTAssertTrue(buf.snapshot().isEmpty)
    }
}

final class MonitorBacktraceTests: XCTestCase {

    func test_capture_returnsFrames() {
        let frames = MonitorBacktrace.capture()
        XCTAssertFalse(frames.isEmpty)
        // Every frame has a hex address.
        for f in frames {
            XCTAssertTrue(f.address.hasPrefix("0x"))
        }
    }

    func test_capture_respectsMaxDepth() {
        let frames = MonitorBacktrace.capture(skip: 0, maxDepth: 5)
        XCTAssertLessThanOrEqual(frames.count, 5)
    }

    func test_format_producesNonEmptyText() {
        let frames = MonitorBacktrace.capture()
        let text = MonitorBacktrace.format(frames)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("0x"))
    }
}
