import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Color {
    /// Parse a CSS-style hex string ("#RRGGBB", "RRGGBB", or "#RGB"). Returns nil
    /// on malformed input so callers can fall back to a default. Used to paint the
    /// auth view with the branding `checkout_bg_color` from `/api/sdk/config` (#26).
    init?(oneloHex: String) {
        var s = oneloHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() } // #RGB → #RRGGBB
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0
        )
    }
}

/// Visual configuration for OneloAuthView.
/// Pass a customised instance to match your app's design system.
///
/// #681: every colour and the corner radius are OPTIONAL overrides. `nil` (the
/// default) means "use the app's brand tokens" from `/api/sdk/config`, so the
/// native form matches the hosted pages and the Branding page without any code.
/// Set a value only to deliberately override the Branding.
public struct OneloAuthConfig {
    // MARK: - Colors (nil = brand tokens)
    /// Buttons, links and focus rings. nil → `button_bg`.
    public var accentColor: Color?
    /// Main background of the auth sheet. nil → `page_bg`.
    public var backgroundColor: Color?
    /// Input field background. nil → `card_bg`.
    public var surfaceColor: Color?
    /// Primary text. nil → `text`.
    public var textColor: Color?
    /// Secondary text (subtitles, placeholders, footer). nil → `text_muted`.
    public var subtitleColor: Color?
    /// Text inside primary action buttons. nil → `button_text`.
    public var buttonForegroundColor: Color?
    /// Input field border. nil → `border`.
    public var inputBorderColor: Color?
    /// Border width of input fields. Set to 0 to remove border.
    public var inputBorderWidth: CGFloat

    // MARK: - Branding
    /// Optional logo shown at the top of the view.
    public var appLogo: Image?
    /// App name shown below the logo. Pass "" to hide.
    public var appName: String

    // MARK: - Shape & spacing
    /// Corner radius of buttons and input fields. nil → `button_radius` for
    /// buttons and `field_radius` for inputs.
    public var cornerRadius: CGFloat?
    /// Height of primary action buttons.
    public var buttonHeight: CGFloat
    /// Height of text input fields.
    public var inputHeight: CGFloat
    /// Padding around the content area.
    public var contentPadding: EdgeInsets
    /// Vertical spacing between form elements.
    public var itemSpacing: CGFloat

    public init(
        accentColor: Color? = nil,
        backgroundColor: Color? = nil,
        surfaceColor: Color? = nil,
        textColor: Color? = nil,
        subtitleColor: Color? = nil,
        buttonForegroundColor: Color? = nil,
        inputBorderColor: Color? = nil,
        inputBorderWidth: CGFloat = 1,
        appLogo: Image? = nil,
        appName: String = "",
        cornerRadius: CGFloat? = nil,
        buttonHeight: CGFloat = 48,
        inputHeight: CGFloat = 48,
        contentPadding: EdgeInsets = EdgeInsets(top: 32, leading: 24, bottom: 24, trailing: 24),
        itemSpacing: CGFloat = 12
    ) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.surfaceColor = surfaceColor
        self.textColor = textColor
        self.subtitleColor = subtitleColor
        self.buttonForegroundColor = buttonForegroundColor
        self.inputBorderColor = inputBorderColor
        self.inputBorderWidth = inputBorderWidth
        self.appLogo = appLogo
        self.appName = appName
        self.cornerRadius = cornerRadius
        self.buttonHeight = buttonHeight
        self.inputHeight = inputHeight
        self.contentPadding = contentPadding
        self.itemSpacing = itemSpacing
    }

    /// Default config — everything from the app's brand tokens, no logo.
    public static let `default` = OneloAuthConfig()

    /// Kept for source compatibility. Identical to `.default`: the hosted pages
    /// and this form both wear the app's Branding (#681), so there is no separate
    /// "Onelo-branded" palette to lock to.
    public static let oneloBranded = OneloAuthConfig()
}

/// `OneloAuthConfig` resolved against the app's brand tokens (#681): every
/// value concrete. The native form's subviews read this, never the raw config.
struct OneloAuthStyle {
    var accentColor: Color
    var backgroundColor: Color
    var surfaceColor: Color
    var textColor: Color
    var subtitleColor: Color
    var buttonForegroundColor: Color
    var inputBorderColor: Color
    var inputBorderWidth: CGFloat
    var appLogo: Image?
    var appName: String
    /// Buttons.
    var cornerRadius: CGFloat
    /// Input fields.
    var fieldCornerRadius: CGFloat
    var buttonHeight: CGFloat
    var inputHeight: CGFloat
    var contentPadding: EdgeInsets
    var itemSpacing: CGFloat
    var palette: OneloBrandPalette

    init(config c: OneloAuthConfig, tokens: OneloBrandTokens) {
        let p = OneloBrandPalette(tokens)
        palette = p
        accentColor = c.accentColor ?? p.buttonBg
        backgroundColor = c.backgroundColor ?? p.pageBg
        surfaceColor = c.surfaceColor ?? p.cardBg
        textColor = c.textColor ?? p.text
        subtitleColor = c.subtitleColor ?? p.textMuted
        buttonForegroundColor = c.buttonForegroundColor ?? p.buttonText
        inputBorderColor = c.inputBorderColor ?? p.border
        inputBorderWidth = c.inputBorderWidth
        appLogo = c.appLogo
        appName = c.appName
        cornerRadius = c.cornerRadius ?? p.buttonRadius
        fieldCornerRadius = c.cornerRadius ?? p.fieldRadius
        buttonHeight = c.buttonHeight
        inputHeight = c.inputHeight
        contentPadding = c.contentPadding
        itemSpacing = c.itemSpacing
    }
}
