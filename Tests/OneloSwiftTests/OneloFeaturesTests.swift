import XCTest
@testable import OneloSwift

@MainActor
final class OneloFeaturesTests: XCTestCase {

    func testUnknownFeatureReturnsHidden() {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.com")!)
        let features = OneloFeatures(client: client)
        XCTAssertFalse(features.feature("nonexistent").isEnabled)
        XCTAssertEqual(features.feature("nonexistent").status, .hidden)
    }

    func testIsEnabledReturnsTrueAfterCacheSet() {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.com")!)
        let features = OneloFeatures(client: client)
        features._setCache(["export-button": .enabled])
        XCTAssertTrue(features.feature("export-button").isEnabled)
    }

    func testStatusReturnsCorrectValue() {
        let client = _OneloHTTPClient(publishableKey: "pk_test", baseURL: URL(string: "https://example.com")!)
        let features = OneloFeatures(client: client)
        features._setCache(["dark-mode": .greyed])
        XCTAssertEqual(features.feature("dark-mode").status, .greyed)
    }
}
