import Foundation

/// App-level identifiers that are auto-attached to every monitor event.
///
/// `appVersion` / `appBuild` come from the host app's `Info.plist`. Note:
/// inside an app extension or widget, `Bundle.main` is the *extension*
/// bundle, not the parent app — devs aware of this should pass an explicit
/// override via `OneloConfig.appVersion`.
enum MonitorAppContext {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var bundleId: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    static var sdkName: String { "onelo-swift" }

    static var sdkVersion: String { OneloSDK.sdkVersion }
}
