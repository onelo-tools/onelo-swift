import Foundation

/// PII / secret scrubbing for monitor data captured before transport.
///
/// Mirrors the backend Python denylist (sdk_monitor.py) plus client-only
/// concerns (URL query params, request headers). Backend has its own
/// trigger-level scrubber; this is the first line of defense so secrets
/// never leave the device in the first place.
enum MonitorScrubber {
    static let redacted = "[REDACTED]"

    /// Header names whose values must never be transmitted in breadcrumbs.
    /// Lower-cased; comparison is case-insensitive.
    static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "proxy-authorization",
        "x-api-key",
        "x-auth-token",
        "x-onelo-secret",
        "www-authenticate",
    ]

    /// Query-param keys whose values must be redacted in URL breadcrumbs.
    static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "refresh_token", "id_token",
        "key", "api_key", "apikey",
        "secret", "client_secret",
        "password", "passwd",
        "auth", "authorization",
        "code",     // OAuth authorization code
        "session",  // session token in URL
    ]

    /// Substring patterns matched against arbitrary keys (case-insensitive,
    /// partial match). Mirrors backend PII_KEY_DENYLIST.
    static let piiKeySubstrings: [String] = [
        "password", "passwd", "secret", "token", "api_key", "apikey",
        "authorization", "cookie", "credential", "private_key",
        "client_secret", "cvv", "ssn",
    ]

    /// Compiled regex patterns matched against string values.
    ///
    /// Boundary anchors: ICU regex's ``\\b`` is Unicode-aware just like
    /// Python's, so non-ASCII padding ("prefix𝐬sk_live_…") would slip past
    /// a ``\\b``-anchored pattern. We use ASCII-only lookbehind / lookahead
    /// (``(?<![A-Za-z0-9])`` / ``(?![A-Za-z0-9])``) to mirror the Python
    /// scrubber. Underscore is intentionally NOT in the boundary set so
    /// env-var-style concatenation ("API_sk_live_…") still latches.
    private static let valuePatterns: [NSRegularExpression] = {
        let lb = "(?<![A-Za-z0-9])"
        let la = "(?![A-Za-z0-9])"
        let raw: [String] = [
            // Bearer / Basic tokens
            "(?i)" + lb + "Bearer\\s+[A-Za-z0-9\\-._~+/]+=*",
            // JWTs (three base64url segments)
            lb + "eyJ[A-Za-z0-9\\-_]+\\.[A-Za-z0-9\\-_]+\\.[A-Za-z0-9\\-_]+" + la,
            // Stripe-style API keys
            lb + "(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}" + la,
            // Onelo SDK keys: onelo_pk_live_… / onelo_sk_live_… (Python parity).
            // Without this, a Swift app accidentally logging its own secret
            // key in an exception message would ship the live key to the
            // dashboard intact.
            lb + "onelo_(?:pk|sk|rk)_(?:live|test)_[A-Za-z0-9]{8,}" + la,
            // Credit-card numbers — separated form (Visa/MC/Amex/Discover)
            lb + "(?:4[0-9]{3}|5[1-5][0-9]{2}|3[47][0-9]{2}|6(?:011|5[0-9]{2}))[\\s-][0-9]{4}[\\s-][0-9]{4}[\\s-][0-9]{4}" + la,
            // Credit-card numbers — unseparated greedy (catches 17–20 digit
            // blobs the old fixed-length pattern leaked, e.g. 4111…111111111).
            lb + "(?:4|5[1-5]|6(?:011|5))[0-9]{14,}(?![0-9])",
            // Credit-card numbers — unseparated greedy Amex
            lb + "3[47][0-9]{13,}(?![0-9])",
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Returns true if the supplied key looks like it carries secrets.
    static func isPIIKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if piiKeySubstrings.contains(where: lower.contains) { return true }
        // Segment "key" catches custom secret headers (x-anthropic-key /
        // x-groq-key / x-elevenlabs-key) without false-positives like "monkey".
        let segments = lower.replacingOccurrences(of: "-", with: "_").split(separator: "_").map(String.init)
        return segments.contains("key")
    }

    /// Replace sensitive substrings inside an arbitrary text payload
    /// (e.g. an Error.localizedDescription that may include a Bearer token).
    static func scrubText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        var out = text as NSString
        for pat in valuePatterns {
            let range = NSRange(location: 0, length: out.length)
            out = pat.stringByReplacingMatches(
                in: out as String,
                options: [],
                range: range,
                withTemplate: redacted
            ) as NSString
        }
        return out as String
    }

    /// Recursively scrub a JSON-shaped meta dictionary.
    /// Returns a copy; the original is untouched. Adds `_onelo_redacted`
    /// listing redacted keys so the developer knows their data was cleaned.
    static func scrubMeta(_ meta: [String: Any]?) -> [String: Any]? {
        guard var meta else { return nil }
        var redactedKeys: Set<String> = []
        meta = scrubDictionary(meta, redactedKeys: &redactedKeys, depth: 0)
        if !redactedKeys.isEmpty {
            meta["_onelo_redacted"] = redactedKeys.sorted()
        }
        return meta
    }

    /// Strip query-param values for sensitive keys. Returns the URL string.
    static func scrubURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = comps.queryItems, !items.isEmpty {
            comps.queryItems = items.map { item in
                if sensitiveQueryKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: redacted)
                }
                return item
            }
        }
        return comps.string ?? url.absoluteString
    }

    /// Filter a header dictionary, redacting sensitive values.
    static func scrubHeaders(_ headers: [String: String]?) -> [String: String]? {
        guard let headers else { return nil }
        var out: [String: String] = [:]
        for (k, v) in headers {
            if sensitiveHeaders.contains(k.lowercased()) || isPIIKey(k) {
                out[k] = redacted
            } else {
                out[k] = v
            }
        }
        return out
    }

    // MARK: - Internal recursion

    private static let maxDepth = 10

    private static func scrubDictionary(
        _ dict: [String: Any],
        redactedKeys: inout Set<String>,
        depth: Int
    ) -> [String: Any] {
        // At the depth limit we used to silently pass the sub-tree through —
        // which meant a deliberately deep payload could hide secrets from the
        // scrubber. Now we replace the whole sub-tree with a marker so nothing
        // sneaks past, and the developer sees the truncation.
        guard depth < maxDepth else {
            redactedKeys.insert("_onelo_depth_exceeded")
            return ["_onelo_depth_exceeded": true]
        }
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if k == "_onelo_redacted" {
                out[k] = v
                continue
            }
            if isPIIKey(k) {
                redactedKeys.insert(k)
                out[k] = redacted
                continue
            }
            out[k] = scrubValue(v, redactedKeys: &redactedKeys, depth: depth + 1)
        }
        return out
    }

    private static func scrubValue(
        _ value: Any,
        redactedKeys: inout Set<String>,
        depth: Int
    ) -> Any {
        if depth >= maxDepth { return value }
        if let s = value as? String {
            return scrubText(s) ?? s
        }
        if let d = value as? [String: Any] {
            return scrubDictionary(d, redactedKeys: &redactedKeys, depth: depth + 1)
        }
        if let arr = value as? [Any] {
            return arr.map { scrubValue($0, redactedKeys: &redactedKeys, depth: depth + 1) }
        }
        return value
    }
}
