import CryptoKit
import Foundation
import Security
import XCTest
@testable import ScreenpunkApple

final class ReviewedCertificatePinTests: XCTestCase {
    // Public synthetic P-256 server certificate with IP SAN 192.168.1.23.
    private let certificate = "MIIBoTCCAUagAwIBAgIURBnKRQLG5pwXmjYaLdaK6hO1ZQgwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJc3ludGhldGljMB4XDTI2MTEyMjIxMTQyN1oXDTI3MDIyMDIxMTQyN1owFDESMBAGA1UEAwwJc3ludGhldGljMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoC3/DSYGLPVRsN6+lY61XGKA7zIDwto+F4UQPU5uLDn2H06FCCVnzUNcGzG9NuLzk8A7oVcjTVhc4zpPkkjPw6N2MHQwHQYDVR0OBBYEFDkuCYUmtvU5iR7UI+AH5NeniY0+MB8GA1UdIwQYMBaAFDkuCYUmtvU5iR7UI+AH5NeniY0+MA8GA1UdEQQIMAaHBMCoARcwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNJADBGAiEAhXcw53/mFLdwxZBghQYU7OSTAfQ/uomFiZCZvZ2kRZcCIQCfvodL9Zl9SVYwP5NmeC32pjE6KfnysRgaRw0aqDM64Q=="

    func testExactLeafIPValidityAndOrigin() throws {
        guard #available(macOS 15, iOS 18, *) else { throw XCTSkip("Pinning requires certificate validity APIs") }
        let der = try XCTUnwrap(Data(base64Encoded: certificate))
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let start = try XCTUnwrap(SecCertificateCopyNotValidBeforeDate(leaf) as Date?)
        let end = try XCTUnwrap(SecCertificateCopyNotValidAfterDate(leaf) as Date?)
        let validDate = start.addingTimeInterval(60)
        func trust() throws -> SecTrust {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
            let value = try XCTUnwrap(trust)
            XCTAssertEqual(SecTrustSetVerifyDate(value, validDate as CFDate), errSecSuccess)
            return value
        }
        let origin = "https://192.168.1.23"
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let pin = try ReviewedCertificatePin(origin: origin, fingerprint: fingerprint)
        XCTAssertTrue(pin.matches(scheme: "https", host: "192.168.1.23", port: 443))
        XCTAssertFalse(pin.matches(scheme: "http", host: "192.168.1.23", port: 443))
        XCTAssertFalse(pin.matches(scheme: "https", host: "192.168.1.23", port: 444))
        XCTAssertFalse(pin.matches(scheme: "https", host: "192.168.1.24", port: 443))
        XCTAssertTrue(pin.accepts(try trust(), host: "192.168.1.23", now: validDate))
        XCTAssertFalse(pin.accepts(try trust(), host: "192.168.1.24", now: validDate))
        XCTAssertFalse(pin.accepts(try trust(), host: "192.168.1.23", now: start.addingTimeInterval(-1)))
        XCTAssertFalse(pin.accepts(try trust(), host: "192.168.1.23", now: end))
        let wrong = try ReviewedCertificatePin(origin: origin, fingerprint: String(repeating: "0", count: 64))
        XCTAssertFalse(wrong.accepts(try trust(), host: "192.168.1.23", now: validDate))
        XCTAssertFalse(SecTrustEvaluateWithError(try trust(), nil))
        XCTAssertThrowsError(try ReviewedCertificatePin(origin: origin, fingerprint: "1234"))
    }
}
