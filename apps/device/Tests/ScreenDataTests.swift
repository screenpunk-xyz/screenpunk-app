import Foundation
import ScreenpunkCore
import XCTest
@testable import DeviceAuthoring

final class ScreenDataTests: XCTestCase {
    private func root() -> URL {
        let parent = ProcessInfo.processInfo.environment["SCREENPUNK_SCREEN_DATA_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        return parent.appendingPathComponent("screen-data-" + UUID().uuidString)
    }

    private func artifact(_ title: String, declarations: ManifestScreenData) throws -> ScreenArtifact {
        let html = "<html><body>Fixture</body></html>"
        let bytes = Data(html.utf8)
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "untrusted-dashboard-id", name: title,
            revision: "untrusted-manifest-revision", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "fixture", width: 800, height: 600, scale: 1, orientation: "landscape"),
            connections: [], files: [.init(path: "index.html", bytes: bytes.count, sha256: AuthoringContract.contentDigest(bytes))],
            screenData: declarations)
        return .init(title: title, files: [
            .init(path: "index.html", content: html),
            .init(path: "manifest.json", content: String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self))
        ])
    }

    @MainActor private func fixture(_ root: URL) throws -> ScreenLibrary {
        let library = try ScreenLibrary(accountID: "account-a", rootDirectory: root, screenDataLocalDeviceIds: ["device-a"])
        try library.install(artifact("Publisher", declarations: .init(exports: [.init(name: "snapshot", description: "A sample report")])),
            requestID: "publisher-1", replacing: "publisher")
        try library.install(artifact("Reader", declarations: .init(queries: [.init(alias: "report", screenId: "publisher", exportName: "snapshot")])),
            requestID: "reader-1", replacing: "reader")
        return library
    }

    @MainActor private func permission(in library: ScreenLibrary, owner: String = "account-a",
                                       target: DeviceScreenDataTarget? = nil) throws -> DeviceScreenDataPermission {
        let reader = try XCTUnwrap(library.screenDataInstallation("reader"))
        let publisher = try XCTUnwrap(library.screenDataInstallation("publisher"))
        return try library.screenDataPermission(owner: owner, target: target ?? publisher.target(exportName: "snapshot"),
            reader: .init(kind: .screen, deviceId: "device-a", screenId: reader.screen.id, revision: reader.screen.revision,
                          generation: reader.generation, grantId: nil, title: "Reader", deviceTitle: "Fixture"))
    }

    @MainActor func testHiddenPublicationSurvivesReloadAndNullIsDistinctFromRemoval() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try fixture(directory)
        try library.setScreenShown(false, id: "publisher")
        let target = try XCTUnwrap(library.screenDataInstallation("publisher")).target(exportName: "snapshot")
        try library.publishScreenData(owner: "account-a", target: target, value: .null)
        var consent = try permission(in: library)
        XCTAssertThrowsError(try library.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .permissionRequired) }
        consent.decision = .allowed
        try library.screenDataArchive.set(consent)

        let reopened = try ScreenLibrary(accountID: "account-a", rootDirectory: directory, screenDataLocalDeviceIds: ["device-a"])
        XCTAssertFalse(reopened.isScreenShown("publisher"))
        XCTAssertEqual(reopened.selected?.id, "reader")
        XCTAssertEqual(try permission(in: reopened).key, consent.key)
        let first = try reopened.screenDataArchive.query(consent.key)
        XCTAssertEqual(first.value, .null)
        XCTAssertEqual(first.version, 1)
        let updated = try XCTUnwrap(DeviceScreenDataArchive.date(from: first.updatedAt))
        let read = try XCTUnwrap(DeviceScreenDataArchive.date(from: first.readAt))
        XCTAssertGreaterThanOrEqual(read, updated)

        try reopened.publishScreenData(owner: "account-a", target: target, value: nil)
        XCTAssertThrowsError(try reopened.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .notFound) }
        try reopened.publishScreenData(owner: "account-a", target: target, value: .bool(false))
        let restored = try reopened.screenDataArchive.query(consent.key)
        XCTAssertEqual(restored.value, .bool(false))
        XCTAssertGreaterThan(restored.version, first.version)
    }

    @MainActor func testDeclaringAnExportDoesNotExposePrivateStateAndConsentIsExact() throws {
        let directory = root()
        let secondDirectory = root()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let library = try fixture(directory)
        let secondLibrary = try fixture(secondDirectory)
        let target = try XCTUnwrap(library.screenDataInstallation("publisher")).target(exportName: "snapshot")
        var consent = try permission(in: library)
        consent.decision = .allowed
        try library.screenDataArchive.set(consent)
        XCTAssertThrowsError(try library.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .notFound) }
        try library.publishScreenData(owner: "account-a", target: target, value: .object(["fixture": .bool(true)]))
        XCTAssertThrowsError(try secondLibrary.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .permissionRequired) }
        let wrongAccount = try permission(in: library, owner: "account-b")
        XCTAssertThrowsError(try library.screenDataArchive.query(wrongAccount.key)) { XCTAssertEqual($0 as? ScreenDataError, .permissionRequired) }
        let undeclared = try XCTUnwrap(library.screenDataInstallation("publisher")).target(exportName: "privateValue")
        XCTAssertThrowsError(try library.publishScreenData(owner: "account-a", target: undeclared, value: .bool(true))) {
            XCTAssertEqual($0 as? ScreenDataError, .permissionRequired)
        }
        let spoofed = DeviceScreenDataTarget(screenId: "untrusted-dashboard-id", revision: target.revision, generation: target.generation, exportName: "snapshot")
        XCTAssertThrowsError(try permission(in: library, target: spoofed)) { XCTAssertEqual($0 as? ScreenDataError, .notFound) }
        consent.decision = .revoked
        try library.screenDataArchive.set(consent)
        XCTAssertEqual(try library.screenDataArchive.decision(for: consent.key), .revoked)
        XCTAssertThrowsError(try library.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .permissionRequired) }
    }

    @MainActor func testRollbackAndReinstallRetirePublishedGenerationAndConsent() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try fixture(directory)
        let original = try XCTUnwrap(library.screenDataInstallation("publisher"))
        var consent = try permission(in: library)
        consent.decision = .allowed
        try library.screenDataArchive.set(consent)
        try library.publishScreenData(owner: "account-a", target: original.target(exportName: "snapshot"), value: .string("old"))
        let replacement = try artifact("Publisher updated", declarations: original.declarations)
        try library.install(replacement, requestID: "publisher-2", replacing: "publisher")
        try library.rollback()
        let rolledBack = try XCTUnwrap(library.screenDataInstallation("publisher"))
        XCTAssertEqual(rolledBack.screen.revision, original.screen.revision)
        XCTAssertNotEqual(rolledBack.generation, original.generation)
        XCTAssertNil(try library.screenDataArchive.decision(for: consent.key))
        XCTAssertThrowsError(try permission(in: library, target: original.target(exportName: "snapshot"))) {
            XCTAssertEqual($0 as? ScreenDataError, .notFound)
        }
        try library.remove("publisher")
        try library.install(replacement, requestID: "publisher-3", replacing: "publisher")
        let reinstalled = try XCTUnwrap(library.screenDataInstallation("publisher"))
        XCTAssertNotEqual(reinstalled.generation, rolledBack.generation)
        XCTAssertNil(try library.screenDataArchive.decision(for: permission(in: library).key))
    }

    @MainActor func testRetiredPayloadsDoNotAccumulateAndRedeclarationKeepsVersion() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try fixture(directory)
        let first = try XCTUnwrap(library.screenDataInstallation("publisher"))
        try library.publishScreenData(owner: "account-a", target: first.target(exportName: "snapshot"), value: .bool(true))

        for iteration in 0..<20 {
            let name = "sample-\(iteration)"
            let replacement = try artifact("Publisher", declarations: .init(exports: [.init(name: name, description: "Sample")]))
            try library.install(replacement, requestID: "rename-\(iteration)", replacing: "publisher")
            let current = try XCTUnwrap(library.screenDataInstallation("publisher"))
            try library.publishScreenData(owner: "account-a", target: current.target(exportName: name),
                                          value: .string(String(repeating: "a", count: 16_000)))
        }

        let archive = directory.appendingPathComponent("screen-data/archive-v1.json")
        XCTAssertLessThan(try Data(contentsOf: archive).count, 32 * 1024)
        try library.install(artifact("Publisher", declarations: first.declarations), requestID: "restore-name", replacing: "publisher")
        let current = try XCTUnwrap(library.screenDataInstallation("publisher"))
        var consent = try permission(in: library)
        consent.decision = .allowed
        try library.screenDataArchive.set(consent)
        XCTAssertThrowsError(try library.screenDataArchive.query(consent.key)) { XCTAssertEqual($0 as? ScreenDataError, .notFound) }
        try library.publishScreenData(owner: "account-a", target: current.target(exportName: "snapshot"), value: .bool(false))
        let republished = try library.screenDataArchive.query(consent.key)
        XCTAssertGreaterThan(republished.version, 20)
        XCTAssertEqual(republished.value, .bool(false))
    }

    @MainActor func testMCPConsentCannotTransferToAnotherGrantWithSameDisplayName() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try fixture(directory)
        let target = try XCTUnwrap(library.screenDataInstallation("publisher")).target(exportName: "snapshot")
        func permission(_ grant: String) throws -> DeviceScreenDataPermission {
            try library.screenDataPermission(owner: "account-a", target: target, reader: .init(kind: .mcp, deviceId: nil,
                screenId: nil, revision: nil, generation: nil, grantId: grant, title: "ChatGPT", deviceTitle: nil))
        }
        var approved = try permission("grant-a")
        approved.decision = .allowed
        try library.screenDataArchive.set(approved)
        try library.publishScreenData(owner: "account-a", target: target, value: .string("fixture"))
        XCTAssertEqual(try library.screenDataArchive.query(approved.key).value, .string("fixture"))
        XCTAssertThrowsError(try library.screenDataArchive.query(permission("grant-b").key)) {
            XCTAssertEqual($0 as? ScreenDataError, .permissionRequired)
        }
    }

    func testCloudNoticeRequiresTypedCorrelationAndReader() throws {
        let socket = UUID().uuidString
        let status = Data(#"{"type":"status_changed","screenDataSocketId":"\#(socket)"}"#.utf8)
        XCTAssertEqual(DeviceCloudNotice.decode(status), .screenDataConnected(socketID: socket))
        let queryID = UUID().uuidString
        let notice = #"{"type":"screen_data_query","queryId":"\#(queryID)","deadlineAt":1800000000000,"target":{"screenId":"publisher","revision":"revision","generation":"generation","exportName":"snapshot"},"reader":{"kind":"mcp","grantId":"exact-grant","title":"ChatGPT"}}"#
        guard case let .screenDataQuery(query)? = DeviceCloudNotice.decode(Data(notice.utf8)) else {
            return XCTFail("Expected a typed notice")
        }
        XCTAssertEqual(query.reader.identity.grantId, "exact-grant")
        XCTAssertNil(DeviceCloudNotice.decode(Data(notice.replacingOccurrences(of: queryID, with: "..").utf8)))
        XCTAssertNil(DeviceCloudNotice.decode(Data(notice.replacingOccurrences(of: #","grantId":"exact-grant""#, with: "").utf8)))
    }

    func testCloudReplyPreservesFailureAndRejectsInvalidSuccess() throws {
        let failure = try JSONDecoder().decode(DeviceScreenDataWire.Reply.self, from: Data(#"{"status":"not_found"}"#.utf8))
        XCTAssertThrowsError(try failure.snapshot()) { XCTAssertEqual($0 as? ScreenDataError, .notFound) }
        let timestamp = "2026-11-12T15:00:00.000Z"
        let oversizedVersion = ScreenDataSnapshot(value: .null, version: ScreenDataContract.maxVersion + 1,
                                                   updatedAt: timestamp, readAt: timestamp)
        XCTAssertThrowsError(try DeviceScreenDataWire.Reply(oversizedVersion).snapshot()) {
            XCTAssertEqual($0 as? ScreenDataError, .unavailable)
        }
    }
}
