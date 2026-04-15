// Sources/OneloSwift/OneloAuthView.swift
import SwiftUI
import WebKit

/// Drop-in SwiftUI authentication view.
///
/// ```swift
/// OneloAuthView(auth: onelo.auth.authObject, config: .default) { session in
///     // user signed in
/// }
/// ```
public struct OneloAuthView<Content: View>: View {
    @StateObject private var vm: OneloAuthViewModel
    private let requestedConfig: OneloAuthConfig
    private let auth: any OneloAuthProtocol
    private let content: () -> Content
    @State private var isAuthenticated: Bool = false
    @State private var isReady: Bool = false
    @State private var hostedUrl: URL? = nil
    @State private var showRetry: Bool = false
    @State private var errorMessage: String? = nil

    private var effectiveConfig: OneloAuthConfig { requestedConfig }

    /// Create an auth view. The `content` closure is shown after successful sign-in.
    ///
    /// ```swift
    /// OneloAuthView(auth: auth) {
    ///     ContentView().environmentObject(auth)
    /// }
    /// ```
    public init(
        auth: any OneloAuthProtocol,
        config: OneloAuthConfig = .default,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
        self.requestedConfig = config
        self.auth = auth
        _vm = StateObject(wrappedValue: OneloAuthViewModel(auth: auth, onSuccess: nil))
    }

    public var body: some View {
        Group {
            if isAuthenticated {
                content()
            } else if let url = hostedUrl, !showRetry {
                // Hosted page embedded in the app window via WKWebView
                EmbeddedWebAuthView(
                    url: url,
                    callbackScheme: callbackScheme,
                    onCode: { code in
                        Task { await handleCode(code) }
                    },
                    onError: { err in
                        hostedUrl = nil
                        errorMessage = err
                        showRetry = true
                    }
                )
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 680)
                .ignoresSafeArea()
                #endif
            } else {
                // Loading state or retry after cancel/error
                ZStack {
                    effectiveConfig.backgroundColor.ignoresSafeArea()

                    if showRetry {
                        VStack(spacing: 16) {
                            if let err = errorMessage {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Sign In") {
                                showRetry = false
                                errorMessage = nil
                                Task { await loadHostedUrl() }
                            }
                            .buttonStyle(.plain)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(oneloOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    } else if isReady {
                        ProgressView()
                            .tint(.white.opacity(0.3))
                    }
                }
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await session in oneloAuth.$currentSession.values {
                isAuthenticated = session != nil
            }
        }
        .task {
            guard let oneloAuth = auth as? OneloAuth else { return }
            for await value in oneloAuth.$isReady.values {
                isReady = value
                if value && !isAuthenticated {
                    await loadHostedUrl()
                }
            }
        }
    }

    private var callbackScheme: String {
        (auth as? OneloAuth)?.config.callbackScheme ?? ""
    }

    @MainActor
    private func loadHostedUrl() async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        do {
            hostedUrl = try await oneloAuth.initiateHostedFlow()
        } catch {
            errorMessage = error.localizedDescription
            showRetry = true
        }
    }

    @MainActor
    private func handleCode(_ code: String) async {
        guard let oneloAuth = auth as? OneloAuth else { return }
        do {
            _ = try await oneloAuth.exchangeHostedCode(code)
        } catch {
            hostedUrl = nil
            errorMessage = error.localizedDescription
            showRetry = true
        }
    }
}

// MARK: - Embedded web auth view (WKWebView)

private final class WebAuthCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let callbackScheme: String
    let onCode: (String) -> Void
    let onError: (String) -> Void

    init(callbackScheme: String, onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.callbackScheme = callbackScheme
        self.onCode = onCode
        self.onError = onError
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Intercept auth callback
        if url.scheme?.lowercased() == callbackScheme.lowercased() {
            let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
            if let code {
                DispatchQueue.main.async { self.onCode(code) }
            } else {
                DispatchQueue.main.async { self.onError("Auth callback missing code parameter") }
            }
            decisionHandler(.cancel)
            return
        }
        // Open external links (e.g. onelo.tools) in the system browser
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme, (scheme == "https" || scheme == "http"),
           url.host != webView.url?.host {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Handle target="_blank" links — open in system browser instead of new WKWebView
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "document.documentElement.style.overflowX='hidden';" +
            "document.body.style.overflowX='hidden';"
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != "WebKitErrorDomain" else { return }
        DispatchQueue.main.async { self.onError(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != "WebKitErrorDomain" else { return }
        DispatchQueue.main.async { self.onError(error.localizedDescription) }
    }
}

#if os(macOS)
private struct EmbeddedWebAuthView: NSViewRepresentable {
    let url: URL
    let callbackScheme: String
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> WebAuthCoordinator {
        WebAuthCoordinator(callbackScheme: callbackScheme, onCode: onCode, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Let the window title bar follow the system appearance (dark/light mode)
        // rather than being stuck at whatever the default window color is.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.appearance = nil // follow system
        }
    }
}
#elseif os(iOS)
private struct EmbeddedWebAuthView: UIViewRepresentable {
    let url: URL
    let callbackScheme: String
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> WebAuthCoordinator {
        WebAuthCoordinator(callbackScheme: callbackScheme, onCode: onCode, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let noZoomScript = WKUserScript(
            source: """
            var meta = document.querySelector('meta[name=viewport]');
            if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(noZoomScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Inline auth view (paid plan) — matches hosted page design

private struct InlineAuthView: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig
    let appName: String
    let appLogoUrl: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                config.backgroundColor.ignoresSafeArea()

                ScrollView {
                    VStack {
                        Spacer(minLength: 0)

                        VStack(spacing: 0) {
                            // Logo
                            Group {
                                if let url = appLogoUrl {
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image {
                                            img.resizable().scaledToFill()
                                                .frame(width: 64, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                        } else {
                                            OneloLogoMark(size: 64)
                                        }
                                    }
                                } else {
                                    OneloLogoMark(size: 64)
                                }
                            }
                            .padding(.bottom, 16)

                            // Title — matches hosted page: "Sign in to AppName"
                            (Text("Sign in to ")
                                .foregroundStyle(config.textColor)
                            + Text(appName)
                                .foregroundStyle(oneloOrange))
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 6)

                            Text("Secure authentication powered by Onelo")
                                .font(.subheadline)
                                .foregroundStyle(config.subtitleColor)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 32)

                            // Form
                            switch vm.screen {
                            case .signIn:
                                InlineSignInForm(vm: vm, config: config)
                            case .signUp:
                                InlineSignUpForm(vm: vm, config: config)
                            case .forgotPassword:
                                InlineForgotPasswordForm(vm: vm, config: config)
                            }
                        }
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 420)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geo.size.height)
                    .frame(maxWidth: .infinity)
                }

                // Footer pinned bottom-center
                VStack {
                    Spacer()
                    OneloFooter()
                        .padding(.bottom, 20)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct InlineSignInForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            AuthTextField("you@example.com", text: $vm.email, config: config)
            AuthSecureField("Password", text: $vm.password, config: config)

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Sign In", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignIn() }
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Text("Don't have an account?").foregroundStyle(config.subtitleColor)
                Button("Sign up") { vm.showSignUp() }
                    .buttonStyle(.plain).foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
    }
}

private struct InlineSignUpForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            AuthTextField("you@example.com", text: $vm.email, config: config)
            AuthSecureField("Password", text: $vm.password, config: config)
            AuthSecureField("Confirm password", text: $vm.confirmPassword, config: config)

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if vm.signUpVerificationSent {
                Text("Check your email to verify your account.")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AuthButton("Create Account", config: config, isLoading: vm.isLoading) {
                Task { await vm.submitSignUp() }
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Text("Already have an account?").foregroundStyle(config.subtitleColor)
                Button("Sign in") { vm.showSignIn() }
                    .buttonStyle(.plain).foregroundStyle(config.accentColor)
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
    }
}

private struct InlineForgotPasswordForm: View {
    @ObservedObject var vm: OneloAuthViewModel
    let config: OneloAuthConfig

    var body: some View {
        VStack(spacing: config.itemSpacing) {
            Text("Enter your email and we'll send you a reset link.")
                .font(.subheadline).foregroundStyle(config.subtitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            if vm.forgotPasswordSent {
                Text("Check your email for the reset link.")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AuthTextField("you@example.com", text: $vm.email, config: config)

                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AuthButton("Send Reset Link", config: config, isLoading: vm.isLoading) {
                    Task { await vm.submitForgotPassword() }
                }
                .padding(.top, 4)
            }

            Button("Back to sign in") { vm.showSignIn() }
                .buttonStyle(.plain).font(.subheadline).foregroundStyle(config.accentColor)
                .padding(.top, 4)
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

// MARK: - Onelo brand color

private let oneloOrange = Color(red: 0.976, green: 0.451, blue: 0.086) // #f97316

// MARK: - Onelo Logo (with dark background — used in hosted flow button)

private struct OneloLogo: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(red: 0.067, green: 0.067, blue: 0.067))
                .frame(width: size, height: size)
            OneloLogoMark(size: size * 0.72)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Onelo Logo Mark (just the white symbol, no background)

private struct OneloLogoMark: View {
    var size: CGFloat = 56

    var body: some View {
        Image("onelo-logo-white", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

// MARK: - Onelo Footer (with logo, left-aligned)

private struct OneloFooter: View {
    var body: some View {
        Link(destination: URL(string: "https://onelo.tools")!) {
            HStack(spacing: 4) {
                Image("onelo-logo-white", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .opacity(0.4)
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

// MARK: - Hosted Sign In Button (legacy — no longer used by OneloAuthView)
// Kept for reference only. OneloAuthView now uses EmbeddedWebAuthView (WKWebView).

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
                            (Text("Sign in to ")
                                .foregroundStyle(config.textColor)
                            + Text(appName)
                                .foregroundStyle(oneloOrange))
                            .font(.title2.bold())

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
            let url = try await oneloAuth.initiateHostedFlow()
            // Legacy path — callers should use OneloAuthView (WKWebView) instead
            _ = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
