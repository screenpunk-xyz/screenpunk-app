import XCTest
@testable import ScreenpunkCore

@MainActor final class CloudDeviceNameRepositoryTests: XCTestCase {
    private let key = CloudDeviceNameRepository.key(origin: "https://api.screenpunk.xyz", accountID: "account-a", deviceID: "device-a")
    private func snapshot(_ name: String, _ revision: Int, enrollment: Int = 1) -> CloudDeviceNameSnapshot {
        .init(deviceId: "device-a", name: name, nameRevision: revision, enrollmentRevision: enrollment)
    }
    private func fixture(_ body: (CloudDeviceNameRepository, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-name-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(CloudDeviceNameRepository(rootDirectory: root), root)
    }
    func testOfflineEditSurvivesRestartWithStableOperationAndOriginalRevision() throws {
        try fixture { repository, root in
            try repository.observe(snapshot("Office", 4), key: key)
            let edit = try repository.queue(name: "Pappy's iPad", key: key)
            let reopened = try CloudDeviceNameRepository(rootDirectory: root)
            XCTAssertEqual(try reopened.record(key: key).pending, edit)
            XCTAssertEqual(edit.expectedNameRevision, 4)
            XCTAssertNotNil(UUID(uuidString: edit.operationID))
            let other = CloudDeviceNameRepository.key(origin: "https://staging.screenpunk.xyz", accountID: "account-a", deviceID: "device-a")
            XCTAssertNil(try reopened.record(key: other).pending)
        }
    }
    func testCloudRenameWinsOverStaleOfflineEditAndCannotBeDowngradedByLateStatus() throws {
        try fixture { repository, _ in
            try repository.observe(snapshot("Office", 1), key: key)
            let edit = try repository.queue(name: "Old offline name", key: key)
            try repository.observe(snapshot("Cloud name", 2), key: key)
            XCTAssertEqual(try repository.record(key: key).pending?.expectedNameRevision, 1)
            try repository.complete(edit, snapshot: snapshot("Cloud name", 2), conflict: true, key: key)
            try repository.observe(snapshot("Office", 1), key: key)
            let record = try repository.record(key: key)
            XCTAssertNil(record.pending)
            XCTAssertTrue(record.conflict)
            XCTAssertEqual(record.canonical?.name, "Cloud name")
        }
    }
    func testNewerEditDuringSuccessfulFlightIsPreservedAndRebasedOnlyOverOwnWrite() throws {
        try fixture { repository, _ in
            try repository.observe(snapshot("Office", 2), key: key)
            let first = try repository.queue(name: "First", key: key)
            let second = try repository.queue(name: "Second", key: key)
            try repository.complete(first, snapshot: snapshot("First", 3), conflict: false, key: key)
            let next = try XCTUnwrap(repository.record(key: key).pending)
            XCTAssertEqual(next.name, "Second")
            XCTAssertEqual(next.operationID, second.operationID)
            XCTAssertEqual(next.expectedNameRevision, 3)
            try repository.complete(next, snapshot: snapshot("Second", 4), conflict: false, key: key)
            XCTAssertNil(try repository.record(key: key).pending)
            XCTAssertEqual(try repository.record(key: key).canonical?.name, "Second")
        }
    }
    func testLateWriteAcknowledgementCannotReplaceNewerCloudName() throws {
        try fixture { repository, _ in
            try repository.observe(snapshot("Office", 1), key: key)
            let edit = try repository.queue(name: "Native", key: key)
            try repository.observe(snapshot("New Cloud name", 3), key: key)
            try repository.complete(edit, snapshot: snapshot("Native", 2), conflict: false, key: key)
            XCTAssertEqual(try repository.record(key: key).canonical?.name, "New Cloud name")
        }
    }
    func testReauthorizationDiscardsPreviousEnrollmentPendingEditAndKeepsOtherAccount() throws {
        try fixture { repository, _ in
            let other = CloudDeviceNameRepository.key(origin: "https://api.screenpunk.xyz", accountID: "account-b", deviceID: "device-a")
            try repository.observe(snapshot("Office", 2), key: key)
            _ = try repository.queue(name: "Removed enrollment edit", key: key)
            _ = try repository.queue(name: "Other account", key: other)
            try repository.observe(snapshot("Fresh authorization", 3, enrollment: 2), key: key)
            XCTAssertNil(try repository.record(key: key).pending)
            XCTAssertEqual(try repository.record(key: other).pending?.name, "Other account")
        }
    }
}
