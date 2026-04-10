import Foundation
#if canImport(UIKit)
import UIKit
import WebKit
import SafariServices
#endif

// MARK: - Types

public struct PaywallAccessResult: Sendable {
    public let hasAccess: Bool
    public let accesses: [PaywallAccess]
}

public struct PaywallAccess: Sendable {
    public let productId: String
    public let productName: String
    public let grantedAt: Date
    public let expiresAt: Date?
}

// MARK: - OneloPaywall

/// OneloPaywall — Swift SDK for Onelo paywall.
///
/// Initialize with a publishable key and use with an `OneloAuth` session:
/// ```swift
/// let paywall = OneloPaywall(config: OneloConfig(publishableKey: "onelo_pk_live_abc123"))
///
/// // Check access
/// let result = try await paywall.check(userToken: session.accessToken, productId: "prod_abc")
///
/// // Show checkout overlay
/// try await paywall.show(from: viewController, userToken: session.accessToken, productId: "prod_abc")
/// paywall.onSuccess {
///     // Unlock your content here
/// }
/// ```
@MainActor
public final class OneloPaywall: ObservableObject {
    @Published public private(set) var isLoading: Bool = false

    private let config: OneloConfig
    private var successCallbacks: [() -> Void] = []
    private var dismissCallbacks: [() -> Void] = []

    public init(config: OneloConfig) {
        self.config = config
    }

    // MARK: - Public API

    /// Check if the current user has access to a product.
    /// Pass `productId` to check a specific product, or omit to check any product.
    public func check(userToken: String, productId: String? = nil) async throws -> PaywallAccessResult {
        var body: [String: String] = [
            "publishableKey": config.publishableKey,
            "userToken": userToken,
        ]
        if let pid = productId { body["productId"] = pid }

        let url = config.apiUrl.appendingPathComponent("api/sdk/paywall/access")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return PaywallAccessResult(hasAccess: false, accesses: [])
        }

        let decoded = try JSONDecoder().decode(AccessResponse.self, from: data)
        let accesses = decoded.accesses.compactMap { a -> PaywallAccess? in
            guard let granted = ISO8601DateFormatter().date(from: a.grantedAt) else { return nil }
            let expires = a.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return PaywallAccess(productId: a.productId, productName: a.productName, grantedAt: granted, expiresAt: expires)
        }
        return PaywallAccessResult(hasAccess: decoded.hasAccess, accesses: accesses)
    }

    /// Get a checkout URL for a product (one-time use token URL).
    public func getCheckoutUrl(userToken: String, productId: String) async throws -> URL? {
        let body: [String: String] = [
            "publishableKey": config.publishableKey,
            "userToken": userToken,
            "productId": productId,
        ]

        let url = config.apiUrl.appendingPathComponent("api/sdk/paywall/checkout")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(CheckoutResponse.self, from: data)
        return decoded.url.flatMap { URL(string: $0) }
    }

    /// Show the paywall checkout overlay.
    /// Opens Onelo's hosted checkout in a modal sheet (SFSafariViewController).
    #if canImport(UIKit)
    public func show(from viewController: UIViewController, userToken: String, productId: String) async throws {
        isLoading = true
        defer { isLoading = false }

        guard let checkoutUrl = try await getCheckoutUrl(userToken: userToken, productId: productId) else {
            throw OneloError.serverError("Failed to get checkout URL")
        }

        await MainActor.run {
            let safari = SFSafariViewController(url: checkoutUrl)
            safari.preferredControlTintColor = .systemOrange
            safari.modalPresentationStyle = .pageSheet
            viewController.present(safari, animated: true)

            // Listen for payment success notification posted by the success page
            NotificationCenter.default.addObserver(
                forName: .oneloPaymentSuccess,
                object: nil,
                queue: .main
            ) { [weak self, weak safari] _ in
                safari?.dismiss(animated: true)
                self?.successCallbacks.forEach { $0() }
            }
        }
    }
    #endif

    /// Register a callback for successful payment.
    @discardableResult
    public func onSuccess(_ callback: @escaping () -> Void) -> Self {
        successCallbacks.append(callback)
        return self
    }

    /// Register a callback for when user dismisses without paying.
    @discardableResult
    public func onDismiss(_ callback: @escaping () -> Void) -> Self {
        dismissCallbacks.append(callback)
        return self
    }

    // MARK: - Private types

    private struct AccessResponse: Decodable {
        let hasAccess: Bool
        let accesses: [AccessItem]

        struct AccessItem: Decodable {
            let productId: String
            let productName: String
            let grantedAt: String
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case productId = "product_id"
                case productName = "product_name"
                case grantedAt = "granted_at"
                case expiresAt = "expires_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case hasAccess = "has_access"
            case accesses
        }
    }

    private struct CheckoutResponse: Decodable {
        let url: String?
    }
}

// MARK: - Notification

public extension Notification.Name {
    /// Post this from your app's universal link / deep link handler when Onelo returns a payment success URL.
    static let oneloPaymentSuccess = Notification.Name("OneloPaymentSuccess")
}
