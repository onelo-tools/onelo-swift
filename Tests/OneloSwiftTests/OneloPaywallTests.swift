import XCTest
@testable import OneloSwift

final class OneloPaywallTests: XCTestCase {

    func testFreeUserCanAccessFree() {
        let paywall = OneloPaywall()
        XCTAssertTrue(paywall.check("free", userPlan: "free"))
    }

    func testFreeUserCannotAccessPro() {
        let paywall = OneloPaywall()
        XCTAssertFalse(paywall.check("pro", userPlan: "free"))
    }

    func testProUserCanAccessPro() {
        let paywall = OneloPaywall()
        XCTAssertTrue(paywall.check("pro", userPlan: "pro"))
    }

    func testProUserCannotAccessBusiness() {
        let paywall = OneloPaywall()
        XCTAssertFalse(paywall.check("business", userPlan: "pro"))
    }
}
