import XCTest
@testable import OneloSwift

/// #548 — what a refused `/api/sdk/auth/refresh` tells the app. Only a ban is
/// "suspended"; a replaced (`session_compromised`), expired or unknown session
/// is a neutral "session ended"; a lapsed plan stays plan-accurate. Pure
/// mapping — no `OneloAuth(config:)`, so no Keychain access.
final class RefreshRefusalTests: XCTestCase {
    private func refusal(_ status: Int, _ detail: [String: Any]) -> OneloError {
        refreshRefusalError(status: status, json: ["detail": detail])
    }

    func testSessionCodesMapToNeutralSessionEnded() {
        for code in ["session_compromised", "session_expired", "session_invalid"] {
            let err = refusal(401, ["error": code])
            guard case .sessionEnded = err else { return XCTFail("\(code) → \(err)") }
            XCTAssertEqual(err.errorDescription, "Your session ended — please sign in again")
            XCTAssertFalse(err.errorDescription!.lowercased().contains("suspended"))
        }
    }

    func testOnlyBanSaysSuspended() {
        let err = refusal(403, ["error": "banned"])
        guard case .userRevoked = err else { return XCTFail("banned → \(err)") }
        XCTAssertEqual(err.errorDescription, "This user account has been suspended")
    }

    func testNoPlanIsPlanAccurate() {
        let err = refusal(403, ["error_code": "no_plan_available", "message": "x"])
        guard case .noActivePlan = err else { return XCTFail("no_plan_available → \(err)") }
    }

    func testUnknownRefusalIsSessionEnded() {
        guard case .sessionEnded = refreshRefusalError(status: 500, json: [:]) else {
            return XCTFail("an unknown refusal must not claim an account action")
        }
    }

    func testLegacyStringDetailAccountActionIsStillARevocation() {
        let err = refreshRefusalError(status: 403, json: ["detail": "account_suspended"])
        guard case .userRevoked = err else { return XCTFail("legacy → \(err)") }
    }

    /// #547/#548: a transient failure (503 `refresh_unavailable`, 5xx, 429,
    /// offline) keeps the session and retries with backoff; the first retry
    /// lands inside the server's 30 s grace window.
    @MainActor
    func testTransientRetryBackoff() {
        XCTAssertEqual(OneloAuth.refreshRetryDelay(attempt: 0), 5)
        XCTAssertLessThan(OneloAuth.refreshRetryDelay(attempt: 0), 30)
        XCTAssertEqual(OneloAuth.refreshRetryDelay(attempt: 1), 10)
        XCTAssertEqual(OneloAuth.refreshRetryDelay(attempt: 3), 40)
        XCTAssertEqual(OneloAuth.refreshRetryDelay(attempt: 10), 60)
    }
}
