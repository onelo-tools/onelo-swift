import SwiftUI

// MARK: - Public entry point

/// Drop-in authentication UI for Onelo.
///
/// Usage:
/// ```swift
/// OneloAuthView(auth: auth) {
///     ContentView()
/// }
/// ```
@MainActor
public struct OneloAuthView<Authenticated: View>: View {
    @ObservedObject public var auth: OneloAuth
    let authenticated: () -> Authenticated

    public init(auth: OneloAuth, @ViewBuilder authenticated: @escaping () -> Authenticated) {
        self.auth = auth
        self.authenticated = authenticated
    }

    public var body: some View {
        Group {
            if auth.currentSession != nil {
                authenticated()
            } else {
                _AuthFlowView(auth: auth)
            }
        }
    }
}

// MARK: - Flow controller

private enum AuthMode {
    case signIn, signUp, resetPassword
}

@MainActor
private struct _AuthFlowView: View {
    @ObservedObject var auth: OneloAuth
    @State private var mode: AuthMode = .signIn

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Card
                VStack(spacing: 32) {
                    _BrandHeader()

                    ZStack {
                        switch mode {
                        case .signIn:
                            _SignInForm(auth: auth, mode: $mode)
                                .transition(AnyTransition.asymmetric(
                                    insertion: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading)),
                                    removal: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading))
                                ))
                                .id("signIn")
                        case .signUp:
                            _SignUpForm(auth: auth, mode: $mode)
                                .transition(AnyTransition.asymmetric(
                                    insertion: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing)),
                                    removal: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing))
                                ))
                                .id("signUp")
                        case .resetPassword:
                            _ResetPasswordForm(auth: auth, mode: $mode)
                                .transition(AnyTransition.asymmetric(
                                    insertion: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing)),
                                    removal: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing))
                                ))
                                .id("resetPassword")
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mode)

                    if auth.showBranding {
                        _PoweredByView()
                    }
                }
                .padding(40)
                .frame(width: 400)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 40, x: 0, y: 8)

                Spacer()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

// MARK: - Brand header

private struct _BrandHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 44, height: 44)
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Sign In

@MainActor
private struct _SignInForm: View {
    @ObservedObject var auth: OneloAuth
    @Binding var mode: AuthMode

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("Welcome back")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                Text("Sign in to your account")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                _InputField(label: "Email", placeholder: "you@example.com", text: $email, isSecure: false, contentType: .emailAddress)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }

                _InputField(label: "Password", placeholder: "••••••••", text: $password, isSecure: true, contentType: .password)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await submit() } }
            }

            if let error {
                _ErrorBanner(message: error)
            }

            VStack(spacing: 12) {
                _PrimaryButton(title: "Sign in", isLoading: auth.isLoading || !auth.isReady) {
                    Task { await submit() }
                }

                HStack {
                    Button("Forgot password?") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .resetPassword } }
                        .buttonStyle(_LinkButtonStyle())
                    Spacer()
                    Button("Create account") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .signUp } }
                        .buttonStyle(_LinkButtonStyle())
                }
            }
        }
    }

    private func submit() async {
        guard !email.isEmpty, !password.isEmpty else {
            error = "Please fill in all fields."
            return
        }
        error = nil
        do {
            _ = try await auth.signIn(email: email, password: password)
        } catch OneloError.serverError(let msg) {
            switch msg {
            case "invalid_credentials": self.error = "Invalid email or password."
            case "banned":              self.error = "Your account has been suspended."
            default:                    self.error = msg
            }
        } catch {
            self.error = "Something went wrong. Please try again."
        }
    }
}

// MARK: - Sign Up

@MainActor
private struct _SignUpForm: View {
    @ObservedObject var auth: OneloAuth
    @Binding var mode: AuthMode

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var success = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, confirm }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("Create account")
                    .font(.system(size: 22, weight: .semibold))
                Text("Get started for free")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            if success {
                _SuccessBanner(message: "Check your email to confirm your account.")
            } else {
                VStack(spacing: 14) {
                    _InputField(label: "Email", placeholder: "you@example.com", text: $email, isSecure: false, contentType: .emailAddress)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }

                    _InputField(label: "Password", placeholder: "Min. 8 characters", text: $password, isSecure: true, contentType: .newPassword)
                        .focused($focusedField, equals: .password)
                        .onSubmit { focusedField = .confirm }

                    _InputField(label: "Confirm password", placeholder: "••••••••", text: $confirmPassword, isSecure: true, contentType: .newPassword)
                        .focused($focusedField, equals: .confirm)
                        .onSubmit { Task { await submit() } }
                }

                if let error {
                    _ErrorBanner(message: error)
                }

                _PrimaryButton(title: "Create account", isLoading: auth.isLoading || !auth.isReady) {
                    Task { await submit() }
                }
            }

            Button("Already have an account? Sign in") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .signIn } }
                .buttonStyle(_LinkButtonStyle())
        }
    }

    private func submit() async {
        guard !email.isEmpty, !password.isEmpty else {
            error = "Please fill in all fields."
            return
        }
        guard password == confirmPassword else {
            error = "Passwords don't match."
            return
        }
        guard password.count >= 8 else {
            error = "Password must be at least 8 characters."
            return
        }
        error = nil
        do {
            let needsVerification = try await auth.signUp(email: email, password: password)
            if needsVerification {
                success = true
            } else {
                // Email confirmations disabled — sign in immediately
                _ = try await auth.signIn(email: email, password: password)
            }
        } catch OneloError.serverError(let msg) {
            switch msg {
            case "email_already_registered": self.error = "An account with this email already exists."
            case "plan_limit_exceeded":      self.error = "This app has reached its user limit."
            default:                         self.error = msg
            }
        } catch {
            self.error = "Something went wrong. Please try again."
        }
    }
}

// MARK: - Reset Password

@MainActor
private struct _ResetPasswordForm: View {
    @ObservedObject var auth: OneloAuth
    @Binding var mode: AuthMode

    @State private var email = ""
    @State private var error: String?
    @State private var success = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("Reset password")
                    .font(.system(size: 22, weight: .semibold))
                Text("We'll send you a reset link")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            if success {
                _SuccessBanner(message: "Check your email for a reset link.")
            } else {
                VStack(spacing: 14) {
                    _InputField(label: "Email", placeholder: "you@example.com", text: $email, isSecure: false)
                        .focused($emailFocused)
                        .onSubmit { Task { await submit() } }
                }

                if let error {
                    _ErrorBanner(message: error)
                }

                _PrimaryButton(title: "Send reset link", isLoading: auth.isLoading || !auth.isReady) {
                    Task { await submit() }
                }
            }

            Button("Back to sign in") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .signIn } }
                .buttonStyle(_LinkButtonStyle())
        }
    }

    private func submit() async {
        guard !email.isEmpty else {
            error = "Please enter your email."
            return
        }
        error = nil
        do {
            try await auth.resetPassword(email: email)
            success = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Shared components

private struct _InputField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    var contentType: NSTextContentType? = nil

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            ZStack(alignment: .trailing) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .padding(.trailing, isSecure ? 40 : 12)
                .textContentType(contentType)


                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
}

private struct _PrimaryButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Color(NSColor.windowBackgroundColor))
                } else {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(NSColor.windowBackgroundColor))
                }
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .animation(.easeInOut(duration: 0.15), value: isLoading)
    }
}

private struct _ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.07))
        )
    }
}

private struct _SuccessBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
    }
}

private struct _LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(configuration.isPressed ? Color.primary.opacity(0.5) : Color.secondary)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Powered by Onelo

private struct _OneloBadgeIcon: View {
    var body: some View {
        Image("onelo-logo", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
    }
}

private struct _PoweredByView: View {
    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            HStack(spacing: 5) {
                _OneloBadgeIcon()
                Text("Powered by Onelo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
