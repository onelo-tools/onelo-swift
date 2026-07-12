import XCTest
@testable import OneloSwift

final class FeatureStateReasonTests: XCTestCase {
    func test_decodes_reason_and_required_plan() throws {
        let json = #"""
        {"status":"greyed","reason":"plan","required_plan":"pro"}
        """#.data(using: .utf8)!
        let state = try JSONDecoder().decode(FeatureStateWire.self, from: json)
        XCTAssertEqual(state.status, "greyed")
        XCTAssertEqual(state.reason, .plan)
        XCTAssertEqual(state.requiredPlan, "pro")
    }

    func test_decodes_without_new_fields_backward_compat() throws {
        let json = #"{"status":"enabled"}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(FeatureStateWire.self, from: json)
        XCTAssertEqual(state.status, "enabled")
        XCTAssertNil(state.reason)
        XCTAssertNil(state.requiredPlan)
    }

    func test_decodes_all_reason_values() throws {
        for raw in ["user_override", "plan", "default", "static"] {
            let json = "{\"status\":\"enabled\",\"reason\":\"\(raw)\"}".data(using: .utf8)!
            let state = try JSONDecoder().decode(FeatureStateWire.self, from: json)
            XCTAssertNotNil(state.reason, "reason '\(raw)' should decode")
        }
    }

    func test_upgradeHint_when_plan_blocked_with_required_plan() {
        let state = FeatureState(
            name: "export",
            status: .greyed,
            reason: .plan,
            requiredPlan: "pro"
        )
        XCTAssertEqual(state.upgradeHint?.requiredPlan, "pro")
        XCTAssertEqual(state.upgradeHint?.currentStatus, .greyed)
    }

    func test_upgradeHint_nil_when_status_available() {
        let state = FeatureState(
            name: "chat",
            status: .enabled,
            reason: .plan,
            requiredPlan: nil
        )
        XCTAssertNil(state.upgradeHint)
    }

    func test_upgradeHint_nil_when_reason_not_plan() {
        let state = FeatureState(
            name: "chat",
            status: .greyed,
            reason: .userOverride,
            requiredPlan: nil
        )
        XCTAssertNil(state.upgradeHint)
    }

    func test_existing_helpers_unchanged_with_reason_present() {
        // Contractual: pre-3.52 helpers must keep working regardless of new fields.
        let state = FeatureState(name: "x", status: .beta, reason: .plan, requiredPlan: nil)
        XCTAssertTrue(state.isEnabled)  // .beta is in the enabled-group
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.isBeta)
        XCTAssertEqual(state.badgeLabel, "Beta")
    }
}
