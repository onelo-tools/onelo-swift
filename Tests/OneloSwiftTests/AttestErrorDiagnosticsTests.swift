import XCTest
@testable import OneloSwift

#if canImport(DeviceCheck)
/// A silently-failing security mechanism is worse than none. These tests pin the
/// observability contract added for the App Attest path: every failure case must
/// produce a non-empty, human-readable diagnostic, and the two detail-carrying
/// cases must preserve the underlying cause (raw DeviceCheck error / backend
/// status+body) so a developer can tell WHY attestation failed — not just that
/// `attestToken` ended up nil.
final class AttestErrorDiagnosticsTests: XCTestCase {

    func test_every_case_has_a_nonempty_diagnostic() {
        let cases: [OneloAttestError] = [
            .notSupported,
            .attestationFailed,
            .invalidResponse,
            .timeout,
            .deviceCheckFailed("DCError 2: The operation couldn't be completed."),
            .serverRejected(status: 403, detail: #"{"error":"invalid_attestation"}"#),
        ]
        for c in cases {
            XCTAssertFalse(c.diagnosticDescription.isEmpty, "\(c) must have a diagnostic")
        }
    }

    func test_deviceCheckFailed_preserves_underlying_error_text() {
        let raw = "DCError Code=2 \"App Attest not available\""
        let err = OneloAttestError.deviceCheckFailed(raw)
        XCTAssertTrue(err.diagnosticDescription.contains(raw),
                      "the raw DeviceCheck cause must survive into the diagnostic")
    }

    func test_serverRejected_preserves_status_and_body() {
        let err = OneloAttestError.serverRejected(status: 403, detail: #"{"error":"bundle_id_not_registered"}"#)
        let d = err.diagnosticDescription
        XCTAssertTrue(d.contains("403"), "HTTP status must be visible")
        XCTAssertTrue(d.contains("bundle_id_not_registered"), "backend reason must be visible")
    }

    func test_notSupported_hints_at_capability() {
        // The most common real-device cause is a missing App Attest capability;
        // the message should point there, not just say "not supported".
        XCTAssertTrue(
            OneloAttestError.notSupported.diagnosticDescription.lowercased().contains("capability"),
            "notSupported should hint at the App Attest capability"
        )
    }
}
#endif
