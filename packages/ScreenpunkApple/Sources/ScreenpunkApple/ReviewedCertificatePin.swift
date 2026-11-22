import CryptoKit
import Foundation
import Security
import ScreenpunkCore

/// A device Settings decision, bound to the HTTPS origin the user reviewed.
public struct ReviewedCertificatePin: Codable, Equatable, Sendable {
    public let origin: String
    public let fingerprint: String

    public init(origin: String, fingerprint: String) throws {
        let canonical = try CustomHTTPDestination.origin(origin, allowInsecureHTTP: false)
        let hex = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "").lowercased()
        guard canonical.hasPrefix("https://"), hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConnectionFailure.validationFailed
        }
        self.origin = canonical
        self.fingerprint = hex
    }

    func matches(scheme: String?, host: String?, port: Int?) -> Bool {
        guard let endpoint = URLComponents(string: origin), scheme?.lowercased() == "https",
              endpoint.scheme == "https", let host, endpoint.host == host.lowercased() else { return false }
        return (endpoint.port ?? 443) == (port ?? 443)
    }

    func accepts(_ trust: SecTrust, host: String, now: Date = Date()) -> Bool {
        guard #available(iOS 18, macOS 15, *),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map({ String(format: "%02x", $0) }).joined() == fingerprint,
              let start = SecCertificateCopyNotValidBeforeDate(leaf) as Date?,
              let end = SecCertificateCopyNotValidAfterDate(leaf) as Date?,
              start <= now, now < end,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
