import CryptoKit
import Foundation
import Security
import XCTest
@testable import ScreenpunkApple

final class ReviewedCertificatePinTests: XCTestCase {
    // Public synthetic P-256 server certificate with IP SAN 192.168.1.23.
    private let certificate = "MIIBoTCCAUagAwIBAgIURBnKRQLG5pwXmjYaLdaK6hO1ZQgwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJc3ludGhldGljMB4XDTI2MTEyMjIxMTQyN1oXDTI3MDIyMDIxMTQyN1owFDESMBAGA1UEAwwJc3ludGhldGljMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoC3/DSYGLPVRsN6+lY61XGKA7zIDwto+F4UQPU5uLDn2H06FCCVnzUNcGzG9NuLzk8A7oVcjTVhc4zpPkkjPw6N2MHQwHQYDVR0OBBYEFDkuCYUmtvU5iR7UI+AH5NeniY0+MB8GA1UdIwQYMBaAFDkuCYUmtvU5iR7UI+AH5NeniY0+MA8GA1UdEQQIMAaHBMCoARcwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNJADBGAiEAhXcw53/mFLdwxZBghQYU7OSTAfQ/uomFiZCZvZ2kRZcCIQCfvodL9Zl9SVYwP5NmeC32pjE6KfnysRgaRw0aqDM64Q=="

    private func validityDates() throws -> (Date, Date) {
        let formatter = ISO8601DateFormatter()
        return (try XCTUnwrap(formatter.date(from: "2026-11-22T21:14:27Z")),
                try XCTUnwrap(formatter.date(from: "2027-02-20T21:14:27Z")))
    }

    func testLegacyLeafParserRejectsMalformedExpiredAndWrongIPSAN() throws {
        let der = try XCTUnwrap(Data(base64Encoded: certificate))
        let (start, end) = try validityDates()
        XCTAssertTrue(ReviewedCertificatePin.legacyLeafIsValid(der, host: "192.168.1.23", now: start))
        XCTAssertFalse(ReviewedCertificatePin.legacyLeafIsValid(der, host: "192.168.1.24", now: start))
        XCTAssertFalse(ReviewedCertificatePin.legacyLeafIsValid(der, host: "[2001:db8::1]", now: start))
        XCTAssertFalse(ReviewedCertificatePin.legacyLeafIsValid(der, host: "192.168.1.23", now: start.addingTimeInterval(-1)))
        XCTAssertFalse(ReviewedCertificatePin.legacyLeafIsValid(der, host: "192.168.1.23", now: end))
        XCTAssertFalse(ReviewedCertificatePin.legacyLeafIsValid(der.dropLast(), host: "192.168.1.23", now: start))
    }

    func testExactLeafIPValidityAndOrigin() throws {
        let der = try XCTUnwrap(Data(base64Encoded: certificate))
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let (start, end) = try validityDates()
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
        XCTAssertEqual(pin.rejection(try trust(), host: "192.168.1.24", now: validDate), .certificateRejected)
        XCTAssertEqual(pin.rejection(try trust(), host: "192.168.1.23", now: start.addingTimeInterval(-1)), .certificateRejected)
        XCTAssertEqual(pin.rejection(try trust(), host: "192.168.1.23", now: end), .certificateRejected)
        let wrong = try ReviewedCertificatePin(origin: origin, fingerprint: String(repeating: "0", count: 64))
        XCTAssertEqual(wrong.rejection(try trust(), host: "192.168.1.23", now: validDate), .pinMismatch)
        XCTAssertFalse(SecTrustEvaluateWithError(try trust(), nil))
        XCTAssertThrowsError(try ReviewedCertificatePin(origin: origin, fingerprint: "1234"))
    }
}
