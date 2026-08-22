import XCTest
@testable import OneloSwift

/// `awaitReady(timeout:)` — the deadline must fire when `isReady` NEVER flips.
///
/// This is a regression test for a hang that cost real money. The original
/// implementation checked the deadline inside `for await ready in
/// $isReady.values`, so the check only ran when the publisher emitted. A
/// `@Published` publisher emits its current value on subscribe and then only on
/// change — so with `isReady` stuck at false the loop saw false once (0 s
/// elapsed) and then awaited an emission that never came. It waited FOREVER;
/// the 5 s was decorative.
///
/// What it hung, in order of who paid for it:
///   - `OneloAuthModule.awaitReady(timeout:)` — the public facade the Monitor
///     snippet tells developers to call at startup. A tenant with no network got
///     a permanently hung launch.
///   - `handleAuthCallback(_:)` — awaits this before exchanging a code, i.e. the
///     magic-link return on a cold start, exactly where `initialize()` may not
///     have settled.
///   - `HandleAuthCallbackTests` — found still running after 5 h 15 m locally;
///     the same hang on `macos-latest` ran to the 6-hour job limit and consumed
///     the month's entire Actions allowance (docs/ci-cost-controls.md).
///
/// `skipInitialize: true` is the whole point of the setup: nothing will ever set
/// `isReady`, which is the state the old code could not escape.
@MainActor
final class AwaitReadyTimeoutTests: XCTestCase {

    private func makeUninitializedAuth() -> OneloAuth {
        OneloAuth(
            config: OneloConfig(
                publishableKey: "onelo_pk_test_stub",
                apiUrl: URL(string: "https://test.example.com")!,
                callbackScheme: "turingo"
            ),
            urlSession: .shared,
            skipInitialize: true
        )
    }

    func test_awaitReady_throws_timeout_when_isReady_never_flips() async {
        let auth = makeUninitializedAuth()
        XCTAssertFalse(auth.isReady, "precondition: skipInitialize must leave isReady false")

        let started = Date()
        do {
            // A short timeout keeps the test fast; the bug was independent of the
            // value — any timeout waited forever.
            try await auth.awaitReady(timeout: 0.5)
            XCTFail("awaitReady returned without isReady ever becoming true")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            // Upper bound is the assertion that matters: before the fix this
            // never returned at all. Generous so a loaded machine can't flake it.
            XCTAssertLessThan(elapsed, 10, "the deadline did not fire independently of the publisher")
            // And it must be a timeout, not some unrelated failure.
            guard case OneloError.timeout = error else {
                return XCTFail("expected OneloError.timeout, got \(error)")
            }
        }
    }

    /// The happy path must still work — a fix that makes the timeout fire while
    /// breaking the wake-up would pass the test above and ship a broken SDK.
    func test_awaitReady_returns_as_soon_as_isReady_becomes_true() async throws {
        let auth = makeUninitializedAuth()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            auth._setReadyForTesting(true)
        }

        // Timeout comfortably longer than the 50 ms flip: if this throws, the
        // waiter is not observing the publisher any more.
        try await auth.awaitReady(timeout: 5)
        XCTAssertTrue(auth.isReady)
    }

    /// Already-ready must return immediately without touching the task group at
    /// all — this is the warm-app path every `handleAuthCallback` takes.
    func test_awaitReady_returns_immediately_when_already_ready() async throws {
        let auth = makeUninitializedAuth()
        auth._setReadyForTesting(true)

        let started = Date()
        try await auth.awaitReady(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }
}
