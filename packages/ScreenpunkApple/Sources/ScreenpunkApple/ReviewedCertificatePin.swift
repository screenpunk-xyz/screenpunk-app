import CryptoKit
import Darwin
import Foundation
import Security
import ScreenpunkCore
import X509

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
        rejection(trust, host: host, now: now) == nil
    }

    func rejection(_ trust: SecTrust, host: String, now: Date = Date()) -> CustomHTTPConnectionTestFailure? {
        guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return .certificateRejected }
        let der = SecCertificateCopyData(leaf) as Data
        let presentedFingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard presentedFingerprint == fingerprint else { return .pinMismatch }
        let leafIsValid: Bool
        if #available(iOS 18, macOS 15, *) {
            guard let start = SecCertificateCopyNotValidBeforeDate(leaf) as Date?,
                  let end = SecCertificateCopyNotValidAfterDate(leaf) as Date? else { return .certificateRejected }
            leafIsValid = start <= now && now < end
        } else {
            leafIsValid = Self.legacyLeafIsValid(der, host: host, now: now)
        }
        guard leafIsValid,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return .certificateRejected }
        return SecTrustEvaluateWithError(trust, nil) ? nil : .certificateRejected
    }

    // Treating the leaf as a trust anchor can omit its date check. Parse the
    // same DER on systems without public Security certificate date APIs.
    static func legacyLeafIsValid(_ der: Data, host: String, now: Date) -> Bool {
        guard let certificate = try? Certificate(derEncoded: Array(der)),
              certificate.notValidBefore <= now, now < certificate.notValidAfter else { return false }
        guard let address = ipAddressBytes(host) else { return true } // Security still checks DNS names.
        guard let names = try? certificate.extensions.subjectAlternativeNames else { return false }
        return names.contains { name in
            guard case .ipAddress(let octets) = name else { return false }
            return octets.bytes.elementsEqual(address)
        }
    }

    private static func ipAddressBytes(_ host: String) -> [UInt8]? {
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        for (family, length) in [(AF_INET, 4), (AF_INET6, 16)] {
            var address = [UInt8](repeating: 0, count: length)
            if address.withUnsafeMutableBytes({ inet_pton(family, literal, $0.baseAddress) }) == 1 {
                return address
            }
        }
        return nil
    }
}
