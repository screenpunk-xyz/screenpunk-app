import Foundation
import ScreenpunkCore
import XCTest
@testable import DeviceAuthoring

final class PublicDataApprovalStoreTests: XCTestCase {
    func testForgettingDeletedScreensRemovesAllDeclarationVariantsForOnlyThoseScreens() throws {
        let suite = "screenpunk-public-approval-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PublicDataApprovalStore(defaults: defaults)
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        let removed = [
            "screenpunk.publicReads.local:one.starter-weather." + firstDigest,
            "screenpunk.publicReads.local:one.starter-weather." + secondDigest,
            "screenpunk.publicReads.local:one.starter-nasa." + firstDigest
        ]
        let preserved = [
            "screenpunk.publicReads.local:two.starter-weather." + firstDigest,
            "screenpunk.publicReads.local:one.starter-weather.copy." + firstDigest,
            "screenpunk.publicReads.local:one.custom-screen." + firstDigest,
            "screenpunk.publicReads.local:one.starter-weather.invalid",
            "screenpunk.publicReads.local:one.starter-weather." + String(repeating: "A", count: 64)
        ]
        for key in removed + preserved { store.setAllowed(true, key: key) }

        store.forget(owner: "local:one", dashboardIDs: [])
        for key in removed + preserved { XCTAssertTrue(store.isAllowed(key: key), key) }

        store.forget(owner: "local:one", dashboardIDs: ["starter-weather", "starter-nasa"])
        for key in removed { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in preserved { XCTAssertTrue(store.isAllowed(key: key), key) }
    }

    @MainActor func testSingleDeletionClearsVariantsAfterCommitAndReplacementPreservesApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-public-delete-" + UUID().uuidString)
        let suite = root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let owner = "local:one"
        let library = try ScreenLibrary(accountID: owner, rootDirectory: root, catalogDefaults: defaults)
        let templates = try StarterScreens.templates()
        try library.installStarterScreensIfNeeded(templates)
        let weather = try XCTUnwrap(templates.first { $0.id == "starter-weather" })
        let current = approvalKey(owner: owner, dashboardID: weather.id, hex: "a")
        let previous = approvalKey(owner: owner, dashboardID: weather.id, hex: "b")
        let unrelated = approvalKey(owner: owner, dashboardID: "starter-nasa", hex: "a")
        for key in [current, previous, unrelated] { defaults.set(true, forKey: key) }

        try library.install(weather.artifact, requestID: "replacement", replacing: weather.id, selectInstalled: false)
        for key in [current, previous, unrelated] { XCTAssertTrue(defaults.bool(forKey: key), key) }

        try library.savePending(id: "in-flight", screenID: weather.id, consumedID: nil)
        XCTAssertThrowsError(try library.remove(weather.id))
        XCTAssertTrue(library.state.screens.contains { $0.id == weather.id })
        for key in [current, previous, unrelated] { XCTAssertTrue(defaults.bool(forKey: key), key) }

        try library.savePending(id: nil, screenID: nil, consumedID: nil)
        try library.remove(weather.id)
        XCTAssertFalse(library.state.screens.contains { $0.id == weather.id })
        for key in [current, previous] { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertTrue(defaults.bool(forKey: unrelated))
    }

    @MainActor func testBulkDeletionClearsOnlyDeletedDashboardsForBoundPermissionOwner() throws {
        let libraries = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-public-bulk-delete-" + UUID().uuidString)
        let suite = libraries.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: libraries)
        }

        let account = "account"
        let libraryOwner = "local:library"
        let permissionOwner = "local:permission"
        let profile = LocalProfileDescriptor(id: "profile", libraryOwner: libraryOwner, permissionOwner: permissionOwner,
                                             localDeviceID: "device", cloudBinding: .init(accountID: account, profileID: "profile", deviceID: "device"))
        let folder = Data(libraryOwner.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let root = libraries.appendingPathComponent(folder, isDirectory: true)
        let library = try ScreenLibrary(profile: profile, rootDirectory: root)
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        let removed = StarterScreens.ids.map { approvalKey(owner: permissionOwner, dashboardID: $0, hex: "a") }
        let preserved = [approvalKey(owner: account, dashboardID: "starter-weather", hex: "a"),
                         approvalKey(owner: libraryOwner, dashboardID: "starter-nasa", hex: "a"),
                         approvalKey(owner: permissionOwner, dashboardID: "already-absent", hex: "a")]
        for key in removed + preserved { defaults.set(true, forKey: key) }

        XCTAssertThrowsError(try ScreenLibrary.deleteAccountScreens(accountID: "other", profile: profile, librariesDirectory: libraries, approvalDefaults: defaults))
        for key in removed + preserved { XCTAssertTrue(defaults.bool(forKey: key), key) }

        try ScreenLibrary.deleteAccountScreens(accountID: account, profile: profile, librariesDirectory: libraries, approvalDefaults: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        for key in removed { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in preserved { XCTAssertTrue(defaults.bool(forKey: key), key) }
    }

    @MainActor func testInterruptedSingleDeletionReplaysRevocationForThePermissionOwner() throws {
        enum Interrupted: Error { case crash }
        let templates = try StarterScreens.templates()
        let weather = try XCTUnwrap(templates.first { $0.id == "starter-weather" })
        for cut in AuthoringJournal.Cut.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-public-replay-" + UUID().uuidString)
            let suite = root.lastPathComponent
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let owner = "local:permission"
            let libraryOwner = "local:library"
            let library = try ScreenLibrary(accountID: libraryOwner, rootDirectory: root, permissionOwner: owner, catalogDefaults: defaults)
            try library.installStarterScreensIfNeeded([weather])
            let approval = approvalKey(owner: owner, dashboardID: weather.id, hex: "a")
            let unrelated = approvalKey(owner: libraryOwner, dashboardID: weather.id, hex: "a")
            for key in [approval, unrelated] { defaults.set(true, forKey: key) }

            let interrupted = try ScreenLibrary(accountID: libraryOwner, rootDirectory: root, permissionOwner: owner,
                                                catalogDefaults: defaults, journalFault: { if $0 == cut { throw Interrupted.crash } })
            XCTAssertThrowsError(try interrupted.remove(weather.id), cut.rawValue)
            XCTAssertTrue(defaults.bool(forKey: approval), cut.rawValue)

            let reopened = try ScreenLibrary(accountID: libraryOwner, rootDirectory: root, permissionOwner: owner, catalogDefaults: defaults)
            let deletionCommitted = cut != .assetsDurable
            XCTAssertEqual(reopened.state.screens.isEmpty, deletionCommitted, cut.rawValue)
            XCTAssertEqual(defaults.bool(forKey: approval), !deletionCommitted, cut.rawValue)
            XCTAssertTrue(defaults.bool(forKey: unrelated), cut.rawValue)
            XCTAssertNil(reopened.state.publicDataRevocations, cut.rawValue)
        }
    }

    @MainActor func testReopeningFinishesAnInterruptedAccountLibraryDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-public-discarded-" + UUID().uuidString)
        let suite = directory.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let owner = "local:permission"
        let libraryOwner = "local:library"
        let root = directory.appendingPathComponent("library", isDirectory: true)
        let discarded = directory.appendingPathComponent(".discarded-library", isDirectory: true)
        let library = try ScreenLibrary(accountID: libraryOwner, rootDirectory: root, permissionOwner: owner, catalogDefaults: defaults)
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        let approval = approvalKey(owner: owner, dashboardID: "starter-weather", hex: "a")
        let unrelated = approvalKey(owner: libraryOwner, dashboardID: "starter-weather", hex: "a")
        for key in [approval, unrelated] { defaults.set(true, forKey: key) }
        try FileManager.default.moveItem(at: root, to: discarded)

        let reopened = try ScreenLibrary(accountID: libraryOwner, rootDirectory: root, permissionOwner: owner, catalogDefaults: defaults)
        XCTAssertTrue(reopened.state.screens.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
        XCTAssertNil(defaults.object(forKey: approval))
        XCTAssertTrue(defaults.bool(forKey: unrelated))
    }

    private func approvalKey(owner: String, dashboardID: String, hex: Character) -> String {
        "screenpunk.publicReads.\(owner).\(dashboardID)." + String(repeating: hex, count: 64)
    }
}
