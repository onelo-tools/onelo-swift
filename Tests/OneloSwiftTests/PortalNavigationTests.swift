import XCTest
@testable import OneloSwift

/// #592 — how the embedded Customer Portal WebView routes navigations. A store
/// purchase started from the portal must dismiss it instead of leaving the buyer
/// on "You're in!".
final class PortalNavigationTests: XCTestCase {

    private func route(_ s: String?, scheme: String = "myapp") -> PortalNavigation {
        routePortalNavigation(s.flatMap(URL.init(string:)), callbackScheme: scheme)
    }

    func test_a_finished_store_checkout_dismisses_the_portal() {
        XCTAssertEqual(route("onelo://callback?code=oac_1"), .checkoutComplete)
    }

    // #627 — the relayed hand-back is decoded by classifyHandBack, not by the relay.
    func test_a_relayed_code_less_switch_dismisses_the_portal() {
        XCTAssertEqual(route("onelo://callback?source=store&event=switch_scheduled"), .checkoutComplete)
        XCTAssertEqual(route("onelo://callback?source=store&event=plan_switch_pending"), .checkoutComplete)
    }

    func test_return_to_app_on_a_spent_store_link_closes_the_container() {
        XCTAssertEqual(route("onelo://callback?error=token_expired"), .storeCancel)
    }

    func test_an_app_whose_own_scheme_is_onelo_still_closes_on_portal_done() {
        XCTAssertEqual(route("onelo://callback?source=portal", scheme: "onelo"), .done)
    }

    func test_the_retired_checkout_complete_sentinel_is_not_honoured() {
        XCTAssertEqual(route("onelo://checkout-complete"), .allow)
        XCTAssertEqual(route("onelo://callback"), .allow)
    }

    func test_the_ready_ping_still_hides_the_failsafe() {
        XCTAssertEqual(route("onelo://ready"), .ready)
    }

    func test_the_portal_return_deep_link_is_done() {
        XCTAssertEqual(route("myapp://callback?source=portal"), .done)
        XCTAssertEqual(route("MyApp://callback?source=portal", scheme: "myapp"), .done)
    }

    func test_ordinary_pages_and_unknown_sentinels_load() {
        XCTAssertEqual(route("https://st.onelo.tools/store/hosted?token=srt_1"), .allow)
        XCTAssertEqual(route("onelo://something-else"), .allow)
        XCTAssertEqual(route(nil), .allow)
        XCTAssertEqual(route("myapp://callback", scheme: ""), .allow)
    }

    func test_the_relay_marks_the_page_embedded_and_forwards_every_hand_back() {
        // /store/hosted reads window.OneloPortalHost to show "Taking you back…"
        // and hold before handing back. The relay re-expresses each hand-back
        // postMessage in the deep-link wire format (store-hand-back.ts
        // handBackDeepLink) so HandBack is the one decoder (#627).
        let js = portalRelayScriptSource
        XCTAssertTrue(js.contains("window.OneloPortalHost = true"))
        XCTAssertTrue(js.contains("onelo://ready"))
        XCTAssertTrue(js.contains("'onelo://callback?' + query"))
        XCTAssertTrue(js.contains("d.type === 'onelo:code'") && js.contains("'code=' + encodeURIComponent(d.code)"))
        XCTAssertTrue(js.contains("d.type === 'onelo:done'") && js.contains("'source=store&event='"))
        XCTAssertTrue(js.contains("d.type === 'onelo:cancel'") && js.contains("'token_expired'"))
        XCTAssertFalse(js.contains("checkout-complete"))
    }

    // MARK: #606 — change-plan intent

    func test_the_change_plan_intent_rides_on_the_portal_url() {
        let url = URL(string: "https://onelo.tools/customer/portal?token=prt_1")!
        XCTAssertEqual(portalURL(url, intent: .changePlan).absoluteString,
                       "https://onelo.tools/customer/portal?token=prt_1&intent=change_plan")
        XCTAssertEqual(portalURL(url, intent: nil), url)
    }

    func test_the_intent_is_set_once() {
        let url = URL(string: "https://onelo.tools/customer/portal?token=prt_1&intent=other")!
        XCTAssertEqual(portalURL(url, intent: .changePlan).absoluteString,
                       "https://onelo.tools/customer/portal?token=prt_1&intent=change_plan")
    }

    // MARK: #613 / #614 — the portal renews its token through the app

    func test_a_renew_request_is_routed_with_its_id_not_as_a_close() {
        XCTAssertEqual(route("onelo://renew-portal?request_id=abc%20def"), .renew(requestId: "abc def"))
        XCTAssertEqual(route("onelo://renew-portal"), .allow)
    }

    func test_the_relay_forwards_only_self_posted_portal_renew_requests() {
        XCTAssertTrue(portalRelayScriptSource.contains("e.source === window && e.data.type === 'onelo:renew_request'"))
        XCTAssertTrue(portalRelayScriptSource.contains("e.data.kind === 'portal'"))
        XCTAssertTrue(portalRelayScriptSource.contains("onelo://renew-portal?request_id="))
    }

    func test_the_renewed_reply_is_a_self_post_of_json() throws {
        let script = portalRenewReplyScript(requestId: "r1", hostedUrl: "https://onelo.tools/customer/portal?token=prt_new", reason: "")
        XCTAssertTrue(script.hasPrefix("window.postMessage({"))
        XCTAssertTrue(script.hasSuffix("}, '*');"))
        let literal = String(script.dropFirst("window.postMessage(".count).dropLast(", '*');".count))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: String])
        XCTAssertEqual(obj["type"], "onelo:renewed")
        XCTAssertEqual(obj["request_id"], "r1")
        XCTAssertEqual(obj["hosted_url"], "https://onelo.tools/customer/portal?token=prt_new")
    }

    func test_a_failed_renewal_names_the_reason() throws {
        let script = portalRenewReplyScript(requestId: "\"); alert(1); (\"", hostedUrl: nil, reason: "not_authenticated")
        let literal = String(script.dropFirst("window.postMessage(".count).dropLast(", '*');".count))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: String])
        XCTAssertEqual(obj["type"], "onelo:renew_failed")
        XCTAssertEqual(obj["reason"], "not_authenticated")
        XCTAssertEqual(obj["request_id"], "\"); alert(1); (\"")
    }

    func test_signed_out_is_the_only_not_authenticated_reason() {
        XCTAssertEqual(portalRenewFailureReason(OneloError.notAuthenticated), "not_authenticated")
        XCTAssertEqual(portalRenewFailureReason(OneloError.serverError("x")), "renew_failed")
    }

    func test_renewal_is_answered_only_on_the_portal_origin() {
        XCTAssertEqual(portalOrigin(of: URL(string: "https://Onelo.tools/customer/portal?token=prt_x")), "https://onelo.tools")
        XCTAssertEqual(portalOrigin(of: URL(string: "http://localhost:3000/store/hosted")), "http://localhost:3000")
        XCTAssertNotEqual(portalOrigin(of: URL(string: "https://checkout.stripe.com/x")), "https://onelo.tools")
        XCTAssertNil(portalOrigin(of: nil))
    }
}
