import XCTest
@testable import OneloSwift

@MainActor
final class OneloFeaturesRefreshTests: XCTestCase {

    private func makeFeatures() -> OneloFeatures {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.invalid")!)
        return OneloFeatures(client: client)
    }

    // MARK: - _applyResolveResult

    func testApplyResolveResultPopulatesCache() {
        let features = makeFeatures()
        features._applyResolveResult([
            "chat":    ["status": "hidden"],
            "notepad": ["status": "enabled"],
            "beta":    ["status": "beta"],
        ])
        XCTAssertEqual(features.feature("chat").status, .hidden)
        XCTAssertEqual(features.feature("notepad").status, .enabled)
        XCTAssertEqual(features.feature("beta").status, .beta)
    }

    func testApplyResolveResultReplacesPriorCache() {
        let features = makeFeatures()
        features._setCache(["chat": .enabled, "stale": .enabled])
        features._applyResolveResult(["chat": ["status": "hidden"]])
        XCTAssertEqual(features.feature("chat").status, .hidden)
        // `stale` was not in the new resolve payload — must NOT linger from old cache,
        // otherwise feature flips that REMOVE a feature would never propagate.
        XCTAssertEqual(features.feature("stale").status, .hidden) // default fallback
    }

    func testApplyResolveResultIgnoresUnknownStatus() {
        let features = makeFeatures()
        features._applyResolveResult(["mystery": ["status": "not_a_real_status"]])
        XCTAssertEqual(features.feature("mystery").status, .hidden) // default
    }

    // MARK: - refresh() debounce

    func testRefreshDebouncesSecondCallWithinWindow() async {
        let features = makeFeatures()
        features._refreshDebounce = 5.0
        // Seed cache directly so we can detect a SECOND refresh by observing
        // whether it gets clobbered by the network call (which will fail
        // against `example.invalid` and leave cache untouched). Easier: just
        // assert the internal gate.
        let before = Date()
        await features.refresh() // first call sets lastRefreshAt → now
        // Immediate second call must be a no-op (returns before network).
        // We measure by: second call should return faster than the network
        // timeout, and `lastRefreshAt` should not have advanced.
        let firstStamp = features._lastRefreshAtForTesting
        await features.refresh()
        let secondStamp = features._lastRefreshAtForTesting
        XCTAssertEqual(firstStamp, secondStamp,
                       "Second refresh() within debounce window must not run")
        XCTAssertGreaterThanOrEqual(firstStamp, before)
    }

    func testRefreshAllowsCallAfterDebounceWindow() async {
        let features = makeFeatures()
        features._refreshDebounce = 0.05
        await features.refresh()
        let firstStamp = features._lastRefreshAtForTesting
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s > 0.05s window
        await features.refresh()
        let secondStamp = features._lastRefreshAtForTesting
        XCTAssertGreaterThan(secondStamp, firstStamp,
                             "refresh() after debounce window must run again")
    }

    // MARK: - SSE zombie detector

    func testCheckSSEHealthIsNoopWithoutActiveStream() {
        let features = makeFeatures()
        // No _load has been called → streamTask is nil → must not crash, must not log
        features._sseStaleThreshold = 0.001
        features._setLastEventReceivedForTesting(.distantPast)
        features._checkSSEHealth() // would panic if it tried to reconnect with no userId/state
        // Pass: no crash. Stream still nil.
        XCTAssertFalse(features._sseTaskActive())
    }

    func testCheckSSEHealthDetectsStaleAndReconnects() async {
        let features = makeFeatures()
        // Start a fake stream task we can observe for replacement.
        let sentinel = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        features._installFakeStreamTaskForTesting(sentinel)
        XCTAssertTrue(features._sseTaskActive())

        features._sseStaleThreshold = 0.001
        features._setLastEventReceivedForTesting(.distantPast)
        features._checkSSEHealth()

        // After detection, _connectSSE replaces streamTask. The sentinel must
        // be cancelled (since _connectSSE calls streamTask?.cancel()).
        // Give the runtime a beat to process cancellation.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sentinel.isCancelled,
                      "Stale SSE detection must cancel the previous stream task")
        XCTAssertTrue(features._sseTaskActive(),
                      "A new stream task must be installed after reconnect")
    }

    // MARK: - refresh(force:) bypass

    func testRefreshForceTrueBypassesDebounce() async {
        let features = makeFeatures()
        features._refreshDebounce = 60 // huge — anything non-force would be skipped
        await features.refresh()
        let firstStamp = features._lastRefreshAtForTesting
        // sleep tiny window — well within debounce, but force should still run
        try? await Task.sleep(nanoseconds: 10_000_000)
        await features.refresh(force: true)
        let secondStamp = features._lastRefreshAtForTesting
        XCTAssertGreaterThan(secondStamp, firstStamp,
                             "refresh(force: true) must bypass debounce window")
    }

    // MARK: - _resyncOnLifecycle (App-Nap recovery path)

    func testResyncOnLifecycleReconnectsZombieSSE() async {
        let features = makeFeatures()
        let sentinel = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        features._installFakeStreamTaskForTesting(sentinel)
        features._sseLifecycleStaleThreshold = 0.001
        features._setLastEventReceivedForTesting(.distantPast)

        features._resyncOnLifecycle()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(sentinel.isCancelled,
                      "Lifecycle resync must tear down stale SSE so the next dashboard Deploy propagates")
        XCTAssertTrue(features._sseTaskActive(),
                      "Lifecycle resync must install a fresh SSE task")
    }

    func testResyncOnLifecycleLeavesFreshSSEAlone() async {
        let features = makeFeatures()
        let sentinel = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        features._installFakeStreamTaskForTesting(sentinel)
        features._sseLifecycleStaleThreshold = 60
        features._setLastEventReceivedForTesting(Date())

        features._resyncOnLifecycle()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sentinel.isCancelled,
                       "Fresh SSE must not be torn down when last event is recent")
    }

    func testResyncOnLifecycleAlwaysRunsForceRefresh() async {
        // Even when SSE looks fresh, lifecycle should still pull a REST snapshot
        // — the SSE could be fresh-looking due to a recent reconnect that hasn't
        // delivered its first event yet.
        let features = makeFeatures()
        features._refreshDebounce = 60
        // pre-stamp so non-force refresh would be a no-op
        await features.refresh()
        let stampBefore = features._lastRefreshAtForTesting
        try? await Task.sleep(nanoseconds: 10_000_000)

        features._sseLifecycleStaleThreshold = 60
        features._setLastEventReceivedForTesting(Date())
        features._resyncOnLifecycle()
        // Wait for the spawned Task to run refresh(force: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let stampAfter = features._lastRefreshAtForTesting
        XCTAssertGreaterThan(stampAfter, stampBefore,
                             "_resyncOnLifecycle must run refresh(force: true) regardless of SSE state")
    }

    func testCheckSSEHealthLeavesFreshStreamAlone() {
        let features = makeFeatures()
        let sentinel = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        features._installFakeStreamTaskForTesting(sentinel)
        features._sseStaleThreshold = 60
        features._setLastEventReceivedForTesting(Date()) // just received an event
        features._checkSSEHealth()
        XCTAssertFalse(sentinel.isCancelled,
                       "Fresh SSE must not be torn down by the healthcheck")
    }
}
