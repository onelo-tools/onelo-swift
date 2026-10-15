import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The app's resolved brand tokens (#681) — the ONE model every piece of this
/// SDK's native chrome is painted from: spinner / progress, the close ✕, retry
/// and "Sign In" buttons, skeleton placeholders, error screens, the auth sheet
/// container, portal / feedback / store backgrounds.
///
/// The backend resolves the app's Branding once and sends it as `brand_tokens`
/// on `/api/sdk/config` and on the store / portal / manage / upgrade initiate
/// responses. An older backend sends only `primary_color` + `checkout_bg_color`;
/// those seed the same shape with the registry's bg-aware defaults. Before any
/// response arrives the SDK paints `.neutral` — a grey accent on the dark page
/// default, never Onelo orange. `OneloAuth.brandTokens` holds the current value
/// and caches it in the keychain for the next launch's first paint.
public struct OneloBrandTokens: Codable, Equatable, Sendable {
    public var version: Int
    public var pageBg: String
    public var brand: String
    public var cardBg: String
    public var text: String
    /// May be an `rgba(...)` string.
    public var textMuted: String
    public var border: String
    public var buttonBg: String
    public var buttonText: String
    public var buttonRadius: Double
    public var fieldRadius: Double
    public var cardRadius: Double
    /// CSS font-family stack; native views use its first family when installed.
    public var bodyFont: String
    public var headingFont: String
    /// May be an `rgba(...)` string.
    public var spinnerTrack: String
    public var lightBg: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case pageBg = "page_bg"
        case brand
        case cardBg = "card_bg"
        case text
        case textMuted = "text_muted"
        case border
        case buttonBg = "button_bg"
        case buttonText = "button_text"
        case buttonRadius = "button_radius"
        case fieldRadius = "field_radius"
        case cardRadius = "card_radius"
        case bodyFont = "body_font"
        case headingFont = "heading_font"
        case spinnerTrack = "spinner_track"
        case lightBg = "light_bg"
    }

    public init(
        version: Int = 1, pageBg: String, brand: String, cardBg: String, text: String,
        textMuted: String, border: String, buttonBg: String, buttonText: String,
        buttonRadius: Double, fieldRadius: Double, cardRadius: Double,
        bodyFont: String, headingFont: String, spinnerTrack: String, lightBg: Bool
    ) {
        self.version = version; self.pageBg = pageBg; self.brand = brand; self.cardBg = cardBg
        self.text = text; self.textMuted = textMuted; self.border = border
        self.buttonBg = buttonBg; self.buttonText = buttonText
        self.buttonRadius = buttonRadius; self.fieldRadius = fieldRadius; self.cardRadius = cardRadius
        self.bodyFont = bodyFont; self.headingFont = headingFont
        self.spinnerTrack = spinnerTrack; self.lightBg = lightBg
    }

    private static let systemFont = "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"

    /// Before config arrives (and for an app the SDK cannot identify): the page
    /// default with the registry's unknown-app accent — neutral, never orange.
    public static let neutral = OneloBrandTokens(
        pageBg: "#111111", brand: "#a1a1aa", cardBg: "#1a1a1a", text: "#ffffff",
        textMuted: "rgba(255,255,255,0.6)", border: "#2a2a2a",
        buttonBg: "#a1a1aa", buttonText: "#111111",
        buttonRadius: 14, fieldRadius: 14, cardRadius: 14,
        bodyFont: systemFont, headingFont: systemFont,
        spinnerTrack: "rgba(255,255,255,0.18)", lightBg: false
    )

    /// The shape an older backend implies: its two colours + the registry's
    /// bg-aware defaults (branding_registry.json card/text/border defaults).
    public static func fromLegacy(primaryColor: String?, pageBg: String?) -> OneloBrandTokens {
        var t = neutral
        let bg = pageBg.flatMap { oneloIsHex($0) ? $0.trimmingCharacters(in: .whitespaces) : nil } ?? neutral.pageBg
        let light = oneloHexIsLight(bg) ?? false
        t.pageBg = bg
        t.lightBg = light
        if light {
            t.cardBg = "#ffffff"; t.text = "#111111"; t.textMuted = "rgba(17,17,17,0.65)"
            t.border = "#e4e4e7"; t.spinnerTrack = "rgba(0,0,0,0.12)"
        }
        if let p = primaryColor, oneloIsHex(p) {
            let v = p.trimmingCharacters(in: .whitespaces)
            t.brand = v; t.buttonBg = v; t.buttonText = "#ffffff"
        }
        return t
    }

    /// Tolerant decode: a missing or malformed field keeps the `.neutral` value
    /// (never fails the whole config over one bad token).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = OneloBrandTokens.decode(c, fallback: .neutral)
    }

    /// Decode over a specific fallback (the legacy-seeded shape of the same response).
    static func decode(_ c: KeyedDecodingContainer<CodingKeys>, fallback f: OneloBrandTokens) -> OneloBrandTokens {
        func color(_ k: CodingKeys, _ d: String) -> String {
            guard let v = try? c.decode(String.self, forKey: k), oneloIsCSSColor(v) else { return d }
            return v.trimmingCharacters(in: .whitespaces)
        }
        func num(_ k: CodingKeys, _ d: Double) -> Double {
            guard let v = try? c.decode(Double.self, forKey: k), v.isFinite, v >= 0, v <= 100 else { return d }
            return v
        }
        func font(_ k: CodingKeys, _ d: String) -> String {
            guard let raw = try? c.decode(String.self, forKey: k) else { return d }
            let v = raw.trimmingCharacters(in: .whitespaces)
            return oneloIsFontStack(v) ? v : d
        }
        return OneloBrandTokens(
            version: (try? c.decode(Int.self, forKey: .version)) ?? 1,
            pageBg: color(.pageBg, f.pageBg), brand: color(.brand, f.brand),
            cardBg: color(.cardBg, f.cardBg), text: color(.text, f.text),
            textMuted: color(.textMuted, f.textMuted), border: color(.border, f.border),
            buttonBg: color(.buttonBg, f.buttonBg), buttonText: color(.buttonText, f.buttonText),
            buttonRadius: num(.buttonRadius, f.buttonRadius), fieldRadius: num(.fieldRadius, f.fieldRadius),
            cardRadius: num(.cardRadius, f.cardRadius),
            bodyFont: font(.bodyFont, f.bodyFont), headingFont: font(.headingFont, f.headingFont),
            spinnerTrack: color(.spinnerTrack, f.spinnerTrack),
            lightBg: (try? c.decode(Bool.self, forKey: .lightBg)) ?? f.lightBg
        )
    }

    /// The tokens a config / initiate response body carries: its `brand_tokens`
    /// when present, else the shape its legacy colour fields imply, else nil.
    public static func from(responseData data: Data) -> OneloBrandTokens? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return from(json: obj)
    }

    /// Same as `from(responseData:)` for an already-parsed JSON object.
    public static func from(json obj: [String: Any]) -> OneloBrandTokens? {
        let primary = obj["primary_color"] as? String
        let bg = obj["checkout_bg_color"] as? String
        let legacy = fromLegacy(primaryColor: primary, pageBg: bg)
        if let bt = obj["brand_tokens"] as? [String: Any],
           let btData = try? JSONSerialization.data(withJSONObject: bt) {
            let d = JSONDecoder()
            d.userInfo[SeededBrandTokens.fallbackKey] = legacy
            if let parsed = try? d.decode(SeededBrandTokens.self, from: btData) { return parsed.value }
        }
        let hasLegacy = (primary.map(oneloIsHex) ?? false) || (bg.map(oneloIsHex) ?? false)
        return hasLegacy ? legacy : nil
    }
}

/// Decodes a `brand_tokens` object over a given fallback (`userInfo`).
struct SeededBrandTokens: Decodable {
    static let fallbackKey = CodingUserInfoKey(rawValue: "onelo.brandTokens.fallback")!
    let value: OneloBrandTokens
    init(from decoder: Decoder) throws {
        let fb = decoder.userInfo[SeededBrandTokens.fallbackKey] as? OneloBrandTokens ?? .neutral
        value = OneloBrandTokens.decode(try decoder.container(keyedBy: OneloBrandTokens.CodingKeys.self), fallback: fb)
    }
}

// MARK: - Colour parsing

/// `#rgb` / `#rrggbb` / `#rrggbbaa`.
func oneloIsHex(_ s: String) -> Bool {
    var v = s.trimmingCharacters(in: .whitespaces)
    guard v.hasPrefix("#") else { return false }
    v.removeFirst()
    return [3, 6, 8].contains(v.count) && UInt64(v, radix: 16) != nil
}

/// A colour the SDK may paint: hex or `rgb(a)(…)`.
func oneloIsCSSColor(_ s: String) -> Bool {
    oneloIsHex(s) || oneloRGBA(s) != nil
}

/// The same safe CSS font-stack grammar used by the JS SDK. Font values are
/// interpolated into WebView CSS, so quotes, braces and control characters are
/// rejected instead of being treated as arbitrary CSS.
func oneloIsFontStack(_ s: String) -> Bool {
    let v = s.trimmingCharacters(in: .whitespaces)
    guard !v.isEmpty, v.count <= 200 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ,'\"_-"))
    return v.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Parse `rgb(r,g,b)` / `rgba(r,g,b,a)` into 0…1 components.
func oneloRGBA(_ s: String) -> (Double, Double, Double, Double)? {
    let v = s.trimmingCharacters(in: .whitespaces).lowercased()
    guard v.hasPrefix("rgb"), let open = v.firstIndex(of: "("), v.hasSuffix(")") else { return nil }
    let inner = v[v.index(after: open)..<v.index(before: v.endIndex)]
    let parts = inner.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
    let p = parts.map { $0! }
    return (p[0] / 255, p[1] / 255, p[2] / 255, p.count == 4 ? p[3] : 1)
}

extension Color {
    /// A token colour: hex (via `oneloHex`) or `rgb(a)(…)`. Nil when malformed.
    init?(oneloCSS: String) {
        if let rgba = oneloRGBA(oneloCSS) {
            self = Color(.sRGB, red: rgba.0, green: rgba.1, blue: rgba.2, opacity: rgba.3)
        } else if let c = Color(oneloHex: oneloCSS) {
            self = c
        } else {
            return nil
        }
    }
}

// MARK: - Tokens → native colours / shapes / fonts (pure)

/// The SwiftUI values the SDK's chrome paints with, derived from brand tokens.
/// Pure (no Onelo / OneloAuth), so it is unit-tested directly.
public struct OneloBrandPalette: Equatable {
    public let pageBg: Color
    public let brand: Color
    public let cardBg: Color
    public let text: Color
    public let textMuted: Color
    public let border: Color
    public let buttonBg: Color
    public let buttonText: Color
    public let spinnerTrack: Color
    public let buttonRadius: CGFloat
    public let fieldRadius: CGFloat
    public let cardRadius: CGFloat
    /// First family of `body_font` when installed on this platform, else nil (system font).
    public let bodyFontFamily: String?
    public let headingFontFamily: String?
    public let lightBg: Bool

    public init(_ t: OneloBrandTokens) {
        let n = OneloBrandTokens.neutral
        func c(_ v: String, _ d: String) -> Color { Color(oneloCSS: v) ?? Color(oneloCSS: d)! }
        pageBg = c(t.pageBg, n.pageBg)
        brand = c(t.brand, n.brand)
        cardBg = c(t.cardBg, n.cardBg)
        text = c(t.text, n.text)
        textMuted = c(t.textMuted, n.textMuted)
        border = c(t.border, n.border)
        buttonBg = c(t.buttonBg, n.buttonBg)
        buttonText = c(t.buttonText, n.buttonText)
        spinnerTrack = c(t.spinnerTrack, n.spinnerTrack)
        buttonRadius = CGFloat(t.buttonRadius)
        fieldRadius = CGFloat(t.fieldRadius)
        cardRadius = CGFloat(t.cardRadius)
        bodyFontFamily = oneloInstalledFontFamily(t.bodyFont)
        headingFontFamily = oneloInstalledFontFamily(t.headingFont)
        lightBg = t.lightBg
    }

    /// Body font at `size`: the brand family when installed, else the system font.
    public func bodyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let f = bodyFontFamily { return .custom(f, size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }

    public func headingFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if let f = headingFontFamily { return .custom(f, size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }
}

/// The first family of a CSS font stack, if it is installed on this platform.
func oneloFirstFontFamily(_ stack: String) -> String? {
    guard let first = stack.split(separator: ",").first else { return nil }
    let name = first.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    guard !name.isEmpty, !name.hasPrefix("-"), name != "system-ui", name != "sans-serif", name != "serif" else { return nil }
    return name
}

func oneloInstalledFontFamily(_ stack: String) -> String? {
    guard let name = oneloFirstFontFamily(stack) else { return nil }
    #if canImport(UIKit)
    return UIFont.familyNames.contains(name) ? name : nil
    #else
    return NSFontManager.shared.availableFontFamilies.contains(name) ? name : nil
    #endif
}

// MARK: - Tokens → HTML chrome (pure)

extension OneloBrandTokens {
    /// Shimmer placeholder CSS for srcdoc / loadHTMLString skeletons: `.sk` soft
    /// block, `.strong` field-like block. Base = card / border, sweep = track.
    var skeletonCSS: String {
        let sweep = "background-image:linear-gradient(90deg,transparent 0%,\(spinnerTrack) 50%,transparent 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite"
        return """
        @keyframes onelo-shimmer{0%{background-position:-60vw 0}100%{background-position:100vw 0}}
        .sk{background-color:\(cardBg);\(sweep);border-radius:\(Int(fieldRadius))px}
        .strong{background-color:\(border);\(sweep);border-radius:\(Int(fieldRadius))px}
        """
    }
}

// MARK: - Named status colours

enum OneloStatusTone { case success, danger, warning }

func oneloStatusColor(_ t: OneloBrandTokens, tone: OneloStatusTone) -> Color {
    switch tone {
    case .success: return Color(oneloHex: t.lightBg ? "#15803d" : "#22c55e")!
    case .danger: return Color(oneloHex: t.lightBg ? "#dc2626" : "#f87171")!
    case .warning: return Color(oneloHex: t.lightBg ? "#b45309" : "#fbbf24")!
    }
}

/// Named status colour for errors (branding_registry.json `status.danger`),
/// picked for the page's light / dark ground — the only non-brand colour chrome uses.
func oneloStatusDanger(_ t: OneloBrandTokens) -> Color {
    oneloStatusColor(t, tone: .danger)
}

// MARK: - Environment

private struct OneloBrandTokensKey: EnvironmentKey {
    static let defaultValue: OneloBrandTokens = .neutral
}

extension EnvironmentValues {
    /// The brand tokens SDK chrome below this point paints with (#681). Set by
    /// `OneloAuthView`, the portal and the feedback sheet from `OneloAuth.brandTokens`.
    var oneloBrandTokens: OneloBrandTokens {
        get { self[OneloBrandTokensKey.self] }
        set { self[OneloBrandTokensKey.self] = newValue }
    }
}

// MARK: - Shared HTML chrome (feedback / error pages)

/// HTML-escape a value placed in page text.
func oneloEscapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// An error screen with a "Try again" button that navigates `retryHref` (an SDK
/// sentinel the web view's navigation delegate intercepts). Painted from the
/// brand tokens (#681): page ground, text / muted text, the button pair + radius.
func oneloErrorPageHTML(_ t: OneloBrandTokens, title: String, message: String, retryHref: String, buttonLabel: String = "Try again") -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { height: 100%; }
      body {
        background:\(t.pageBg); color:\(t.text);
        font-family:\(t.bodyFont);
        display: flex; flex-direction: column; align-items: center;
        justify-content: center; text-align: center; padding: 40px 36px;
      }
      .title { font-size: 17px; font-weight: 600; margin-bottom: 10px; font-family:\(t.headingFont); }
      .msg   { font-size: 13px; color:\(t.textMuted); line-height: 1.5; max-width: 320px; margin-bottom: 28px; }
      .btn {
        appearance: none; border: 0; cursor: pointer;
        background:\(t.buttonBg); color:\(t.buttonText); font-size: 14px; font-weight: 600;
        padding: 11px 22px; border-radius:\(Int(t.buttonRadius))px;
      }
      .btn:active { opacity: 0.8; }
    </style>
    </head>
    <body>
      <div class="title">\(oneloEscapeHTML(title))</div>
      <div class="msg">\(oneloEscapeHTML(message))</div>
      <button class="btn" onclick="window.location.href='\(retryHref)'">\(oneloEscapeHTML(buttonLabel))</button>
    </body>
    </html>
    """
}

/// Feedback-form skeleton (icon, title, three type cards, two fields, CTA),
/// painted from the brand tokens (#681).
func oneloFeedbackSkeletonHTML(_ t: OneloBrandTokens) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background:\(t.pageBg); font-family:\(t.bodyFont); padding: 40px 36px 32px; overflow: hidden; }
      \(t.skeletonCSS)
      .icon  { width: 64px; height: 64px; border-radius:\(Int(t.cardRadius))px; margin: 0 auto 16px; }
      .title { width: 220px; height: 22px; margin: 0 auto 40px; }
      .cards { display: flex; gap: 12px; margin-bottom: 32px; }
      .card  { flex: 1; height: 76px; border-radius:\(Int(t.cardRadius))px; }
      .label { width: 60px; height: 13px; margin-bottom: 8px; }
      .input { width: 100%; height: 44px; margin-bottom: 24px; }
      .textarea { width: 100%; height: 110px; margin-bottom: 32px; }
      .btn   { width: 100%; height: 48px; border-radius:\(Int(t.buttonRadius))px; }
    </style>
    </head>
    <body>
      <div class="sk icon"></div>
      <div class="sk title"></div>
      <div class="cards">
        <div class="sk card"></div>
        <div class="sk card"></div>
        <div class="sk card"></div>
      </div>
      <div class="sk label"></div>
      <div class="strong input"></div>
      <div class="sk label"></div>
      <div class="strong textarea"></div>
      <div class="strong btn"></div>
    </body>
    </html>
    """
}
