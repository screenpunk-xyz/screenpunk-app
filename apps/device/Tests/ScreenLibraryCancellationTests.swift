import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryCancellationTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-cancellation-" + UUID().uuidString) }
    @MainActor private func request(_ library: ScreenLibrary, id: String, route: String = "local") throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: id, createdAt: 1_000, deadlineAt: 601_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            context: .init(profileID: "profile", deviceID: "device", screenID: "screen", baseRevision: library.selected?.revision,
                userRequest: "Change the caption", currentScreen: library.selected?.artifact,
                viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: route)))
    }
    @MainActor private func repeatedCancellation(version: Int) throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var library = try ScreenLibrary(accountID: "owner", rootDirectory: root)
        try library.install(.init(title: "Original", files: [.init(path: "index.html", content: "<html>Original</html>")]), requestID: "initial", replacing: "screen")
        let revision = library.selected?.revision
        for index in 0..<40 {
            let original = try request(library, id: "cancel-\(index)")
            if version == 1 {
                try library.saveAuthoringRequest(original)
                try library.saveSubmission(key: original.requestID, text: original.context.userRequest, screen: library.selected?.artifact)
                try library.savePending(id: original.requestID, screenID: "screen", consumedID: nil)
            } else {
                let input = try library.makeAuthoringRequestV2(from: original)
                try library.prepareAuthoringRequest(input, text: input.context.userRequest, screen: library.selected?.artifact)
                XCTAssertNotNil(library.state.authoring?.revisionPins?[input.requestID])
            }
            let digest = library.state.authoring?.requestDigests[original.requestID]
            try library.cancelRequest(original.requestID)
            // The captured coordinator repeats persistence after native source retirement.
            try library.cancelRequest(original.requestID)
            library = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            // Its immutable route also wins over a later caller's stale route hint.
            try library.cancelRequest(original.requestID, route: .cloud)
            XCTAssertTrue(library.authoringRequest(id: original.requestID) == nil)
            XCTAssertTrue(library.authoringRequestV2(id: original.requestID) == nil)
            XCTAssertNil(library.state.authoring?.revisionPins?[original.requestID])
            XCTAssertEqual(library.state.authoring?.requestDigests[original.requestID], digest)
            XCTAssertEqual(library.state.authoring?.requestDeviceIDs?[original.requestID], "device")
            XCTAssertTrue(library.state.authoring?.retiredRequestIDs?.contains(original.requestID) == true)
            XCTAssertTrue(library.state.authoring?.cancelledRequestIDs?.contains(original.requestID) == true)
            XCTAssertTrue(library.state.localRequestIDs?.contains(original.requestID) == true)
            XCTAssertNil(library.state.pendingID); XCTAssertNil(library.state.submissionKey)
            XCTAssertTrue(library.state.cancelIntents?.isEmpty ?? true)
            if version == 1 {
                let late = AuthoringResultV1(requestID: original.requestID, inputDigest: original.delivery.snapshotDigest, baseRevision: original.context.baseRevision,
                    preferenceRevisions: [:], operationID: "late-\(index)", answer: "Late")
                XCTAssertThrowsError(try library.applyAuthoringResult(late, now: 2_000))
            } else {
                let input = try library.makeAuthoringRequestV2(from: original)
                let late = AuthoringResultV2(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, baseRevision: input.context.baseRevision,
                    preferenceRevisions: [:], operationID: "late-\(index)", answer: "Late")
                XCTAssertThrowsError(try library.applyAuthoringResult(late, now: 2_000))
            }
            XCTAssertEqual(library.selected?.revision, revision)
            XCTAssertTrue(library.preferences.isEmpty); XCTAssertTrue(library.pendingReceipts.isEmpty)
        }
        let next = try request(library, id: "next")
        if version == 1 { XCTAssertNoThrow(try library.saveAuthoringRequest(next)) }
        else {
            let input = try library.makeAuthoringRequestV2(from: next)
            XCTAssertNoThrow(try library.prepareAuthoringRequest(input, text: input.context.userRequest, screen: library.selected?.artifact))
        }
    }
    @MainActor func testFortyLocalV1CancellationsAcrossRestartsReleaseSnapshotCapacity() throws { try repeatedCancellation(version: 1) }
    @MainActor func testFortyLocalV2CancellationsAcrossRestartsReleaseSnapshotCapacity() throws { try repeatedCancellation(version: 2) }
    @MainActor func testCapturedCoordinatorsRepeatLocalCancellationAfterSnapshotRetirement() async throws {
        for version in [1, 2] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            let original = try request(library, id: "cancelled")
            if version == 1 {
                try library.saveAuthoringRequest(original)
                let transport = FixtureAuthoringTransport { _ in throw AuthoringCoordinationError.unknownRequest }
                let coordinator = AuthoringCoordinator(transport: transport,
                    persistRequest: { try library.saveAuthoringRequest($0) },
                    applyResult: { try library.applyAuthoringResult($0) },
                    persistCancellation: { try library.cancelRequest($0) },
                    acknowledged: { try library.acknowledgeReceipt($0) })
                try library.cancelRequest(original.requestID, route: .local)
                try await coordinator.cancel(requestID: original.requestID)
            } else {
                let input = try library.makeAuthoringRequestV2(from: original)
                try library.prepareAuthoringRequest(input, text: input.context.userRequest, screen: nil)
                let transport = FixtureAuthoringTransportV2 { _ in throw AuthoringCoordinationError.unknownRequest }
                let coordinator = AuthoringCoordinatorV2(transport: transport,
                    persistRequest: { try library.saveAuthoringRequest($0) },
                    applyResult: { try library.applyAuthoringResult($0) },
                    persistCancellation: { try library.cancelRequest($0) },
                    acknowledged: { try library.acknowledgeReceipt($0) })
                try library.cancelRequest(original.requestID, route: .local)
                try await coordinator.cancel(requestID: original.requestID)
            }
            let restarted = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            XCTAssertTrue(restarted.state.cancelIntents?.isEmpty ?? true)
            XCTAssertTrue(restarted.state.localRequestIDs?.contains(original.requestID) == true)
            XCTAssertTrue(restarted.state.authoring?.cancelledRequestIDs?.contains(original.requestID) == true)
            XCTAssertNil(restarted.authoringRequest(id: original.requestID))
            XCTAssertNil(restarted.authoringRequestV2(id: original.requestID))
        }
    }
    @MainActor func testReopeningRetiresPreviouslyRetainedCancelledLocalSnapshotsOnly() throws {
        for version in [1, 2] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            for index in 0..<31 {
                let original = try request(library, id: "old-\(index)")
                if version == 1 { try library.saveAuthoringRequest(original) }
                else { try library.saveAuthoringRequest(library.makeAuthoringRequestV2(from: original)) }
            }
            let cloud = try request(library, id: "cloud-pending", route: "cloud")
            try library.saveAuthoringRequest(cloud)
            // Exact old on-disk state: Local tombstones exist, source payloads remain,
            // and a Cloud cancellation still awaits acknowledgement.
            var old = library.state
            let localIDs = Set((0..<31).map { "old-\($0)" })
            old.authoring?.cancelledRequestIDs = localIDs.union([cloud.requestID])
            old.cancelledRequests = Array(localIDs.union([cloud.requestID]))
            old.cancelIntents = [cloud.requestID]
            old.pendingID = "old-30"; old.submissionKey = "old-30"
            try JSONEncoder().encode(old).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            let restarted = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            XCTAssertTrue(localIDs.allSatisfy { restarted.authoringRequest(id: $0) == nil && restarted.authoringRequestV2(id: $0) == nil })
            XCTAssertTrue(localIDs.allSatisfy { restarted.state.authoring?.requestDigests[$0] != nil && restarted.state.authoring?.retiredRequestIDs?.contains($0) == true })
            XCTAssertEqual(restarted.authoringRequest(id: cloud.requestID), cloud)
            XCTAssertEqual(restarted.state.cancelIntents, [cloud.requestID])
            XCTAssertNil(restarted.state.pendingID); XCTAssertNil(restarted.state.submissionKey)
            XCTAssertNoThrow(try restarted.saveAuthoringRequest(request(restarted, id: "next")))
        }
    }
    @MainActor func testLocalCancellationPreservesAnAlreadyCommittedApplicationReceipt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "owner", rootDirectory: root)
        let input = try request(library, id: "completed")
        try library.saveAuthoringRequest(input)
        let result = AuthoringResultV1(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "operation", answer: "Done")
        let receipt = try library.applyAuthoringResult(result, now: 2_000)
        try library.cancelRequest(input.requestID)
        let restarted = try ScreenLibrary(accountID: "owner", rootDirectory: root)
        XCTAssertEqual(restarted.state.authoring?.receipts[receipt.operationID], receipt)
        XCTAssertEqual(try restarted.applyAuthoringResult(result, now: 3_000), receipt)
        XCTAssertTrue(restarted.pendingReceipts.isEmpty)
        XCTAssertNoThrow(try restarted.acknowledgeReceipt(receipt))
        XCTAssertTrue(restarted.state.authoring?.acknowledgedReceiptIDs.contains(receipt.operationID) == true)
    }
    @MainActor func testLocalCancellationJournalCutsKeepRetirementAndTombstoneTogether() throws {
        enum Crash: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "owner", rootDirectory: root, journalFault: { if armed && $0 == cut { throw Crash.interrupted } })
            try library.install(.init(title: "Original", files: [.init(path: "index.html", content: "<html>Original</html>")]), requestID: "initial", replacing: "screen")
            let input = try library.makeAuthoringRequestV2(from: request(library, id: "cancelled"))
            try library.prepareAuthoringRequest(input, text: input.context.userRequest, screen: library.selected?.artifact)
            armed = true
            XCTAssertThrowsError(try library.cancelRequest(input.requestID))
            let restarted = try ScreenLibrary(accountID: "owner", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertEqual(restarted.authoringRequestV2(id: input.requestID), input)
                XCTAssertNotNil(restarted.state.authoring?.revisionPins?[input.requestID])
                XCTAssertFalse(restarted.state.authoring?.cancelledRequestIDs?.contains(input.requestID) == true)
            } else {
                XCTAssertNil(restarted.authoringRequestV2(id: input.requestID))
                XCTAssertNil(restarted.state.authoring?.revisionPins?[input.requestID])
                XCTAssertTrue(restarted.state.authoring?.cancelledRequestIDs?.contains(input.requestID) == true)
                XCTAssertTrue(restarted.state.authoring?.retiredRequestIDs?.contains(input.requestID) == true)
                XCTAssertNil(restarted.state.pendingID); XCTAssertNil(restarted.state.submissionKey)
            }
            XCTAssertNotNil(restarted.state.authoring?.requestDigests[input.requestID])
            XCTAssertEqual(restarted.selected?.artifact.title, "Original")
        }
    }
}
