import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryPreviewTests: XCTestCase {
    private var binding: ScreenLibrary.CatalogBinding { .init(origin: "https://staging.screenpunk.xyz", accountID: "account", userID: "user", deviceID: "device", libraryID: "library") }
    private var png: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")! }
    private var declaration: CatalogPNGPreviewDeclaration { .init(byteLength: png.count, digest: CatalogContract.digest(png), width: 1, height: 1) }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-preview-" + UUID().uuidString) }
    private func screen(_ title: String) -> ScreenArtifact { .init(title: title, files: [.init(path: "index.html", content: "<html><body>\(title)</body></html>")]) }

    @MainActor func testOffPreventsPreviewCaptureAndRetryWithoutLosingPendingBytes() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(screen("Source"), requestID: "source", replacing: "screen")
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
        let digest = try XCTUnwrap(intent.packageDigest)
        let timestamp = "2026-11-05T20:00:00.000Z"
        try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: digest, capturedAt: timestamp, binding: binding)
        let pending = try XCTUnwrap(library.catalogQueue?.previews?.first)
        try library.setCatalogBackupsEnabled(false, binding: binding)
        XCTAssertThrowsError(try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: digest, capturedAt: timestamp, binding: binding))
        XCTAssertThrowsError(try library.readCatalogPreview(pending, binding: binding))
        XCTAssertThrowsError(try library.updateCatalogPreview(pending, binding: binding))
        let restart = try CatalogFixture.open(root, binding: binding)
        XCTAssertEqual(restart.catalogQueue?.previews?.first?.operationID, pending.operationID)
        try CatalogFixture.enable(restart, binding: binding)
        XCTAssertEqual(try restart.readCatalogPreview(pending, binding: binding), png)
    }

    @MainActor func testPreviewBytesRecoverAtEveryJournalBoundaryWithoutChangingPackageReceipt() throws {
        enum PowerLoss: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { CatalogFixture.cleanup(root) }
            var armed = false
            let library = try CatalogFixture.open(root, binding: binding, journalFault: { if armed && $0 == cut { throw PowerLoss.interrupted } })
            try CatalogFixture.enable(library, binding: binding)
            try library.install(screen("Source"), requestID: "source", replacing: "screen")
            let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
            armed = true
            XCTAssertThrowsError(try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: try XCTUnwrap(intent.packageDigest), capturedAt: "2026-11-05T20:00:00.000Z", binding: binding))
            let restart = try CatalogFixture.open(root, binding: binding)
            try restart.activateCatalog(binding: binding)
            XCTAssertEqual(restart.selected?.revision, intent.revision)
            XCTAssertEqual(restart.catalogQueue?.entries.first?.operationID, intent.operationID)
            if cut == .assetsDurable { XCTAssertTrue(restart.catalogQueue?.previews?.isEmpty ?? true) }
            else { let capture = try XCTUnwrap(restart.catalogQueue?.previews?.first); XCTAssertEqual(try restart.readCatalogPreview(capture, binding: binding), png) }
        }
    }
    @MainActor func testPackageAckPruningAndRestartDoNotLosePendingExactScreenshot() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(screen("Source"), requestID: "source", replacing: "screen")
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first), digest = try XCTUnwrap(intent.packageDigest)
        try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: digest, capturedAt: "2026-11-05T20:00:00.000Z", binding: binding)
        let captured = try XCTUnwrap(library.catalogQueue?.previews?.first)
        try library.acknowledgeCatalogIntent(id: intent.id, binding: binding)
        for index in 0..<3 { try library.install(screen("New \(index)"), requestID: "new-\(index)", replacing: "screen") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(intent.revision).path))
        let restart = try CatalogFixture.open(root, binding: binding)
        try restart.activateCatalog(binding: binding)
        XCTAssertEqual(try restart.readCatalogPreview(captured, binding: binding), png)
        let queue = try XCTUnwrap(restart.catalogQueue), copy = try XCTUnwrap(queue.copies["screen"])
        let candidate = CatalogPreviewCandidate(catalogScreenID: "catalog", versionID: "version", libraryID: queue.libraryID, localScreenID: copy.localScreenID, sourceRevisionID: intent.revision, packageDigest: digest, packageBytes: intent.packageBytes)
        try restart.bindCatalogPreview(candidate, binding: binding)
        let job = try XCTUnwrap(restart.catalogQueue?.previews?.first)
        XCTAssertEqual(job.candidate?.sourceRevisionID, intent.revision)
        try restart.acknowledgeCatalogPreview(job, binding: binding)
        XCTAssertTrue(restart.catalogQueue?.previews?.isEmpty == true)
        try restart.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: digest, capturedAt: "2026-11-05T20:01:00.000Z", binding: binding, candidate: candidate)
        XCTAssertTrue(restart.catalogQueue?.previews?.isEmpty == true, "An acknowledged immutable preview is not recaptured with different current pixels.")
    }
    @MainActor func testWrongAccountWrongSourceAndChangedBytesCannotEnterPreviewQueue() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(screen("Source"), requestID: "source", replacing: "screen")
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
        var other = binding; other.accountID = "other"
        XCTAssertThrowsError(try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: intent.packageDigest!, capturedAt: "2026-11-05T20:00:00.000Z", binding: other))
        XCTAssertThrowsError(try library.captureCatalogPreview(bytes: png, declaration: declaration, revision: intent.revision, packageDigest: String(repeating: "0", count: 64), capturedAt: "2026-11-05T20:00:00.000Z", binding: binding))
        XCTAssertThrowsError(try library.captureCatalogPreview(bytes: png + Data([0]), declaration: declaration, revision: intent.revision, packageDigest: intent.packageDigest!, capturedAt: "2026-11-05T20:00:00.000Z", binding: binding))
        XCTAssertTrue(library.catalogQueue?.previews?.isEmpty ?? true)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
    }
}
