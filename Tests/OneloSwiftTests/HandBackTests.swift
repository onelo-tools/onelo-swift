import XCTest
@testable import OneloSwift

/// #615 — the one Store Hand-back decoder. Every `<scheme>://callback` shape the
/// hosted store and portal send. Pure: never constructs Onelo / OneloAuth.
final class HandBackTests: XCTestCase {

    private func hb(_ s: String) -> HandBack? { classifyHandBack(URL(string: s)!) }

    func test_every_wire_shape() {
        XCTAssertEqual(hb("myapp://callback?code=oac_1"), .purchase(code: "oac_1"))
        XCTAssertEqual(hb("myapp://callback?source=store&event=plan_switched"), .switched(reason: "plan_switched"))
        XCTAssertEqual(hb("myapp://callback?source=store&event=plan_switch_pending"), .switched(reason: "plan_switch_pending"))
        XCTAssertEqual(hb("myapp://callback?source=store&event=switch_scheduled"), .switched(reason: "switch_scheduled"))
        XCTAssertEqual(hb("myapp://callback?source=store"), .switched(reason: ""))
        XCTAssertEqual(hb("myapp://callback?source=portal"), .portalClosed(event: nil))
        XCTAssertEqual(hb("myapp://callback?source=portal&event=account_revoked"), .portalClosed(event: "account_revoked"))
        XCTAssertEqual(hb("myapp://callback?error=token_expired"), .error("token_expired"))
    }

    func test_not_a_hand_back() {
        XCTAssertNil(hb("myapp://callback"))
        XCTAssertNil(hb("myapp://evil?code=abc"))
        XCTAssertNil(hb("onelo://checkout-complete"))
    }
}
