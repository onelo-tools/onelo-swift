import XCTest
@testable import OneloSwift

/// #368 — the server's `: keepalive` comment is the Event Stream's proof of
/// life. The parser used to drop it, so the Features staleness clock saw a
/// healthy idle stream as dead and reconnected it every ~2 minutes.
///
/// These tests feed the real wire bytes through `_OneloSSEParser` — the parser
/// the URLSession delegate uses — never a synthesised empty-named event.
@MainActor
final class SSEKeepaliveTests: XCTestCase {

    private static let connected = Data("event: connected\ndata: {\"config_version\":1,\"features\":{}}\n\n".utf8)
    private static let keepalive = Data(": keepalive\n\n".utf8)

    func testParserTurnsTheKeepaliveIntoACommentFrameNotAnEvent() {
        var parser = _OneloSSEParser()
        let frames = parser.feed(Self.keepalive)

        XCTAssertEqual(frames.count, 1, "the keepalive must be visible to the consumer")
        XCTAssertEqual(frames.first?.isComment, true)
        XCTAssertEqual(frames.filter { !$0.isComment }.count, 0, "a comment is not an event")
    }

    func testParserStillDecodesEventsAroundAKeepaliveSplitAcrossChunks() {
        var parser = _OneloSSEParser()
        var frames = parser.feed(Data(": keep".utf8))
        frames += parser.feed(Data("alive\r\n\r\nevent: up_to".utf8))
        frames += parser.feed(Data("_date\r\ndata: {}\r\n\r\n".utf8))

        XCTAssertEqual(frames.map(\.isComment), [true, false])
        XCTAssertEqual(frames.last?.type, "up_to_date")
        XCTAssertEqual(frames.last?.data, "{}")
    }

    func testEventStreamReportsTheKeepaliveAsActivityWithoutDispatchingIt() async {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.invalid")!,
                                      securityContext: _OneloSecurityContext())
        let stream = OneloEventStream(httpClient: client)
        let seen = Seen()
        stream.onActivity { seen.activity += 1 }
        stream.on("") { seen.dispatched.append($0) }
        stream.on("message") { seen.dispatched.append($0) }
        stream._openStream = { _, _ in Self.wire([Self.keepalive]) }

        stream.start(userId: nil)
        await waitUntil { seen.activity >= 1 }
        stream.stop()

        XCTAssertEqual(seen.activity, 1)
        XCTAssertEqual(seen.dispatched, [], "a keepalive must never reach an event handler")
    }

    func testKeepaliveOnTheWireHoldsTheFeaturesStreamPastTheStalenessWindow() async {
        let (features, opens) = makeFeatures(keepaliveEvery: 0.02)
        let reconnects = await runHealthchecks(features, for: 0.6)

        XCTAssertEqual(reconnects, 0, "a stream that keeps sending keepalives must not be reconnected")
        XCTAssertEqual(opens.count, 1)
    }

    func testSilenceForTheStalenessWindowStillReconnects() async {
        let (features, opens) = makeFeatures(keepaliveEvery: nil)
        let reconnects = await runHealthchecks(features, for: 0.6)

        XCTAssertGreaterThanOrEqual(reconnects, 1, "an open socket that delivers nothing is still a zombie")
        XCTAssertGreaterThanOrEqual(opens.count, 2)
    }

    // MARK: - Helpers

    private final class Opens { var count = 0 }
    private final class Seen { var activity = 0; var dispatched: [String] = [] }

    /// A standalone Features whose owned stream is served by `wire(...)`: one
    /// `connected` frame, then a keepalive every `keepaliveEvery` seconds (or
    /// nothing), held open until the stream is cancelled.
    private func makeFeatures(keepaliveEvery: TimeInterval?) -> (OneloFeatures, Opens) {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.invalid")!,
                                      securityContext: _OneloSecurityContext())
        let features = OneloFeatures(client: client)
        features._sseStaleThreshold = 0.2
        let opens = Opens()
        features._setOpenStreamForTesting { _, _ in
            opens.count += 1
            return Self.wire([Self.connected], thenEvery: keepaliveEvery, send: Self.keepalive)
        }
        return (features, opens)
    }

    /// Stands in for the healthcheck timer (whose floor is 5 s): checks
    /// staleness every 20 ms, as `_startHealthcheck` would. Returns how many
    /// times the healthcheck cycled the connection.
    private func runHealthchecks(_ features: OneloFeatures, for seconds: TimeInterval) async -> Int {
        features._startEventStreamForTesting()
        features._setLastEventReceivedForTesting(Date())
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            features._checkSSEHealth()
        }
        let reconnects = features._eventStreamStopCallCountForTesting
        features._stopEventStreamForTesting()
        return reconnects
    }

    /// Wire bytes → the real parser → the frames `SSEDelegate` would yield.
    private static func wire(
        _ chunks: [Data],
        thenEvery interval: TimeInterval? = nil,
        send repeated: Data = Data()
    ) -> AsyncThrowingStream<_OneloHTTPClient.SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = _OneloSSEParser()
                for chunk in chunks { parser.feed(chunk).forEach { continuation.yield($0) } }
                guard let interval else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    parser.feed(repeated).forEach { continuation.yield($0) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}
