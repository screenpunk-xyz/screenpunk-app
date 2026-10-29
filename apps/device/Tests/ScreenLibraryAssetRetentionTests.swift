import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryAssetRetentionTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-v2-assets-" + UUID().uuidString) }
    /// Valid one-pixel PNG with a large synthetic tEXt chunk, embedded in SVG like the reported image.
    private let svg: String = {
        var png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
        let text = Data(("Fixture\0" + String(repeating: "synthetic", count: 6000)).utf8)
        let payload = Data("tEXt".utf8) + text
        var crc: UInt32 = 0xffff_ffff
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        func bigEndian(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        let chunk = bigEndian(UInt32(text.count)) + payload + bigEndian(crc ^ 0xffff_ffff)
        png.insert(contentsOf: chunk, at: png.count - 12)
        return "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"data:image/png;base64," + png.base64EncodedString() + "\"/></svg>"
    }()

    private func artifact(_ title: String = "Synthetic image") -> ScreenArtifact {
        .init(title: title, entry: "index.html", files: [
            .init(path: "index.html", content: "<html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><img src=\"cosmo.svg\"></body></html>"),
            .init(path: "style.css", content: "body { color: red; }"), .init(path: "cosmo.svg", content: svg)])
    }
    @MainActor private func request(_ library: ScreenLibrary, id: String = UUID().uuidString) throws -> AuthoringRequestV2 {
        let legacy = try AuthoringContract.seal(AuthoringRequestV1(requestID: id, createdAt: 1000, deadlineAt: 600000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            preferences: library.preferences(profileID: "profile", deviceID: "device", screenID: "screen"),
            context: .init(profileID: "profile", deviceID: "device", screenID: "screen", baseRevision: library.selected?.revision,
                userRequest: "Remember to always use large text and change the caption.", currentScreen: library.selected?.artifact,
                viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "local")))
        return try library.makeAuthoringRequestV2(from: legacy)
    }
    private func result(_ request: AuthoringRequestV2, operation: String? = nil, preferences: Bool = false) -> AuthoringResultV2 {
        let files = request.context.currentScreen!.files.map { source -> AuthoringFileMutationV2 in
            if source.path == "style.css" { return .write(path: source.path, content: "body { color: blue; }") }
            return .retain(path: source.path, sourcePath: source.path, reference: source.reference, digest: source.digest)
        }
        return .init(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
            preferenceRevisions: Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id, $0.revision) }), operationID: operation ?? "operation-" + request.requestID,
            screen: .init(title: "Edited", files: files),
            preferenceMutations: preferences ? [.init(kind: "upsert", id: "large", expectedRevision: nil,
                record: .init(id: "large", scope: "device", targetID: "device", category: "typography", value: .string("large"), revision: 1, originRequestID: request.requestID))] : nil,
            durablePreferenceAuthorization: preferences ? .init(requestID: request.requestID, quote: request.context.userRequest) : nil)
    }
    @MainActor func testRepeatedEditsKeepExactImageBytesAndCompactRequestsAcrossRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
        try library.install(artifact(), requestID: "initial", replacing: "screen")
        let expected = Data(svg.utf8), digest = AuthoringContract.contentDigest(expected)
        for index in 0..<4 {
            let input = try request(library, id: "edit-\(index)")
            XCTAssertEqual(input.context.libraryID, "library-owner")
            XCTAssertNil(input.context.currentScreen?.files.first(where: { $0.path == "cosmo.svg" })?.content)
            let requestBytes = try JSONEncoder().encode(input).count
            XCTAssertLessThan(requestBytes, 32 * 1024)
            print("Synthetic SVG bytes=\(expected.count) sha256=\(digest) edit=\(index) requestBytes=\(requestBytes)")
            try library.saveAuthoringRequest(input)
            XCTAssertEqual(library.state.authoring?.revisionPins?[input.requestID]?.revision, input.context.baseRevision)
            library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            let output = result(input)
            let receipt = try library.applyAuthoringResult(output, now: 2000)
            XCTAssertEqual(receipt.status, "applied")
            let saved = try XCTUnwrap(library.selected)
            let raw = try XCTUnwrap(library.store(for: saved).assets["cosmo.svg"]?.data)
            XCTAssertEqual(raw, expected); XCTAssertEqual(AuthoringContract.contentDigest(raw), digest)
            XCTAssertNil(library.state.authoring?.revisionPins?[input.requestID])
            let revision = saved.revision
            XCTAssertEqual(try library.applyAuthoringResult(output, now: 3000), receipt)
            XCTAssertEqual(library.selected?.revision, revision)
            var secondOperation = output; secondOperation.operationID += "-conflict"
            XCTAssertThrowsError(try library.applyAuthoringResult(secondOperation, now: 3000))
            try library.acknowledgeReceipt(receipt)
            library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            XCTAssertEqual(try library.applyAuthoringResult(output, now: 4000), receipt)
        }
    }
    @MainActor func testPinnedBaseSurvivesPruningAndRestartUntilDurableStaleReceipt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
        try library.install(artifact(), requestID: "initial", replacing: "screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        let pinned = root.appendingPathComponent(try XCTUnwrap(input.context.baseRevision))
        for index in 0..<3 { try library.install(artifact("Concurrent \(index)"), requestID: "concurrent-\(index)", replacing: "screen") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        let restarted = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertEqual(try restarted.applyAuthoringResult(result(input), now: 2000).status, "conflict")
        XCTAssertEqual(restarted.selected?.artifact.title, "Concurrent 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinned.path))
    }
    @MainActor func testNativeMissingDependencyRejectsV1AndV2WithoutSavingPreference() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
        try library.install(artifact(), requestID: "initial", replacing: "screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        var output = result(input, preferences: true)
        output.screen?.files.removeAll { $0.path == "cosmo.svg" }
        output.screen?.deletedPaths = ["cosmo.svg"]
        XCTAssertEqual(try library.applyAuthoringResult(output, now: 2000).status, "rejected")
        XCTAssertEqual(library.selected?.artifact.title, "Synthetic image")
        XCTAssertTrue(library.preferences.isEmpty); XCTAssertTrue(library.preferenceOutbox.isEmpty)
        XCTAssertNil(library.state.authoring?.revisionPins?[input.requestID])
        let legacy = try AuthoringContract.seal(input.legacyRequest(currentScreen: library.selected?.artifact))
        var nextLegacy = legacy; nextLegacy.requestID = "legacy-missing"; nextLegacy = try AuthoringContract.seal(nextLegacy)
        try library.saveAuthoringRequest(nextLegacy)
        let missing = AuthoringScreen(title: "Missing image", files: [.init(path: "index.html", content: "<img src='cosmo.svg'>")])
        let legacyOutput = AuthoringResultV1(requestID: nextLegacy.requestID, inputDigest: nextLegacy.delivery.snapshotDigest, baseRevision: nextLegacy.context.baseRevision, preferenceRevisions: [:], operationID: "legacy-operation", screen: missing)
        XCTAssertEqual(try library.applyAuthoringResult(legacyOutput, now: 2000).status, "rejected")
    }
    @MainActor func testCorruptMissingAndSymlinkPinnedBytesFailClosed() throws {
        for damage in ["corrupt", "missing", "symlink"] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            try library.install(artifact(), requestID: "initial", replacing: "screen")
            let input = try request(library); try library.saveAuthoringRequest(input)
            let file = root.appendingPathComponent(input.context.baseRevision!).appendingPathComponent("cosmo.svg")
            if damage == "corrupt" { try Data(String(repeating: "X", count: svg.utf8.count).utf8).write(to: file) }
            else {
                try FileManager.default.removeItem(at: file)
                if damage == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("library.json")) }
            }
            let revision = library.selected?.revision
            XCTAssertEqual(try library.applyAuthoringResult(result(input, preferences: true), now: 2000).status, "rejected", damage)
            XCTAssertEqual(library.selected?.revision, revision); XCTAssertTrue(library.preferences.isEmpty)
        }
    }
    @MainActor func testCancelledAndExpiredV2NeverReadReleasedBase() throws {
        for cancel in [true, false] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            try library.install(artifact(), requestID: "initial", replacing: "screen")
            let input = try request(library); try library.saveAuthoringRequest(input)
            if cancel {
                try library.saveSubmission(key: input.requestID, text: input.context.userRequest, screen: library.selected?.artifact)
                try library.cancelRequest(input.requestID, route: .local)
                XCTAssertNil(library.state.submissionKey); XCTAssertNil(library.state.submissionText)
                // The bounded UI history may age out, but the durable cancellation fence must remain.
                for index in 0..<101 { try library.cancelRequest("noise-\(index)", route: .local) }
                XCTAssertFalse(library.state.cancelledRequests?.contains(input.requestID) == true)
                XCTAssertTrue(library.state.authoring?.cancelledRequestIDs?.contains(input.requestID) == true)
            }
            let revision = library.selected?.revision
            if cancel { XCTAssertThrowsError(try library.applyAuthoringResult(result(input, preferences: true), now: 2000)) }
            else { XCTAssertEqual(try library.applyAuthoringResult(result(input, preferences: true), now: input.deadlineAt).status, "rejected") }
            XCTAssertEqual(library.selected?.revision, revision); XCTAssertTrue(library.preferences.isEmpty)
            XCTAssertNil(library.state.authoring?.revisionPins?[input.requestID])
        }
    }
    @MainActor func testAllJournalCutsCommitScreenPreferencesReceiptAndPinReleaseTogether() throws {
        enum Crash: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root, journalFault: { if armed && $0 == cut { throw Crash.interrupted } })
            try library.install(artifact(), requestID: "initial", replacing: "screen")
            let input = try request(library); try library.saveAuthoringRequest(input)
            let output = result(input, preferences: true)
            armed = true
            XCTAssertThrowsError(try library.applyAuthoringResult(output, now: 2000))
            let restarted = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertEqual(restarted.selected?.artifact.title, "Synthetic image")
                XCTAssertTrue(restarted.preferences.isEmpty); XCTAssertNotNil(restarted.state.authoring?.revisionPins?[input.requestID])
            } else {
                XCTAssertEqual(restarted.selected?.artifact.title, "Edited")
                XCTAssertEqual(restarted.preferences.first?.value, .string("large"))
                XCTAssertEqual(restarted.preferenceOutbox.count, 1)
                XCTAssertNil(restarted.state.authoring?.revisionPins?[input.requestID])
                XCTAssertEqual(try restarted.applyAuthoringResult(output, now: 3000).status, "applied")
            }
            XCTAssertEqual(try restarted.store(for: XCTUnwrap(restarted.selected)).assets["cosmo.svg"]?.data, Data(svg.utf8))
        }
    }
    @MainActor func testRenameReplaceDeleteAndForeignReferencesHaveExplicitAccounting() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
        try library.install(artifact(), requestID: "initial", replacing: "screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        let image = try XCTUnwrap(input.context.currentScreen?.files.first(where: { $0.path == "cosmo.svg" }))
        let style = try XCTUnwrap(input.context.currentScreen?.files.first(where: { $0.path == "style.css" }))
        var renamed = result(input)
        renamed.screen = .init(title: "Renamed", files: [
            .write(path: "index.html", content: "<link href='style.css'><img src='assets/renamed.svg'>"),
            .retain(path: "style.css", sourcePath: style.path, reference: style.reference, digest: style.digest),
            .retain(path: "assets/renamed.svg", sourcePath: image.path, reference: image.reference, digest: image.digest)], deletedPaths: ["cosmo.svg"], requiredAssets: ["assets/renamed.svg"])
        var foreign = renamed; foreign.screen?.files[2].reference = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try library.applyAuthoringResult(foreign, now: 2000))
        XCTAssertNotNil(library.state.authoring?.revisionPins?[input.requestID])
        XCTAssertEqual(try library.applyAuthoringResult(renamed, now: 2000).status, "applied")
        let raw = try library.store(for: XCTUnwrap(library.selected)).assets
        XCTAssertNil(raw["cosmo.svg"]); XCTAssertEqual(raw["assets/renamed.svg"]?.data, Data(svg.utf8))
        let second = try request(library); try library.saveAuthoringRequest(second)
        var replacement = result(second)
        replacement.screen = .init(title: "Replaced", files: [
            .write(path: "index.html", content: "<img src='assets/renamed.svg'>"),
            .write(path: "assets/renamed.svg", content: "<svg xmlns='http://www.w3.org/2000/svg'><rect width='1' height='1'/></svg>")], deletedPaths: ["style.css"])
        XCTAssertEqual(try library.applyAuthoringResult(replacement, now: 2000).status, "applied")
        XCTAssertNil(try library.store(for: XCTUnwrap(library.selected)).assets["style.css"])
        let otherRoot = directory(); defer { try? FileManager.default.removeItem(at: otherRoot) }
        let other = try ScreenLibrary(accountID: "other-owner", rootDirectory: otherRoot)
        XCTAssertThrowsError(try other.saveAuthoringRequest(second))
    }
    @MainActor func testEveryRequestPreparationCrashCutRecoversSnapshotAndPinTogether() throws {
        enum Crash: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "library-owner", rootDirectory: root, journalFault: { if armed && $0 == cut { throw Crash.interrupted } })
            try library.install(artifact(), requestID: "initial", replacing: "screen")
            let input = try request(library)
            armed = true; XCTAssertThrowsError(try library.prepareAuthoringRequest(input, text: input.context.userRequest, screen: library.selected?.artifact))
            let restarted = try ScreenLibrary(accountID: "library-owner", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertNil(restarted.authoringRequestV2(id: input.requestID))
                XCTAssertNil(restarted.state.authoring?.revisionPins?[input.requestID])
                XCTAssertNil(restarted.state.submissionKey); XCTAssertNil(restarted.state.pendingID)
            } else {
                XCTAssertEqual(restarted.authoringRequestV2(id: input.requestID), input)
                XCTAssertEqual(restarted.state.authoring?.revisionPins?[input.requestID]?.revision, input.context.baseRevision)
                XCTAssertEqual(restarted.state.submissionKey, input.requestID); XCTAssertEqual(restarted.state.pendingID, input.requestID)
                XCTAssertEqual(restarted.state.submissionText, input.context.userRequest)
            }
        }
    }

}
