import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

@MainActor enum CatalogFixture {
    static func defaults(_ root: URL) -> UserDefaults {
        UserDefaults(suiteName: root.lastPathComponent)!
    }

    static func open(_ root: URL, binding: ScreenLibrary.CatalogBinding, journalFault: AuthoringJournal.Fault? = nil) throws -> ScreenLibrary {
        let library = try ScreenLibrary(accountID: binding.libraryID, rootDirectory: root, catalogDefaults: defaults(root), journalFault: journalFault)
        library.setCatalogBackupScope(binding, validUntil: .distantFuture)
        return library
    }

    static func enable(_ library: ScreenLibrary, binding: ScreenLibrary.CatalogBinding, maxRevisions: Int = 100) throws {
        try library.setCatalogBackupsEnabled(true, binding: binding)
        try library.activateCatalog(binding: binding, maxRevisions: maxRevisions)
    }

    static func cleanup(_ root: URL) {
        defaults(root).removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }
}

final class ScreenLibraryCatalogTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-catalog-" + UUID().uuidString) }
    private func artifact(_ title: String) -> ScreenArtifact { .init(title: title, files: [.init(path: "index.html", content: "<html><body>\(title)</body></html>")]) }
    private var binding: ScreenLibrary.CatalogBinding { .init(origin: "https://example.test", accountID: "account", userID: "user", deviceID: "device", libraryID: "library") }

    @MainActor func testAssetRestoreStagingSurvivesReopenAndKeepsLargeRawFiles() async throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let entry = Data("<html><body>Large screen</body></html>".utf8)
        let media = Data(repeating: 0, count: 5 * 1024 * 1024 + 1)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("packages/contracts/fixtures/conformance-catalog-package-v2.json"))) as? [String: Any])
        let legacy = try JSONDecoder().decode(CatalogPackage.self, from: JSONSerialization.data(withJSONObject: fixture["package"]!))
        let legacyManifest = try XCTUnwrap(legacy.files.first { $0.path == "manifest.json" })
        var sdk = try JSONDecoder().decode(DashboardManifest.self, from: XCTUnwrap(Data(base64Encoded: legacyManifest.contentBase64)))
        let entryFile = CatalogAssetFile(path: "index.html", mediaType: "text/html", byteLength: entry.count, digest: CatalogContract.digest(entry))
        let mediaFile = CatalogAssetFile(path: "media.mp4", mediaType: "video/mp4", byteLength: media.count, digest: CatalogContract.digest(media))
        sdk.files = [entryFile, mediaFile].map { .init(path: $0.path, bytes: $0.byteLength, sha256: $0.digest) }
        let sdkBytes = try CatalogContract.canonical(sdk)
        let manifest = CatalogAssetManifest(schemaVersion: 2, screen: .init(title: "Large screen", entry: "index.html", requiredAssets: [], externalDependencies: []), files: [
            entryFile,
            .init(path: "manifest.json", mediaType: "application/json", byteLength: sdkBytes.count, digest: CatalogContract.digest(sdkBytes)),
            mediaFile
        ])
        let packageBytes = entry.count + media.count + sdkBytes.count
        var version = CatalogVersion(versionID: "assets-version", catalogScreenID: "catalog-large", displayVersion: 1, sourceRevisionID: "source",
            parentRevisionIDs: [], copyID: "copy", commitCounter: 1, screenName: manifest.screen.title,
            sourceAppliedAt: "2026-11-21T00:00:00.000Z", backedUpAt: "2026-11-21T00:00:00.000Z", packageSchema: 3,
            packageDigest: CatalogContract.digest(try CatalogContract.canonical(manifest)), sizeBytes: packageBytes,
            deviceDisplayName: "Test iPad", deviceLinked: true, preview: .init(), packageStorage: "assets")
        var library = try CatalogFixture.open(root, binding: binding)
        let staging = try library.openCatalogRestoreDirectory(binding: binding, version: version)
        XCTAssertThrowsError(try library.openCatalogRestoreDirectory(binding: binding, version: version))
        try entry.write(to: staging.appendingPathComponent("index.html"))
        try sdkBytes.write(to: staging.appendingPathComponent("manifest.json"))
        try media.prefix(CatalogContract.assetChunkBytes).write(to: staging.appendingPathComponent("media.mp4"))
        library.closeCatalogRestoreDirectory(staging)

        library = try CatalogFixture.open(root, binding: binding)
        var differentBinding = binding
        differentBinding.deviceID = "other-installation"
        let otherEnrollment = try library.openCatalogRestoreDirectory(binding: differentBinding, version: version)
        XCTAssertNotEqual(otherEnrollment, staging)
        library.closeCatalogRestoreDirectory(otherEnrollment)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: otherEnrollment.path)

        let originalVersion = version
        version.packageDigest = String(repeating: "a", count: 64)
        let changedManifest = try library.openCatalogRestoreDirectory(binding: binding, version: version)
        XCTAssertNotEqual(changedManifest, staging)
        library.closeCatalogRestoreDirectory(changedManifest)

        library = try CatalogFixture.open(root, binding: binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherEnrollment.path))
        let reopened = try library.openCatalogRestoreDirectory(binding: binding, version: originalVersion)
        XCTAssertEqual(reopened, staging)
        XCTAssertEqual(try Data(contentsOf: reopened.appendingPathComponent("media.mp4")), media.prefix(CatalogContract.assetChunkBytes))
        var offsets: [Int] = []
        try await CatalogAssetDownload.restore(file: mediaFile, destination: reopened.appendingPathComponent("media.mp4"), current: {}) { offset, count in
            offsets.append(offset)
            return media.subdata(in: offset..<offset + count)
        }
        XCTAssertEqual(offsets.first, CatalogContract.assetChunkBytes)
        XCTAssertEqual(offsets.last, 5 * 1024 * 1024)
        try library.setCatalogBackupsEnabled(true, binding: binding)
        try library.activateCatalog(binding: binding, maxBytes: 1, assetBackups: true)
        let item = CatalogScreen(catalogScreenID: originalVersion.catalogScreenID, latest: originalVersion, history: [])
        try library.installCatalogAssets(item, manifest: manifest, staged: reopened)
        library.closeCatalogRestoreDirectory(reopened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(library.containsCatalogScreen(item))
        let installed = try XCTUnwrap(library.state.screens.first)
        XCTAssertEqual(installed.catalogPackageSchema, 2)
        XCTAssertEqual(installed.catalogAssetPaths, ["index.html", "manifest.json", "media.mp4"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(installed.revision).appendingPathComponent("media.mp4")), media)
        let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
        XCTAssertEqual(intent.packageStorage, "assets")
        let exported = try await library.exportCatalogAssetIntent(intent, binding: binding)
        XCTAssertEqual(exported.manifest, manifest)
        XCTAssertEqual(exported.declaration.byteLength, packageBytes)
        XCTAssertEqual(exported.declaration.digest, originalVersion.packageDigest)
        XCTAssertEqual(try exported.chunk(file: mediaFile, offset: 5 * 1024 * 1024), Data([0]))

        let request = try library.makeAuthoringRequestV2(from: .init(requestID: UUID().uuidString, createdAt: 1_000,
            deadlineAt: 600_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime,
            services: [], context: .init(profileID: "profile", deviceID: "device", screenID: installed.id, baseRevision: installed.revision,
                userRequest: "Edit the heading.", viewport: .init(width: 1_024, height: 768, orientation: "landscape")),
            delivery: .init(route: "local")))
        let source = try XCTUnwrap(request.context.currentScreen)
        XCTAssertEqual(source.packageSchema, 3)
        let files = source.files.map { file in
            file.path == "index.html"
                ? AuthoringFileMutationV2.write(path: file.path, content: "<html><body>Edited screen</body></html>")
                : .retain(path: file.path, sourcePath: file.path, reference: file.reference, digest: file.digest)
        }
        try library.prepareAuthoringRequest(request, text: request.context.userRequest, screen: nil)
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest,
            baseRevision: request.context.baseRevision, preferenceRevisions: [:], operationID: UUID().uuidString,
            screen: .init(title: source.title, files: files))
        XCTAssertEqual(try library.applyAuthoringResult(result, now: 2_000).status, "applied")
        let edited = try XCTUnwrap(library.state.screens.first)
        let pending = try XCTUnwrap(library.catalogQueue?.entries.first { $0.revision == edited.revision })
        let backup = try await library.exportCatalogAssetIntent(pending, binding: binding)
        XCTAssertEqual(backup.manifest.schemaVersion, 2)
        XCTAssertEqual(backup.manifest.files.first { $0.path == mediaFile.path }, mediaFile)
        XCTAssertNotEqual(backup.declaration.digest, originalVersion.packageDigest)
    }

    @MainActor func testAssetDownloadRechecksPersistedBytesAndDropsCorruptFile() async throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = CatalogContract.assetChunkBytes
        let bytes = Data(repeating: 7, count: 2 * size + 1)
        let file = CatalogAssetFile(path: "media.bin", mediaType: "application/octet-stream", byteLength: bytes.count, digest: CatalogContract.digest(bytes))
        let destination = root.appendingPathComponent(file.path)
        try Data(repeating: 8, count: size + 3).write(to: destination)
        var requested: [Int] = []
        do {
            try await CatalogAssetDownload.restore(file: file, destination: destination, current: {}) { offset, count in
                requested.append(offset)
                return bytes.subdata(in: offset..<offset + count)
            }
            XCTFail("A corrupt persisted chunk cannot be installed")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertEqual(requested, [size, 2 * size])

        requested.removeAll()
        try await CatalogAssetDownload.restore(file: file, destination: destination, current: {}) { offset, count in
            requested.append(offset)
            return bytes.subdata(in: offset..<offset + count)
        }
        XCTAssertEqual(requested, [0, size, 2 * size])
        requested.removeAll()
        try await CatalogAssetDownload.restore(file: file, destination: destination, current: {}) { offset, _ in
            requested.append(offset)
            return Data()
        }
        XCTAssertTrue(requested.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    @MainActor func testNativeCatalogImportRetainsAudioOnDiskReopenAndBackup() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("packages/contracts/fixtures/conformance-catalog-package-v2.json"))) as? [String: Any])
        let package = try JSONDecoder().decode(CatalogPackage.self, from: JSONSerialization.data(withJSONObject: fixture["package"]!))
        let encoded = try CatalogContract.encodePackage(package)
        let version = CatalogVersion(versionID: "version", catalogScreenID: "catalog-audio", displayVersion: 1, sourceRevisionID: "source", parentRevisionIDs: [], copyID: "copy", commitCounter: 1, screenName: package.screen.title, sourceAppliedAt: "2026-11-21T00:00:00.000Z", backedUpAt: "2026-11-21T00:00:00.000Z", packageSchema: 2, packageDigest: CatalogContract.digest(encoded), sizeBytes: encoded.count, deviceDisplayName: "Theater iPad", deviceLinked: false, preview: .init())
        let item = CatalogScreen(catalogScreenID: version.catalogScreenID, latest: version, history: [])
        let library = try CatalogFixture.open(root, binding: binding)
        try library.install(artifact("Existing"), requestID: "existing", replacing: "existing")
        try CatalogFixture.enable(library, binding: binding)
        try library.installCatalogScreen(item, package: package)
        XCTAssertEqual(library.state.selectedID, "existing")
        XCTAssertEqual(library.state.lastRequest, "existing")
        let imported = try XCTUnwrap(library.state.screens.first { $0.catalogPackageSchema == 2 })
        let sound = try XCTUnwrap(package.files.first { $0.path == "sound.wav" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(imported.revision).appendingPathComponent(sound.path)), Data(base64Encoded: sound.contentBase64))
        let reopened = try CatalogFixture.open(root, binding: binding)
        XCTAssertTrue(reopened.containsCatalogScreen(item))
        try reopened.activateCatalog(binding: binding)
        let intent = try XCTUnwrap(reopened.catalogQueue?.entries.first { $0.screenID == imported.id })
        let exported = try reopened.exportCatalogIntent(intent, binding: binding)
        XCTAssertEqual(exported.bytes, encoded)
        try reopened.remove(imported.id)
        XCTAssertFalse(reopened.containsCatalogScreen(item))
    }

    @MainActor func testNativeCatalogEditsRetainAudioAndLargeTextWithExplicitRemoval() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("packages/contracts/fixtures/conformance-catalog-package-v2.json"))) as? [String: Any])
        var package = try JSONDecoder().decode(CatalogPackage.self, from: JSONSerialization.data(withJSONObject: fixture["package"]!))
        let manifestIndex = try XCTUnwrap(package.files.firstIndex(where: { $0.path == "manifest.json" }))
        let oldManifest = try XCTUnwrap(Data(base64Encoded: package.files[manifestIndex].contentBase64))
        var manifest = try JSONDecoder().decode(DashboardManifest.self, from: oldManifest)
        let largeText = Data(String(repeating: "Original text\r\n", count: 21_000).utf8)
        let note = "large.txt"
        manifest.files.append(.init(path: note, bytes: largeText.count, sha256: CatalogContract.digest(largeText)))
        let connection = ManifestConnection(alias: "googleCalendar", required: false)
        manifest.connections = [connection]
        let manifestBytes = try JSONEncoder().encode(manifest)
        package.files[manifestIndex] = .init(path: "manifest.json", mediaType: "application/json", byteLength: manifestBytes.count,
                                           digest: CatalogContract.digest(manifestBytes), contentBase64: manifestBytes.base64EncodedString())
        package.files.append(.init(path: note, mediaType: "text/plain", byteLength: largeText.count,
                                   digest: CatalogContract.digest(largeText), contentBase64: largeText.base64EncodedString()))
        package.files.sort { $0.path < $1.path }
        try verifyNativeCatalogEdit(package, explicitlyRemoving: note)
    }

    @MainActor func testNativeMigrationPackageEditsWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_CATALOG_PACKAGE_FIXTURES"] else { throw XCTSkip("No local migration packages supplied") }
        let directory = URL(fileURLWithPath: path)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let packages = try urls.map { try JSONDecoder().decode(CatalogPackage.self, from: Data(contentsOf: $0)) }.filter { $0.schemaVersion == 2 }
        XCTAssertFalse(packages.isEmpty)
        for package in packages { try verifyNativeCatalogEdit(package) }
    }

    @MainActor private func verifyNativeCatalogEdit(_ package: CatalogPackage, explicitlyRemoving removedPath: String? = nil) throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        var library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        let encoded = try CatalogContract.encodePackage(package)
        let version = CatalogVersion(versionID: "version", catalogScreenID: "editing-fixture", displayVersion: 1,
            sourceRevisionID: "source", parentRevisionIDs: [], copyID: "copy", commitCounter: 1,
            screenName: package.screen.title, sourceAppliedAt: "2026-11-21T00:00:00.000Z",
            backedUpAt: "2026-11-21T00:00:00.000Z", packageSchema: package.schemaVersion,
            packageDigest: CatalogContract.digest(encoded), sizeBytes: encoded.count,
            deviceDisplayName: "Test Device", deviceLinked: false, preview: .init())
        try library.installCatalogScreen(.init(catalogScreenID: version.catalogScreenID, latest: version, history: []), package: package)
        let original = try XCTUnwrap(library.state.screens.first)
        func makeRequest(_ base: ScreenLibrary.Saved) throws -> AuthoringRequestV2 {
            try library.makeAuthoringRequestV2(from: .init(requestID: UUID().uuidString, createdAt: 1_000,
                deadlineAt: 600_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime,
                services: [], context: .init(profileID: "profile", deviceID: "device", screenID: base.id, baseRevision: base.revision,
                    userRequest: "Update the page.", viewport: .init(width: 1_024, height: 768, orientation: "landscape")),
                delivery: .init(route: "local")))
        }
        func makeResult(_ request: AuthoringRequestV2, excluding excluded: String? = nil, deletedPaths: [String] = []) throws -> AuthoringResultV2 {
            let source = try XCTUnwrap(request.context.currentScreen)
            let files = source.files.filter { $0.path != excluded }.map { file in
                file.path == "index.html"
                    ? AuthoringFileMutationV2.write(path: file.path, content: (file.content ?? "") + "\n<!-- edit -->")
                    : .retain(path: file.path, sourcePath: file.path, reference: file.reference, digest: file.digest)
            }
            return .init(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest,
                baseRevision: request.context.baseRevision, preferenceRevisions: [:], operationID: UUID().uuidString,
                screen: .init(title: source.title, files: files, deletedPaths: deletedPaths))
        }
        let request = try makeRequest(original)
        XCTAssertEqual(Set(request.context.currentScreen?.files.map(\.path) ?? []), Set(package.files.map(\.path)))
        for file in package.files where file.mediaType.hasPrefix("audio/") || file.byteLength > 128 * 1024 {
            let manifestAsset = try XCTUnwrap(request.context.currentScreen?.files.first { $0.path == file.path })
            XCTAssertNil(manifestAsset.content)
            XCTAssertEqual(manifestAsset.digest, file.digest)
        }
        try library.prepareAuthoringRequest(request, text: request.context.userRequest, screen: nil)
        let result = try makeResult(request)
        let receipt = try library.applyAuthoringResult(result, now: 2_000)
        XCTAssertEqual(receipt.status, "applied", receipt.message ?? "")
        let edited = try XCTUnwrap(library.state.screens.first)
        XCTAssertNotEqual(edited.revision, original.revision)
        library = try CatalogFixture.open(root, binding: binding)
        XCTAssertEqual(try library.applyAuthoringResult(result, now: 3_000), receipt)
        XCTAssertEqual(library.state.screens.first?.revision, edited.revision)
        try library.activateCatalog(binding: binding)
        let backup = try XCTUnwrap(library.catalogQueue?.entries.first { $0.revision == edited.revision })
        let exported = try library.exportCatalogIntent(backup, binding: binding).package
        let manifestFile = try XCTUnwrap(exported.files.first { $0.path == "manifest.json" })
        let oldManifestFile = try XCTUnwrap(package.files.first { $0.path == "manifest.json" })
        func decodeManifest(_ file: CatalogPackageFile) throws -> DashboardManifest {
            try JSONDecoder().decode(DashboardManifest.self, from: XCTUnwrap(Data(base64Encoded: file.contentBase64)))
        }
        let old = try decodeManifest(oldManifestFile)
        let new = try decodeManifest(manifestFile)
        XCTAssertEqual(new.connections, old.connections)
        XCTAssertEqual(new.dashboardId, old.dashboardId)
        XCTAssertEqual(new.revision, old.revision)
        for file in package.files where file.path != "index.html" && file.path != "manifest.json" {
            XCTAssertEqual(exported.files.first { $0.path == file.path }, file)
        }

        if let removedPath {
            let newerRequest = try makeRequest(edited)
            try library.prepareAuthoringRequest(newerRequest, text: newerRequest.context.userRequest, screen: nil)
            XCTAssertThrowsError(try library.applyAuthoringResult(makeResult(newerRequest, excluding: removedPath), now: 4_000))
            XCTAssertEqual(library.state.screens.first?.revision, edited.revision)
            let removal = try library.applyAuthoringResult(makeResult(newerRequest, excluding: removedPath, deletedPaths: [removedPath]), now: 5_000)
            XCTAssertEqual(removal.status, "applied", removal.message ?? "")
            let updated = try XCTUnwrap(library.state.screens.first)
            XCTAssertFalse(updated.packagePaths.contains(removedPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(updated.revision).appendingPathComponent(removedPath).path))
        }
    }

    @MainActor func testCatalogImportPersistsIdentityExcludesHiddenAndAllowsReaddingAfterRemoval() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        let content = "<html><body>Imported</body></html>"
        let bytes = Data(content.utf8)
        let package = CatalogPackage(screen: .init(title: "Imported", entry: "index.html", requiredAssets: [], externalDependencies: []), files: [
            .init(path: "index.html", mediaType: "text/html", byteLength: bytes.count, digest: CatalogContract.digest(bytes), contentBase64: bytes.base64EncodedString())
        ])
        let encoded = try CatalogContract.encodePackage(package)
        let version = CatalogVersion(versionID: "version", catalogScreenID: "catalog", displayVersion: 1, sourceRevisionID: "source", parentRevisionIDs: [], copyID: "copy", commitCounter: 1, screenName: "Imported", sourceAppliedAt: "2026-11-20T00:00:00.000Z", backedUpAt: "2026-11-20T00:00:00.000Z", packageDigest: CatalogContract.digest(encoded), sizeBytes: encoded.count, deviceDisplayName: "Other device", deviceLinked: true, preview: .init())
        let item = CatalogScreen(catalogScreenID: "catalog", latest: version, history: [])
        try library.install(artifact("Existing"), requestID: "existing", replacing: "existing")
        let selected = library.state.selectedID
        XCTAssertFalse(library.containsCatalogScreen(item))
        try library.installCatalogScreen(item, package: package)
        XCTAssertEqual(library.state.selectedID, selected)
        XCTAssertEqual(library.state.lastRequest, "existing")
        XCTAssertFalse(library.catalogBackupsPreference(binding: binding))
        XCTAssertTrue(library.containsCatalogScreen(item))
        XCTAssertThrowsError(try library.installCatalogScreen(item, package: package))
        let imported = try XCTUnwrap(library.state.screens.first { $0.id != "existing" })
        try library.setScreenShown(false, id: imported.id)
        XCTAssertTrue(library.containsCatalogScreen(item))
        let reopened = try CatalogFixture.open(root, binding: binding)
        XCTAssertTrue(reopened.containsCatalogScreen(item))
        try reopened.remove(imported.id)
        XCTAssertFalse(reopened.containsCatalogScreen(item))
        try reopened.installCatalogScreen(item, package: package)
        XCTAssertEqual(reopened.state.screens.count, 2)
    }

    @MainActor func testBackupGrantDeadlineBlocksCaptureAndUploadWithoutDeletingQueueOrConsent() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(artifact("Queued"), requestID: "queued", replacing: "screen")
        let pending = try XCTUnwrap(library.catalogQueue?.entries.first)

        library.setCatalogBackupScope(binding, validUntil: .distantPast)
        XCTAssertNil(library.catalogAuthorization(binding: binding))
        XCTAssertTrue(library.catalogBackupsPreference(binding: binding))
        XCTAssertThrowsError(try library.activateCatalog(binding: binding))
        XCTAssertThrowsError(try library.exportCatalogIntent(pending, binding: binding))
        try library.install(artifact("After expiry"), requestID: "expired", replacing: "screen")
        XCTAssertEqual(library.catalogQueue?.entries.map(\.id), [pending.id])

        library.setCatalogBackupScope(nil)
        library.disableCatalogBackups(binding: binding)
        XCTAssertFalse(library.catalogBackupsPreference(binding: binding))
        library.setCatalogBackupScope(binding, validUntil: .distantFuture)
        XCTAssertNil(library.catalogAuthorization(binding: binding), "An upgrade must not turn backups on again.")
        XCTAssertEqual(library.catalogQueue?.entries.map(\.id), [pending.id])
    }

    @MainActor func testWakeRequiresConsentAndDurableQueuedRevision() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        var wakes = 0
        library.onCatalogRevisionCommitted = { wakes += 1 }
        try library.install(artifact("Local only"), requestID: "offline", replacing: "screen")
        XCTAssertEqual(wakes, 0)
        try CatalogFixture.enable(library, binding: binding)
        XCTAssertEqual(wakes, 0)
        try library.install(artifact("New edit"), requestID: "edit", replacing: "screen")
        XCTAssertEqual(wakes, 1)
        try library.saveInstruction("No screen mutation")
        try library.newScreen()
        let head = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.updateCatalogIntent(head, binding: binding)
        try library.acknowledgeCatalogIntent(id: head.id, binding: binding)
        try library.setCatalogBackupsEnabled(false, binding: binding)
        try library.install(artifact("Off again"), requestID: "offline-again", replacing: "screen")
        XCTAssertEqual(wakes, 1)
    }

    @MainActor func testDelayedGrantCatchesUpPlainHTMLWithoutRequeuingAcknowledgedScreens() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(artifact("Weather"), requestID: "weather", replacing: "weather")
        try library.install(artifact("NASA"), requestID: "nasa", replacing: "nasa")
        while let head = library.catalogQueue?.entries.first {
            try library.acknowledgeCatalogIntent(id: head.id, binding: binding)
        }
        let originals = library.state.screens
        let weatherCopy = library.catalogQueue?.copies["weather"]?.id
        let nasaCopy = library.catalogQueue?.copies["nasa"]?.id

        // Startup can discover local content before the asynchronous Pro read.
        library.setCatalogBackupScope(nil)
        try library.install(artifact("SDK-free counter"), requestID: "counter", replacing: "counter")
        XCTAssertTrue(library.catalogQueue?.entries.isEmpty == true)
        XCTAssertTrue(library.catalogBackupsPreference(binding: binding))
        XCTAssertNil(library.catalogQueue?.copies["counter"])

        // Once verified, run capability catch-up, not just an empty-queue drain.
        library.setCatalogBackupScope(binding, validUntil: .distantFuture)
        try library.activateCatalog(binding: binding)
        let queued = try XCTUnwrap(library.catalogQueue?.entries.first)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
        XCTAssertEqual(queued.screenID, "counter")
        XCTAssertEqual(queued.origin, "seed")
        XCTAssertEqual(library.catalogQueue?.acknowledgedCount, 2)
        XCTAssertEqual(library.catalogQueue?.copies["weather"]?.id, weatherCopy)
        XCTAssertEqual(library.catalogQueue?.copies["nasa"]?.id, nasaCopy)
        for original in originals {
            let current = try XCTUnwrap(library.state.screens.first { $0.id == original.id })
            XCTAssertEqual(current.revision, original.revision)
            XCTAssertEqual(current.artifact.files, original.artifact.files)
        }
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.map(\.id), [queued.id])
    }

    @MainActor func testDefaultOffRequiresOptInAndCapabilityBeforeSeedingCurrentScreens() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        XCTAssertNil(library.catalogAuthorization(binding: binding))
        try library.install(artifact("Earlier"), requestID: "earlier", replacing: "screen")
        XCTAssertThrowsError(try library.activateCatalog(binding: binding))
        XCTAssertNil(library.catalogQueue)
        try library.setCatalogBackupsEnabled(true, binding: binding)
        try library.install(artifact("Current"), requestID: "current", replacing: "screen")
        XCTAssertNil(library.catalogQueue)
        try library.activateCatalog(binding: binding)
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.map(\.title), ["Current"])
        XCTAssertEqual(library.catalogQueue?.entries.map(\.origin), ["seed"])
        try library.install(artifact("Future"), requestID: "future", replacing: "screen")
        XCTAssertEqual(library.catalogQueue?.entries.map(\.origin), ["seed", "apply"])
    }

    @MainActor func testOffFreezesPendingRetryAndReenableSeedsOnlyCurrentOffEdit() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        let authorized = try XCTUnwrap(library.catalogAuthorization(binding: binding))
        try library.install(artifact("Pending"), requestID: "pending", replacing: "screen")
        var pending = try XCTUnwrap(library.catalogQueue?.entries.first)
        pending.retryAt = 100
        try library.updateCatalogIntent(pending, binding: binding)
        try library.setCatalogBackupsEnabled(false, binding: binding)
        XCTAssertNil(library.catalogAuthorization(binding: binding))
        XCTAssertThrowsError(try library.exportCatalogIntent(pending, binding: binding))
        XCTAssertThrowsError(try library.restartExpiredCatalogOperation(intentID: pending.id, operationID: pending.operationID, binding: binding))
        XCTAssertThrowsError(try library.acknowledgeCatalogIntent(id: pending.id, binding: binding))
        try library.setCatalogBackupsEnabled(true, binding: binding)
        XCTAssertNotEqual(library.catalogAuthorization(binding: binding), authorized, "The previous flight must fail its post-await check after off/on.")
        try library.setCatalogBackupsEnabled(false, binding: binding)
        let restart = try CatalogFixture.open(root, binding: binding)
        XCTAssertNil(restart.catalogAuthorization(binding: binding))
        try restart.install(artifact("Skip"), requestID: "skip", replacing: "screen")
        try restart.install(artifact("Current"), requestID: "current", replacing: "screen")
        XCTAssertEqual(restart.catalogQueue?.entries.map(\.id), [pending.id])
        XCTAssertEqual(restart.catalogQueue?.copies["screen"]?.counter, 1)
        XCTAssertNil(restart.catalogQueue?.copies["screen"]?.gapFrom)
        try restart.setCatalogBackupsEnabled(true, binding: binding)
        XCTAssertThrowsError(try restart.exportCatalogIntent(pending, binding: binding), "Consent alone cannot restore the stale capability.")
        try restart.activateCatalog(binding: binding)
        let entries = try XCTUnwrap(restart.catalogQueue?.entries)
        XCTAssertEqual(entries.map(\.title), ["Pending", "Current"])
        XCTAssertEqual(entries.map(\.counter), [1, 2])
        XCTAssertEqual(entries[0].operationID, pending.operationID)
        XCTAssertEqual(entries[0].retryAt, pending.retryAt)
        XCTAssertEqual(entries[1].parentIDs, [pending.revision])
        XCTAssertNil(entries[1].gap)
    }

    @MainActor func testLegacyQueueWithoutConsentDefaultsOffAndKeepsRollbackIdentity() throws {
        for rolledBack in [false, true] {
            let root = directory(); defer { CatalogFixture.cleanup(root) }
            let library = try CatalogFixture.open(root, binding: binding)
            try CatalogFixture.enable(library, binding: binding)
            for title in ["First", "Latest"] {
                try library.install(artifact(title), requestID: title, replacing: "screen")
                let intent = try XCTUnwrap(library.catalogQueue?.entries.first)
                try library.acknowledgeCatalogIntent(id: intent.id, binding: binding)
            }
            if rolledBack { try library.rollback() }
            let metadata = root.appendingPathComponent("library.json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            var catalog = try XCTUnwrap(legacy["catalog"] as? [String: Any])
            catalog.removeValue(forKey: "knownSavedRevisions")
            legacy["catalog"] = catalog
            try JSONSerialization.data(withJSONObject: legacy).write(to: metadata)
            CatalogFixture.defaults(root).removeObject(forKey: binding.preferenceKey)

            let restart = try CatalogFixture.open(root, binding: binding)
            XCTAssertNil(restart.catalogAuthorization(binding: binding))
            if !rolledBack { try restart.install(artifact("New while off"), requestID: "new", replacing: "screen") }
            XCTAssertTrue(restart.catalogQueue?.entries.isEmpty == true)
            try CatalogFixture.enable(restart, binding: binding)
            XCTAssertEqual(restart.catalogQueue?.entries.map(\.title), rolledBack ? [] : ["New while off"])
            XCTAssertEqual(restart.catalogQueue?.copies["screen"]?.counter, rolledBack ? 2 : 3)
        }
    }

    @MainActor func testReenableDoesNotRenumberBackedUpRevisionRestoredAfterBranching() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        for title in ["A", "B", "C"] {
            try library.install(artifact(title), requestID: title, replacing: "screen")
            try library.acknowledgeCatalogIntent(id: XCTUnwrap(library.catalogQueue?.entries.first?.id), binding: binding)
        }
        try library.rollback()
        XCTAssertEqual(library.selected?.artifact.title, "B")
        try library.setCatalogBackupsEnabled(false, binding: binding)
        try library.install(artifact("D"), requestID: "D", replacing: "screen")
        try CatalogFixture.enable(library, binding: binding)
        let edit = try XCTUnwrap(library.catalogQueue?.entries.first)
        XCTAssertEqual(edit.title, "D")
        XCTAssertEqual(edit.revision, library.selected?.revision)
        try library.acknowledgeCatalogIntent(id: edit.id, binding: binding)
        try library.setCatalogBackupsEnabled(false, binding: binding)
        try library.rollback()
        let restart = try CatalogFixture.open(root, binding: binding)
        XCTAssertEqual(restart.selected?.artifact.title, "B")
        try CatalogFixture.enable(restart, binding: binding)
        XCTAssertEqual(restart.catalogQueue?.entries.count, 0)
        XCTAssertEqual(restart.catalogQueue?.copies["screen"]?.counter, 4)
    }

    @MainActor func testAccountEnvironmentAndEnrollmentChangesFencePreviousAuthorization() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(artifact("Private"), requestID: "private", replacing: "screen")
        let pending = try XCTUnwrap(library.catalogQueue?.entries.first)
        let prior = try XCTUnwrap(library.catalogAuthorization(binding: binding))
        let fields: [WritableKeyPath<ScreenLibrary.CatalogBinding, String>] = [\.origin, \.accountID, \.userID, \.deviceID, \.libraryID]
        for field in fields {
            var other = binding
            other[keyPath: field] += "-different"
            library.setCatalogBackupScope(other, validUntil: .distantFuture)
            XCTAssertNil(library.catalogAuthorization(binding: binding))
            XCTAssertNil(library.catalogAuthorization(binding: other))
            XCTAssertThrowsError(try library.activateCatalog(binding: other))
            XCTAssertThrowsError(try library.exportCatalogIntent(pending, binding: binding))
        }
        library.setCatalogBackupScope(binding, validUntil: .distantFuture)
        XCTAssertNotNil(library.catalogAuthorization(binding: binding))
        XCTAssertNotEqual(library.catalogAuthorization(binding: binding), prior)
        XCTAssertEqual(library.catalogQueue?.entries.first?.operationID, pending.operationID)
    }

    @MainActor func testLegacyInstallPinsEveryQueuedRevisionAcrossPruningAndRestart() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        var library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        for index in 0..<4 { try library.install(artifact("Edit \(index)"), requestID: "edit-\(index)", replacing: "screen") }
        let queue = try XCTUnwrap(library.catalogQueue)
        XCTAssertEqual(queue.entries.map(\.counter), [1, 2, 3, 4])
        XCTAssertEqual(Set(queue.entries.map(\.copyID)).count, 1)
        for item in queue.entries { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(item.revision).path)) }
        library = try CatalogFixture.open(root, binding: binding)
        try library.activateCatalog(binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.map(\.id), queue.entries.map(\.id))
        XCTAssertEqual(library.catalogQueue?.entries.last?.parentIDs, [queue.entries[2].revision])
        try library.acknowledgeCatalogIntent(id: queue.entries[0].id, binding: binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(queue.entries[0].revision).path))
        XCTAssertEqual(library.catalogQueue?.entries.count, 3)
    }

    @MainActor func testCatalogIntentAndInstalledScreenRecoverAtEveryJournalCut() throws {
        enum PowerLoss: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { CatalogFixture.cleanup(root) }
            var armed = false
            let library = try CatalogFixture.open(root, binding: binding, journalFault: { if armed && $0 == cut { throw PowerLoss.interrupted } })
            try CatalogFixture.enable(library, binding: binding)
            armed = true
            XCTAssertThrowsError(try library.install(artifact("Committed"), requestID: "edit", replacing: "screen"))
            let restart = try CatalogFixture.open(root, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding, maxRevisions: 2)
        for index in 0..<5 { try library.install(artifact("Edit \(index)"), requestID: "edit-\(index)", replacing: "screen") }
        XCTAssertEqual(library.selected?.artifact.title, "Edit 4")
        let restarted = try CatalogFixture.open(root, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try library.install(artifact("Past"), requestID: "past", replacing: "screen")
        try library.install(artifact("Current"), requestID: "current", replacing: "screen")
        try CatalogFixture.enable(library, binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
        XCTAssertEqual(library.catalogQueue?.entries.first?.origin, "seed")
        XCTAssertEqual(library.catalogQueue?.entries.first?.title, "Current")
        try library.saveInstruction("No screen mutation")
        try library.newScreen()
        try CatalogFixture.enable(library, binding: binding)
        XCTAssertEqual(library.catalogQueue?.entries.count, 1)
    }
    @MainActor func testV1V2LocalAndCloudCommitsCaptureOnceAndReceiptAckIsIndependent() throws {
        for route in ["local", "cloud"] {
            for version in [1, 2] {
                let root = directory(); defer { CatalogFixture.cleanup(root) }
                let library = try CatalogFixture.open(root, binding: binding)
                try CatalogFixture.enable(library, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Exact café bytes</text></svg>"
        let source = ScreenArtifact(title: "Assets", files: [.init(path: "index.html", content: "<html><body><img src=\"art.svg\"></body></html>"), .init(path: "art.svg", content: svg)])
        try library.install(source, requestID: "initial", replacing: "screen")
        let first = try XCTUnwrap(library.catalogQueue?.entries.first)
        let exported = try library.exportCatalogIntent(first, binding: binding)
        XCTAssertEqual(exported.package.screen.requiredAssets, ["art.svg"])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(exported.package.files.first(where: { $0.path == "art.svg" })?.contentBase64)), Data(svg.utf8))
        let begin = try library.catalogBegin(first, declaration: exported.declaration, binding: binding)
        try CatalogContract.validateBegin(begin)
        let restart = try CatalogFixture.open(root, binding: binding)
        try restart.activateCatalog(binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding, maxRevisions: 1)
        try library.install(artifact("First"), requestID: "first", replacing: "screen")
        let first = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.install(artifact("Skipped"), requestID: "skipped", replacing: "screen")
        XCTAssertThrowsError(try library.resumeCatalog(binding: binding))
        try library.acknowledgeCatalogIntent(id: first.id, binding: binding)
        XCTAssertTrue(library.catalogQueue?.paused == true)
        try library.resumeCatalog(binding: binding)
        let restart = try CatalogFixture.open(root, binding: binding)
        try restart.activateCatalog(binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(artifact("Pinned"), requestID: "first", replacing: "screen")
        let before = try XCTUnwrap(library.catalogQueue?.entries.first)
        try library.restartExpiredCatalogOperation(intentID: before.id, operationID: before.operationID, binding: binding)
        let restart = try CatalogFixture.open(root, binding: binding)
        try restart.activateCatalog(binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
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
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
        try library.install(artifact("Offline"), requestID: "first", replacing: "screen")
        try library.pauseCatalogAuthentication(binding: binding)
        let restart = try CatalogFixture.open(root, binding: binding)
        XCTAssertTrue(restart.catalogQueue?.authPaused == true)
        var other = binding; other.userID = "other"
        try restart.resumeCatalogAuthentication(binding: other)
        XCTAssertTrue(restart.catalogQueue?.authPaused == true)
        try restart.resumeCatalogAuthentication(binding: binding)
        XCTAssertFalse(restart.catalogQueue?.authPaused == true)
        XCTAssertEqual(restart.catalogQueue?.entries.count, 1)
    }

    @MainActor func testAuthoritativeCollectorExportsQuotedAttributesPresentationReferencesAndEmptyAssets() throws {
        let root = directory(); defer { CatalogFixture.cleanup(root) }
        let library = try CatalogFixture.open(root, binding: binding)
        try CatalogFixture.enable(library, binding: binding)
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
