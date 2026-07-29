#if canImport(DeviceCheck)
import DeviceCheck
import CryptoKit
import Foundation
import os

/// Shared logger for the App Attest path. A silently-failing security mechanism
/// is worse than none — the developer must be able to see WHY attestation failed
/// (missing App Attest capability, timeout to Apple, backend rejection, …) instead
/// of an unexplained `attestToken == nil`.
@available(iOS 14.0, macOS 11.0, *)
enum OneloAttestLog {
    static let logger = Logger(subsystem: "io.onelo.sdk", category: "attest")
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// Handles Apple App Attest at SDK init time.
/// Generates a key, fetches a server challenge, attests the key with Apple,
/// exchanges the attestation for an Onelo attest_token JWT, and caches it in Keychain.
/// Refreshes automatically when the token is near expiry (< 5 min remaining).
///
/// Calls into DCAppAttestService are wrapped in a 5s timeout: on macOS without a
/// proper provisioning profile they can hang indefinitely waiting on Apple's
/// attestation servers, which would otherwise block SDK startup.
@available(iOS 14.0, macOS 11.0, *)
public final class OneloAppAttest {

    private let baseURL: String
    private let publishableKey: String
    private let bundleId: String

    private let keychainKeyId  = "io.onelo.attest_key_id"
    private let keychainToken  = "io.onelo.attest_token"
    private let keychainExpiry = "io.onelo.attest_token_expiry"

    /// Cap on each individual DCAppAttestService call.
    private let dcCallTimeoutSeconds: TimeInterval = 5
    /// Cap on each Onelo attest endpoint round-trip.
    private let networkTimeoutSeconds: TimeInterval = 10

    public init(baseURL: String, publishableKey: String) {
        self.baseURL = baseURL
        self.publishableKey = publishableKey
        self.bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Returns a valid attest_token. Attests the device if no valid cached token exists.
    public func getAttestToken() async throws -> String {
        if let cached = loadCachedToken(), !isNearExpiry(cached) {
            return cached.token
        }
        return try await performAttestation()
    }

    // MARK: - Attestation

    private func performAttestation() async throws -> String {
        guard DCAppAttestService.shared.isSupported else {
            OneloAttestLog.error("App Attest unavailable — DCAppAttestService.isSupported == false (simulator, or App Attest capability not enabled for this build).")
            throw OneloAttestError.notSupported
        }
        // On macOS DCAppAttestService.shared.isSupported can return true even when the
        // App Attest entitlement is missing (e.g. Developer ID-signed apps without a
        // provisioning profile). In that case attestKey() blocks Apple's attestation
        // servers and never returns. Skip cleanly here instead.
        guard hasAppAttestEntitlement() else {
            OneloAttestLog.error("App Attest unavailable — missing App Attest entitlement / provisioning profile.")
            throw OneloAttestError.notSupported
        }

        // Always attest a FRESH key — an App Attest key can be attested only once
        // (see generateFreshAttestKey). generateKey() / attestKey() throw a raw
        // Apple DCError (NOT an OneloAttestError) — e.g. the App Attest capability
        // isn't enabled on the target, so the call fails on-device before any
        // /attest request. Wrap it so the real cause is logged and surfaced
        // instead of vanishing into `try?`.
        let keyId: String
        do {
            keyId = try await generateFreshAttestKey()
        } catch let e as OneloAttestError {
            throw e  // already-typed (e.g. .timeout)
        } catch {
            OneloAttestLog.error("App Attest generateKey failed: \(error)")
            throw OneloAttestError.deviceCheckFailed("generateKey: \(error)")
        }

        let challenge = try await fetchChallenge()
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))

        let attestation: Data
        do {
            attestation = try await withTimeout(seconds: dcCallTimeoutSeconds) {
                try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
            }
        } catch let e as OneloAttestError {
            throw e  // .timeout from withTimeout
        } catch {
            OneloAttestLog.error("App Attest attestKey failed: \(error)")
            throw OneloAttestError.deviceCheckFailed("attestKey: \(error)")
        }

        let token = try await sendAttestation(attestation: attestation, keyId: keyId, challenge: challenge)
        saveTokenToKeychain(token)
        // Persist the key id only now that it has been successfully attested AND
        // accepted by the server, so keychainKeyId always names an attested key
        // (a future generateAssertion flow signs with it). Saving before this
        // point would let a generate-but-attest-failed key overwrite a good one.
        saveToKeychain(keyId, forKey: keychainKeyId)
        return token
    }

    /// Mint a FRESH App Attest key and return its key id.
    ///
    /// An App Attest key can be attested EXACTLY ONCE — Apple rejects
    /// `attestKey(...)` on a key that was already attested. `performAttestation`
    /// runs only when we need a new attestation (first launch, or the ~30-day
    /// attest token expired and we're refreshing), so it must NEVER reuse the
    /// previously-attested key. Reusing it was a latent time-bomb: ~30 days after
    /// each user's first attestation the refresh re-attested the stale key, Apple
    /// rejected it, and App Attest broke permanently for that install. We always
    /// generate a new key; the caller persists its id (keychainKeyId) only AFTER
    /// attestation succeeds, so the stored id always names an attested key (the
    /// one a future assertion flow would sign with) — a generate-but-fail never
    /// overwrites a good one.
    private func generateFreshAttestKey() async throws -> String {
        return try await withTimeout(seconds: dcCallTimeoutSeconds) {
            try await DCAppAttestService.shared.generateKey()
        }
    }

    // MARK: - Assertions (FAZA 3 — per-request device proof)

    /// Server endpoints whose enforcement is replay-guarded (single-use
    /// challenge + monotonic counter). MUST mirror the backend REPLAY_GUARD_PATHS
    /// set (app/lib/attest_gate.py) — anything else uses the reusable stateless
    /// nonce. A path added on the server MUST be added here too, or the SDK will
    /// send the wrong (reusable) challenge and get 403 attest_challenge_invalid.
    private static let replayGuardPaths: Set<String> = [
        "/api/sdk/auth/signin", "/api/sdk/auth/signup", "/api/sdk/auth/magic-link",
        "/api/sdk/auth/hosted-callback", "/api/sdk/paywall/switch/apply",
        "/api/sdk/waitlist/join", "/api/sdk/waitlist/redeem", "/api/sdk/forms/submit",
    ]

    /// Reusable stateless challenge (verify-only paths). Refreshed a bit before
    /// the server's 5-min TTL so it never presents an expired one. Guarded by
    /// `challengeLock` — assertionHeaders is a `nonisolated async` method, so two
    /// concurrent gated requests can enter it on the global executor at once
    /// (D2). We never hold the lock across the `await` fetch: at worst two
    /// racers each fetch a fresh challenge (benign duplicate), never a torn read.
    private var cachedStatelessChallenge: (value: String, fetchedAt: Date)?
    private let statelessChallengeMaxAge: TimeInterval = 240  // 4 min < 5-min server TTL
    private let challengeLock = NSLock()

    /// Build the `X-Attest-*` assertion headers for ONE outgoing request, or nil
    /// if this device can't produce an assertion (no attested key yet, App Attest
    /// unsupported, offline). On nil the caller falls back to the legacy
    /// `X-Attest-Token` bearer — backward compatible during the migration.
    ///
    /// The signed `clientDataHash` is `SHA256(METHOD\npath?query\nchallenge\nbody)`
    /// and MUST match the backend's `compute_client_data_hash` byte-for-byte.
    public func assertionHeaders(
        method: String, path: String, query: String, body: Data
    ) async -> [String: String]? {
        guard DCAppAttestService.shared.isSupported, hasAppAttestEntitlement(),
              let keyId = loadFromKeychain(keychainKeyId) else { return nil }

        let challenge: String
        do {
            challenge = Self.replayGuardPaths.contains(path)
                ? try await fetchSingleUseChallenge()
                : try await cachedOrFreshStatelessChallenge()
        } catch {
            OneloAttestLog.error("assertion challenge fetch failed: \(error)")
            return nil
        }

        let pathWithQuery = query.isEmpty ? path : "\(path)?\(query)"
        var signed = "\(method.uppercased())\n\(pathWithQuery)\n\(challenge)\n".data(using: .utf8)!
        signed.append(body)
        let clientDataHash = Data(SHA256.hash(data: signed))

        do {
            let assertion = try await withTimeout(seconds: dcCallTimeoutSeconds) {
                try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
            }
            return [
                "X-Attest-Key-Id": keyId,
                "X-Attest-Assertion": assertion.base64EncodedString(),
                "X-Attest-Challenge": challenge,
            ]
        } catch {
            // A generateAssertion failure (e.g. the key was invalidated) is not
            // fatal to the request — fall back to the bearer and let the backend
            // 403 drive a re-attest if enforcement is on.
            OneloAttestLog.error("generateAssertion failed: \(error)")
            return nil
        }
    }

    /// Drop the attested key + cached tokens so the next call re-attests from a
    /// fresh key. Called by the transport on a hard attestation 403
    /// (`attest_key_unknown` / `attest_key_revoked` / `invalid_assertion`) — the
    /// self-heal path (#24 P4). NOT called on `counter_stale` (retryable) or on
    /// the session-refresh path (Filar 5 — never evict a logged-in user).
    public func resetAttestedKey() {
        deleteFromKeychain(keychainKeyId)
        deleteFromKeychain(keychainToken)
        deleteFromKeychain(keychainExpiry)
        clearCachedChallenge()
    }

    private struct ChallengeResponse: Decodable { let challenge: String }

    private func fetchSingleUseChallenge() async throws -> String {
        var comps = URLComponents(string: "\(baseURL)/api/sdk/auth/assert-challenge")!
        comps.queryItems = [URLQueryItem(name: "key", value: publishableKey)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = networkTimeoutSeconds
        req.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ChallengeResponse.self, from: data) else {
            throw OneloAttestError.invalidResponse
        }
        return decoded.challenge
    }

    // Sync lock helpers — NSLock.lock()/unlock() are unavailable directly from an
    // async context (Swift 6). Keeping them in sync functions guarantees the lock
    // is never held across a suspension.
    private func readCachedChallenge() -> (value: String, fetchedAt: Date)? {
        challengeLock.lock(); defer { challengeLock.unlock() }
        return cachedStatelessChallenge
    }
    private func storeCachedChallenge(_ value: String) {
        challengeLock.lock(); defer { challengeLock.unlock() }
        cachedStatelessChallenge = (value, Date())
    }
    private func clearCachedChallenge() {
        challengeLock.lock(); defer { challengeLock.unlock() }
        cachedStatelessChallenge = nil
    }

    private func cachedOrFreshStatelessChallenge() async throws -> String {
        if let c = readCachedChallenge(),
           Date().timeIntervalSince(c.fetchedAt) < statelessChallengeMaxAge {
            return c.value
        }
        let value = try await fetchChallenge()  // GET /attest-challenge (no lock held across await)
        storeCachedChallenge(value)
        return value
    }

    // MARK: - Entitlement check

    /// Best-effort check for the App Attest entitlement.
    /// - iOS: trust DCAppAttestService.shared.isSupported (reliable on real devices).
    /// - macOS: look for an embedded provisioning profile that lists the entitlement.
    ///   Apps signed with Developer ID for direct distribution typically lack such a
    ///   profile; we treat them as unsupported rather than blocking on Apple's servers.
    private func hasAppAttestEntitlement() -> Bool {
        #if os(macOS)
        let profileURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile")
        guard let profileData = try? Data(contentsOf: profileURL) else {
            return false
        }
        let needle = Data("com.apple.developer.devicecheck.appattest-environment".utf8)
        return profileData.range(of: needle) != nil
        #else
        return true
        #endif
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw OneloAttestError.timeout
            }
            guard let first = try await group.next() else {
                throw OneloAttestError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Network

    private func fetchChallenge() async throws -> String {
        let url = URL(string: "\(baseURL)/api/sdk/auth/attest-challenge")!
        var req = URLRequest(url: url)
        req.timeoutInterval = networkTimeoutSeconds
        req.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONDecoder().decode([String: String].self, from: data),
              let challenge = json["challenge"] else {
            throw OneloAttestError.invalidResponse
        }
        return challenge
    }

    private func sendAttestation(attestation: Data, keyId: String, challenge: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/sdk/auth/attest")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(OneloInstanceId.current(), forHTTPHeaderField: "X-Onelo-Instance-Id")
        req.timeoutInterval = networkTimeoutSeconds

        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif

        let body: [String: String] = [
            "attestation":     attestation.base64EncodedString(),
            "key_id":          keyId,
            "bundle_id":       bundleId,
            "challenge":       challenge,
            "platform":        platform,
            "publishable_key": publishableKey,
        ]
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Preserve the backend's status + reason (e.g. {"error":"invalid_attestation",
            // "message":…}) so the developer sees WHY /attest rejected the attestation.
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            OneloAttestLog.error("Attest endpoint rejected (HTTP \(status)): \(detail)")
            throw OneloAttestError.serverRejected(status: status, detail: detail)
        }
        guard let json = try? JSONDecoder().decode([String: String].self, from: data),
              let token = json["attest_token"] else {
            OneloAttestLog.error("Attest endpoint returned 200 but body had no attest_token.")
            throw OneloAttestError.invalidResponse
        }
        return token
    }

    // MARK: - Token cache

    private struct CachedToken { var token: String; var expiresAt: Date }

    private func isNearExpiry(_ cached: CachedToken) -> Bool {
        return Date().addingTimeInterval(300) >= cached.expiresAt
    }

    private func loadCachedToken() -> CachedToken? {
        guard let token     = loadFromKeychain(keychainToken),
              let expiryStr = loadFromKeychain(keychainExpiry),
              let expiry    = ISO8601DateFormatter().date(from: expiryStr) else { return nil }
        return CachedToken(token: token, expiresAt: expiry)
    }

    private func saveTokenToKeychain(_ token: String) {
        saveToKeychain(token, forKey: keychainToken)
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var payload = String(parts[1])
            while payload.count % 4 != 0 { payload += "=" }
            if let data = Data(base64Encoded: payload),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let exp  = json["exp"] as? TimeInterval {
                let expDate = Date(timeIntervalSince1970: exp)
                saveToKeychain(ISO8601DateFormatter().string(from: expDate), forKey: keychainExpiry)
            }
        }
    }

    // MARK: - Keychain helpers

    private func saveToKeychain(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // SecItemDelete above couldn't reach the existing entry (ACL mismatch
            // from a prior run as a different bundle / unsigned binary). Update in place.
            let updateQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrAccount as String: key,
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String:   data,
            ]
            SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        }
    }

    private func deleteFromKeychain(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }

    private func loadFromKeychain(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

public enum OneloAttestError: Error {
    case notSupported
    case attestationFailed
    case invalidResponse
    case timeout
    /// A raw Apple DeviceCheck/App Attest error (e.g. the App Attest capability is
    /// not enabled for this build, so generateKey()/attestKey() throws on-device
    /// before any /attest request). Carries the underlying error's description.
    case deviceCheckFailed(String)
    /// The Onelo /attest endpoint rejected the attestation. Carries the HTTP status
    /// and (truncated) response body so the reason is visible.
    case serverRejected(status: Int, detail: String)

    /// Human-readable, log-safe explanation of the failure cause. Prefer this over
    /// the raw case when logging or surfacing the error in UI.
    public var diagnosticDescription: String {
        switch self {
        case .notSupported:
            return "App Attest not supported on this device/build (simulator, or the App Attest capability is not enabled)."
        case .attestationFailed:
            return "Attestation failed."
        case .invalidResponse:
            return "The attest endpoint returned an unexpected response."
        case .timeout:
            return "A DeviceCheck call timed out (Apple attestation servers unreachable)."
        case .deviceCheckFailed(let detail):
            return "DeviceCheck error: \(detail)"
        case .serverRejected(let status, let detail):
            return "The attest endpoint rejected the attestation (HTTP \(status)): \(detail)"
        }
    }
}
#endif
