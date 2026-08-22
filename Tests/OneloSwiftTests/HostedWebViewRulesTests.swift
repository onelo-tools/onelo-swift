import XCTest
@testable import OneloSwift

/// The two rules that decide what the hosted WebView SHOWS and where native
/// OAuth GOES. Both were written inline, untested, and both were wrong.
@MainActor
final class HostedWebViewRulesTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Reloading

    func test_a_changed_url_is_reason_enough_to_reload() {
        // THE bug that swallowed the Access Gate refusal. The views reloaded
        // only on an explicit flag, so handing them a new URL changed nothing:
        // the SDK set the no-plan surface and the WebView carried on showing
        // "Check your inbox" forever (Turingo, 2026-08-19).
        XCTAssertTrue(shouldReloadHostedWebView(
            loaded: url("https://st.onelo.tools/auth/hosted?token=a"),
            requested: url("https://st.onelo.tools/no-plan/hosted?token=npt_1"),
            forced: false,
        ))
    }

    func test_the_same_url_does_not_reload_on_every_re_render() {
        // The other half. SwiftUI re-renders a representable constantly, and the
        // naive "just load in update()" fix reloads the page each time — an
        // endless flicker, and any form the user was filling in is lost.
        let same = url("https://st.onelo.tools/auth/hosted?token=a")
        XCTAssertFalse(shouldReloadHostedWebView(loaded: same, requested: same, forced: false))
    }

    func test_a_forced_reload_beats_an_identical_url() {
        // Retry: the URL has not changed, the page must load anyway. This is why
        // the flag survives instead of being replaced by the comparison.
        let same = url("https://st.onelo.tools/auth/hosted?token=a")
        XCTAssertTrue(shouldReloadHostedWebView(loaded: same, requested: same, forced: true))
    }

    func test_the_first_load_happens() {
        XCTAssertTrue(shouldReloadHostedWebView(
            loaded: nil, requested: url("https://st.onelo.tools/auth/hosted"), forced: false,
        ))
    }

    func test_a_query_only_difference_still_counts() {
        // Hosted URLs differ ONLY by their one-time token, so comparing anything
        // coarser than the whole URL would treat a fresh surface as the old one.
        XCTAssertTrue(shouldReloadHostedWebView(
            loaded: url("https://st.onelo.tools/store/hosted?token=srt_1"),
            requested: url("https://st.onelo.tools/store/hosted?token=srt_2"),
            forced: false,
        ))
    }

    // MARK: - Native OAuth hand-off

    func test_a_sign_up_carries_its_intent() {
        // Without this the backend cannot tell "Sign up with Google" from
        // "Sign in with Google", refuses to create the account, and the user is
        // told they are not registered whichever button they pressed.
        let out = nativeOAuthURL(
            base: url("https://st.onelo.tools/auth/hosted?token=x"),
            provider: "google", token: "art_1", intent: "signup",
        )
        XCTAssertEqual(out?.path, "/api/sdk/auth/oauth/google")
        XCTAssertTrue(out?.query?.contains("intent=signup") ?? false)
    }

    func test_a_sign_in_sends_no_intent_and_gets_the_safe_default() {
        let out = nativeOAuthURL(
            base: url("https://st.onelo.tools/auth/hosted?token=x"),
            provider: "github", token: "art_1", intent: nil,
        )
        XCTAssertFalse(out?.query?.contains("intent") ?? true)
    }

    func test_an_unrecognised_intent_is_not_forwarded() {
        // The value arrives over a bridge message from a web page. Forwarding
        // anything unrecognised would let a string decide whether an account is
        // created.
        let out = nativeOAuthURL(
            base: url("https://st.onelo.tools/auth/hosted?token=x"),
            provider: "apple", token: "art_1", intent: "SIGNUP",
        )
        XCTAssertFalse(out?.query?.contains("intent") ?? true)
    }

    func test_the_fragment_is_dropped() {
        // A fragment carried over from the hosted URL would ride along into the
        // provider hand-off, where it means nothing and can only confuse.
        let out = nativeOAuthURL(
            base: url("https://st.onelo.tools/auth/hosted?token=x#section"),
            provider: "google", token: "art_1", intent: nil,
        )
        XCTAssertNil(out?.fragment)
    }
}
