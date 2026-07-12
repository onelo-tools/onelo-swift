import XCTest
@testable import OneloSwift

/// Single-owner claim for the consent gate. Two presenters (OneloAuthView's
/// built-in gate + a `.oneloConsentGate` modifier), and a multi-window macOS
/// app, otherwise each present their own hosted gate → duplicate windows. The
/// claim is the single source of truth for "who is presenting"; these lock its
/// semantics so the duplication bug can't silently regress.
@MainActor
final class OneloConsentGateClaimTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://test.example.com")!
        )
        return OneloAuth(config: config, urlSession: .shared, skipInitialize: true)
    }

    func test_free_gate_can_be_claimed() {
        let auth = makeAuth()
        XCTAssertNil(auth.consentGateOwner)
        let a = UUID()
        XCTAssertTrue(auth.claimConsentGate(a))
        XCTAssertEqual(auth.consentGateOwner, a)
    }

    func test_second_presenter_is_refused_while_claimed() {
        let auth = makeAuth()
        let a = UUID(), b = UUID()
        XCTAssertTrue(auth.claimConsentGate(a))
        // The whole point: a second presenter must NOT win → it won't render a
        // duplicate gate.
        XCTAssertFalse(auth.claimConsentGate(b))
        XCTAssertEqual(auth.consentGateOwner, a)
    }

    func test_claim_is_idempotent_for_the_owner() {
        let auth = makeAuth()
        let a = UUID()
        XCTAssertTrue(auth.claimConsentGate(a))
        XCTAssertTrue(auth.claimConsentGate(a))   // re-claim by owner is fine
        XCTAssertEqual(auth.consentGateOwner, a)
    }

    func test_release_by_owner_frees_the_gate() {
        let auth = makeAuth()
        let a = UUID()
        _ = auth.claimConsentGate(a)
        auth.releaseConsentGate(a)
        XCTAssertNil(auth.consentGateOwner)
    }

    func test_release_by_non_owner_is_a_noop() {
        let auth = makeAuth()
        let a = UUID(), b = UUID()
        _ = auth.claimConsentGate(a)
        // A stood-down presenter releasing on disappear must NOT steal the
        // owner's claim out from under it.
        auth.releaseConsentGate(b)
        XCTAssertEqual(auth.consentGateOwner, a)
    }

    func test_handoff_after_owner_releases() {
        let auth = makeAuth()
        let a = UUID(), b = UUID()
        _ = auth.claimConsentGate(a)
        XCTAssertFalse(auth.claimConsentGate(b))  // refused while a owns
        auth.releaseConsentGate(a)                // a unmounts / clears
        XCTAssertTrue(auth.claimConsentGate(b))   // b can now take over
        XCTAssertEqual(auth.consentGateOwner, b)
    }
}
