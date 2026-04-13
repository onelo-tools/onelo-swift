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
        Group {
            if !allowCustomBranding {
                // Free tier: full-screen branded hosted flow
                HostedSignInButton(auth: auth, config: effectiveConfig, onSuccess: vm.onSuccess)
            } else {
                // Paid tier: inline customisable form
                ZStack {
                    effectiveConfig.backgroundColor.ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 0) {
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

                            Group {
                                switch vm.screen {
                                case .signIn:         SignInScreen(vm: vm, config: effectiveConfig)
                                case .signUp:         SignUpScreen(vm: vm, config: effectiveConfig)
                                case .forgotPassword: ForgotPasswordScreen(vm: vm, config: effectiveConfig)
                                }
                            }

                            Spacer(minLength: 32)

                            HStack {
                                OneloFooter()
                                Spacer()
                            }
                        }
                        .padding(effectiveConfig.contentPadding)
                    }
                }
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

// MARK: - Onelo Logo (SVG-faithful SwiftUI replica)
// Logo: black background, white rotated square (diamond), orange dot top-right
// Colors from public/logo.svg: bg #111111, diamond white, dot #f97316

private let oneloOrange = Color(red: 0.976, green: 0.451, blue: 0.086) // #f97316

private struct OneloLogo: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111111
                .frame(width: size, height: size)

            // White diamond (rotated square)
            Rectangle()
                .fill(Color.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .cornerRadius(size * 0.06)
                .rotationEffect(.degrees(45))

            // Orange dot — top-right quadrant
            Circle()
                .fill(oneloOrange)
                .frame(width: size * 0.24, height: size * 0.24)
                .offset(x: size * 0.22, y: -size * 0.22)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Onelo Footer (with logo, left-aligned)

private struct OneloFooter: View {
    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            HStack(spacing: 5) {
                OneloLogo(size: 16)
                Text("Powered by ")
                    .foregroundStyle(Color.primary.opacity(0.35))
                + Text("Onelo")
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .font(.caption2)
        }
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
    @State private var appName: String = "App"
    @State private var appLogoUrl: URL? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                config.backgroundColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // App / Onelo branding block
                    VStack(spacing: 16) {
                        // Show app logo if available, otherwise Onelo logo
                        if let logoUrl = appLogoUrl {
                            AsyncImage(url: logoUrl) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                } else {
                                    OneloLogo(size: 72)
                                }
                            }
                        } else {
                            OneloLogo(size: 72)
                        }

                        VStack(spacing: 4) {
                            Text("Sign in to \(appName)")
                                .font(.title2.bold())
                                .foregroundStyle(config.textColor)

                            Text("Secure authentication powered by Onelo")
                                .font(.subheadline)
                                .foregroundStyle(config.subtitleColor)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.bottom, 40)

                    // Sign In button
                    VStack(spacing: 12) {
                        if isLoading {
                            ProgressView()
                                .tint(oneloOrange)
                                .frame(height: config.buttonHeight)
                        } else {
                            Button {
                                Task { await signIn() }
                            } label: {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: config.buttonHeight)
                                    .background(oneloOrange)
                                    .foregroundStyle(.white)
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
                    .padding(.horizontal, config.contentPadding.leading)

                    Spacer()

                    // Footer — left aligned
                    HStack {
                        OneloFooter()
                        Spacer()
                    }
                    .padding(.horizontal, config.contentPadding.leading)
                    .padding(.bottom, 24)
                }
                .frame(width: geo.size.width)
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await name in oneloAuth.$hostedAppName.values {
                appName = name
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await logoUrl in oneloAuth.$hostedAppLogoUrl.values {
                appLogoUrl = logoUrl
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
            // Sync updated app metadata after sign-in completes
            appName = oneloAuth.hostedAppName
            appLogoUrl = oneloAuth.hostedAppLogoUrl
            onSuccess?(session)
            #endif
        } catch OneloError.cancelled {
            // User dismissed — no error shown
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - HostedSignInButton app metadata sync extension
// appName / appLogoUrl are populated after presentHostedSignIn() calls /initiate.
// We observe OneloAuth.$hostedAppName and $hostedAppLogoUrl to update the UI
// if the button is shown before the first sign-in attempt completes.
private extension HostedSignInButton {
    func observeAppMetadata() async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        for await name in oneloAuth.$hostedAppName.values {
            appName = name
        }
    }
}
