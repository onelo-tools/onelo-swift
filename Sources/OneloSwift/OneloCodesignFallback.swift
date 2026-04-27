#if os(macOS)
import Foundation
import Security
import CryptoKit

/// Computes the SHA-256 fingerprint of the leaf certificate in the running app's code signature.
/// Used as the `X-Codesign-Fingerprint` fallback for macOS 13 and earlier
/// (macOS 14+ uses App Attest via OneloAppAttest).
public enum OneloCodesignFallback {

    /// Returns the SHA-256 hex fingerprint of the app's Developer ID certificate, or nil on error.
    public static func codesignFingerprint() -> String? {
        guard let url = Bundle.main.bundleURL as CFURL? else { return nil }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess,
              let staticCode = code else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        guard let certChain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certChain.first else { return nil }

        guard let certData = SecCertificateCopyData(leaf) as Data? else { return nil }

        let digest = SHA256.hash(data: certData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
