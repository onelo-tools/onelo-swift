import XCTest
@testable import OneloSwift

@MainActor
final class OneloIdentityBridgeTests: XCTestCase {

    private func makeAuth() -> OneloAuth {
        OneloAuth(_testingConfig: OneloConfig(
            publishableKey: "pk_test",
            apiUrl: URL(string: "https://example.com")!,
            callbackScheme: ""
        ))
    }

    func testSessionPublisherEmitsUserIdOnSignIn() async {
        let auth = makeAuth()

        // Subscribe to the stream first, then inject — both on @MainActor so ordering is guaranteed.
        var iterator = auth.$currentSession.values.makeAsyncIterator()

        // Consume the initial nil that @Published emits on subscription.
        let initial: OneloSession?? = await iterator.next()
        XCTAssertNil(initial!)

        // Now inject a session and read the next emission.
        auth._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-xyz", email: nil, role: .member, tenantId: nil)
        ))

        let session: OneloSession?? = await iterator.next()
        XCTAssertEqual(session!!.user.id, "user-xyz")
    }

    func testSessionPublisherEmitsNilWhenSessionCleared() async {
        let auth = makeAuth()

        var iterator = auth.$currentSession.values.makeAsyncIterator()

        // Consume the initial nil.
        _ = await iterator.next()

        // Inject a session → emission #1.
        auth._injectSessionForTesting(OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 0),
            user: OneloUser(id: "user-xyz", email: nil, role: .member, tenantId: nil)
        ))
        let sessionEmission = await iterator.next()
        XCTAssertEqual(sessionEmission??.user.id, "user-xyz")

        // Clear the session → emission #2 should be nil (OneloSession? = nil).
        auth._clearSessionForTesting()
        let nilEmission = await iterator.next()  // OneloSession??
        let innerValue: OneloSession? = nilEmission!  // unwrap next()-Optional, keep inner Optional
        XCTAssertNil(innerValue)
    }
}
