import XCTest
@testable import OneloSwift

@MainActor
final class OneloSwiftTests: XCTestCase {

    func test_AuthSkeletonView_exists_and_renders() {
        // AuthSkeletonView must be accessible from @testable import.
        // This test fails to compile until the view is created.
        let _ = AuthSkeletonView()
    }

    func test_NeutralSkeletonView_exists_and_renders() {
        let _ = NeutralSkeletonView()
    }

    /// The classifier that decides which skeleton covers a navigation.
    ///
    /// Pinned because it already failed silently once: it was `/store/` →
    /// `.store`, else `.auth`, so `/no-plan/hosted` and `/auth/sdk-magic-link`
    /// — added 2026-08-17 — drew a sign-in form (email, password, "Forgot
    /// password?", social pills) for pages that have none. Nothing broke, so
    /// nothing caught it. A new hosted surface must be added here AND to
    /// `navigationKind(for:)` together.
    func test_navigationKind_classifies_every_hosted_surface() {
        func kind(_ path: String) -> NavigationKind {
            navigationKind(for: URL(string: "https://st.onelo.tools\(path)")!)
        }

        // Store → 3-card grid.
        XCTAssertEqual(kind("/store/hosted?token=abc"), .store)

        // Short surfaces → neutral. These are the two the old classifier ate.
        XCTAssertEqual(kind("/no-plan/hosted?token=abc"), .neutral)
        XCTAssertEqual(kind("/auth/sdk-magic-link?token=abc"), .neutral)

        // Sign-in page (and its reload) keeps the form skeleton. Note this is
        // asserted on `/auth/hosted` explicitly, NOT via the default — so a
        // future reshuffle of the prefix order can't quietly move it.
        XCTAssertEqual(kind("/auth/hosted?token=abc"), .auth)

        // Query strings must not affect classification — the tokens on these
        // URLs are per-request, so prefix matching is the whole point.
        XCTAssertEqual(kind("/no-plan/hosted"), .neutral)
        XCTAssertEqual(kind("/store/hosted"), .store)
    }

    /// `?error=invalid_token` must mean "reload", never "surface an error".
    ///
    /// This is the rule every other Onelo SDK was copied from, and until now it
    /// was an inline comparison inside a `WKNavigationDelegate` — untestable, so
    /// untested. The behaviour it drives: "Use a different account" on the
    /// no-plan page signs the user out and returns here; treating that as an
    /// error would strand them instead of showing a clean sign-in form.
    func test_isExpiredAuthError_recognises_the_three_expiry_codes() {
        XCTAssertTrue(isExpiredAuthError("invalid_token"))
        XCTAssertTrue(isExpiredAuthError("expired_token"))
        XCTAssertTrue(isExpiredAuthError("token_expired"))
    }

    func test_isExpiredAuthError_leaves_a_genuine_failure_alone() {
        // Not a catch-all — reloading on every error would loop on a real failure.
        XCTAssertFalse(isExpiredAuthError("attest_invalid"))
        XCTAssertFalse(isExpiredAuthError("access_denied"))
    }

    func test_isExpiredAuthError_does_not_claim_expiry_for_absent_values() {
        XCTAssertFalse(isExpiredAuthError(nil))
        XCTAssertFalse(isExpiredAuthError(""))
    }
}
