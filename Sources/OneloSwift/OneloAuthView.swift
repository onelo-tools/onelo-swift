// Sources/OneloSwift/OneloAuthView.swift
import SwiftUI

/// Drop-in SwiftUI authentication view.
///
/// ```swift
/// OneloAuthView(auth: onelo.auth.authObject, config: .default) { session in
///     // user signed in
/// }
/// ```
public struct OneloAuthView: View {
    @StateObject private var vm: OneloAuthViewModel
    private let config: OneloAuthConfig

    public init(
        auth: any OneloAuthProtocol,
        config: OneloAuthConfig = .default,
        onSuccess: @escaping (OneloSession) -> Void
    ) {
        _vm = StateObject(wrappedValue: OneloAuthViewModel(auth: auth, onSuccess: onSuccess))
        self.config = config
    }

    public var body: some View {
        ZStack {
            config.backgroundColor.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Logo / app name
                    VStack(spacing: 8) {
                        if let logo = config.appLogo {
                            logo
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
                        }
                        if !config.appName.isEmpty {
                            Text(config.appName)
                                .font(.headline)
                                .foregroundColor(config.textColor)
                        }
                    }
                    .padding(.bottom, 24)

                    // Active screen
                    Group {
                        switch vm.screen {
                        case .signIn:         SignInScreen(vm: vm, config: config)
                        case .signUp:         SignUpScreen(vm: vm, config: config)
                        case .forgotPassword: ForgotPasswordScreen(vm: vm, config: config)
                        }
                    }

                    Spacer(minLength: 24)

                    // Hardcoded Onelo branding — cannot be removed
                    OneloFooter(subtitleColor: config.subtitleColor)
                }
                .padding(config.contentPadding)
            }
        }
    }
}

// MARK: - Sign In Screen

private struct SignInScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            Text("Sign in")
                .font(.title2.bold())
                .foregroundColor(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
#endif

            AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                .textContentType(.password)
#endif

            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Sign In", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignIn() }
            }

            Button("Forgot password?") { vm.showForgotPassword() }
                .font(.subheadline)
                .foregroundColor(config.accentColor)

            HStack(spacing: 4) {
                Text("Don't have an account?").foregroundColor(config.subtitleColor)
                Button("Sign up") { vm.showSignUp() }.foregroundColor(config.accentColor)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Sign Up Screen

private struct SignUpScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            Text("Create account")
                .font(.title2.bold())
                .foregroundColor(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
#endif

            AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                .textContentType(.newPassword)
#endif

            AuthSecureField("Confirm password", text: $vm.confirmPassword, config: config)
#if os(iOS)
                .textContentType(.newPassword)
#endif

            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Show "check your email" when verification is required
            if vm.forgotPasswordSent {
                Text("Check your email to verify your account.")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Create Account", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignUp() }
            }

            HStack(spacing: 4) {
                Text("Already have an account?").foregroundColor(config.subtitleColor)
                Button("Sign in") { vm.showSignIn() }.foregroundColor(config.accentColor)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Forgot Password Screen

private struct ForgotPasswordScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            Text("Reset password")
                .font(.title2.bold())
                .foregroundColor(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Enter your email and we'll send you a reset link.")
                .font(.subheadline)
                .foregroundColor(config.subtitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if vm.forgotPasswordSent {
                Text("Check your email for the reset link.")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
#endif

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AuthButton("Send Reset Link", config: config, isLoading: vm.isLoading) {
                    Task { await vm.submitForgotPassword() }
                }
            }

            Button("Back to sign in") { vm.showSignIn() }
                .font(.subheadline)
                .foregroundColor(config.accentColor)
        }
    }
}

// MARK: - Reusable components

private struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    let config: OneloAuthConfig

    init(_ placeholder: String, text: Binding<String>, config: OneloAuthConfig) {
        self.placeholder = placeholder
        self._text = text
        self.config = config
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .padding(.horizontal, 12)
            .frame(height: config.inputHeight)
            .background(config.surfaceColor)
            .cornerRadius(config.cornerRadius)
            .foregroundColor(config.textColor)
    }
}

private struct AuthSecureField: View {
    let placeholder: String
    @Binding var text: String
    let config: OneloAuthConfig

    init(_ placeholder: String, text: Binding<String>, config: OneloAuthConfig) {
        self.placeholder = placeholder
        self._text = text
        self.config = config
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .padding(.horizontal, 12)
            .frame(height: config.inputHeight)
            .background(config.surfaceColor)
            .cornerRadius(config.cornerRadius)
            .foregroundColor(config.textColor)
    }
}

private struct AuthButton: View {
    let label: String
    let config: OneloAuthConfig
    let isLoading: Bool
    let action: () -> Void

    init(_ label: String, config: OneloAuthConfig, isLoading: Bool, action: @escaping () -> Void) {
        self.label = label
        self.config = config
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(label).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: config.buttonHeight)
            .background(config.accentColor)
            .foregroundColor(.white)
            .cornerRadius(config.cornerRadius)
        }
        .disabled(isLoading)
    }
}

private struct OneloFooter: View {
    let subtitleColor: Color

    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            Text("Powered by ")
                .foregroundColor(subtitleColor.opacity(0.6))
            + Text("Onelo")
                .foregroundColor(subtitleColor.opacity(0.8))
        }
        .font(.caption2)
    }
}
