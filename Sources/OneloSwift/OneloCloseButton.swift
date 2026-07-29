import SwiftUI

/// The unified close affordance for every Onelo SDK modal (feedback sheet,
/// customer portal, …): an SF Symbol `xmark`, neutral (`.secondary`), no Onelo
/// branding. It must LOOK IDENTICAL everywhere — the exact same gray glyph.
///
/// The only difference between the two `Style`s is INVISIBLE — it does not change
/// how the glyph looks, only how the host supplies neutral colour + a tap target:
///
///  - `.toolbar` — hosted inside `.toolbar { ToolbarItem { … } }` (feedback sheet).
///    The system bar renders the glyph neutral and gives it a ≥44pt hit target,
///    so this variant is just the bare glyph.
///
///  - `.overlay` — a bare overlay pinned over a `WKWebView` (customer/account
///    portal). There is no toolbar, so this variant adds two INVISIBLE things to
///    match the toolbar's behaviour: `.buttonStyle(.plain)` so the glyph renders
///    the SAME neutral gray (without it the bare Button tints iOS accent-blue),
///    and a 44×44 `.contentShape(Rectangle())` hit target so near-miss taps don't
///    fall through to the web view and the "X" appears not to close (#40). The
///    glyph itself — symbol, size, weight, colour — is byte-for-byte the same as
///    the toolbar one, so the two X's are visually identical.
struct OneloCloseButton: View {
    enum Style { case toolbar, overlay }

    let style: Style
    let action: () -> Void

    init(style: Style = .toolbar, action: @escaping () -> Void) {
        self.style = style
        self.action = action
    }

    var body: some View {
        switch style {
        case .toolbar:
            Button(action: action) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close")
        case .overlay:
            Button(action: action) {
                // Identical glyph to `.toolbar` — no circle, no material, default
                // size/weight — wrapped in an INVISIBLE 44×44 hit target so it's
                // reliably tappable over the WKWebView without changing its look.
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}
