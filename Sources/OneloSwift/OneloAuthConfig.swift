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
public struct OneloAuthConfig {
    // MARK: - Colors
    /// Color used for buttons, links, and focus rings.
    public var accentColor: Color
    /// Main background color of the auth sheet.
    public var backgroundColor: Color
    /// Background color of input fields.
    public var surfaceColor: Color
    /// Primary text color.
    public var textColor: Color
    /// Secondary text color (subtitles, placeholders, footer).
    public var subtitleColor: Color
    /// Foreground color of text inside primary action buttons.
    public var buttonForegroundColor: Color
    /// Border color of input fields.
    public var inputBorderColor: Color
    /// Border width of input fields. Set to 0 to remove border.
    public var inputBorderWidth: CGFloat

    // MARK: - Branding
    /// Optional logo shown at the top of the view.
    public var appLogo: Image?
    /// App name shown below the logo. Pass "" to hide.
    public var appName: String

    // MARK: - Shape & spacing
    /// Corner radius applied to buttons and input fields.
    public var cornerRadius: CGFloat
    /// Height of primary action buttons.
    public var buttonHeight: CGFloat
    /// Height of text input fields.
    public var inputHeight: CGFloat
    /// Padding around the content area.
    public var contentPadding: EdgeInsets
    /// Vertical spacing between form elements.
    public var itemSpacing: CGFloat

    // MARK: - Presets

    /// Onelo brand orange (#f97316)
    private static let oneloOrange = Color(red: 249/255, green: 115/255, blue: 22/255)

    public init(
        accentColor: Color = Color(red: 249/255, green: 115/255, blue: 22/255),
        backgroundColor: Color = {
            #if canImport(UIKit)
            return Color(uiColor: .systemBackground)
            #else
            return Color(nsColor: .windowBackgroundColor)
            #endif
        }(),
        surfaceColor: Color = {
            #if canImport(UIKit)
            return Color(uiColor: .secondarySystemBackground)
            #else
            return Color(nsColor: .controlBackgroundColor)
            #endif
        }(),
        textColor: Color = .primary,
        subtitleColor: Color = .secondary,
        buttonForegroundColor: Color = .white,
        inputBorderColor: Color = Color.primary.opacity(0.1),
        inputBorderWidth: CGFloat = 1,
        appLogo: Image? = nil,
        appName: String = "",
        cornerRadius: CGFloat = 10,
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

    /// Default config — Onelo brand indigo accent, system colors, no logo.
    public static let `default` = OneloAuthConfig()

    /// Locked Onelo brand config used automatically on free plan.
    /// Identical to `.default` — exists so the intent is explicit in code.
    public static let oneloBranded = OneloAuthConfig(
        accentColor: Self.oneloOrange,
        buttonForegroundColor: .white,
        inputBorderColor: Color.primary.opacity(0.1),
        inputBorderWidth: 1
    )
}
