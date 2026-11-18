import XCTest
@testable import OneloSwift

/// #1074 — the SDK's own texts ("Close", "Sign In", "Use a different method",
/// the feedback window, error messages) are in the App's Page Language: the
/// one `/api/sdk/config` answers for the App's language, else the device
/// language. Every text exists in en, pl, de, fr, es, it, pt, nl. Storage is
/// in memory: no Keychain prompt.
@MainActor
final class BuiltInTexts1074Tests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var urls: [URL] = []
        nonisolated(unsafe) static var pageLanguage: Any? = "de"
        nonisolated(unsafe) static var configAcceptLanguage: String?
        nonisolated(unsafe) static var waitlistLanguage: String?
        static let lock = NSLock()
        static let host = "texts1074.example.invalid"

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let answer = Self.lock.withLock { () -> Any? in
                Self.urls.append(url)
                return Self.pageLanguage
            }
            var status = 200
            var json: [String: Any] = [:]
            if url.path.hasSuffix("/api/sdk/config") {
                let accept = request.value(forHTTPHeaderField: "Accept-Language")
                Self.lock.withLock { Self.configAcceptLanguage = accept }
                json = ["supabase_url": "https://\(Self.host)", "supabase_anon_key": "anon",
                        "tenant_id": "tenant-1", "attest_required": false, "paywall_enabled": false]
                if let answer { json["page_language"] = answer }
            } else if url.path.hasSuffix("/api/sdk/waitlist/join") {
                let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any]
                Self.lock.withLock { Self.waitlistLanguage = body?["language"] as? String }
                json = ["position": 1]
            } else if url.path.hasSuffix("/store-initiate") {
                json = ["store_url": "https://st.example/store/hosted?token=srt_1"]
            } else {
                status = 204
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200 {
                client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        private static func body(of request: URLRequest) -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }

        static func lang(sentTo suffix: String) -> String? {
            let url = lock.withLock { urls.last(where: { $0.path.hasSuffix(suffix) }) }
            guard let url else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "lang" })?.value
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(Stub.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(Stub.self)
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        Stub.lock.withLock { Stub.urls = []; Stub.pageLanguage = "de"; Stub.configAcceptLanguage = nil; Stub.waitlistLanguage = nil }
        OneloPageLanguage.adopt("en")
    }
    override func tearDown() {
        // The Page Language is one value per process: leave English behind.
        OneloPageLanguage.adopt("en")
        super.tearDown()
    }

    private let baseURL = URL(string: "https://\(Stub.host)")!
    private var device: String { OneloSignupMarketingConsent.deviceLanguage }

    private func config(language: String? = nil) -> OneloConfig {
        OneloConfig(publishableKey: "onelo_pk_test_texts1074", apiUrl: baseURL, language: language)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Every text in every language

    func test_onelo_translates_into_the_eight_supported_languages() {
        XCTAssertEqual(OneloPageLanguage.supported, ["en", "pl", "de", "fr", "es", "it", "pt", "nl"])
        XCTAssertEqual(Set(OneloText.table.keys), Set(OneloPageLanguage.supported))
    }

    func test_every_built_in_text_exists_in_every_supported_language() {
        for lang in OneloPageLanguage.supported {
            let texts = OneloText.table[lang] ?? [:]
            for key in OneloText.allCases {
                let value = texts[key]
                XCTAssertNotNil(value, "\(key) has no \(lang) text")
                XCTAssertFalse((value ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is empty in \(lang)")
            }
            XCTAssertEqual(texts.count, OneloText.allCases.count, "\(lang) carries a text no case names")
        }
    }

    func test_a_text_carrying_a_detail_keeps_its_place_in_every_language() {
        for lang in OneloPageLanguage.supported {
            for key in [OneloText.errorNetwork, .errorTimeout, .badgeAvailableIn] {
                XCTAssertTrue(key.text(in: lang).contains("{detail}"), "\(key) in \(lang) loses {detail}")
            }
        }
    }

    func test_the_translations_are_not_english_copies() {
        // A few texts read the same in two languages ("Feedback"); a whole
        // table equal to English is an untranslated copy.
        let english = OneloText.table["en"]!
        for lang in OneloPageLanguage.supported where lang != "en" {
            let same = OneloText.allCases.filter { OneloText.table[lang]![$0] == english[$0] }
            XCTAssertLessThan(same.count, 3, "\(lang) repeats English for \(same)")
        }
    }

    func test_german_is_formal() {
        XCTAssertTrue(OneloText.couldNotConfirmAccess.text(in: "de").contains("Ihr"))
        XCTAssertTrue(OneloText.signingYouIn.text(in: "de").contains("Sie"))
        for key in OneloText.allCases {
            let de = " " + key.text(in: "de") + " "
            XCTAssertFalse(de.contains(" du ") || de.contains(" dein"), "\(key) addresses the reader as du")
        }
    }

    // MARK: The texts follow the Page Language

    func test_the_texts_follow_the_adopted_page_language() {
        XCTAssertEqual(OneloText.close.text, "Close")
        OneloPageLanguage.adopt("pl-PL")
        XCTAssertEqual(OneloPageLanguage.current, "pl")
        XCTAssertEqual(OneloText.close.text, "Zamknij")
        XCTAssertEqual(OneloText.signIn.text, "Zaloguj się")
        OneloPageLanguage.adopt("pt")
        XCTAssertEqual(OneloText.sendFeedback.text, "Enviar feedback")
    }

    func test_app_user_errors_speak_the_page_language_developer_errors_stay_as_written() {
        OneloPageLanguage.adopt("fr")
        XCTAssertEqual(OneloError.sessionEnded.errorDescription, OneloText.errorSessionEnded.text(in: "fr"))
        XCTAssertEqual(OneloError.networkError("offline").errorDescription, "Erreur réseau : offline")
        XCTAssertEqual(OneloError.invalidPublishableKey("bad").errorDescription, "Invalid publishable key: bad")
        XCTAssertEqual(OneloError.serverError("Server said no").errorDescription, "Server said no")
    }

    func test_a_language_onelo_does_not_translate_into_shows_english() {
        // Only a language carried over from an older setting can be one.
        OneloPageLanguage.adopt("sv")
        XCTAssertEqual(OneloText.close.text, "Close")
    }

    func test_no_answer_keeps_the_current_language() {
        OneloPageLanguage.adopt("it")
        XCTAssertNil(OneloPageLanguage.adopt(nil))
        XCTAssertNil(OneloPageLanguage.adopt("not a tag"))
        XCTAssertEqual(OneloPageLanguage.current, "it")
    }

    func test_the_error_page_declares_its_language_and_translates_its_button() {
        OneloPageLanguage.adopt("nl")
        let html = oneloErrorPageHTML(.neutral, title: "t", message: "m", retryHref: "onelo://feedback_retry")
        XCTAssertTrue(html.contains("<html lang=\"nl\">"))
        XCTAssertTrue(html.contains("Opnieuw proberen"))
    }

    // MARK: The backend chooses; the SDK asks and adopts

    func test_config_decodes_the_page_language_and_tolerates_an_older_backend() throws {
        let base: [String: Any] = ["supabase_url": "https://x", "supabase_anon_key": "a", "tenant_id": "t"]
        var withLang = base
        withLang["page_language"] = "es"
        let decoded = try JSONDecoder().decode(ResolvedConfig.self, from: JSONSerialization.data(withJSONObject: withLang))
        XCTAssertEqual(decoded.pageLanguage, "es")
        let older = try JSONDecoder().decode(ResolvedConfig.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertNil(older.pageLanguage)
    }

    func test_launch_asks_with_the_device_language_and_adopts_the_answer() async {
        let storage = InMemorySessionStorage()
        let auth = OneloAuth(config: config(), storage: storage)
        await waitUntil { auth.pageLanguage == "de" }
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/config"), device)
        XCTAssertEqual(auth.pageLanguage, "de")
        XCTAssertEqual(OneloText.close.text, "Schließen")
        // Kept for the next launch's first paint.
        XCTAssertEqual(storage.snapshot["page_language"], "de")
    }

    func test_the_device_languages_are_the_next_choice_after_the_one_asked_with() async {
        XCTAssertEqual(OneloPageLanguage.deviceAcceptLanguage(["pt-PT", "en-GB", "de"]), "pt-PT, en-GB;q=0.9, de;q=0.8")
        XCTAssertNil(OneloPageLanguage.deviceAcceptLanguage([]))
        let auth = OneloAuth(config: config(language: "sv"), storage: InMemorySessionStorage())
        await waitUntil { auth.pageLanguage == "de" }
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/config"), "sv")
        XCTAssertEqual(Stub.lock.withLock { Stub.configAcceptLanguage }, OneloPageLanguage.deviceAcceptLanguage())
    }

    func test_the_language_the_app_passes_is_what_the_sdk_asks_with() async {
        Stub.lock.withLock { Stub.pageLanguage = "pl" }
        let auth = OneloAuth(config: config(language: "pl"), storage: InMemorySessionStorage())
        await waitUntil { auth.pageLanguage == "pl" }
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/config"), "pl")
        XCTAssertEqual(OneloText.signIn.text, "Zaloguj się")
    }

    func test_the_last_page_language_paints_the_first_frame() {
        let auth = OneloAuth(_testingConfig: config(), storage: InMemorySessionStorage(["page_language": "fr"]))
        XCTAssertEqual(auth.pageLanguage, "fr")
        XCTAssertEqual(OneloText.close.text, "Fermer")
    }

    func test_a_backend_that_cannot_tell_keeps_the_language_the_sdk_had() async {
        Stub.lock.withLock { Stub.pageLanguage = nil }
        let auth = OneloAuth(config: config(), storage: InMemorySessionStorage(["page_language": "it"]))
        await waitUntil { auth.isReady }
        XCTAssertTrue(auth.isReady)
        XCTAssertEqual(auth.pageLanguage, "it")
        XCTAssertEqual(OneloText.close.text, "Chiudi")
    }

    func test_hosted_pages_get_the_language_the_app_passed_too() async throws {
        let auth = OneloAuth(
            config: OneloConfig(publishableKey: "onelo_pk_test_texts1074", apiUrl: baseURL,
                                callbackScheme: "turingo", language: "nl"),
            urlSession: .shared, skipInitialize: true, storage: InMemorySessionStorage()
        )
        _ = try await auth.initiateStoreFlow()
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/store-initiate"), "nl")
        // A language passed for one page still wins for that page.
        _ = try await auth.initiateStoreFlow(lang: "es")
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/store-initiate"), "es")
    }

    // MARK: Errors on SDK screens (review F1)

    func test_an_sdk_screen_never_shows_a_raw_english_diagnostic() {
        OneloPageLanguage.adopt("pl")
        let generic = OneloText.somethingWentWrong.text(in: "pl")
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.serverError("flow/init failed (500)"), context: "test"), generic)
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.serverError("Code exchange failed: bad"), context: "test"), generic)
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.invalidResponse, context: "test"), generic)
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.invalidPublishableKey("x"), context: "test"), generic)
        XCTAssertEqual(oneloAppUserMessage(for: NSError(domain: "Other", code: 1), context: "test"), generic)
    }

    func test_a_connection_failure_says_so_in_the_page_language() {
        OneloPageLanguage.adopt("de")
        let connection = OneloText.connectionProblem.text(in: "de")
        XCTAssertEqual(oneloAppUserMessage(for: URLError(.notConnectedToInternet), context: "test"), connection)
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.networkError("HTTP 503"), context: "test"), connection)
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.timeout("ready"), context: "test"), connection)
    }

    func test_an_error_meant_for_the_app_user_keeps_its_own_words() {
        OneloPageLanguage.adopt("es")
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.sessionEnded, context: "test"),
                       OneloText.errorSessionEnded.text(in: "es"))
        XCTAssertEqual(oneloAppUserMessage(for: OneloError.noActivePlan, context: "test"),
                       OneloText.errorNoActivePlan.text(in: "es"))
    }

    // MARK: The App's language reaches every request (review F3)

    func test_a_waitlist_join_without_a_language_sends_the_apps() async {
        let client = _OneloHTTPClient(publishableKey: "onelo_pk_test_texts1074", baseURL: baseURL,
                                      securityContext: _OneloSecurityContext())
        let waitlist = OneloWaitlist(client: client, language: "it")
        _ = await waitlist.join("list-1", email: "a@b.c")
        XCTAssertEqual(Stub.lock.withLock { Stub.waitlistLanguage }, "it")
        // A language passed for one join still wins for that join.
        _ = await waitlist.join("list-1", email: "a@b.c", language: "es")
        XCTAssertEqual(Stub.lock.withLock { Stub.waitlistLanguage }, "es")
    }

    func test_upgrade_sends_the_apps_language() async {
        let onelo = Onelo(testingKey: "onelo_pk_test_texts1074", baseURL: baseURL, language: "fr",
                          skipAuthInitialize: true)
        onelo.auth.authObject._injectSessionForTesting(OneloSession(
            accessToken: "tok", refreshToken: "ref", expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u1", email: "a@b.c", role: .member, tenantId: nil)
        ))
        await onelo.openUpgrade(forPlan: "pro")
        XCTAssertEqual(Stub.lang(sentTo: "/api/sdk/paywall/upgrade-initiate"), "fr")
    }

    // MARK: Feature badges (review R2-F1)

    func test_feature_badges_speak_the_page_language_and_keep_the_plan_name() {
        OneloPageLanguage.adopt("de")
        XCTAssertEqual(FeatureState(name: "chat", status: .new).badgeLabel, "Neu")
        XCTAssertEqual(FeatureState(name: "chat", status: .coming_soon).badgeLabel, "Demnächst verfügbar")
        XCTAssertEqual(FeatureState(name: "chat", status: .greyed).badgeLabel, "🔒")
        let upsell = FeatureState(name: "chat", status: .upsell, requiredPlan: "pro", requiredPlanLabel: "Pro Plus")
        XCTAssertEqual(upsell.badgeLabel, "Verfügbar im Plan Pro Plus")
        XCTAssertEqual(FeatureState(name: "chat", status: .upsell).badgeLabel, "Plan ändern")
        OneloPageLanguage.adopt("en")
        XCTAssertEqual(upsell.badgeLabel, "Available in Pro Plus")
    }

    func test_the_view_models_failures_speak_the_page_language() async {
        OneloPageLanguage.adopt("it")
        let vm = OneloAuthViewModel(
            auth: OneloAuth(_testingConfig: config(), storage: InMemorySessionStorage()), onSuccess: nil
        )
        vm.email = "a@b.c"
        vm.password = "secret123"
        await vm.submitSignIn()
        let message = vm.errorMessage ?? ""
        // Read the language after the await: a launch left running by an
        // earlier test may have adopted its own answer meanwhile.
        let lang = OneloPageLanguage.current
        XCTAssertTrue(
            [OneloText.somethingWentWrong, .connectionProblem, .errorNotAuthenticated]
                .map { $0.text(in: lang) }.contains(message),
            "raw message on the view model: \(message)"
        )
    }

    // MARK: Badge words are the hosted page's words (owner decision, #1075 review F1)

    /// The monorepo's frontend dictionaries; the published SDK repository has
    /// no `frontend/`, so the pin is skipped there.
    private func frontendDictionary(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("frontend/lib/\(name)")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(url.path) not present (published SDK repository)")
        }
        return source
    }

    /// The value of `key` in the `lang: {` block of a TS dictionary: a quoted
    /// string, or a template literal whose `${...}` becomes `{detail}`.
    private func value(of key: String, in lang: String, source: String) -> String? {
        guard let block = source.range(of: "\n  \(lang): {") else { return nil }
        let rest = String(source[block.upperBound...])
        let pattern = key + #":\s*(?:\([a-z]+\)\s*=>\s*`([^`]*)`|'([^']*)'|"([^"]*)")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return nil }
        for i in 1...3 {
            if let r = Range(m.range(at: i), in: rest) {
                return String(rest[r]).replacingOccurrences(
                    of: #"\$\{[a-zA-Z]+\}"#, with: "{detail}", options: .regularExpression
                )
            }
        }
        return nil
    }

    func test_badge_words_are_the_hosted_pages_words_in_every_language() throws {
        let notice = try frontendDictionary("hosted-notice-i18n.ts")
        let store = try frontendDictionary("store-i18n.ts")
        for lang in OneloPageLanguage.supported {
            XCTAssertEqual(OneloText.badgeComingSoon.text(in: lang),
                           value(of: "lockComingSoon", in: lang, source: notice), "\(lang) Coming soon")
            XCTAssertEqual(OneloText.badgeAvailableIn.text(in: lang),
                           value(of: "lockAvailableIn", in: lang, source: notice), "\(lang) Available in")
            XCTAssertEqual(OneloText.badgeUpgrade.text(in: lang),
                           value(of: "changePlan", in: lang, source: store), "\(lang) Upgrade")
        }
    }
}
