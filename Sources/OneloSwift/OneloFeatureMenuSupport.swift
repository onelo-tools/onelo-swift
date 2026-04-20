#if canImport(AppKit)
import AppKit

public extension FeatureState {
    /// Returns an NSAttributedString for use as NSMenuItem.attributedTitle.
    /// Appends a colored pill-style badge for New / Beta / Coming Soon statuses.
    ///
    /// Usage:
    ///   menuItem.attributedTitle = chatFeature.menuAttributedTitle("Chat...")
    func menuAttributedTitle(_ base: String) -> NSAttributedString {
        guard let label = badgeLabel else {
            return NSAttributedString(string: base)
        }

        let result = NSMutableAttributedString(string: base + "  ")

        let badgeText = " \(label) "
        let badge = NSMutableAttributedString(string: badgeText)

        let badgeColor = _badgeNSColor
        badge.addAttributes([
            .foregroundColor: badgeColor,
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .backgroundColor: badgeColor.withAlphaComponent(0.15),
        ], range: NSRange(location: 0, length: badgeText.count))

        result.append(badge)
        return result
    }

    private var _badgeNSColor: NSColor {
        switch status {
        case .new:         return NSColor(red: 0.78, green: 0.55, blue: 1.0, alpha: 1)  // purple
        case .beta:        return NSColor(red: 0.42, green: 0.78, blue: 1.0, alpha: 1)  // sky
        case .coming_soon: return NSColor(red: 1.0,  green: 0.75, blue: 0.28, alpha: 1) // amber
        default:           return .labelColor
        }
    }
}
#endif
