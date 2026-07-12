#if canImport(DeviceCheck)
import DeviceCheck
import CryptoKit
import Foundation

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
            throw OneloAttestError.notSupported
        }
        // On macOS DCAppAttestService.shared.isSupported can return true even when the
        // App Attest entitlement is missing (e.g. Developer ID-signed apps without a
        // provisioning profile). In that case attestKey() blocks Apple's attestation
        // servers and never returns. Skip cleanly here instead.
        guard hasAppAttestEntitlement() else {
            throw OneloAttestError.notSupported
        }

        let keyId     = try await getOrGenerateKeyId()
        let challenge = try await fetchChallenge()

        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await withTimeout(seconds: dcCallTimeoutSeconds) {
            try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
        }

        let token = try await sendAttestation(attestation: attestation, keyId: keyId, challenge: challenge)
        saveTokenToKeychain(token)
        return token
    }

    private func getOrGenerateKeyId() async throws -> String {
        if let existing = loadFromKeychain(keychainKeyId) { return existing }
        let keyId = try await withTimeout(seconds: dcCallTimeoutSeconds) {
            try await DCAppAttestService.shared.generateKey()
        }
        saveToKeychain(keyId, forKey: keychainKeyId)
        return keyId
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
            throw OneloAttestError.attestationFailed
        }
        guard let json = try? JSONDecoder().decode([String: String].self, from: data),
              let token = json["attest_token"] else {
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
}
#endif
