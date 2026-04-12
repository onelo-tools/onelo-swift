// Tests/OneloSwiftTests/OneloAuthViewModelTests.swift
import XCTest
@testable import OneloSwift

@MainActor
final class OneloAuthViewModelTests: XCTestCase {

    func test_initial_screen_is_signIn() {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        XCTAssertEqual(vm.screen, .signIn)
    }

    func test_navigate_to_signUp() {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.showSignUp()
        XCTAssertEqual(vm.screen, .signUp)
    }

    func test_navigate_to_forgotPassword() {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.showForgotPassword()
        XCTAssertEqual(vm.screen, .forgotPassword)
    }

    func test_navigate_back_to_signIn() {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.showSignUp()
        vm.showSignIn()
        XCTAssertEqual(vm.screen, .signIn)
    }

    func test_signIn_clears_error_on_start() async {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.errorMessage = "old error"
        vm.email = "test@example.com"
        vm.password = "password"
        await vm.submitSignIn()
        XCTAssertNil(vm.errorMessage)
    }

    func test_signIn_sets_error_on_failure() async {
        let auth = MockOneloAuth()
        auth.shouldFailSignIn = true
        let vm = OneloAuthViewModel(auth: auth)
        vm.email = "test@example.com"
        vm.password = "wrong"
        await vm.submitSignIn()
        XCTAssertNotNil(vm.errorMessage)
    }

    func test_signUp_sets_error_when_passwords_do_not_match() async {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.email = "test@example.com"
        vm.password = "abc123"
        vm.confirmPassword = "xyz999"
        await vm.submitSignUp()
        XCTAssertEqual(vm.errorMessage, "Passwords do not match.")
    }

    func test_forgotPassword_sets_success_message() async {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.email = "test@example.com"
        await vm.submitForgotPassword()
        XCTAssertTrue(vm.forgotPasswordSent)
    }

    func test_isLoading_true_during_signIn() async {
        let vm = OneloAuthViewModel(auth: MockOneloAuth())
        vm.email = "test@example.com"
        vm.password = "password"
        await vm.submitSignIn()
        XCTAssertFalse(vm.isLoading)
    }
}

// MARK: - Mock

@MainActor
final class MockOneloAuth: OneloAuthProtocol {
    var shouldFailSignIn = false
    var shouldFailSignUp = false

    func signIn(email: String, password: String) async throws -> OneloSession {
        if shouldFailSignIn { throw OneloError.serverError("Invalid credentials") }
        return OneloSession(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: Date().addingTimeInterval(3600),
            user: OneloUser(id: "u1", email: email, role: .member, tenantId: nil)
        )
    }

    func signUp(email: String, password: String) async throws -> Bool {
        if shouldFailSignUp { throw OneloError.serverError("Email taken") }
        return true
    }

    func resetPassword(email: String, redirectTo: URL?) async throws {}
}
