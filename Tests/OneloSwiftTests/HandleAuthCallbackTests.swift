import XCTest
@testable import OneloSwift

/// `handleAuthCallback(_:)` — the entry point for a sign-in that finishes OUTSIDE
/// the SDK's WebView. A magic link is why it exists: the email opens in the
/// browser, the browser hands the code back over the app's registered scheme, and
/// the process may have been killed in between.
///
/// These tests cover the URL guard, not the network. The guard is the security
/// half: without the `host == "callback"` check any page could navigate to
/// `myapp://anything?code=…` and smuggle a foreign code into the exchange, which
/// is exactly why the WebView coordinator has the same restriction. The rejection
/// paths return before any request is made, so they are the part worth pinning —
/// a happy path would need a live backend and belongs in the staging E2E.
@MainActor
final class HandleAuthCallbackTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://test.example.com")!,
            callbackScheme: "turingo"
        )
        return OneloAuth(config: config, urlSession: .shared, skipInitialize: true)
    }

    /// Returning nil rather than throwing lets an app funnel EVERY incoming URL
    /// through this method without pre-filtering — which is how it will actually
    /// be wired (`.onOpenURL`), so anything else would be a trap.
    func test_foreign_scheme_is_ignored_not_rejected() async throws {
        let auth = makeAuth()
        let out = try await auth.handleAuthCallback(URL(string: "otherapp://callback?code=abc")!)
        XCTAssertNil(out)
    }

    func test_wrong_host_is_ignored() async throws {
        // The smuggling guard: only the canonical <scheme>://callback shape counts.
        let auth = makeAuth()
        let out = try await auth.handleAuthCallback(URL(string: "turingo://anything?code=abc")!)
        XCTAssertNil(out)
    }

    func test_callback_without_a_code_is_ignored() async throws {
        // e.g. the portal's `?source=portal` return, which travels the same scheme
        // and must not be mistaken for a sign-in.
        let auth = makeAuth()
        let out = try await auth.handleAuthCallback(URL(string: "turingo://callback?source=portal")!)
        XCTAssertNil(out)
    }

    func test_empty_code_is_ignored() async throws {
        let auth = makeAuth()
        let out = try await auth.handleAuthCallback(URL(string: "turingo://callback?code=")!)
        XCTAssertNil(out)
    }

    func test_scheme_match_is_case_insensitive() async throws {
        // iOS hands the scheme back lowercased; a developer who registered
        // "Turingo" in Info.plist must not silently get a dead deep link. This one
        // gets PAST the guard, so it attempts a request against an unroutable host
        // and throws — proving acceptance without needing a backend.
        let auth = makeAuth()
        do {
            _ = try await auth.handleAuthCallback(URL(string: "TURINGO://CALLBACK?code=abc")!)
            XCTFail("expected the exchange to be attempted and fail against a stub host")
        } catch {
            // Any error is the pass condition here: reaching the network means the
            // URL was accepted rather than dropped by the guard.
        }
    }
}

/// The Access Gate's REFUSAL arriving over the deep link.
///
/// A magic link that the gate turns down produces no code by design — the
/// backend withholds it rather than letting the app decide. Before this path
/// existed the refusal could only be shown in the browser tab the email opened,
/// and the app was never told anything: the user saw "No active plan" in Safari
/// while the app sat on "Check your inbox" indefinitely (Turingo, 2026-08-19).
///
/// The URL is loaded in a WebView, and ANY app on the device can fire a custom
/// scheme at us — so the anchor check is the security half here, and most of
/// these tests are about refusing, not accepting.
@MainActor
final class GateDeepLinkTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://test.example.com")!,
            callbackScheme: "turingo"
        )
        return OneloAuth(config: config, urlSession: .shared, skipInitialize: true)
    }

    /// The trust anchor is PERSISTED (Keychain), on purpose: a magic link can
    /// relaunch a killed process, and a value that died with the process would
    /// leave nothing to check against on exactly the path this exists for.
    ///
    /// That persistence is shared across the whole test process, and it caught a
    /// test lying: `test_with_no_remembered_origin_it_fails_closed` passed only
    /// because an earlier test had already written the anchor. Clearing here is
    /// what makes "no anchor" actually mean no anchor.
    override func setUp() async throws {
        try await super.setUp()
        // Targeted delete, not clear(). The anchor outlived clear() even in a
        // single-test run — i.e. it was left behind by a PREVIOUS run of the
        // suite, on disk. Whatever clear() is doing on the macOS file-based
        // keychain, it is not reliably removing this row, and a test that quietly
        // depends on that would assert nothing at all.
        try? KeychainStorage().delete(forKey: "hosted_origin")
        let leftover = try? KeychainStorage().get(forKey: "hosted_origin")
        XCTAssertNil(leftover, "setUp did not actually clear the anchor")
    }

    private func gateLink(_ target: String) -> URL {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "turingo://callback?gate=\(encoded)")!
    }

    func test_a_gate_url_on_a_known_origin_is_presented() async throws {
        let auth = makeAuth()
        // Primed exactly as /flow/init does when it hands the app a hosted URL.
        auth._rememberHostedOrigin(URL(string: "https://st.onelo.tools/auth/hosted?token=x")!)

        let out = try await auth.handleAuthCallback(gateLink("https://st.onelo.tools/no-plan/hosted?token=npt_1"))

        // Nil is CORRECT and not a failure: a refusal is an answer, and there is
        // no session to return. The surface travels on `pendingGateUrl`.
        XCTAssertNil(out)
        XCTAssertEqual(auth.pendingGateUrl?.absoluteString,
                       "https://st.onelo.tools/no-plan/hosted?token=npt_1")
    }

    func test_a_foreign_origin_is_refused() async throws {
        // The one that matters. Any installed app can fire `turingo://callback`,
        // so an unchecked value here renders an attacker's page inside the app's
        // own sign-in window — indistinguishable from the real thing.
        let auth = makeAuth()
        auth._rememberHostedOrigin(URL(string: "https://st.onelo.tools/auth/hosted")!)

        _ = try await auth.handleAuthCallback(gateLink("https://evil.example.com/no-plan/hosted?token=npt_1"))

        XCTAssertNil(auth.pendingGateUrl)
    }

    func test_a_plain_http_gate_url_is_refused() async throws {
        // Downgrade guard: the anchor is an https origin, and a matching host
        // over http would still be interceptable on the wire.
        let auth = makeAuth()
        auth._rememberHostedOrigin(URL(string: "https://st.onelo.tools/auth/hosted")!)

        _ = try await auth.handleAuthCallback(gateLink("http://st.onelo.tools/no-plan/hosted?token=npt_1"))

        XCTAssertNil(auth.pendingGateUrl)
    }

    func test_with_no_remembered_origin_it_fails_closed() async throws {
        // Nothing has told this process where Onelo hosts its surfaces, so there
        // is nothing to check against and the only safe answer is no. The user
        // loses nothing recoverable: the app re-resolves and shows sign-in.
        let auth = makeAuth()

        _ = try await auth.handleAuthCallback(gateLink("https://st.onelo.tools/no-plan/hosted?token=npt_1"))

        XCTAssertNil(auth.pendingGateUrl)
    }

    func test_a_gate_on_a_foreign_scheme_is_ignored_entirely() async throws {
        let auth = makeAuth()
        auth._rememberHostedOrigin(URL(string: "https://st.onelo.tools/auth/hosted")!)

        let encoded = "https://st.onelo.tools/no-plan/hosted".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        _ = try await auth.handleAuthCallback(URL(string: "otherapp://callback?gate=\(encoded)")!)

        XCTAssertNil(auth.pendingGateUrl)
    }

    func test_clearing_the_pending_gate_stops_it_being_re_presented() async throws {
        // The view clears after presenting. Without this a later re-resolve would
        // reopen a screen the user had already dismissed.
        let auth = makeAuth()
        auth._rememberHostedOrigin(URL(string: "https://st.onelo.tools/auth/hosted")!)
        _ = try await auth.handleAuthCallback(gateLink("https://st.onelo.tools/no-plan/hosted?token=npt_1"))
        XCTAssertNotNil(auth.pendingGateUrl)

        auth.clearPendingGate()

        XCTAssertNil(auth.pendingGateUrl)
    }
}

/// The PKCE verifier behind a hosted flow, and why it must SURVIVE the next one.
///
/// `OneloAuthView` resolves the flow from 24 places. Each resolve used to mint a
/// fresh verifier and overwrite the persisted one — so any outstanding magic
/// link was silently invalidated before the user could click it. The failure
/// surfaces nowhere useful: `/hosted-callback` refuses the mismatch, the app
/// swallows the error, and it sits on "Check your inbox" forever while the
/// browser cheerfully says "You're signed in" (Turingo, 2026-08-19).
@MainActor
final class FlowVerifierReuseTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://test.example.com")!,
            callbackScheme: "turingo"
        )
        return OneloAuth(config: config, urlSession: .shared, skipInitialize: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        try? KeychainStorage().delete(forKey: "flow_code_verifier")
        try? KeychainStorage().delete(forKey: "flow_code_verifier_issued_at")
    }

    func test_a_second_flow_does_not_invalidate_an_outstanding_challenge() async throws {
        // THE regression, stated as the user experiences it: ask for a magic
        // link, let the app resolve the flow again for any reason, and the link
        // must still work when it arrives.
        let auth = makeAuth()
        let challengeBoundToTheEmailedLink = auth._beginFlowPKCE()

        let challengeAfterAnUnrelatedResolve = auth._beginFlowPKCE()

        XCTAssertEqual(challengeAfterAnUnrelatedResolve, challengeBoundToTheEmailedLink)
    }

    func test_the_persisted_verifier_survives_the_second_flow() async throws {
        // The half that actually completes the sign-in: the app is relaunched by
        // the deep link, so ONLY the Keychain copy is left to exchange with.
        let auth = makeAuth()
        _ = auth._beginFlowPKCE()
        let stored = try KeychainStorage().get(forKey: "flow_code_verifier")

        _ = auth._beginFlowPKCE()

        XCTAssertEqual(try KeychainStorage().get(forKey: "flow_code_verifier"), stored)
    }

    func test_a_stale_verifier_is_replaced() async throws {
        // The window is not "forever". Past the magic-link TTL nothing can still
        // be waiting on that challenge, so a fresh pair is minted.
        let auth = makeAuth()
        let first = auth._beginFlowPKCE()
        // 16 minutes ago — one minute past the link's own lifetime.
        try KeychainStorage().set(
            String(Date().timeIntervalSince1970 - (16 * 60)),
            forKey: "flow_code_verifier_issued_at",
        )

        XCTAssertNotEqual(auth._beginFlowPKCE(), first)
    }

    func test_a_missing_timestamp_mints_a_fresh_pair() async throws {
        // Fails closed. A verifier we cannot date is one we cannot vouch for,
        // and reusing it blindly would pin it indefinitely.
        let auth = makeAuth()
        let first = auth._beginFlowPKCE()
        try KeychainStorage().delete(forKey: "flow_code_verifier_issued_at")

        XCTAssertNotEqual(auth._beginFlowPKCE(), first)
    }

    func test_a_clock_that_moved_backwards_is_treated_as_stale() async throws {
        let auth = makeAuth()
        let first = auth._beginFlowPKCE()
        try KeychainStorage().set(
            String(Date().timeIntervalSince1970 + 3600),
            forKey: "flow_code_verifier_issued_at",
        )

        XCTAssertNotEqual(auth._beginFlowPKCE(), first)
    }

    func test_clearing_removes_the_timestamp_too() async throws {
        // A stamp left behind would make the NEXT verifier look older than it is
        // and cut its window short.
        let auth = makeAuth()
        _ = auth._beginFlowPKCE()

        auth._clearFlowPKCE()

        XCTAssertNil(try KeychainStorage().get(forKey: "flow_code_verifier_issued_at"))
    }
}
