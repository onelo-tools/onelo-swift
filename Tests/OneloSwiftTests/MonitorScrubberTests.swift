import XCTest
@testable import OneloSwift

final class MonitorScrubberTests: XCTestCase {

    // MARK: - isPIIKey

    func test_isPIIKey_matchesDenylistSubstrings() {
        XCTAssertTrue(MonitorScrubber.isPIIKey("password"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("Password"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("user_password"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("api_key"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("apiKey"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("Authorization"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("set-cookie"))
        XCTAssertTrue(MonitorScrubber.isPIIKey("client_secret"))
    }

    func test_isPIIKey_safeKeysPass() {
        XCTAssertFalse(MonitorScrubber.isPIIKey("plan"))
        XCTAssertFalse(MonitorScrubber.isPIIKey("region"))
        XCTAssertFalse(MonitorScrubber.isPIIKey("user_id"))
        XCTAssertFalse(MonitorScrubber.isPIIKey("email"))      // intentionally NOT in denylist
        XCTAssertFalse(MonitorScrubber.isPIIKey("featureName"))
    }

    // MARK: - scrubText

    func test_scrubText_redactsBearerToken() {
        let s = "Auth failed: Bearer abcDEF123_token"
        XCTAssertEqual(MonitorScrubber.scrubText(s), "Auth failed: [REDACTED]")
    }

    func test_scrubText_redactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature_part"
        let scrubbed = MonitorScrubber.scrubText("token=\(jwt) more")
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
        XCTAssertFalse(scrubbed?.contains(jwt) == true)
    }

    func test_scrubText_redactsStripeKey() {
        let s = "Using sk_live_abcdefghij1234567890"
        let scrubbed = MonitorScrubber.scrubText(s)
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
        XCTAssertFalse(scrubbed?.contains("sk_live_") == true)
    }

    func test_scrubText_redactsCreditCard() {
        let s = "Card 4111-1111-1111-1111 declined"
        let scrubbed = MonitorScrubber.scrubText(s)
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
    }

    func test_scrubText_redactsCreditCardWithoutSeparators() {
        // Regression: pre-fix regex required separators between groups, so a
        // raw 16-digit card slipped through the scrubber.
        let s = "Card 4111111111111111 declined"
        let scrubbed = MonitorScrubber.scrubText(s)
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
        XCTAssertFalse(scrubbed?.contains("4111111111111111") == true)
    }

    func test_scrubText_redactsAmexUnseparated() {
        let s = "Charge 378282246310005 OK"
        let scrubbed = MonitorScrubber.scrubText(s)
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
    }

    func test_scrubText_redactsOneloPublishableKey() {
        // Parity with the Python SDK: Onelo's own SDK keys must be scrubbed
        // out of error messages so a logged init-time exception doesn't
        // ship the live key to the dashboard.
        let s = "Got onelo_pk_live_CL2FmTgopEuY2QPqZms4scVR from cache"
        let scrubbed = MonitorScrubber.scrubText(s)
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
        XCTAssertFalse(scrubbed?.contains("onelo_pk_live_") == true)
    }

    func test_scrubText_redactsOneloSecretKey() {
        let scrubbed = MonitorScrubber.scrubText("ENV=onelo_sk_test_abc12345")
        XCTAssertTrue(scrubbed?.contains("[REDACTED]") == true)
        XCTAssertFalse(scrubbed?.contains("onelo_sk_test_") == true)
    }

    func test_scrubText_stripeKeyWithUnderscorePrefix_redacted() {
        // Underscore is NOT a boundary character in our lookarounds, so a
        // leading-underscore env-var name no longer hides the secret.
        let scrubbed = MonitorScrubber.scrubText("ENV_sk_live_abcdefghij1234567890_SUFFIX")
        XCTAssertFalse(scrubbed?.contains("sk_live_abcdefghij") == true)
    }

    func test_scrubText_creditCardWithExtraDigits_redacted() {
        // 19-digit blob that previously slipped past the boundary anchor.
        let scrubbed = MonitorScrubber.scrubText("paid 4111111111111111111 ok")
        XCTAssertFalse(scrubbed?.contains("4111111111111111") == true)
    }

    func test_scrubText_amexWithExtraDigits_redacted() {
        let scrubbed = MonitorScrubber.scrubText("AMEX 378282246310005777 declined")
        XCTAssertFalse(scrubbed?.contains("378282246310005") == true)
    }

    func test_scrubText_keepsBenignText() {
        let s = "Plan upgraded to pro"
        XCTAssertEqual(MonitorScrubber.scrubText(s), s)
    }

    func test_scrubText_handlesNilAndEmpty() {
        XCTAssertNil(MonitorScrubber.scrubText(nil))
        XCTAssertEqual(MonitorScrubber.scrubText(""), "")
    }

    // MARK: - scrubMeta

    func test_scrubMeta_redactsTopLevelPIIKeys() {
        let meta: [String: Any] = ["plan": "pro", "password": "hunter2"]
        let scrubbed = MonitorScrubber.scrubMeta(meta)!
        XCTAssertEqual(scrubbed["plan"] as? String, "pro")
        XCTAssertEqual(scrubbed["password"] as? String, "[REDACTED]")
        XCTAssertEqual((scrubbed["_onelo_redacted"] as? [String])?.contains("password"), true)
    }

    func test_scrubMeta_redactsNestedPIIKeys() {
        let meta: [String: Any] = [
            "outer": "ok",
            "nested": ["secret": "sssh", "ok_field": "yes"] as [String: Any]
        ]
        let scrubbed = MonitorScrubber.scrubMeta(meta)!
        let nested = scrubbed["nested"] as? [String: Any]
        XCTAssertEqual(nested?["secret"] as? String, "[REDACTED]")
        XCTAssertEqual(nested?["ok_field"] as? String, "yes")
    }

    func test_scrubMeta_redactsValuesWhenSecretInString() {
        let meta: [String: Any] = ["log": "Bearer xyz123 happened"]
        let scrubbed = MonitorScrubber.scrubMeta(meta)!
        XCTAssertTrue((scrubbed["log"] as? String)?.contains("[REDACTED]") == true)
    }

    func test_scrubMeta_returnsNilForNil() {
        XCTAssertNil(MonitorScrubber.scrubMeta(nil))
    }

    func test_scrubMeta_doesNotAddRedactedKeyWhenNothingRedacted() {
        let meta: [String: Any] = ["plan": "pro", "region": "eu"]
        let scrubbed = MonitorScrubber.scrubMeta(meta)!
        XCTAssertNil(scrubbed["_onelo_redacted"])
    }

    func test_scrubMeta_replacesDeepNestedSubtreeWithMarker() {
        // Build a payload deeper than the scrubber's max depth (10).
        // Pre-fix the deep sub-tree was returned untouched, which could hide
        // secrets buried below the limit. Now the whole sub-tree is replaced.
        var deep: [String: Any] = ["password": "leaked"]
        for _ in 0..<15 {
            deep = ["nested": deep]
        }
        let scrubbed = MonitorScrubber.scrubMeta(deep)!
        // Walk down the result and assert we either hit the marker or never
        // see the leaked secret.
        var node: Any = scrubbed
        var foundMarker = false
        for _ in 0..<20 {
            guard let dict = node as? [String: Any] else { break }
            if dict["_onelo_depth_exceeded"] as? Bool == true {
                foundMarker = true
                break
            }
            if let next = dict["nested"] {
                node = next
            } else {
                break
            }
        }
        XCTAssertTrue(foundMarker, "expected _onelo_depth_exceeded marker somewhere in the tree")
    }

    // MARK: - scrubURL

    func test_scrubURL_redactsSensitiveQueryParams() {
        let url = URL(string: "https://api.example.com/x?token=secret&user=alice")!
        let scrubbed = MonitorScrubber.scrubURL(url)!
        XCTAssertTrue(scrubbed.contains("token=%5BREDACTED%5D") || scrubbed.contains("token=[REDACTED]"))
        XCTAssertTrue(scrubbed.contains("user=alice"))
    }

    func test_scrubURL_passesThroughBenignURL() {
        let url = URL(string: "https://api.example.com/users?limit=10")!
        let scrubbed = MonitorScrubber.scrubURL(url)!
        XCTAssertTrue(scrubbed.contains("limit=10"))
    }

    // MARK: - scrubHeaders

    func test_scrubHeaders_redactsAuthorizationAndCookie() {
        let h = ["Authorization": "Bearer xyz", "X-Plan": "pro", "cookie": "session=abc"]
        let s = MonitorScrubber.scrubHeaders(h)!
        XCTAssertEqual(s["Authorization"], "[REDACTED]")
        XCTAssertEqual(s["cookie"], "[REDACTED]")
        XCTAssertEqual(s["X-Plan"], "pro")
    }
}
