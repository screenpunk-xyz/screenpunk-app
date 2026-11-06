import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryCatalogTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-catalog-" + UUID().uuidString) }
    private func artifact(_ title: String) -> ScreenArtifact { .init(title: title, files: [.init(path: "index.html", content: "<html><body>\(title)</body></html>")]) }
    private var binding: ScreenLibrary.CatalogBinding { .init(origin: "https://example.test", accountID: "account", userID: "user", deviceID: "device", libraryID: "library") }

    @MainActor func testWakeRequiresDurableQueuedRevision() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        var wakes = 0
        library.onCatalogRevisionCommitted = { wakes += 1 }
        try library.install(artifact("Local only"), requestID: "offline", replacing: "screen")
        XCTAssertEqual(wakes, 0)
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(wakes, 0)
        try library.install(artifact("New edit"), requestID: "edit", replacing: "screen")
        XCTAssertEqual(wakes, 1)
        try library.saveInstruction("No screen mutation")
        try library.newScreen()
        let head = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.updateCatalogIntent(head, binding: binding)
        try library.acknowledgeCatalogIntent(id: head.id, binding: binding)
        XCTAssertEqual(wakes, 1)
    }

    @MainActor func testLegacyInstallPinsEveryQueuedRevisionAcrossPruningAndRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        for index in 0..<4 { try library.install(artifact("Edit \(index)"), requestID: "edit-\(index)", replacing: "screen") }
        let queue = try XCTUnwrap(library.catalogQueue)
        XCTAssertEqual(queue.entries.map(\.counter), [1, 2, 3, 4])
        XCTAssertEqual(Set(queue.entries.map(\.copyID)).count, 1)
        for item in queue.entries { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(item.revision).path)) }
        library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        XCTAssertEqual(library.catalogQueue?.entries.map(\.id), queue.entries.map(\.id))
        XCTAssertEqual(library.catalogQueue?.entries.last?.parentIDs, [queue.entries[2].revision])
        try library.acknowledgeCatalogIntent(id: queue.entries[0].id, binding: binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(queue.entries[0].revision).path))
        XCTAssertEqual(library.catalogQueue?.entries.count, 3)
    }

    @MainActor func testCatalogIntentAndInstalledScreenRecoverAtEveryJournalCut() throws {
        enum PowerLoss: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "library", rootDirectory: root, journalFault: { if armed && $0 == cut { throw PowerLoss.interrupted } })
            try library.activateCatalog(binding: binding)
            armed = true
            XCTAssertThrowsError(try library.install(artifact("Committed"), requestID: "edit", replacing: "screen"))
            let restart = try ScreenLibrary(accountID: "library", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertNil(restart.selected)
                XCTAssertTrue(restart.catalogQueue?.entries.isEmpty == true)
            } else {
                XCTAssertEqual(restart.selected?.revision, restart.catalogQueue?.entries.first?.revision)
                let id = try XCTUnwrap(restart.catalogQueue?.entries.first?.id)
                try restart.install(artifact("Committed"), requestID: "edit", replacing: "screen")
                XCTAssertEqual(restart.catalogQueue?.entries.map(\.id), [id])
            }
        }
    }

    @MainActor func testFullQueuePreservesPinsAndMakesDurableGapWhileEditingContinues() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding, maxRevisions: 2)
        for index in 0..<5 { try library.install(artifact("Edit \(index)"), requestID: "edit-\(index)", replacing: "screen") }
        XCTAssertEqual(library.selected?.artifact.title, "Edit 4")
        let restarted = try ScreenLibrary(accountID: "library", rootDirectory: root)
        let queue = try XCTUnwrap(restarted.catalogQueue)
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertTrue(queue.paused)
        XCTAssertEqual(queue.copies["screen"]?.gapFrom, 3)
        XCTAssertEqual(queue.copies["screen"]?.gapThrough, 5)
        XCTAssertEqual(queue.copies["screen"]?.counter, 5)
        XCTAssertTrue(queue.status?.contains("not queued") == true)
        for item in queue.entries { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(item.revision).path)) }
    }

    @MainActor func testAccountOrEnrollmentChangeCannotAdoptOrAcknowledgeOldQueue() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        try library.install(artifact("Private"), requestID: "edit", replacing: "screen")
        let id = try XCTUnwrap(library.catalogQueue?.entries.first?.id)
        var other = binding; other.userID = "other-user"
        XCTAssertThrowsError(try library.activateCatalog(binding: other))
        XCTAssertThrowsError(try library.acknowledgeCatalogIntent(id: id, binding: other))
        other = binding; other.deviceID = "new-enrollment"
        XCTAssertThrowsError(try library.activateCatalog(binding: other))
        XCTAssertEqual(library.catalogQueue?.entries.first?.id, id)
    }

    @MainActor func testSeedIsCurrentOnlyAndDoesNotChangeOnSelectionOrInstruction() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.install(artifact("Past"), requestID: "past", replacing: "screen")
        try library.install(artifact("Current"), requestID: "current", replacing: "screen")
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
        XCTAssertEqual(library.catalogQueue?.entries.first?.origin, "seed")
        XCTAssertEqual(library.catalogQueue?.entries.first?.title, "Current")
        try library.saveInstruction("No screen mutation")
        try library.newScreen()
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
    }
    @MainActor func testV1V2LocalAndCloudCommitsCaptureOnceAndReceiptAckIsIndependent() throws {
        for route in ["local", "cloud"] {
            for version in [1, 2] {
                let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
                let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
                try library.activateCatalog(binding: binding)
                let request = try AuthoringContract.seal(AuthoringRequestV1(requestID: "edit", createdAt: 1000, deadlineAt: 600000,
                    designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], preferences: [],
                    context: .init(profileID: "profile", deviceID: "device", screenID: "screen", userRequest: "Create a screen", viewport: .init(width: 1024, height: 768, orientation: "landscape")),
                    delivery: .init(route: route)))
                let receipt: ApplicationReceiptV1
                if version == 1 {
                    try library.saveAuthoringRequest(request)
                    let result = AuthoringResultV1(requestID: "edit", inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "operation", screen: artifact("V1"))
                    receipt = try library.applyAuthoringResult(result, now: 2000)
                    XCTAssertEqual(try library.applyAuthoringResult(result, now: 3000), receipt)
                } else {
                    let v2 = try library.makeAuthoringRequestV2(from: request)
                    try library.saveAuthoringRequest(v2)
                    let result = AuthoringResultV2(requestID: "edit", inputDigest: v2.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "operation", screen: .init(title: "V2", files: [.write(path: "index.html", content: "<html><body>V2</body></html>")]))
                    receipt = try library.applyAuthoringResult(result, now: 2000)
                    XCTAssertEqual(try library.applyAuthoringResult(result, now: 3000), receipt)
                }
                XCTAssertEqual(receipt.status, "applied", "\(version) \(route)")
                let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
                XCTAssertEqual(library.catalogQueue?.entries.count, 1)
                XCTAssertEqual(intent.revision, library.selected?.revision)
                try library.acknowledgeReceipt(receipt)
                XCTAssertEqual(library.catalogQueue?.entries.first?.id, intent.id)
                try library.acknowledgeCatalogIntent(id: intent.id, binding: binding)
                XCTAssertEqual(library.state.authoring?.receipts[receipt.operationID], receipt)
            }
        }
    }

    @MainActor func testExporterReadsFinalRetainedBytesAndStableCanonicalManifest() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Exact café bytes</text></svg>"
        let source = ScreenArtifact(title: "Assets", files: [.init(path: "index.html", content: "<html><body><img src=\"art.svg\"></body></html>"), .init(path: "art.svg", content: svg)])
        try library.install(source, requestID: "initial", replacing: "screen")
        let first = try XCTUnwrap(library.catalogQueue?.entries.first)
        let exported = try library.exportCatalogIntent(first, binding: binding)
        XCTAssertEqual(exported.package.screen.requiredAssets, ["art.svg"])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(exported.package.files.first(where: { $0.path == "art.svg" })?.contentBase64)), Data(svg.utf8))
        let begin = try library.catalogBegin(first, declaration: exported.declaration, binding: binding)
        try CatalogContract.validateBegin(begin)
        let restart = try ScreenLibrary(accountID: "library", rootDirectory: root)
        XCTAssertEqual(try restart.exportCatalogIntent(first, binding: binding).bytes, exported.bytes)
        XCTAssertEqual(first.packageDigest, exported.declaration.digest)
        XCTAssertEqual(first.packageBytes, exported.bytes.count)
        let request = try AuthoringContract.seal(AuthoringRequestV1(requestID: "retain-edit", createdAt: 1000, deadlineAt: 600000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], preferences: [],
            context: .init(profileID: "profile", deviceID: "device", screenID: "screen", baseRevision: restart.selected?.revision, userRequest: "Keep the exact image and edit the caption", currentScreen: restart.selected?.artifact, viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "local")))
        let v2 = try restart.makeAuthoringRequestV2(from: request)
        try restart.saveAuthoringRequest(v2)
        let asset = try XCTUnwrap(v2.context.currentScreen?.files.first(where: { $0.path == "art.svg" }))
        let result = AuthoringResultV2(requestID: v2.requestID, inputDigest: v2.delivery.snapshotDigest, baseRevision: v2.context.baseRevision, preferenceRevisions: [:], operationID: "retain-operation", screen: .init(title: "Retained", files: [.write(path: "index.html", content: "<html><body>Edited<img src=\"art.svg\"></body></html>"), .retain(path: "art.svg", sourcePath: "art.svg", reference: asset.reference, digest: asset.digest)]))
        XCTAssertEqual(try restart.applyAuthoringResult(result, now: 2000).status, "applied")
        let committed = try XCTUnwrap(restart.catalogQueue?.entries.last)
        let final = try restart.exportCatalogIntent(committed, binding: binding)
        XCTAssertEqual(final.package.screen.title, "Retained")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(final.package.files.first(where: { $0.path == "art.svg" })?.contentBase64)), Data(svg.utf8))
    }

    @MainActor func testExporterRejectsUnlistedFilesSymlinksAndCredentialsWithoutFailingScreenCommit() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        try library.install(artifact("Ordinary"), requestID: "initial", replacing: "screen")
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
        let revision = root.appendingPathComponent(intent.revision)
        let surprise = revision.appendingPathComponent("surprise.txt")
        try Data("unlisted".utf8).write(to: surprise)
        XCTAssertThrowsError(try library.exportCatalogIntent(intent, binding: binding))
        try FileManager.default.removeItem(at: surprise)
        let entry = revision.appendingPathComponent("index.html")
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try library.exportCatalogIntent(intent, binding: binding))
        let credentialSource = ScreenArtifact(title: "Unsafe", files: [.init(path: "index.html", content: "<html><body>-----BEGIN PRIVATE KEY-----</body></html>")])
        try library.install(credentialSource, requestID: "unsafe", replacing: "screen")
        XCTAssertEqual(library.selected?.artifact.title, "Unsafe")
        XCTAssertNotNil(library.catalogQueue?.entries.last?.blockedReason)
    }

    @MainActor func testExplicitResumeDeclaresGapAfterVerifiedPredecessorsAndSurvivesRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding, maxRevisions: 1)
        try library.install(artifact("First"), requestID: "first", replacing: "screen")
        let first = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.install(artifact("Skipped"), requestID: "skipped", replacing: "screen")
        XCTAssertThrowsError(try library.resumeCatalog(binding: binding))
        try library.acknowledgeCatalogIntent(id: first.id, binding: binding)
        XCTAssertTrue(library.catalogQueue?.paused == true)
        try library.resumeCatalog(binding: binding)
        let restart = try ScreenLibrary(accountID: "library", rootDirectory: root)
        let resumed = try XCTUnwrap(restart.catalogQueue?.entries.first)
        XCTAssertEqual(resumed.counter, 3)
        XCTAssertEqual(resumed.gap?.checkpointCounter, 1)
        XCTAssertEqual(resumed.gap?.skippedFromCounter, 2)
        XCTAssertEqual(resumed.gap?.skippedThroughCounter, 2)
        XCTAssertEqual(resumed.parentIDs, [first.revision])
        XCTAssertEqual(resumed.revision, restart.selected?.revision)
        let exported = try restart.exportCatalogIntent(resumed, binding: binding)
        XCTAssertNoThrow(try restart.catalogBegin(resumed, declaration: exported.declaration, binding: binding))
        XCTAssertFalse(restart.catalogQueue?.paused == true)
    }

    @MainActor func testExpiredLeaseRotatesOnlyOperationAndKeepsImmutableRevisionPinned() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        try library.install(artifact("Pinned"), requestID: "first", replacing: "screen")
        let before = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.restartExpiredCatalogOperation(intentID: before.id, operationID: before.operationID, binding: binding)
        let restart = try ScreenLibrary(accountID: "library", rootDirectory: root)
        let after = try XCTUnwrap(restart.catalogQueue?.entries.first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.operationID, before.operationID)
        XCTAssertEqual(after.counter, before.counter)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.packageDigest, before.packageDigest)
        XCTAssertEqual(after.parentIDs, before.parentIDs)
        XCTAssertEqual(try restart.exportCatalogIntent(after, binding: binding).declaration.digest, before.packageDigest)
        XCTAssertThrowsError(try restart.restartExpiredCatalogOperation(intentID: before.id, operationID: before.operationID, binding: binding))
    }

    @MainActor func testEntitlementPauseTracksGapAndCannotResetUnpublishedCopy() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        try library.setCatalogEntitlement(false, binding: binding)
        try library.install(artifact("First while paused"), requestID: "first", replacing: "screen")
        XCTAssertTrue(library.catalogQueue?.entries.isEmpty == true)
        XCTAssertTrue(library.catalogQueue?.paused == true)
        try library.setCatalogEntitlement(true, binding: binding)
        XCTAssertThrowsError(try library.resumeCatalog(binding: binding))
        XCTAssertTrue(library.catalogQueue?.paused == true)
        XCTAssertEqual(library.catalogQueue?.copies["screen"]?.counter, 1)
        XCTAssertEqual(library.selected?.artifact.title, "First while paused")
    }

    @MainActor func testAuthenticationPauseSurvivesRestartAndOnlyMatchingSignInClearsIt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        try library.install(artifact("Offline"), requestID: "first", replacing: "screen")
        try library.pauseCatalogAuthentication(binding: binding)
        let restart = try ScreenLibrary(accountID: "library", rootDirectory: root)
        XCTAssertTrue(restart.catalogQueue?.authPaused == true)
        var other = binding; other.userID = "other"
        try restart.resumeCatalogAuthentication(binding: other)
        XCTAssertTrue(restart.catalogQueue?.authPaused == true)
        try restart.resumeCatalogAuthentication(binding: binding)
        XCTAssertFalse(restart.catalogQueue?.authPaused == true)
        XCTAssertEqual(restart.catalogQueue?.entries.count, 1)
    }

    @MainActor func testAuthoritativeCollectorExportsQuotedAttributesPresentationReferencesAndEmptyAssets() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library", rootDirectory: root)
        try library.activateCatalog(binding: binding)
        let html = """
        <html><head><link title=">" rel="stylesheet" href="empty.css"><script src="empty.js"></script></head><body><img title=">" src="art.svg"><object data="object.svg"></object><a href="empty.txt">Read</a><svg><rect fill="url(paint.svg#x)" filter="url(filter.svg#f)" mask="url(mask.svg#m)" clip-path="url(clip.svg#c)" stroke="url(stroke.svg#s)" marker-start="url(marker.svg#i)" /></svg></body></html>
        """
        let svgPaths = ["art.svg", "object.svg", "paint.svg", "filter.svg", "mask.svg", "clip.svg", "stroke.svg", "marker.svg"]
        let emptyPaths = ["empty.css", "empty.js", "empty.txt"]
        let files: [ScreenFile] = [.init(path: "index.html", content: html)] + svgPaths.map { .init(path: $0, content: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>") } + emptyPaths.map { .init(path: $0, content: "") }
        try library.install(.init(title: "Native dependency fixture", files: files), requestID: "references", replacing: "screen")
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
        let exported = try library.exportCatalogIntent(intent, binding: binding)
        XCTAssertEqual(exported.package.screen.requiredAssets, (svgPaths + emptyPaths).sorted())
        for path in emptyPaths {
            let file = try XCTUnwrap(exported.package.files.first(where: { $0.path == path }))
            XCTAssertEqual(file.byteLength, 0)
            XCTAssertEqual(file.contentBase64, "")
            XCTAssertEqual(file.digest, CatalogContract.digest(Data()))
        }
        if let output = ProcessInfo.processInfo.environment["CATALOG_EXPORT_FIXTURE_PATH"] { try exported.bytes.write(to: URL(fileURLWithPath: output), options: .atomic) }
    }

}
