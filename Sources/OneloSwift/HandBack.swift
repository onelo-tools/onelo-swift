import Foundation

/// Store Hand-back (#615) — the ONE decoder for "the hosted page is finished"
/// in this SDK. The hosted store and Customer Portal navigate to
/// `<scheme>://callback?…` (produced by one helper on the page,
/// frontend/lib/store-hand-back.ts, plus the portal's Done):
///   `?code=`                   a purchase finished → exchange the code
///   `?source=store&event=<r>`  a plan switch finished without a code
///                              (plan_switched | switch_scheduled |
///                              plan_switch_pending) — a success
///   `?source=portal[&event=]`  the Customer Portal closed
///   `?error=<code>`            failed, or the link is spent
/// `OneloAuthView` (store / auth) and `handlePortalCallback` (every portal
/// presentation) both decide from this, so a new terminal reaches both.
///
/// Returns nil unless the host is `callback`. The caller checks the scheme.
/// Pure: testable without constructing Onelo / OneloAuth.
enum HandBack: Equatable {
    case purchase(code: String)
    /// Success, never a cancel: the buyer is signed in; the SDK reconciles the plan at once (#659).
    case switched(reason: String)
    case portalClosed(event: String?)
    case error(String)
}

func classifyHandBack(_ url: URL) -> HandBack? {
    guard url.host?.lowercased() == "callback" else { return nil }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
    switch value("source") {
    case "store": return .switched(reason: value("event") ?? "")
    case "portal": return .portalClosed(event: value("event"))
    default: break
    }
    if let code = value("code") { return .purchase(code: code) }
    if let error = value("error") { return .error(error) }
    return nil
}
