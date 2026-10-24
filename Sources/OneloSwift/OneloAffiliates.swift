import Foundation

/// Affiliate referral capture for apps with the Onelo SDK (#929).
///
/// An Affiliate link that opens your app carries `?ref=<code>` (the Affiliate
/// linking straight to the app) or `?onelo_click=<id>` (forwarded by Onelo's
/// tracked link after consent there). Pass that URL with the visitor's cookie /
/// tracking answer:
///
/// ```swift
/// .onOpenURL { url in Task { await onelo.affiliates.capture(url: url, consent: userAgreed) } }
/// ```
///
/// - `consent: false` stores nothing on the device; a `?ref=` only adds one to
///   the Affiliate's anonymous total.
/// - `consent: true` keeps the click (UserDefaults key `onelo_aff`). Which of two
///   clicks stays is the program's winner rule, decided by Onelo.
///
/// The kept click is tied to the user who signs in, so their purchase is
/// attributed whichever checkout opens.
public final class OneloAffiliates: @unchecked Sendable {
    public static let storageKey = "onelo_aff"

    typealias Post = (_ path: String, _ body: [String: Any]) async -> (Int, [String: Any])?
    typealias Session = () async -> (accessToken: String, userId: String)?

    private let publishableKey: String
    private let post: Post
    private let session: Session
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(publishableKey: String, defaults: UserDefaults = .standard, post: @escaping Post, session: @escaping Session) {
        self.publishableKey = publishableKey
        self.defaults = defaults
        self.post = post
        self.session = session
    }

    convenience init(client: _OneloHTTPClient, session: @escaping Session) {
        self.init(
            publishableKey: client.publishableKey,
            post: { path, body in try? await client.postRaw(path: path, body: body) },
            session: session
        )
    }

    struct Kept: Equatable { var clickId: String; var claimedFor: String? }

    func kept() -> Kept? {
        lock.lock(); defer { lock.unlock() }
        guard let dict = defaults.dictionary(forKey: Self.storageKey),
              let id = dict["click_id"] as? String, Self.isClickId(id) else { return nil }
        return Kept(clickId: id, claimedFor: dict["claimed_for"] as? String)
    }

    private func keep(_ kept: Kept) {
        lock.lock(); defer { lock.unlock() }
        var dict: [String: Any] = ["click_id": kept.clickId]
        if let c = kept.claimedFor { dict["claimed_for"] = c }
        defaults.set(dict, forKey: Self.storageKey)
    }

    static func isClickId(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    static func isCode(_ s: String) -> Bool {
        (6...32).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Capture the referral in `url` after the visitor's answer. Stores nothing
    /// without consent. Returns whether a referral is now kept on this device.
    @discardableResult
    public func capture(url: URL, consent: Bool) async -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first { $0.name == "ref" }?.value.flatMap { Self.isCode($0) ? $0.lowercased() : nil }
        let forwarded = items.first { $0.name == "onelo_click" }?.value.flatMap { Self.isClickId($0) ? $0 : nil }
        if !consent {
            if let code {
                _ = await post("/v1/sdk/affiliates/refused", ["publishableKey": publishableKey, "code": code])
            }
            return false
        }
        let existing = kept()
        if let code {
            var body: [String: Any] = ["publishableKey": publishableKey, "code": code, "source": "sdk"]
            if let existing { body["existing"] = existing.clickId }
            if let (status, json) = await post("/v1/sdk/affiliates/click", body), status == 200,
               let id = json["click_id"] as? String, Self.isClickId(id), id != existing?.clickId {
                keep(Kept(clickId: id, claimedFor: nil))
            }
        } else if let forwarded, forwarded != existing?.clickId {
            // Onelo's tracked link already recorded this click and applied the
            // program's winner rule; the id it forwards is the one to keep.
            keep(Kept(clickId: forwarded, claimedFor: nil))
        }
        await claimForSession()
        return kept() != nil
    }

    /// Tie the kept click to the signed-in user once. Called on every sign-in.
    public func claimForSession() async {
        guard let k = kept(), let s = await session(), k.claimedFor != s.userId else { return }
        let body: [String: Any] = ["publishableKey": publishableKey, "userToken": s.accessToken, "clickId": k.clickId]
        if let (status, _) = await post("/v1/sdk/affiliates/claim", body), status == 200 {
            keep(Kept(clickId: k.clickId, claimedFor: s.userId))
        }
    }
}
