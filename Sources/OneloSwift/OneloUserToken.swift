import Foundation

/// Proof of the signed-in end user on Features calls (#510, #519).
///
/// The Features endpoints (resolve, batch-ping, module-token and the Event
/// Stream) accept `Authorization: Bearer <Onelo access token>` from a
/// publishable-key caller and take the user from the token instead of the
/// `userId` the SDK names (server: `backend/app/lib/features/end_user.py`). A
/// token the server refuses answers `401 {"detail":{"error":"invalid_user_token"}}`
/// and never falls back to the `userId`.
///
/// This file is the ONE place that decides what a Features call sends — the
/// same rules as the JS SDKs (`packages/onelo-js/src/core/user-token.ts`):
/// - signed in: the current access token, read fresh per call and per
///   reconnect (an expired one is refreshed first);
/// - refused: refresh once and retry once (one refresh per refusal episode);
/// - refused again: the call is made anonymous (no token, no `userId`) and the
///   caller is told, so it can surface the refusal. It never loops.
@MainActor
final class _OneloUserToken {
    private let readCurrent: @MainActor () async -> String?
    private let readRefreshed: @MainActor () async -> String?

    /// Why the refusal state exists: a refresh republishes the session, and a
    /// host (or a future change) that answers that with a new Features call
    /// would, against a server that keeps refusing even fresh tokens (a key
    /// whose app is not the one the user signed in to), refresh → call → be
    /// refused → refresh … without end. So a refusal-triggered refresh happens
    /// at most once per refusal episode: concurrent refusals share the refresh
    /// in flight, and after it no further refresh is made until a token is
    /// accepted again or the user changes (`reset()`).
    private var spent = false
    private var inFlight: Task<String?, Never>?

    /// - Parameters:
    ///   - current: the signed-in user's current access token, or nil when no
    ///     Onelo user is signed in.
    ///   - refresh: refresh the session and return the new access token (nil
    ///     when that fails).
    init(
        current: @escaping @MainActor () async -> String?,
        refresh: @escaping @MainActor () async -> String?
    ) {
        self.readCurrent = current
        self.readRefreshed = refresh
    }

    /// The token to send now, or nil for "no token" (an empty value counts as none).
    func current() async -> String? {
        Self.normalized(await readCurrent())
    }

    /// The refreshed token to retry a refused call with — or nil when this
    /// refusal episode already used its one refresh (the caller then goes anonymous).
    func refreshAfterRefusal() async -> String? {
        if let running = inFlight { return await running.value }
        if spent { return nil }
        spent = true
        let task = Task { @MainActor [readRefreshed] in Self.normalized(await readRefreshed()) }
        inFlight = task
        let token = await task.value
        if inFlight == task { inFlight = nil }
        return token
    }

    /// A call that carried a token was accepted: the next refusal may refresh again.
    func accepted() { spent = false }

    /// A different user signed in (or signed out): start a new refusal episode.
    func reset() { spent = false }

    /// Test probe: true while this refusal episode has used its one refresh.
    var _refreshSpentForTesting: Bool { spent }
    /// Test hook: mark the episode's refresh as used without running one.
    func _spendRefreshForTesting() { spent = true }

    private static func normalized(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}

/// How one attempt of a Features call proves (or does not prove) the user.
struct _OneloUserTokenAttempt: Sendable {
    /// The Bearer to send, or nil for no `Authorization` header.
    let token: String?
    /// True for the final fallback after a refused token: send no `userId` either.
    let anonymous: Bool
}

enum _OneloUserTokenWire {
    /// The error code the server answers with for a refused user token.
    static let invalidUserToken = "invalid_user_token"

    /// `Authorization` header for an attempt — empty when it carries no token.
    static func headers(_ token: String?) -> [String: String] {
        guard let token else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    /// True for the server's `401 invalid_user_token` (FastAPI `{detail:{error}}`, or a flat `{error}`).
    static func isRefusal(status: Int, json: [String: Any]) -> Bool {
        guard status == 401 else { return false }
        return errorCode(json) == invalidUserToken
    }

    static func errorCode(_ json: [String: Any]) -> String? {
        if let detail = json["detail"] as? [String: Any] { return detail["error"] as? String }
        return json["error"] as? String
    }
}

/// Send one Features call with the signed-in user's token.
///
/// `send` performs a single request for the given attempt. When the server
/// refuses the token, the session is refreshed (at most once per refusal
/// episode) and the call retried once; if that is refused too (or there is no
/// refreshed token), `onRefused` runs and, unless `anonymousFallback` is false,
/// the call is sent one last time as anonymous. The response of the last
/// attempt made is returned.
///
/// `provesAcceptance` is false for an endpoint whose 2xx does not prove the
/// token was checked (batch-ping answers a throttled 204 before looking at it);
/// such a call never ends a refusal episode.
@MainActor
func _sendWithUserToken(
    _ source: _OneloUserToken?,
    anonymousFallback: Bool = true,
    provesAcceptance: Bool = true,
    onRefused: () -> Void,
    send: (_OneloUserTokenAttempt) async throws -> (Int, [String: Any])
) async throws -> (Int, [String: Any]) {
    let token = await source?.current()
    let first = try await send(_OneloUserTokenAttempt(token: token, anonymous: false))
    guard let source, token != nil else { return first }
    if !_OneloUserTokenWire.isRefusal(status: first.0, json: first.1) {
        if provesAcceptance, (200..<300).contains(first.0) { source.accepted() }
        return first
    }

    var last = first
    if let fresh = await source.refreshAfterRefusal() {
        last = try await send(_OneloUserTokenAttempt(token: fresh, anonymous: false))
        if !_OneloUserTokenWire.isRefusal(status: last.0, json: last.1) {
            if provesAcceptance, (200..<300).contains(last.0) { source.accepted() }
            return last
        }
    }
    onRefused()
    guard anonymousFallback else { return last }
    return try await send(_OneloUserTokenAttempt(token: nil, anonymous: true))
}
