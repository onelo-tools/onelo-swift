// Sources/OneloSwift/OneloAuthViewModel.swift
import SwiftUI

// MARK: - Protocol (enables mocking in tests)

public protocol OneloAuthProtocol: AnyObject {
    func signIn(email: String, password: String) async throws -> OneloSession
    func signUp(email: String, password: String) async throws -> Bool
    func resetPassword(email: String, redirectTo: URL?) async throws
}

extension OneloAuth: OneloAuthProtocol {}

// MARK: - Screen enum

public enum OneloAuthScreen: Equatable {
    case signIn
    case signUp
    case forgotPassword
}

// MARK: - ViewModel

@MainActor
public final class OneloAuthViewModel: ObservableObject {
    @Published public var screen: OneloAuthScreen = .signIn

    // Form fields (shared across screens)
    @Published public var email: String = ""
    @Published public var password: String = ""
    @Published public var confirmPassword: String = ""

    // State
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var forgotPasswordSent: Bool = false
    @Published public var signUpVerificationSent: Bool = false

    private let auth: any OneloAuthProtocol
    public var onSuccess: ((OneloSession) -> Void)?

    public init(auth: any OneloAuthProtocol, onSuccess: ((OneloSession) -> Void)? = nil) {
        self.auth = auth
        self.onSuccess = onSuccess
    }

    // MARK: - Navigation

    public func showSignIn() { screen = .signIn; clearErrors() }
    public func showSignUp() { screen = .signUp; clearErrors() }

    /// Whether the "Don't have an account? Sign up" affordance may be shown.
    ///
    /// False when a plan is required but this build cannot satisfy it in-app:
    /// an Apple-store platform whose developer has NOT opted into showing the
    /// store inside the app (App Review guideline 3.1.1). Signing up there
    /// would create an account with no plan and walk straight past the very
    /// gate the developer switched on, so the affordance is removed rather
    /// than left to fail.
    ///
    /// Both flags come from /api/sdk/config; `inAppStoreAllowed` defaults to
    /// true, so an older backend behaves exactly as before.
    public var canSignUp: Bool {
        guard let onelo = auth as? OneloAuth else { return true }
        return !(onelo.paywallEnabled && !onelo.inAppStoreAllowed)
    }
    public func showForgotPassword() { screen = .forgotPassword; clearErrors() }

    // MARK: - Actions

    public func submitSignIn() async {
        clearErrors()
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter your email and password."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let session = try await auth.signIn(email: email, password: password)
            onSuccess?(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func submitSignUp() async {
        clearErrors()
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let needsVerification = try await auth.signUp(email: email, password: password)
            if needsVerification {
                // Email confirmation required — show success state, don't sign in yet
                signUpVerificationSent = true
            } else {
                let session = try await auth.signIn(email: email, password: password)
                onSuccess?(session)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func submitForgotPassword() async {
        clearErrors()
        guard !email.isEmpty else {
            errorMessage = "Please enter your email address."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await auth.resetPassword(email: email, redirectTo: nil)
            forgotPasswordSent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func clearErrors() {
        errorMessage = nil
        forgotPasswordSent = false
        signUpVerificationSent = false
    }
}
