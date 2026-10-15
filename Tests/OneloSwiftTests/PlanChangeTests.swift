import XCTest
@testable import OneloSwift

/// #659 — after a store purchase / plan switch the app kept the old plan until
/// the Event Stream caught up. Every hosted container now reports the change,
/// and one refresher re-resolves features + entitlement at once; a pending
/// switch is re-checked on a bounded backoff. Pure: never constructs Onelo /
/// OneloAuth (keychain prompts).
@MainActor
final class PlanChangeTests: XCTestCase {

    // MARK: - Which hand-backs move the plan

    private func change(_ s: String) -> OneloPlanChange? {
        classifyHandBack(URL(string: s)!).flatMap(OneloPlanChange.init)
    }

    func test_a_purchase_and_every_switch_move_the_plan() {
        XCTAssertEqual(change("myapp://callback?code=oac_1"), .purchase)
        XCTAssertEqual(change("onelo://callback?source=store&event=plan_switch_pending"), .switched(reason: "plan_switch_pending"))
        XCTAssertEqual(change("myapp://callback?source=store&event=plan_switched"), .switched(reason: "plan_switched"))
    }

    func test_the_portal_closing_or_an_error_does_not() {
        XCTAssertNil(change("myapp://callback?source=portal"))
        XCTAssertNil(change("myapp://callback?error=token_expired"))
    }

    // MARK: - Refresher

    private final class Probe {
        var refreshes = 0
        var revalidations = 0
        var plan = "pro"
        var applyAfter: Int
        var slept: [Double] = []
        init(applyAfter: Int) { self.applyAfter = applyAfter }
    }

    private func refresher(_ p: Probe) -> PlanChangeRefresher {
        PlanChangeRefresher(
            refreshFeatures: {
                p.refreshes += 1
                if p.refreshes >= p.applyAfter { p.plan = "business" }
            },
            revalidateEntitlement: { p.revalidations += 1 },
            snapshot: { p.plan },
            sleep: { p.slept.append($0) }
        )
    }

    func test_a_finished_switch_refreshes_once_at_once() async {
        let p = Probe(applyAfter: 1)
        let r = refresher(p)
        await r.handBack(.switched(reason: "plan_switched"))
        XCTAssertEqual(p.refreshes, 1)
        XCTAssertEqual(p.revalidations, 1)
        XCTAssertNil(r.recheckTask)
    }

    func test_a_pending_switch_is_rechecked_until_the_plan_moves() async {
        let p = Probe(applyAfter: 3) // immediate + two re-checks
        let r = refresher(p)
        await r.handBack(.switched(reason: "plan_switch_pending"))
        await r.recheckTask?.value
        XCTAssertEqual(p.refreshes, 3)
        XCTAssertEqual(p.slept, [1, 2])
        XCTAssertEqual(p.revalidations, 2, "once at the hand-back, once when the plan moved")
    }

    func test_a_pending_switch_gives_up_after_the_bounded_delays() async {
        let p = Probe(applyAfter: .max)
        let r = refresher(p)
        await r.handBack(.switched(reason: "plan_switch_pending"))
        await r.recheckTask?.value
        XCTAssertEqual(p.refreshes, 1 + pendingRecheckDelaysSeconds.count)
        XCTAssertEqual(p.slept, pendingRecheckDelaysSeconds)
    }

    func test_a_purchase_does_not_poll() async {
        let p = Probe(applyAfter: .max)
        let r = refresher(p)
        await r.handBack(.purchase)
        XCTAssertNil(r.recheckTask)
        XCTAssertEqual(p.refreshes, 1)
    }

    // MARK: - Snapshot the refresher compares

    func test_the_features_snapshot_changes_when_a_plan_unlocks_a_feature() {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.invalid")!, securityContext: _OneloSecurityContext())
        let features = OneloFeatures(client: client)
        features._applyResolveResult(["team-report": ["status": "upsell"]])
        let before = features.snapshotKey()
        features._applyResolveResult(["team-report": ["status": "upsell"]])
        XCTAssertEqual(features.snapshotKey(), before)
        features._applyResolveResult(["team-report": ["status": "enabled"]])
        XCTAssertNotEqual(features.snapshotKey(), before)
    }
}
