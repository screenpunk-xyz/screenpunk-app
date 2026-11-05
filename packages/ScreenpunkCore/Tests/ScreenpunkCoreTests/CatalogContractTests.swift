import XCTest
@testable import ScreenpunkCore

final class CatalogContractTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/fixtures/conformance-catalog-v1.json"))) as? [String: Any])
    }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.withoutEscapingSlashes]) }
    func testCanonicalFixtureAndSHA256Parity() throws {
        let f = try fixture()
        let package = try JSONDecoder().decode(CatalogPackage.self, from: data(f["package"]!))
        let bytes = try CatalogContract.encodePackage(package)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), f["canonicalPackage"] as? String)
        XCTAssertEqual(CatalogContract.digest(bytes), f["packageDigest"] as? String)
        let begin = try JSONDecoder().decode(CatalogBeginBackup.self, from: data(f["begin"]!))
        try CatalogContract.validateBegin(begin)
        XCTAssertEqual(try CatalogContract.verifyPackage(bytes, declaration: begin.package), package)
        XCTAssertEqual(try CatalogContract.canonical(begin), try AuthoringContract.canonicalJSON(data(f["begin"]!)))
        XCTAssertThrowsError(try CatalogContract.verifyPackage(bytes + Data([10]), declaration: begin.package))
    }
    func testPreviewImmutableBindingAndCanonicalParity() throws {
        let f = try XCTUnwrap(try fixture()["previewAttachment"] as? [String: Any])
        var begin = try JSONDecoder().decode(CatalogPreviewBegin.self, from: data(f["begin"]!))
        try CatalogContract.validatePreviewBegin(begin)
        XCTAssertEqual(String(decoding: try CatalogContract.canonical(begin), as: UTF8.self), f["canonicalBegin"] as? String)
        XCTAssertEqual(try CatalogContract.previewBeginDigest(begin), f["beginDigest"] as? String)
        let preview = try JSONDecoder().decode(CatalogPreview.self, from: data(f["available"]!))
        XCTAssertEqual(preview.source, "exact_package")
        XCTAssertEqual(preview.capturedAt, begin.capturedAt)
        let status = try JSONDecoder().decode(CatalogPreviewStatus.self, from: data(f["status"]!))
        try CatalogContract.validateStatus(status)
        let candidates = try JSONDecoder().decode(CatalogPreviewCandidates.self, from: data(f["candidates"]!))
        XCTAssertEqual(candidates.candidates.first?.sourceRevisionID, begin.sourceRevisionID)
        begin.preview.mediaType = "image/jpeg"
        XCTAssertThrowsError(try CatalogContract.validatePreviewBegin(begin))
    }
    func testEmptyCSSPackagePreservesExactBytes() throws {
        let f = try XCTUnwrap(try fixture()["emptyFilePackage"] as? [String: Any])
        let package = try JSONDecoder().decode(CatalogPackage.self, from: data(f["package"]!))
        let bytes = try CatalogContract.encodePackage(package)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), f["canonicalPackage"] as? String)
        XCTAssertEqual(CatalogContract.digest(bytes), f["digest"] as? String)
        XCTAssertEqual(package.files.last?.byteLength, 0)
        XCTAssertEqual(package.files.last?.contentBase64, "")
    }
    func testGapAndUTCAndInvalidPackages() throws {
        let f = try fixture()
        var gap = try JSONDecoder().decode(CatalogBeginBackup.self, from: data(f["gapBegin"]!))
        try CatalogContract.validateBegin(gap)
        gap.gap?.checkpointCounter = 0
        XCTAssertThrowsError(try CatalogContract.validateBegin(gap))
        XCTAssertEqual(CatalogContract.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        var package = try JSONDecoder().decode(CatalogPackage.self, from: data(f["package"]!))
        package.files[0].path = "../index.html"
        XCTAssertThrowsError(try CatalogContract.encodePackage(package))
        XCTAssertTrue(CatalogContract.containsCredentials(path: "secrets.json", content: "{}"))
        XCTAssertTrue(CatalogContract.containsCredentials(path: "index.html", content: "-----BEGIN PRIVATE KEY-----"))
    }
    func testSharedMalformedDependencyAndManifestFixtures() throws {
        let f = try fixture()
        for vector in try XCTUnwrap(f["invalidCompletePackages"] as? [[String: Any]]) {
            let package = try JSONDecoder().decode(CatalogPackage.self, from: data(vector["package"]!))
            XCTAssertThrowsError(try CatalogContract.encodePackage(package), vector["name"] as? String ?? "fixture")
        }
    }
    func testMissingObjectAndExpiredOperationFixtures() throws {
        let f = try fixture()
        let version = try JSONDecoder().decode(CatalogVersion.self, from: data(f["missingVersion"]!))
        XCTAssertEqual(version.integrity, "missing")
        var status = try JSONDecoder().decode(CatalogBackupStatus.self, from: data(f["expiredStatus"]!))
        try CatalogContract.validateStatus(status)
        XCTAssertEqual(status.error?.restartOperation, true)
        status.state = "pending"
        XCTAssertThrowsError(try CatalogContract.validateStatus(status))
    }
    func testMissingPackageDependencyFailsWithoutDeclarations() throws {
        let f = try fixture()
        var package = try JSONDecoder().decode(CatalogPackage.self, from: data(f["package"]!))
        let bytes = Data("<script src=\"missing.js\"></script>".utf8)
        package.files[0].byteLength = bytes.count
        package.files[0].digest = CatalogContract.digest(bytes)
        package.files[0].contentBase64 = bytes.base64EncodedString()
        XCTAssertThrowsError(try CatalogContract.encodePackage(package))
    }
}
