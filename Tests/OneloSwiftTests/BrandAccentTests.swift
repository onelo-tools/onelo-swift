import XCTest
import SwiftUI
@testable import OneloSwift

/// #601 — SDK-drawn controls shown before a hosted page loads paint the app's
/// Branding "Brand color" from `/api/sdk/config`, and fall back to neutral grey —
/// never Onelo orange — when the app has none. Pure: no Onelo / OneloAuth
/// construction (keychain).
final class BrandAccentTests: XCTestCase {

    private func decode(_ json: String) throws -> ResolvedConfig {
        try JSONDecoder().decode(ResolvedConfig.self, from: Data(json.utf8))
    }

    private let base = #""supabase_url":"https://x.supabase.co","supabase_anon_key":"k","tenant_id":"t""#

    func testConfigDecodesPrimaryColor() throws {
        let cfg = try decode("{\(base),\"primary_color\":\"#E4007C\"}")
        XCTAssertEqual(cfg.primaryColor, "#E4007C")
    }

    func testConfigWithoutPrimaryColorIsNil() throws {
        XCTAssertNil(try decode("{\(base)}").primaryColor)
        XCTAssertNil(try decode("{\(base),\"primary_color\":null}").primaryColor)
    }

    // The accent helpers moved to brand tokens (#681): see BrandTokensTests
    // (palette mapping, neutral-before-config, never orange).
}
