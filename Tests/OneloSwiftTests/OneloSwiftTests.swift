import XCTest
@testable import OneloSwift

@MainActor
final class OneloSwiftTests: XCTestCase {

    func test_AuthSkeletonView_exists_and_renders() {
        // AuthSkeletonView must be accessible from @testable import.
        // This test fails to compile until the view is created.
        let _ = AuthSkeletonView()
    }
}
