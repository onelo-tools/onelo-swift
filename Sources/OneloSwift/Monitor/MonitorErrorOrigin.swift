import Foundation

/// Apple / runtime Swift modules — frames in them are never "someone's code".
private let _runtimeModules: Set<String> = [
    "Swift", "SwiftUI", "Foundation", "Combine", "_Concurrency", "AppKit", "UIKit",
    "Dispatch", "os", "CoreFoundation", "ObjectiveC", "Darwin", "Observation",
    "_StringProcessing", "SwiftUICore",
]

/// The module a Swift-mangled symbol belongs to (`$s10OneloSwift…` → "OneloSwift",
/// `$ss…` → "Swift"), or nil for a C / Objective-C / unsymbolicated frame.
func _swiftModule(ofMangled symbol: String) -> String? {
    var s = Substring(symbol)
    for prefix in ["$s", "_$s", "$S", "_$S"] where s.hasPrefix(prefix) {
        s = s.dropFirst(prefix.count)
        if s.hasPrefix("s") { return "Swift" }
        if s.hasPrefix("So") { return "ObjectiveC" }
        let digits = s.prefix(while: { $0.isNumber })
        guard let n = Int(digits), n > 0 else { return nil }
        let rest = s.dropFirst(digits.count)
        return rest.count >= n ? String(rest.prefix(n)) : nil
    }
    return nil
}

/// Whose error is an uncaught crash — the app's or the Onelo SDK's (#548)?
/// Sent as `meta.origin` so the backend keeps the SDK's own errors out of the
/// developer's Monitor data.
///
/// SwiftPM links `OneloSwift` INTO the app binary, so a frame's image name
/// cannot tell them apart; the mangled symbol's module can. The frames of the
/// capture machinery itself are skipped, then the first frame in a non-runtime
/// Swift module decides: `OneloSwift` → `onelo_sdk`, anything else → `app`.
/// A stripped build (no symbols) classifies as `app`.
func monitorErrorOrigin(frames: [MonitorStackFrame]) -> String {
    for frame in frames {
        guard let symbol = frame.symbol else { continue }
        if symbol.contains("MonitorCrashCapture") || symbol.contains("MonitorBacktrace")
            || symbol.contains("OneloMonitor") || symbol.contains("sigtramp") {
            continue
        }
        guard let module = _swiftModule(ofMangled: symbol), !_runtimeModules.contains(module) else {
            continue
        }
        return module == "OneloSwift" ? "onelo_sdk" : "app"
    }
    return "app"
}
