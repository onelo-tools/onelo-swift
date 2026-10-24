import XCTest
@testable import OneloSwift

/// #929 — native referral capture: nothing kept without consent, consented
/// click kept and claimed for the signed-in user, forwarded winner kept.
/// Builds only `OneloAffiliates` (no `Onelo(...)`, no keychain).
final class AffiliatesCaptureTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        var calls: [(String, [String: Any])] = []
        var reply: (String) -> (Int, [String: Any]) = { _ in (200, [:]) }
    }

    let click = "11111111-2222-3333-4444-555555555555"
    var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "affiliates-929-\(UUID().uuidString)")
    }

    func make(_ rec: Recorder, signedIn: Bool = true) -> OneloAffiliates {
        OneloAffiliates(
            publishableKey: "onelo_pk_x", defaults: defaults,
            post: { path, body in rec.calls.append((path, body)); return rec.reply(path) },
            session: { signedIn ? (accessToken: "tok", userId: "u1") : nil }
        )
    }

    func testRefusalStoresNothingAndOnlyCounts() async {
        let rec = Recorder()
        let kept = await make(rec).capture(url: URL(string: "myapp://open?ref=abcdef1234")!, consent: false)
        XCTAssertFalse(kept)
        XCTAssertNil(defaults.object(forKey: OneloAffiliates.storageKey))
        XCTAssertEqual(rec.calls.map(\.0), ["/v1/sdk/affiliates/refused"])
    }

    func testConsentedRefIsKeptAndClaimed() async {
        let rec = Recorder()
        let id = click
        rec.reply = { path in path.hasSuffix("/click") ? (200, ["click_id": id, "kept": false]) : (200, ["claimed": true]) }
        let aff = make(rec)
        let kept = await aff.capture(url: URL(string: "https://app.test/x?ref=ABCDEF1234")!, consent: true)
        XCTAssertTrue(kept)
        XCTAssertEqual(rec.calls.map(\.0), ["/v1/sdk/affiliates/click", "/v1/sdk/affiliates/claim"])
        XCTAssertEqual(rec.calls[0].1["code"] as? String, "abcdef1234")
        XCTAssertEqual(rec.calls[0].1["source"] as? String, "sdk")
        XCTAssertEqual(rec.calls[1].1["clickId"] as? String, click)
        XCTAssertEqual(aff.kept(), .init(clickId: click, claimedFor: "u1"))
        await aff.claimForSession()
        XCTAssertEqual(rec.calls.count, 2, "claimed once per user")
    }

    func testForwardedClickReplacesAnEarlierOne() async {
        let rec = Recorder()
        defaults.set(["click_id": "99999999-2222-3333-4444-555555555555"], forKey: OneloAffiliates.storageKey)
        let aff = make(rec, signedIn: false)
        _ = await aff.capture(url: URL(string: "myapp://open?onelo_click=\(click)")!, consent: true)
        XCTAssertEqual(aff.kept()?.clickId, click)
        XCTAssertTrue(rec.calls.isEmpty)
    }

    func testExistingClickIsSentSoOneloAppliesTheWinner() async {
        let rec = Recorder()
        defaults.set(["click_id": click], forKey: OneloAffiliates.storageKey)
        let id = click
        rec.reply = { _ in (200, ["click_id": id, "kept": true]) }
        _ = await make(rec, signedIn: false).capture(url: URL(string: "myapp://open?ref=zzzzzz9999")!, consent: true)
        XCTAssertEqual(rec.calls.first?.1["existing"] as? String, click)
    }

    func testJunkParametersAreIgnored() async {
        let rec = Recorder()
        let kept = await make(rec).capture(url: URL(string: "myapp://open?ref=%3Cx%3E&onelo_click=nope")!, consent: true)
        XCTAssertFalse(kept)
        XCTAssertTrue(rec.calls.isEmpty)
    }
}
