import XCTest
import AuthenticationServices
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
    // MARK: - Native OAuth return (#666)
    //
    // The provider runs in ASWebAuthenticationSession, outside the hosted page,
    // so the page never learns that it finished. When the sheet closed, the
    // idle sign-in form sat uncovered for the whole /hosted-callback round trip
    // and read as a failed sign-in. The return decides whether the view covers
    // the page with "Signing you in…".

    private func callback(_ query: String) -> URL { url("myapp://callback?\(query)") }

    func test_a_returned_code_covers_the_hosted_page_while_it_is_exchanged() {
        let r = nativeOAuthReturn(callbackURL: callback("code=oac_1"), error: nil)
        XCTAssertEqual(r, .code("oac_1"))
        XCTAssertTrue(r.coversHostedPage)
    }

    func test_closing_the_sheet_is_silent_and_leaves_the_form_usable() {
        // #543's rule: a cancel restores the form, never a stuck spinner.
        let cancel = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        )
        let r = nativeOAuthReturn(callbackURL: nil, error: cancel)
        XCTAssertEqual(r, .cancelled)
        XCTAssertFalse(r.coversHostedPage)
    }

    func test_a_session_failure_goes_to_the_retry_screen_not_the_cover() {
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let r = nativeOAuthReturn(callbackURL: nil, error: failure)
        guard case .failed = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertFalse(r.coversHostedPage)
    }

    func test_a_missing_callback_is_a_failure() {
        let r = nativeOAuthReturn(callbackURL: nil, error: nil)
        guard case .failed = r else { return XCTFail("expected .failed, got \(r)") }
    }

    func test_a_provider_error_is_a_failure_with_its_code() {
        let r = nativeOAuthReturn(callbackURL: callback("error=no_account"), error: nil)
        XCTAssertEqual(r, .failed("no_account"))
        XCTAssertFalse(r.coversHostedPage)
    }

    func test_a_store_preauth_reloads_the_store_and_is_not_a_sign_in_cover() {
        // Paid store flow: the account exists but payment is still owed — the
        // store page reloads itself to take the card; nothing is exchanged.
        let r = nativeOAuthReturn(callbackURL: callback("preauth=jwt_1"), error: nil)
        XCTAssertEqual(r, .preauth("jwt_1"))
        XCTAssertFalse(r.coversHostedPage)
    }

    func test_the_cover_text_follows_the_branding_background() {
        // The cover sits on the branding background; its line must stay legible
        // on a light one as well as the default dark #111111.
        XCTAssertEqual(oneloHexIsLight("#111111"), false)
        XCTAssertEqual(oneloHexIsLight("#FFFFFF"), true)
        XCTAssertEqual(oneloHexIsLight("fafafa"), true)
        XCTAssertEqual(oneloHexIsLight("#fff"), true)
        XCTAssertNil(oneloHexIsLight(nil))
        XCTAssertNil(oneloHexIsLight("not-a-colour"))
    }
}
