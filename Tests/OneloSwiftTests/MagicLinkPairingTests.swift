import XCTest
import AuthenticationServices
import CryptoKit
@testable import OneloSwift

/// A magic link paired with a code (#540/#541): the hosted flow is bound to the
/// flow verifier, and the paired return — in the container or over the OS deep
/// link — is exchanged with that verifier.
///
/// Only `skipInitialize: true` instances are built, so no `initialize()` runs.
@MainActor
final class MagicLinkPairingTests: XCTestCase {

    /// In-memory session store (#732): never the real Keychain. A "relaunched"
    /// instance built over the same store reads what the first one persisted.
    private let storage = InMemorySessionStorage()

    /// Captures `/hosted-callback` and answers with a canned status and body.
    final class ExchangeStub: URLProtocol {
        /// `/hosted-callback` bodies only. Signing in also starts unrelated
        /// traffic on the same session (e.g. presence), recorded in `paths`.
        nonisolated(unsafe) static var bodies: [[String: Any]] = []
        nonisolated(unsafe) static var paths: [String] = []
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var reply: [String: Any] = [:]
        nonisolated(unsafe) static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "pairing.example.invalid"
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
            Self.lock.lock()
            Self.paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/hosted-callback") == true { Self.bodies.append(json) }
            let status = Self.status
            let reply = Self.reply
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let sessionReply: [String: Any] = [
        "access_token": "at", "refresh_token": "rt", "expires_in": 3600,
        "user": ["id": "u1", "email": "a@example.com"],
    ]

    private func makeAuth() -> OneloAuth {
        let config = OneloConfig(
            publishableKey: "onelo_pk_test_stub",
            apiUrl: URL(string: "https://pairing.example.invalid")!,
            callbackScheme: "turingo"
        )
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ExchangeStub.self]
        let auth = OneloAuth(config: config, urlSession: URLSession(configuration: cfg), skipInitialize: true, storage: storage)
        auth._setReadyForTesting(true)
        return auth
    }

    override func setUp() async throws {
        try await super.setUp()
        ExchangeStub.lock.lock()
        ExchangeStub.bodies = []
        ExchangeStub.paths = []
        ExchangeStub.status = 200
        ExchangeStub.reply = Self.sessionReply
        ExchangeStub.lock.unlock()
        try? storage.delete(forKey: "flow_code_verifier")
        try? storage.delete(forKey: "flow_code_verifier_issued_at")
    }

    override func tearDown() async throws {
        try? storage.delete(forKey: "flow_code_verifier")
        try? storage.delete(forKey: "flow_code_verifier_issued_at")
        try await super.tearDown()
    }

    private func s256(_ verifier: String) -> String {
        // Same derivation as the backend (sdk_auth.py hosted_callback).
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The deep link relaunched the app: a NEW instance, nothing in memory, only
    /// the persisted copy of the verifier whose challenge the flow carried.
    func test_a_relaunched_app_exchanges_with_the_stored_flow_verifier() async throws {
        let challenge = makeAuth()._beginFlowPKCE()
        let stored = try XCTUnwrap(try storage.get(forKey: "flow_code_verifier"))
        XCTAssertEqual(s256(stored), challenge)

        let relaunched = makeAuth()
        let session = try await relaunched.handleAuthCallback(URL(string: "turingo://callback?code=paired")!)

        XCTAssertEqual(session?.accessToken, "at")
        XCTAssertEqual(ExchangeStub.bodies.count, 1)
        XCTAssertEqual(ExchangeStub.bodies.first?["code"] as? String, "paired")
        XCTAssertEqual(ExchangeStub.bodies.first?["code_verifier"] as? String, stored)
        // Finished: the verifier cannot match the next flow's challenge.
        XCTAssertNil(try storage.get(forKey: "flow_code_verifier"))
    }

    /// A refused exchange is reported with the backend's reason, after ONE
    /// request, and the stored verifier is kept (the link is still unspent).
    func test_a_pkce_refusal_is_one_request_with_a_clear_message() async throws {
        let auth = makeAuth()
        _ = auth._beginFlowPKCE()
        ExchangeStub.status = 401
        ExchangeStub.reply = ["detail": "PKCE verification failed"]

        do {
            _ = try await auth.handleAuthCallback(URL(string: "turingo://callback?code=paired")!)
            XCTFail("expected the refusal to throw")
        } catch OneloError.serverError(let message) {
            XCTAssertTrue(message.contains("PKCE verification failed"), message)
        }
        XCTAssertEqual(ExchangeStub.bodies.count, 1)
        XCTAssertNotNil(try storage.get(forKey: "flow_code_verifier"))
    }

    func test_a_missing_verifier_surfaces_the_backend_reason() {
        XCTAssertEqual(
            OneloAuth._exchangeFailureMessage(["detail": "code_verifier required"]),
            "Code exchange failed: code_verifier required"
        )
        XCTAssertEqual(OneloAuth._exchangeFailureMessage([:]), "Code exchange failed")
    }

    /// Same device: the link opened from Mail reaches the app through the OS
    /// while `presentHostedSignIn`'s sheet waits. That sheet must finish with the
    /// session and close, not hang.
    func test_an_os_return_settles_the_waiting_sheet() async throws {
        let auth = makeAuth()
        _ = auth._beginFlowPKCE()
        var dismissed = 0

        let waiting = Task { @MainActor in
            try await auth._awaitHostedReturn { _ in { dismissed += 1 } }
        }
        await Task.yield()
        await Task.yield()

        let session = try await auth.handleAuthCallback(URL(string: "turingo://callback?code=paired")!)
        let result = try await waiting.value

        guard case .session(let parkedSession) = result else {
            return XCTFail("expected the parked sheet to receive the session, got \(result)")
        }
        XCTAssertEqual(parkedSession.accessToken, session?.accessToken)
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(ExchangeStub.bodies.count, 1, "the code must be exchanged once; saw \(ExchangeStub.paths)")
    }

    /// Other device: the page inside the sheet navigates to the callback. The
    /// sheet's own completion delivers it; a later `.canceledLogin` from
    /// dismissing it is ignored.
    func test_an_in_sheet_return_resolves_once() async throws {
        let auth = makeAuth()
        var complete: ((Result<URL, Error>) -> Void)?
        let waiting = Task { @MainActor in
            try await auth._awaitHostedReturn { c in complete = c; return {} }
        }
        await Task.yield()
        await Task.yield()

        complete?(.success(URL(string: "turingo://callback?code=paired")!))
        complete?(.failure(OneloError.cancelled))

        guard case .callback(let url) = try await waiting.value else { return XCTFail("expected the callback URL") }
        XCTAssertEqual(url.absoluteString, "turingo://callback?code=paired")
    }

    /// The person closes the sheet: a clean `.cancelled`, and they can start again.
    func test_closing_the_sheet_is_a_clean_cancel() async throws {
        let mapped = OneloAuth._mapAuthSessionCompletion(
            url: nil,
            error: ASWebAuthenticationSessionError(.canceledLogin)
        )
        guard case .failure(OneloError.cancelled) = mapped else { return XCTFail("expected .cancelled, got \(mapped)") }

        let auth = makeAuth()
        var complete: ((Result<URL, Error>) -> Void)?
        let waiting = Task { @MainActor in
            try await auth._awaitHostedReturn { c in complete = c; return {} }
        }
        await Task.yield()
        await Task.yield()
        complete?(mapped)
        do {
            _ = try await waiting.value
            XCTFail("expected cancel")
        } catch OneloError.cancelled {}

        // Nothing is left parked: a later deep link does not resurrect it, and a
        // new presentation starts cleanly.
        XCTAssertFalse(auth._settleParkedHostedSignIn(.failure(OneloError.cancelled)))
    }
}
