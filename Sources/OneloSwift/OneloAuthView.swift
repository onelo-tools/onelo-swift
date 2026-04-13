// Sources/OneloSwift/OneloAuthView.swift
import SwiftUI
import AuthenticationServices

#if os(iOS)
private final class WindowContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
#elseif os(macOS)
private final class WindowContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
#endif

/// Drop-in SwiftUI authentication view.
///
/// ```swift
/// OneloAuthView(auth: onelo.auth.authObject, config: .default) { session in
///     // user signed in
/// }
/// ```
public struct OneloAuthView: View {
    @StateObject private var vm: OneloAuthViewModel
    private let requestedConfig: OneloAuthConfig
    private let auth: any OneloAuthProtocol
    @State private var allowCustomBranding: Bool = false

    /// Returns the config to render. On free plan, enforces Onelo brand.
    private var effectiveConfig: OneloAuthConfig {
        if !allowCustomBranding {
            return .oneloBranded
        }
        return requestedConfig
    }

    public init(
        auth: any OneloAuthProtocol,
        config: OneloAuthConfig = .default,
        onSuccess: @escaping (OneloSession) -> Void
    ) {
        _vm = StateObject(wrappedValue: OneloAuthViewModel(auth: auth, onSuccess: onSuccess))
        self.requestedConfig = config
        self.auth = auth
    }

    public var body: some View {
        ZStack {
            effectiveConfig.backgroundColor.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Logo / app name
                    VStack(spacing: 8) {
                        if let logo = effectiveConfig.appLogo {
                            logo
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: effectiveConfig.cornerRadius))
                        }
                        if !effectiveConfig.appName.isEmpty {
                            Text(effectiveConfig.appName)
                                .font(.headline)
                                .foregroundStyle(effectiveConfig.textColor)
                        }
                    }
                    .padding(.bottom, 32)

                    // Free tier: hosted flow button; paid tier: inline form
                    if !allowCustomBranding {
                        HostedSignInButton(auth: auth, config: effectiveConfig, onSuccess: vm.onSuccess)
                    } else {
                        Group {
                            switch vm.screen {
                            case .signIn:         SignInScreen(vm: vm, config: effectiveConfig)
                            case .signUp:         SignUpScreen(vm: vm, config: effectiveConfig)
                            case .forgotPassword: ForgotPasswordScreen(vm: vm, config: effectiveConfig)
                            }
                        }
                    }

                    Spacer(minLength: 32)

                    // Hardcoded Onelo branding — cannot be removed
                    OneloFooter(subtitleColor: effectiveConfig.subtitleColor)
                }
                .padding(effectiveConfig.contentPadding)
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await value in oneloAuth.$allowCustomBranding.values {
                allowCustomBranding = value
            }
        }
    }
}

// MARK: - Sign In Screen

private struct SignInScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("Sign in")
                .font(.title2.bold())
                .foregroundStyle(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, config.itemSpacing + 4)

            // Fields group
            VStack(spacing: config.itemSpacing) {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                    .textContentType(.password)
#endif
            }

            // Error
            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            // Primary action
            AuthButton("Sign In", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignIn() }
            }
            .padding(.top, config.itemSpacing + 8)

            // Secondary actions
            VStack(spacing: 8) {
                Button("Forgot password?") { vm.showForgotPassword() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(config.accentColor)

                HStack(spacing: 4) {
                    Text("Don't have an account?")
                        .foregroundStyle(config.subtitleColor)
                    Button("Sign up") { vm.showSignUp() }
                        .buttonStyle(.plain)
                        .foregroundStyle(config.accentColor)
                }
                .font(.subheadline)
            }
            .padding(.top, config.itemSpacing + 4)
        }
    }
}

// MARK: - Sign Up Screen

private struct SignUpScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("Create account")
                .font(.title2.bold())
                .foregroundStyle(config.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, config.itemSpacing + 4)

            // Fields group
            VStack(spacing: config.itemSpacing) {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                AuthSecureField("Password", text: $vm.password, config: config)
#if os(iOS)
                    .textContentType(.newPassword)
#endif

                AuthSecureField("Confirm password", text: $vm.confirmPassword, config: config)
#if os(iOS)
                    .textContentType(.newPassword)
#endif
            }

            // Error / success
            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            if vm.signUpVerificationSent {
                Text("Check your email to verify your account.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            // Primary action
            AuthButton("Create Account", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignUp() }
            }
            .padding(.top, config.itemSpacing + 8)

            // Secondary action
            HStack(spacing: 4) {
                Text("Already have an account?")
                    .foregroundStyle(config.subtitleColor)
                Button("Sign in") { vm.showSignIn() }
                    .buttonStyle(.plain)
                    .foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, config.itemSpacing + 4)
        }
    }
}

// MARK: - Forgot Password Screen

private struct ForgotPasswordScreen: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: 0) {
            // Title
            VStack(spacing: 6) {
                Text("Reset password")
                    .font(.title2.bold())
                    .foregroundStyle(config.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Enter your email and we'll send you a reset link.")
                    .font(.subheadline)
                    .foregroundStyle(config.subtitleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, config.itemSpacing + 4)

            if vm.forgotPasswordSent {
                Text("Check your email for the reset link.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AuthTextField("Email", text: $vm.email, config: config)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }

                AuthButton("Send Reset Link", config: config, isLoading: vm.isLoading) {
                    Task { await vm.submitForgotPassword() }
                }
                .padding(.top, config.itemSpacing + 8)
            }

            Button("Back to sign in") { vm.showSignIn() }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(config.accentColor)
                .padding(.top, config.itemSpacing + 4)
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
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius)
                    .strokeBorder(config.inputBorderColor, lineWidth: config.inputBorderWidth)
            )
            .foregroundStyle(config.textColor)
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
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius)
                    .strokeBorder(config.inputBorderColor, lineWidth: config.inputBorderWidth)
            )
            .foregroundStyle(config.textColor)
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
                    ProgressView().tint(config.buttonForegroundColor)
                } else {
                    Text(label).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: config.buttonHeight)
            .background(config.accentColor)
            .foregroundStyle(config.buttonForegroundColor)
            .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

private struct OneloFooter: View {
    let subtitleColor: Color

    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            Text("Powered by ")
                .foregroundStyle(subtitleColor.opacity(0.6))
            + Text("Onelo")
                .foregroundStyle(subtitleColor.opacity(0.8))
        }
        .font(.caption2)
        .buttonStyle(.plain)
    }
}

// MARK: - Hosted Sign In Button (free tier)

private struct HostedSignInButton: View {
    let auth: any OneloAuthProtocol
    let config: OneloAuthConfig
    let onSuccess: ((OneloSession) -> Void)?

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .tint(config.accentColor)
                    .frame(height: config.buttonHeight)
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    Text("Sign In")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: config.buttonHeight)
                        .background(config.accentColor)
                        .foregroundStyle(config.buttonForegroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: config.cornerRadius))
                }
                .buttonStyle(.plain)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @MainActor
    private func signIn() async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            #if os(iOS) || os(macOS)
            let context = WindowContextProvider()
            let session = try await oneloAuth.presentHostedSignIn(from: context)
            onSuccess?(session)
            #endif
        } catch OneloError.cancelled {
            // User dismissed — no error shown
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
