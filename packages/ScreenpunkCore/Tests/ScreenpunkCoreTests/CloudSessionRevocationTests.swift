import XCTest
@testable import ScreenpunkCore

final class CloudSessionRevocationTests: XCTestCase {
    func testRevocationSurvivesRestartWithoutRevokingAnotherOriginOrRotatedCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-revocation-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try CloudSessionRevocationLedger(rootDirectory: root)
        XCTAssertFalse(try ledger.contains(origin: "https://api.screenpunk.xyz", credential: "credential-a"))
        try ledger.record(origin: "https://api.screenpunk.xyz", credential: "credential-a")
        let reopened = try CloudSessionRevocationLedger(rootDirectory: root)
        XCTAssertTrue(try reopened.contains(origin: "https://api.screenpunk.xyz", credential: "credential-a"))
        XCTAssertFalse(try reopened.contains(origin: "https://staging.screenpunk.xyz", credential: "credential-a"))
        XCTAssertFalse(try reopened.contains(origin: "https://api.screenpunk.xyz", credential: "credential-b"))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("credential-a"))
        }
    }

    func testRepeatedRevocationPreservesOtherRevokedCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-revocation-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try CloudSessionRevocationLedger(rootDirectory: root)
        for token in ["first", "second", "first"] { try ledger.record(origin: "https://api.screenpunk.xyz", credential: token) }
        XCTAssertTrue(try ledger.contains(origin: "https://api.screenpunk.xyz", credential: "first"))
        XCTAssertTrue(try ledger.contains(origin: "https://api.screenpunk.xyz", credential: "second"))
    }
}
