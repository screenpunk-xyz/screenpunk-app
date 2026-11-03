import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class StarterScreensTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-starters-\(UUID().uuidString)") }
    @MainActor func testOnlySelectedWeatherAndNASAResourcesAreValidEditablePackages() throws {
        let templates = try StarterScreens.templates()
        XCTAssertEqual(templates.map(\.id), ["starter-weather", "starter-nasa"])
        XCTAssertEqual(templates.map { $0.artifact.title }, ["Ann Arbor Weather", "NASA — A wider view"])
        for template in templates {
            try ScreenLibrary.validate(template.artifact)
            let file = try XCTUnwrap(template.artifact.files.first { $0.path == "manifest.json" })
            let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(file.content.utf8))
            XCTAssertEqual(manifest.dashboardId, template.id)
            XCTAssertTrue(manifest.connections.allSatisfy { $0.publicHTTP != nil })
            XCTAssertLessThanOrEqual(try AuthoringContract.encodedCanonical(template.artifact).count, 204_800)
        }
    }
    @MainActor func testFreshLibraryGetsCopiesAndRestartDoesNotDuplicateThem() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let templates = try StarterScreens.templates(), library = try ScreenLibrary(accountID: "new", rootDirectory: root)
        try library.installStarterScreensIfNeeded(templates)
        XCTAssertEqual(library.state.screens.map(\.id), templates.map(\.id))
        XCTAssertEqual(library.selected?.id, "starter-weather")
        XCTAssertNil(library.state.lastRequest, "Bundling must not fabricate an agent request")
        let revisions = library.state.screens.map(\.revision)
        let reopened = try ScreenLibrary(accountID: "new", rootDirectory: root)
        try reopened.installStarterScreensIfNeeded(templates)
        XCTAssertEqual(reopened.state.screens.map(\.revision), revisions)
        for saved in reopened.state.screens { XCTAssertNotNil(try reopened.store(for: saved).assets["index.html"]) }
    }
    @MainActor func testRemovedDefaultsStayRemovedAfterRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let templates = try StarterScreens.templates(), library = try ScreenLibrary(accountID: "account", rootDirectory: root)
        try library.installStarterScreensIfNeeded(templates)
        for template in templates { try library.remove(template.id) }
        let reopened = try ScreenLibrary(accountID: "account", rootDirectory: root)
        try reopened.installStarterScreensIfNeeded(templates)
        XCTAssertTrue(reopened.state.screens.isEmpty); XCTAssertNil(reopened.selected)
    }
    @MainActor func testEditingOneLibraryPreservesOtherCopyAndBundledOriginal() throws {
        let ra = directory(), rb = directory(); defer { try? FileManager.default.removeItem(at: ra); try? FileManager.default.removeItem(at: rb) }
        let templates = try StarterScreens.templates(), original = templates[0].artifact
        let a = try ScreenLibrary(accountID: "a", rootDirectory: ra), b = try ScreenLibrary(accountID: "b", rootDirectory: rb)
        try a.installStarterScreensIfNeeded(templates); try b.installStarterScreensIfNeeded(templates)
        let bRevision = b.selected?.revision
        try a.install(.init(title: "My weather", entry: original.entry, files: original.files), requestID: "edit", replacing: "starter-weather")
        try a.installStarterScreensIfNeeded(templates)
        XCTAssertEqual(a.selected?.artifact.title, "My weather")
        XCTAssertEqual(b.selected?.artifact.title, original.title); XCTAssertEqual(b.selected?.revision, bRevision)
        XCTAssertEqual(try StarterScreens.templates()[0].artifact.title, original.title)
        XCTAssertEqual(a.state.previous?.artifact.title, original.title)
    }
    @MainActor func testExistingLibraryAndBlankSelectionArePreserved() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "existing", rootDirectory: root)
        try library.install(.init(title: "Existing", files: [.init(path: "index.html", content: "<html><body>Existing</body></html>")]), requestID: "existing-request", replacing: "existing")
        try library.newScreen(); try library.installStarterScreensIfNeeded(StarterScreens.templates())
        XCTAssertEqual(library.state.screens.map(\.id), ["existing", "starter-weather", "starter-nasa"]); XCTAssertNil(library.selected)
        XCTAssertEqual(library.state.lastRequest, "existing-request")
        for id in library.state.screens.map(\.id) { try library.remove(id) }
        let reopened = try ScreenLibrary(accountID: "existing", rootDirectory: root)
        try reopened.installStarterScreensIfNeeded(StarterScreens.templates()); XCTAssertTrue(reopened.state.screens.isEmpty)
    }
    @MainActor func testAddingDefaultsKeepsExistingSelectionAndNeverReplacesSameID() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "existing", rootDirectory: root)
        let templates = try StarterScreens.templates(), original = templates[0].artifact
        try library.install(.init(title: "Already customized", entry: original.entry, files: original.files), requestID: "existing-edit", replacing: "starter-weather")
        let revision = library.selected?.revision
        try library.installStarterScreensIfNeeded(templates)
        XCTAssertEqual(library.state.screens.count, 2)
        XCTAssertEqual(library.selected?.id, "starter-weather")
        XCTAssertEqual(library.selected?.artifact.title, "Already customized")
        XCTAssertEqual(library.selected?.revision, revision)
        XCTAssertEqual(library.state.lastRequest, "existing-edit")
    }
    @MainActor func testMarkerWithoutPackageOrRemovalDoesNotSuppressFirstInstall() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = try ScreenLibrary(accountID: "existing", rootDirectory: root)
        try existing.install(.init(title: "Existing", files: [.init(path: "index.html", content: "<html><body>Existing</body></html>")]), requestID: "old", replacing: "existing")
        var state = existing.state; state.bundledScreenSeeds = Set(StarterScreens.ids)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let reopened = try ScreenLibrary(accountID: "existing", rootDirectory: root)
        try reopened.installStarterScreensIfNeeded(StarterScreens.templates())
        XCTAssertEqual(reopened.state.screens.map(\.id), ["existing", "starter-weather", "starter-nasa"])
        XCTAssertEqual(reopened.selected?.id, "existing")
        XCTAssertEqual(reopened.state.lastRequest, "old")
    }
    @MainActor func testPendingDeliveryDefersSeedingWithoutChangingMetadata() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "account", rootDirectory: root)
        try library.savePending(id: "pending", screenID: nil, consumedID: "old")
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        XCTAssertTrue(library.state.screens.isEmpty); XCTAssertNil(library.state.bundledScreenSeeds)
        XCTAssertEqual(library.state.pendingID, "pending"); XCTAssertEqual(library.state.consumedID, "old")
        try library.savePending(id: nil, screenID: nil, consumedID: "old")
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        XCTAssertEqual(library.state.screens.count, 2); XCTAssertEqual(library.state.consumedID, "old")
    }
    @MainActor func testEveryJournalCutResumesWithoutDuplicateOrMissingPackages() throws {
        enum Interrupted: Error { case crash }
        let templates = try StarterScreens.templates()
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var commits = 0
            let interrupted = try ScreenLibrary(accountID: "account", rootDirectory: root, journalFault: { point in
                if point == cut { commits += 1; if commits == 2 { throw Interrupted.crash } }
            })
            XCTAssertThrowsError(try interrupted.installStarterScreensIfNeeded(templates))
            let recovered = try ScreenLibrary(accountID: "account", rootDirectory: root)
            try recovered.installStarterScreensIfNeeded(templates)
            XCTAssertEqual(recovered.state.screens.map(\.id), templates.map(\.id), cut.rawValue)
            for saved in recovered.state.screens { XCTAssertNotNil(try recovered.store(for: saved).assets["index.html"]) }
        }
    }
}
