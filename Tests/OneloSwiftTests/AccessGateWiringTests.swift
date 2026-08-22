import XCTest
@testable import OneloSwift

/// The Access Gate, as the Swift SDK is allowed to know it.
///
/// Onelo decides; this SDK reads. The rule `!paywallEnabled || hasActiveAccess`
/// used to live here, in the JS SDK and in Flutter — three copies, each found
/// wrong on a different day. The server now computes `allowed_in` and ships it
/// with the user (app/lib/access_gate.user_access_payload).
///
/// Contract: docs/sdk-access-gate-wiring.md
final class AccessGateWiringTests: XCTestCase {

    // MARK: - The answer travels with the user

    func test_allowedIn_is_decoded_from_the_wire() throws {
        let json = """
        {"id":"u1","email":"a@b.c","entitlement":"none","allowed_in":true}
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(OneloUser.self, from: json)

        // Contradictory on purpose: no entitlement, yet allowed. The server may
        // know about a grant this client has not seen, and the server is the one
        // that decides.
        XCTAssertEqual(user.entitlement, .none)
        XCTAssertEqual(user.allowedIn, true)
    }

    func test_absent_allowedIn_stays_nil_not_false() throws {
        // "The server did not say" and "the server said no" are different
        // answers. Only the first may fall back to the legacy derivation; making
        // absence mean `false` would lock every user out against an older
        // backend.
        let json = """
        {"id":"u1","email":"a@b.c","entitlement":"active"}
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(OneloUser.self, from: json)

        XCTAssertNil(user.allowedIn)
        XCTAssertEqual(user.entitlement, .active)
    }

    func test_a_refusal_survives_the_round_trip() throws {
        // Sessions are persisted to the Keychain and decoded again on launch. A
        // `false` that decoded as nil would silently re-enable the local
        // derivation for a user the server has refused.
        let json = """
        {"id":"u1","email":"a@b.c","entitlement":"active","allowed_in":false}
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(OneloUser.self, from: json)
        XCTAssertEqual(user.allowedIn, false)

        let reencoded = try JSONEncoder().encode(user)
        let again = try JSONDecoder().decode(OneloUser.self, from: reencoded)
        XCTAssertEqual(again.allowedIn, false, "a stored refusal must not decay to nil")
    }

    // MARK: - What closing a surface means

    func test_a_signout_surface_is_recognised() {
        // Stamped by the backend on a screen the user only reached because they
        // have no plan: there is no app behind it to dismiss into.
        XCTAssertTrue(closingMeansSignOut(
            URL(string: "https://st.onelo.tools/store/hosted?token=srt_x&exit=signout")))
        XCTAssertTrue(closingMeansSignOut(
            URL(string: "https://st.onelo.tools/no-plan/hosted?token=npt_x&exit=signout")))
    }

    func test_an_ordinary_store_is_left_alone() {
        // Opened by an entitled user from inside a working app. Signing them out
        // for declining to buy would be hostile.
        XCTAssertFalse(closingMeansSignOut(
            URL(string: "https://st.onelo.tools/store/hosted?token=srt_x")))
        // Not a catch-all on any `exit` value.
        XCTAssertFalse(closingMeansSignOut(
            URL(string: "https://st.onelo.tools/store/hosted?exit=back")))
        XCTAssertFalse(closingMeansSignOut(nil))
    }

    // MARK: - The vocabulary this SDK must not reinvent

    func test_invalid_token_means_start_over_not_failure() {
        // It is what "Use a different account" sends. Surfacing it as an error
        // stranded users on a routine sign-out.
        XCTAssertTrue(isExpiredAuthError("invalid_token"))
        XCTAssertTrue(isExpiredAuthError("expired_token"))
        XCTAssertTrue(isExpiredAuthError("token_expired"))
    }

    func test_a_genuine_failure_is_still_a_failure() {
        // Reloading on every error would loop forever on a real one.
        XCTAssertFalse(isExpiredAuthError("attest_invalid"))
        XCTAssertFalse(isExpiredAuthError("access_denied"))
        XCTAssertFalse(isExpiredAuthError(nil))
    }
}

/// `isAllowedIn` — the one signal a host app gates its UI on.
@MainActor
final class AllowedInSignalTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        // `skipInitialize` + a bare scheme: this suite asserts the GATE, and a
        // real init would try to reach the network and to validate the scheme
        // against an Info.plist no test bundle has. Same shape as
        // AwaitReadyTimeoutTests.
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

    private func session(entitlement: OneloEntitlement, allowedIn: Bool?) -> OneloSession {
        OneloSession(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(
                id: "u1", email: "a@b.c", role: .member, tenantId: nil,
                entitlement: entitlement, allowedIn: allowedIn
            )
        )
    }

    func test_the_servers_answer_wins_over_anything_derivable_here() {
        let auth = makeAuth()
        // Contradictory inputs on purpose: a paywalled app and an unentitled
        // user, which the old local rule refused. The server said yes.
        auth._setGateInputsForTesting(
            session: session(entitlement: .none, allowedIn: true), paywallEnabled: true
        )
        XCTAssertTrue(auth.isAllowedIn)
    }

    func test_a_refusal_is_honoured_even_when_local_flags_say_otherwise() {
        let auth = makeAuth()
        // No paywall locally → the old rule said "allowed". The server says no,
        // and giving a paid product away is the failure that cannot be undone.
        auth._setGateInputsForTesting(
            session: session(entitlement: .active, allowedIn: false), paywallEnabled: false
        )
        XCTAssertFalse(auth.isAllowedIn)
    }

    func test_an_older_backend_still_works() {
        // Compatibility, not a second source of truth: without the fallback an
        // SDK released ahead of the server would lock every user out.
        let auth = makeAuth()
        auth._setGateInputsForTesting(
            session: session(entitlement: .active, allowedIn: nil), paywallEnabled: true
        )
        XCTAssertTrue(auth.isAllowedIn)

        auth._setGateInputsForTesting(
            session: session(entitlement: .none, allowedIn: nil), paywallEnabled: true
        )
        XCTAssertFalse(auth.isAllowedIn)
    }

    func test_no_session_is_never_allowed() {
        // A session says WHO someone is; it never says they may be here. This
        // stays local because it is a fact about this client, not policy.
        let auth = makeAuth()
        auth._setGateInputsForTesting(session: nil, paywallEnabled: false)
        XCTAssertFalse(auth.isAllowedIn)
    }
}
