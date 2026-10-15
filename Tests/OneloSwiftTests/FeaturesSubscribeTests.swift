import XCTest
@testable import OneloSwift

/// #606 — the non-SwiftUI change callback, parity with `features.subscribe` in
/// the JS / Electron / React Native SDKs. Builds `OneloFeatures` on a bare
/// client: no `Onelo(...)`, no `OneloAuth(config:)`, no keychain.
@MainActor
final class FeaturesSubscribeTests: XCTestCase {

    private func makeFeatures() -> OneloFeatures {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.com")!, securityContext: _OneloSecurityContext())
        return OneloFeatures(client: client)
    }

    func test_a_listener_fires_on_a_snapshot_change_and_sees_the_new_state() {
        let features = makeFeatures()
        var seen: [FeatureStatus] = []
        let stop = features.subscribe { seen.append(features.feature("export").status) }
        features._applyResolveResult(["export": ["status": "enabled"]])
        XCTAssertEqual(seen, [.enabled])
        stop()
    }

    func test_unsubscribe_stops_the_listener() {
        let features = makeFeatures()
        var calls = 0
        let stop = features.subscribe { calls += 1 }
        features._setCache(["a": .enabled])
        stop()
        features._setCache(["a": .greyed])
        XCTAssertEqual(calls, 1)
    }

    func test_a_listener_may_unsubscribe_itself_while_others_still_fire() {
        let features = makeFeatures()
        var first = 0, second = 0
        var stopFirst: (@MainActor () -> Void)?
        stopFirst = features.subscribe { first += 1; stopFirst?() }
        _ = features.subscribe { second += 1 }
        features._setCache(["a": .enabled])
        features._setCache(["a": .greyed])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
    }
}
