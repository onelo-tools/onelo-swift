import XCTest
@testable import OneloSwift

/// Email Verification (#819) in the Swift SDK: the user fields, the gate on the
/// server's answer, and the resend / confirm calls an app with its own screen
/// uses. Only `skipInitialize: true` instances over in-memory storage are built
/// (#732), and the stub answers only its own host.
@MainActor
final class EmailVerificationTests: XCTestCase {

    final class VerifyStub: URLProtocol {
        nonisolated(unsafe) static var calls: [(path: String, body: [String: Any], auth: String?)] = []
        nonisolated(unsafe) static var replies: [String: (Int, [String: Any])] = [:]
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "verify.example.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    collected.append(buf, count: n)
                }
                data = collected
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let path = request.url?.path ?? ""
            Self.lock.lock()
            Self.calls.append((path, json, request.value(forHTTPHeaderField: "Authorization")))
            let (status, reply) = Self.replies.first(where: { path.hasSuffix($0.key) })?.value ?? (404, [:])
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeAuth() -> OneloAuth {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [VerifyStub.self]
        let auth = OneloAuth(
            config: OneloConfig(
                publishableKey: "onelo_pk_test_stub",
                apiUrl: URL(string: "https://verify.example.invalid")!,
                callbackScheme: "turingo"
            ),
            urlSession: URLSession(configuration: cfg),
            skipInitialize: true,
            storage: InMemorySessionStorage()
        )
        auth._setReadyForTesting(true)
        return auth
    }

    /// The recorded call to one endpoint. Injecting a session starts the
    /// presence heartbeat, which posts to the same stub host, so a call is
    /// picked by its path — never by position.
    private func recorded(_ path: String) -> (path: String, body: [String: Any], auth: String?)? {
        VerifyStub.lock.withLock { VerifyStub.calls.last(where: { $0.path == path }) }
    }

    private func unverifiedSession() -> OneloSession {
        OneloSession(
            accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(
                id: "u1", email: "a@b.c", role: .member, tenantId: nil, entitlement: .none,
                allowedIn: false, emailVerified: false, accessReason: "email_unverified"
            )
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        VerifyStub.lock.withLock {
            VerifyStub.calls = []
            VerifyStub.replies = [:]
        }
    }

    // MARK: - The fields travel with the user

    func test_fields_decode_and_survive_the_keychain_round_trip() throws {
        let json = """
        {"id":"u1","email":"a@b.c","entitlement":"none","allowed_in":false,
         "email_verified":false,"access_reason":"email_unverified"}
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(OneloUser.self, from: json)
        XCTAssertEqual(user.emailVerified, false)
        XCTAssertEqual(user.accessReason, "email_unverified")

        let again = try JSONDecoder().decode(OneloUser.self, from: try JSONEncoder().encode(user))
        XCTAssertEqual(again.emailVerified, false)
        XCTAssertEqual(again.accessReason, "email_unverified")
    }

    func test_absent_fields_stay_nil() throws {
        let user = try JSONDecoder().decode(OneloUser.self, from: #"{"id":"u1"}"#.data(using: .utf8)!)
        XCTAssertNil(user.emailVerified)
        XCTAssertNil(user.accessReason)
    }

    func test_a_complete_answer_clears_an_old_reason() {
        let merged = unverifiedSession().user.mergingAccessAnswer(
            ["allowed_in": true, "email_verified": true], entitlement: .none
        )
        XCTAssertEqual(merged.allowedIn, true)
        XCTAssertEqual(merged.emailVerified, true)
        XCTAssertNil(merged.accessReason)
    }

    // MARK: - Every path keeps the server's answer (#819 review F1)

    func test_the_wire_builder_keeps_the_access_answer() {
        let user = OneloUser.fromWire([
            "id": "u1", "email": "a@b.c", "entitlement": "none",
            "allowed_in": false, "email_verified": false, "access_reason": "email_unverified",
        ], id: "u1")
        XCTAssertEqual(user.allowedIn, false)
        XCTAssertEqual(user.emailVerified, false)
        XCTAssertEqual(user.accessReason, "email_unverified")
        XCTAssertEqual(user.email, "a@b.c")
    }

    /// The custom-UI sign-in and sign-up built their user by hand and dropped
    /// `allowed_in`, so the gate fell back to the local rule and let an
    /// unverified user into a free app. Every path now goes through
    /// `OneloUser.fromWire`; this pins that no hand-built wire user comes back.
    func test_no_auth_path_builds_a_user_from_the_wire_by_hand() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/OneloSwift/OneloAuth.swift"),
            encoding: .utf8
        )
        let handBuilt = source.components(separatedBy: "\n").filter {
            $0.contains("OneloUser(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        // The one survivor is the empty placeholder for a refresh with no user block.
        XCTAssertEqual(handBuilt.count, 1, "hand-built OneloUser in OneloAuth.swift: \(handBuilt)")
        XCTAssertTrue(handBuilt[0].contains(#"OneloUser(id: "", email: nil"#))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "OneloUser.fromWire(").count - 1, 4)
    }

    func test_a_signed_in_unverified_user_from_signin_is_kept_out_of_a_free_app() {
        // The /signin payload in required mode, through the builder sign-in uses.
        let auth = makeAuth()
        let user = OneloUser.fromWire(
            ["id": "u1", "entitlement": "none", "allowed_in": false,
             "email_verified": false, "access_reason": "email_unverified"], id: "u1")
        auth._setGateInputsForTesting(
            session: OneloSession(accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600), user: user),
            paywallEnabled: false
        )
        XCTAssertFalse(auth.isAllowedIn)
    }

    // MARK: - The gate

    func test_an_unverified_user_is_kept_out_of_a_free_app() {
        let auth = makeAuth()
        auth._setGateInputsForTesting(session: unverifiedSession(), paywallEnabled: false)
        XCTAssertFalse(auth.isAllowedIn)
    }

    // MARK: - Resend / confirm

    func test_resend_posts_as_the_signed_in_user() async throws {
        let auth = makeAuth()
        auth._injectSessionForTesting(unverifiedSession())
        VerifyStub.replies = ["/verify-email/resend": (200, ["sent": true, "email_verified": false])]

        let result = try await auth.resendVerificationEmail(redirectTo: "turingo://verified")

        XCTAssertEqual(result, OneloVerificationResend(sent: true, emailVerified: false))
        let call = try XCTUnwrap(recorded("/api/sdk/auth/verify-email/resend"))
        XCTAssertEqual(call.body["publishableKey"] as? String, "onelo_pk_test_stub")
        XCTAssertEqual(call.body["verify_redirect_to"] as? String, "turingo://verified")
        XCTAssertEqual(call.auth, "Bearer at")
    }

    func test_resend_maps_the_hourly_limit_and_the_off_mode() async {
        let auth = makeAuth()
        auth._injectSessionForTesting(unverifiedSession())

        VerifyStub.replies = ["/verify-email/resend": (429, ["detail": ["error": "verification_rate_limited"]])]
        do { _ = try await auth.resendVerificationEmail(); XCTFail("expected a refusal") }
        catch OneloError.verificationRateLimited {} catch { XCTFail("wrong error \(error)") }

        VerifyStub.replies = ["/verify-email/resend": (409, ["detail": ["error": "email_verification_off"]])]
        do { _ = try await auth.resendVerificationEmail(); XCTFail("expected a refusal") }
        catch OneloError.emailVerificationOff {} catch { XCTFail("wrong error \(error)") }
    }

    func test_resend_needs_a_signed_in_user() async {
        let auth = makeAuth()
        do { _ = try await auth.resendVerificationEmail(); XCTFail("expected a refusal") }
        catch OneloError.notAuthenticated {} catch { XCTFail("wrong error \(error)") }
    }

    func test_confirm_names_a_dead_link() async {
        let auth = makeAuth()
        VerifyStub.replies = ["/verify-email/confirm": (400, ["detail": ["error": "invalid_token"]])]
        do { try await auth.confirmEmail(token: "old"); XCTFail("expected a refusal") }
        catch OneloError.invalidVerificationToken {} catch { XCTFail("wrong error \(error)") }
    }

    func test_confirm_refreshes_the_session_so_the_app_opens_at_once() async throws {
        let auth = makeAuth()
        auth._setGateInputsForTesting(session: unverifiedSession(), paywallEnabled: false)
        VerifyStub.replies = ["/verify-email/confirm": (200, ["email_verified": true])]
        // The refresh round trip reads the Keychain, so its test seam stands in:
        // it answers as /refresh does — a fresh session carrying the new answer.
        var refreshed = 0
        auth._refreshOverrideForTesting = { [unowned auth] in
            refreshed += 1
            let fresh = OneloSession(
                accessToken: "at2", refreshToken: "rt2", expiresAt: Date().addingTimeInterval(900),
                user: OneloUser(id: "u1", email: "a@b.c", role: .member, tenantId: nil,
                                entitlement: .none, allowedIn: true, emailVerified: true)
            )
            auth._setGateInputsForTesting(session: fresh, paywallEnabled: false)
            return fresh
        }

        try await auth.confirmEmail(token: "tok")

        XCTAssertEqual(recorded("/api/sdk/auth/verify-email/confirm")?.body["token"] as? String, "tok")
        XCTAssertEqual(refreshed, 1, "confirm must refresh the signed-in session")
        XCTAssertNil(recorded("/api/sdk/auth/user"), "the 30 s-cached /user must not be asked")
        XCTAssertEqual(auth.currentSession?.user.emailVerified, true)
        XCTAssertTrue(auth.isAllowedIn)
    }

    func test_confirm_without_a_session_does_not_refresh() async throws {
        let auth = makeAuth()
        VerifyStub.replies = ["/verify-email/confirm": (200, ["email_verified": true])]
        var refreshed = 0
        auth._refreshOverrideForTesting = { refreshed += 1; return nil }
        try await auth.confirmEmail(token: "tok")
        XCTAssertEqual(refreshed, 0)
    }
}
