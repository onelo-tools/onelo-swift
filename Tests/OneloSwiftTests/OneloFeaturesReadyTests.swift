import XCTest
@testable import OneloSwift

/// Tests for `OneloFeatures.ready(timeout:)` — the cold-start synchronization API
/// host apps call before rendering feature-dependent UI to avoid flicker between
/// stale UserDefaults cache and fresh SSE snapshot.
@MainActor
final class OneloFeaturesReadyTests: XCTestCase {

    private func makeFeatures() -> OneloFeatures {
        let client = _OneloHTTPClient(
            publishableKey: "pk_test",
            baseURL: URL(string: "https://example.com")!,
            securityContext: _OneloSecurityContext()
        )
        return OneloFeatures(client: client)
    }

    // MARK: - Helpers

    /// Measures how long an async block takes, returning seconds.
    private func elapsed(_ block: () async -> Void) async -> TimeInterval {
        let start = Date()
        await block()
        return Date().timeIntervalSince(start)
    }

    // MARK: - 1. Resolves after first SSE event

    func test_ready_resolves_after_first_sse_event() async throws {
        let features = makeFeatures()

        // Schedule a signal shortly after `ready()` starts awaiting.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            features._signalFirstEvent()
        }

        let dt = await elapsed {
            await features.ready(timeout: 2.0)
        }

        XCTAssertLessThan(dt, 0.5, "ready() should resolve well before timeout once signal fires (took \(dt)s)")
        XCTAssertGreaterThan(dt, 0.005, "ready() should not return before the signal (took \(dt)s)")
    }

    // MARK: - 2. Resolves immediately if event already received

    func test_ready_resolves_immediately_if_event_already_received() async throws {
        let features = makeFeatures()
        features._signalFirstEvent()

        let dt = await elapsed {
            await features.ready(timeout: 2.0)
        }

        XCTAssertLessThan(dt, 0.05, "ready() should return ~immediately if first event already fired (took \(dt)s)")
    }

    // MARK: - 3. Falls back after timeout

    func test_ready_falls_back_after_timeout() async throws {
        let features = makeFeatures()

        let dt = await elapsed {
            await features.ready(timeout: 0.1)
        }

        XCTAssertGreaterThanOrEqual(dt, 0.09, "ready() should wait at least the timeout (took \(dt)s)")
        XCTAssertLessThan(dt, 0.5, "ready() should not block beyond timeout by much (took \(dt)s)")
    }

    // MARK: - 4. ready() does not open a second SSE connection

    func test_ready_does_not_open_second_sse_connection() async throws {
        let features = makeFeatures()

        // No _load() call — therefore no SSE should ever be opened.
        XCTAssertFalse(features._sseTaskActive(), "Sanity: no SSE task before _load()")

        // Calling ready() must not start an SSE task on its own.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)
            features._signalFirstEvent()
        }
        await features.ready(timeout: 0.5)

        XCTAssertFalse(features._sseTaskActive(), "ready() must not open its own SSE connection")
    }

    // MARK: - 5. Multiple concurrent ready() calls all resolve on first event

    func test_multiple_concurrent_ready_calls_all_resolve_on_first_event() async throws {
        let features = makeFeatures()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            features._signalFirstEvent()
        }

        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { @MainActor in
                    await features.ready(timeout: 2.0)
                }
            }
            await group.waitForAll()
        }
        let dt = Date().timeIntervalSince(start)

        XCTAssertLessThan(dt, 0.5, "All concurrent ready() calls should resolve on the single signal (took \(dt)s)")
    }

    // MARK: - 6. No double-resume race between signal and timeout

    func test_ready_does_not_double_resume_after_signal_then_timeout() async throws {
        let features = makeFeatures()

        // Fire signal almost simultaneously with the timeout firing.
        // If implementation is buggy (double-resume on a CheckedContinuation),
        // this would crash the test runner with EXC_BREAKPOINT.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000) // ~90ms
            features._signalFirstEvent()
        }
        await features.ready(timeout: 0.1)

        // Wait a bit so any straggler timeout task can fire.
        try await Task.sleep(nanoseconds: 250_000_000)

        // Subsequent ready() should still work (state is consistent, queue drained).
        let dt = await elapsed {
            await features.ready(timeout: 2.0)
        }
        XCTAssertLessThan(dt, 0.05, "After first event signaled, subsequent ready() should be instant (took \(dt)s)")
    }
}
