import XCTest
@testable import OneloSwift

/// #622 — the hosted feedback form's reporter token `ft` lives 30 minutes. A
/// form left open longer asks the app for a fresh one on submit: a self-post
/// the relay turns into the `onelo://feedback_renew` sentinel. Pure contract
/// only — nothing here constructs `Onelo` (keychain).
final class FeedbackRenewalTests: XCTestCase {

    func testSentinelCarriesTheRequestId() {
        XCTAssertEqual(FeedbackWebCoordinator.renewRequestId(from: URL(string: "onelo://feedback_renew?request_id=r-1")!), "r-1")
    }

    func testOtherURLsAreNotRenewRequests() {
        XCTAssertNil(FeedbackWebCoordinator.renewRequestId(from: URL(string: "onelo://feedback_renew")!))
        XCTAssertNil(FeedbackWebCoordinator.renewRequestId(from: URL(string: "onelo://feedback_close")!))
        XCTAssertNil(FeedbackWebCoordinator.renewRequestId(from: URL(string: "https://evil.test/feedback_renew?request_id=x")!))
    }

    func testRelayMarksTheHostAndForwardsOnlyASelfPostedFeedbackRequest() {
        let src = FeedbackWebCoordinator.relaySource
        XCTAssertTrue(src.contains("window.OneloFeedbackHost = true;"))
        XCTAssertTrue(src.contains("e.source === window && e.data.type === 'onelo:renew_request'"))
        XCTAssertTrue(src.contains("e.data.kind === 'feedback'"))
        XCTAssertTrue(src.contains("'onelo://feedback_renew?request_id='"))
    }

    func testReplyIsASelfPostOfTheFreshURL() {
        let script = portalRenewReplyScript(requestId: "r-1", hostedUrl: "https://onelo.tools/feedback/hosted?key=pk&ft=new", reason: "")
        XCTAssertTrue(script.hasPrefix("window.postMessage({"))
        XCTAssertTrue(script.contains("\"type\":\"onelo:renewed\""))
    }
}
