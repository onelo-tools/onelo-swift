import XCTest
@testable import OneloSwift

final class OneloFeaturesTests: XCTestCase {

    func testUnknownFeatureReturnsHidden() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        let features = OneloFeatures(client: client)
        XCTAssertFalse(features.isEnabled("nonexistent"))
        XCTAssertEqual(features.status("nonexistent"), .hidden)
    }

    func testIsEnabledReturnsTrueAfterCacheSet() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        let features = OneloFeatures(client: client)
        features._cache = ["export-button": .enabled]
        XCTAssertTrue(features.isEnabled("export-button"))
    }

    func testStatusReturnsCorrectValue() {
        let client = _OneloHTTPClient(publishableKey: "pk_test")
        let features = OneloFeatures(client: client)
        features._cache = ["dark-mode": .greyed]
        XCTAssertEqual(features.status("dark-mode"), .greyed)
    }
}
