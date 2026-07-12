#if canImport(AppKit)
import AppKit

public extension FeatureState {
    /// Returns an NSAttributedString for use as NSMenuItem.attributedTitle.
    /// Appends a colored badge for New / Beta / Coming Soon statuses.
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

    /// Creates a fully configured NSMenuItem that handles all feature statuses automatically:
    /// - hidden    → returns nil (don't add to menu)
    /// - greyed    → visible but disabled (action = nil so autoenablesItems won't
    ///               re-enable it), shows a 🔒 padlock badge so the user sees the
    ///               feature is locked. Never routed through the upsell-clickable branch.
    /// - coming_soon → visible, disabled, shows "Coming Soon" badge
    /// - upsell    → visible, shows "Available in <plan>" badge. When the
    ///               developer enabled the tap-to-upgrade toggle (upgradeCta)
    ///               the item is CLICKABLE and opens the upgrade flow
    ///               (`Onelo.openUpgrade(forPlan:)` via OneloUpgradeRouter:
    ///               subscribers → hosted "Change plan" with the target plan
    ///               highlighted; others → hosted store). Otherwise disabled.
    /// - new/beta  → visible, enabled, shows badge
    /// - enabled   → visible, enabled, no badge
    ///
    /// Usage:
    ///   if let item = chatFeature.menuItem(title: "Chat...", action: #selector(openChat)) {
    ///       menu.addItem(item)
    ///   }
    func menuItem(title: String, action: Selector) -> NSMenuItem? {
        guard isVisible else { return nil }
        // Tap-to-upgrade: route the click to the upgrade flow instead of the
        // feature's own action. Requires the per-feature CTA toggle, a known
        // unlocking plan and a live Onelo instance (router installed).
        if isUpsell, upgradeCta, let plan = requiredPlan,
           OneloUpgradeRouter.shared.isInstalled {
            let item = NSMenuItem(
                title: title,
                action: #selector(OneloUpgradeRouter.handleMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = OneloUpgradeRouter.shared
            item.representedObject = plan
            item.attributedTitle = menuAttributedTitle(title)
            return item
        }
        let item = NSMenuItem(
            title: title,
            action: isEnabled ? action : nil,
            keyEquivalent: ""
        )
        item.attributedTitle = menuAttributedTitle(title)
        return item
    }

    private var _badgeNSColor: NSColor {
        switch status {
        case .new:         return NSColor(red: 0.78, green: 0.55, blue: 1.0, alpha: 1)
        case .beta:        return NSColor(red: 0.42, green: 0.78, blue: 1.0, alpha: 1)
        case .coming_soon: return NSColor(red: 1.0,  green: 0.75, blue: 0.28, alpha: 1)
        case .upsell:      return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        case .greyed:      return NSColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
        default:           return .labelColor
        }
    }
}
#endif
