import XCTest
import SwiftUI
@testable import OneloSwift

/// #681 — the SDK's native chrome is painted from the backend's `brand_tokens`.
/// Pure: decodes config / initiate bodies and maps tokens → colours, radii and
/// resolved auth styles. No Onelo / OneloAuth construction (keychain prompts).
final class BrandTokensTests: XCTestCase {

    private let base = #""supabase_url":"https://x.supabase.co","supabase_anon_key":"k","tenant_id":"t""#
    private let tokensJSON = #"""
    {"version":1,"page_bg":"#f5f5f4","brand":"#e4007c","card_bg":"#ffffff","text":"#111111",
     "text_muted":"rgba(17,17,17,0.65)","border":"#e4e4e7","button_bg":"#00aa55","button_text":"#010101",
     "button_radius":3,"field_radius":7,"card_radius":21,"body_font":"'Poppins', sans-serif",
     "heading_font":"'Lato', sans-serif","spinner_track":"rgba(0,0,0,0.12)","light_bg":true}
    """#

    private func config(_ extra: String) throws -> ResolvedConfig {
        try JSONDecoder().decode(ResolvedConfig.self, from: Data("{\(base)\(extra)}".utf8))
    }

    func testConfigDecodesBrandTokens() throws {
        let t = try config(",\"primary_color\":\"#f97316\",\"brand_tokens\":\(tokensJSON)").brandTokens
        XCTAssertEqual(t.buttonBg, "#00aa55")
        XCTAssertEqual(t.buttonRadius, 3)
        XCTAssertEqual(t.textMuted, "rgba(17,17,17,0.65)")
        XCTAssertTrue(t.lightBg)
    }

    func testOlderBackendSeedsTokensFromLegacyColours() throws {
        let t = try config(",\"primary_color\":\"#0055ff\",\"checkout_bg_color\":\"#ffffff\"").brandTokens
        XCTAssertEqual(t.brand, "#0055ff")
        XCTAssertEqual(t.buttonBg, "#0055ff")
        XCTAssertEqual(t.pageBg, "#ffffff")
        XCTAssertTrue(t.lightBg)
        XCTAssertEqual(t.text, "#111111")
    }

    func testNeutralBeforeConfigIsNeverOrange() throws {
        XCTAssertEqual(try config("").brandTokens, OneloBrandTokens.neutral)
        XCTAssertNotEqual(OneloBrandTokens.neutral.brand.lowercased(), "#f97316")
        XCTAssertNotEqual(OneloBrandPalette(.neutral).buttonBg, Color(oneloHex: "#f97316"))
    }

    func testInitiateResponseCarriesTokens() {
        let body = Data("{\"hosted_url\":\"https://x\",\"brand_tokens\":\(tokensJSON)}".utf8)
        XCTAssertEqual(OneloBrandTokens.from(responseData: body)?.cardRadius, 21)
        XCTAssertNil(OneloBrandTokens.from(responseData: Data("{\"hosted_url\":\"https://x\"}".utf8)))
    }

    func testPaletteMapsTokensToChromeColours() throws {
        let t = try config(",\"brand_tokens\":\(tokensJSON)").brandTokens
        let p = OneloBrandPalette(t)
        XCTAssertEqual(p.buttonBg, Color(oneloHex: "#00aa55"))
        XCTAssertEqual(p.buttonText, Color(oneloHex: "#010101"))
        XCTAssertEqual(p.pageBg, Color(oneloHex: "#f5f5f4"))
        XCTAssertEqual(p.brand, Color(oneloHex: "#e4007c"))
        XCTAssertEqual(p.buttonRadius, 3)
        XCTAssertEqual(p.cardRadius, 21)
        XCTAssertEqual(p.textMuted, Color(.sRGB, red: 17/255, green: 17/255, blue: 17/255, opacity: 0.65))
    }

    func testAuthConfigNilFieldsResolveFromTokensAndOverridesWin() throws {
        let t = try config(",\"brand_tokens\":\(tokensJSON)").brandTokens
        let style = OneloAuthStyle(config: .default, tokens: t)
        XCTAssertEqual(style.accentColor, Color(oneloHex: "#00aa55"))
        XCTAssertEqual(style.buttonForegroundColor, Color(oneloHex: "#010101"))
        XCTAssertEqual(style.backgroundColor, Color(oneloHex: "#f5f5f4"))
        XCTAssertEqual(style.cornerRadius, 3)
        XCTAssertEqual(style.fieldCornerRadius, 7)
        var custom = OneloAuthConfig()
        custom.accentColor = .red
        custom.cornerRadius = 20
        let over = OneloAuthStyle(config: custom, tokens: t)
        XCTAssertEqual(over.accentColor, .red)
        XCTAssertEqual(over.cornerRadius, 20)
        // Existing presets still compile and defer to the tokens.
        XCTAssertNil(OneloAuthConfig.oneloBranded.accentColor)
    }

    func testSkeletonHtmlIsPaintedFromTokens() throws {
        let t = try config(",\"brand_tokens\":\(tokensJSON)").brandTokens
        let html = oneloPortalSkeletonHTML(t)
        XCTAssertTrue(html.contains("background:#f5f5f4"))
        // #948: light page → soft blocks take the border colour (card = ground).
        XCTAssertTrue(html.contains(".sk{background-color:#e4e4e7"))
        XCTAssertTrue(html.contains("border-radius:21px"))
        XCTAssertFalse(html.contains("rgba(255,255,255,0.04)"))
        var dark = t
        dark.lightBg = false
        XCTAssertTrue(dark.skeletonCSS.contains(".sk{background-color:\(t.cardBg)"))
    }
}
