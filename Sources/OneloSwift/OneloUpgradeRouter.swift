import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Routes taps on plan-upsell UI (e.g. the "Available in <plan>" menu badge)
/// to the `Onelo` instance that can resolve the upgrade URL.
///
/// Why a singleton: `FeatureState` is a value type with no reference to the
/// SDK client, and `NSMenuItem` needs a retained object target for its
/// action. `Onelo.init` installs the handler; when none is installed (custom
/// integrations that bypass the orchestrator) upsell menu items stay
/// disabled — informational, exactly like before 3.56.
public final class OneloUpgradeRouter: NSObject {
    public static let shared = OneloUpgradeRouter()
    private var handler: ((String) -> Void)?
    private override init() {}

    var isInstalled: Bool { handler != nil }

    func install(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    /// Opens the upgrade flow for `plan` via the installed handler.
    /// No-op when no `Onelo` instance has been created.
    public func openUpgrade(plan: String) { handler?(plan) }

    #if canImport(AppKit)
    /// NSMenuItem action — `representedObject` carries the required plan name.
    @objc func handleMenuItem(_ sender: NSMenuItem) {
        guard let plan = sender.representedObject as? String else { return }
        openUpgrade(plan: plan)
    }
    #endif
}
