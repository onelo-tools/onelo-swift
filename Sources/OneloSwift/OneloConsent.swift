// Sources/OneloSwift/OneloConsent.swift
//
// Legal consent gate model. The SDK asks the backend which legal documents the
// signed-in user has not yet accepted (`OneloAuth.requiredConsents()`); each
// item carries an enforcement level and a server-computed `blocking` flag.
//
// When a `blocking` item exists, `OneloAuthView` loads its hosted `consentUrl`
// (the legal page in gate mode) inside the same auth WebView. The page emits
// `{type:'onelo:consent', action:'accept'|'decline'}`; the SDK records the
// acceptance itself (it holds the user token — the page never sees it), exactly
// like the auth flow where the page emits a code and the SDK does the exchange.
//
// Enforcement (mirrors backend/app/lib/legal/enforcement.py):
//   .block  → Terms: after the effective date the user must accept or sign out.
//   .notify → Privacy/DPA/Cookies: informational only; never blocks access.

import Foundation

/// How strongly a legal document is enforced in-app once it takes effect.
public enum OneloConsentEnforcement: String, Codable, Sendable {
    case block
    case notify
    /// Unknown future values decode here rather than failing the whole response.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OneloConsentEnforcement(rawValue: raw) ?? .unknown
    }
}

/// One legal document version the user has not yet accepted.
public struct OneloConsentRequirement: Decodable, Identifiable, Sendable {
    /// Stable identity for SwiftUI = the document version id.
    public var id: String { versionId }

    public let docType: String
    public let versionId: String
    public let version: String
    public let enforcement: OneloConsentEnforcement
    /// True only when this is a `.block` doc whose effective date has passed —
    /// the single signal that the user must accept now or be gated out.
    public let blocking: Bool
    /// Canonical public URL of the read-only document (may be nil for platform docs).
    public let url: URL?
    /// Same page in gate mode (`?gate=1`) — what the SDK loads in the WebView.
    public let consentUrl: URL?

    enum CodingKeys: String, CodingKey {
        case docType = "doc_type"
        case versionId = "version_id"
        case version
        case enforcement
        case blocking
        case url
        case consentUrl = "consent_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docType = try c.decode(String.self, forKey: .docType)
        versionId = try c.decode(String.self, forKey: .versionId)
        version = try c.decode(String.self, forKey: .version)
        enforcement = (try? c.decode(OneloConsentEnforcement.self, forKey: .enforcement)) ?? .unknown
        blocking = (try? c.decode(Bool.self, forKey: .blocking)) ?? false
        url = (try? c.decode(String.self, forKey: .url)).flatMap(URL.init(string:))
        consentUrl = (try? c.decode(String.self, forKey: .consentUrl)).flatMap(URL.init(string:))
    }
}

/// Decodes the `GET /v1/sdk/consent/required` response envelope.
struct OneloConsentRequiredResponse: Decodable {
    let required: [OneloConsentRequirement]
}
