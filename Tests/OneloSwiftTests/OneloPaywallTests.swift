import XCTest
@testable import OneloSwift

final class OneloPaywallTests: XCTestCase {

    func testFreeUserCanAccessFree() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        client.userPlan = "free"
        let paywall = OneloPaywall(client: client)
        XCTAssertTrue(paywall.check("free"))
    }

    func testFreeUserCannotAccessPro() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        client.userPlan = "free"
        let paywall = OneloPaywall(client: client)
        XCTAssertFalse(paywall.check("pro"))
    }

    func testProUserCanAccessPro() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        client.userPlan = "pro"
        let paywall = OneloPaywall(client: client)
        XCTAssertTrue(paywall.check("pro"))
    }

    func testProUserCannotAccessBusiness() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        client.userPlan = "pro"
        let paywall = OneloPaywall(client: client)
        XCTAssertFalse(paywall.check("business"))
    }
}
