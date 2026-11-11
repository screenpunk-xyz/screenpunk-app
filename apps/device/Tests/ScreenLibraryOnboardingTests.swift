import Foundation
import XCTest
@testable import DeviceAuthoring

final class ScreenLibraryOnboardingTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-onboarding-" + UUID().uuidString)
    }

    @MainActor func testNewGuidePersistsAcrossSeedingNavigationAndGalleryDismissal() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        XCTAssertTrue(initial.needsAgentSetup)
        try initial.installStarterScreensIfNeeded(StarterScreens.templates())

        let library = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        let weather = StarterScreens.ids[0]
        XCTAssertEqual(library.rotationIDs, [ScreenLibrary.instructionsID])
        try library.select(offset: 1)
        try library.selectVisible(weather)
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)
        XCTAssertTrue(library.instructionsSelected)
        XCTAssertTrue(library.isScreenShown(ScreenLibrary.instructionsID))

        try library.activateTemporarily(id: "alert", screenID: weather, expiresAt: Date().addingTimeInterval(60))
        XCTAssertEqual(library.selected?.id, weather)
        try library.finishAgentSetup()
        XCTAssertTrue(library.needsAgentSetup)
        try library.endTemporary(id: "alert")
        XCTAssertTrue(library.instructionsSelected)

        try library.finishAgentSetup()
        XCTAssertTrue(library.galleryIntroPending)
        XCTAssertTrue(library.instructionsSelected)
        XCTAssertEqual(library.rotationIDs, StarterScreens.ids + [ScreenLibrary.instructionsID])
        try library.dismissGalleryIntro()

        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        XCTAssertEqual(reopened.state.onboarding, .complete)
        XCTAssertTrue(reopened.instructionsSelected)
        try reopened.select(offset: 1)
        XCTAssertEqual(reopened.selected?.id, weather)
    }

    @MainActor func testExistingLibraryPreservesSelectionAndVisibilityWithoutGuide() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try legacy.installStarterScreensIfNeeded(StarterScreens.templates())
        let weather = StarterScreens.ids[0]
        try legacy.selectVisible(weather)
        try legacy.setScreenShown(false, id: ScreenLibrary.instructionsID)

        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        XCTAssertFalse(reopened.needsAgentSetup)
        XCTAssertFalse(reopened.galleryIntroPending)
        XCTAssertEqual(reopened.selected?.revision, legacy.selected?.revision)
        XCTAssertFalse(reopened.isScreenShown(ScreenLibrary.instructionsID))
    }

    @MainActor func testRouteRequiresAnObservedListenerOrVerifiedLocalConnection() {
        let guide = ScreenLibrary.Onboarding.self
        XCTAssertFalse(guide.agentIsReady(route: .automatic, verifiedLocal: false, cloudListenerConnected: false))
        XCTAssertTrue(guide.agentIsReady(route: .automatic, verifiedLocal: true, cloudListenerConnected: false))
        XCTAssertTrue(guide.agentIsReady(route: .automatic, verifiedLocal: false, cloudListenerConnected: true))
        XCTAssertFalse(guide.agentIsReady(route: .local, verifiedLocal: false, cloudListenerConnected: true))
        XCTAssertFalse(guide.agentIsReady(route: .cloud, verifiedLocal: true, cloudListenerConnected: false))
        XCTAssertTrue(guide.agentIsReady(route: .local, verifiedLocal: true, cloudListenerConnected: false))
        XCTAssertTrue(guide.agentIsReady(route: .cloud, verifiedLocal: false, cloudListenerConnected: true))
    }

    #if DEBUG
    @MainActor func testDebugGuideResetChangesOnlyOnboarding() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        try library.finishAgentSetup()
        try library.dismissGalleryIntro()
        try library.selectVisible(StarterScreens.ids[0])
        try library.setScreenShown(false, id: StarterScreens.ids[1])

        let before = library.state
        let receiptURL = root.appendingPathComponent("ScreenpunkOnboardingTestReceipt.json")
        try library.restartGuideForTesting(receiptURL: receiptURL)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertEqual(receipt["stage"] as? String, "connectAgent")
        XCTAssertEqual(receipt["libraryMetadataPreserved"] as? Bool, true)
        XCTAssertEqual(receipt["screensPreserved"] as? Bool, true)
        XCTAssertEqual(receipt["selectionPreserved"] as? Bool, true)
        XCTAssertEqual(receipt["showPreferencesPreserved"] as? Bool, true)
        XCTAssertEqual(receipt["backupConsentPreserved"] as? Bool, true)
        XCTAssertEqual(receipt.count, 6)
        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root, onboardNewLibrary: true)
        XCTAssertEqual(reopened.state.onboarding, .connectAgent)
        XCTAssertEqual(reopened.state.selectedID, before.selectedID)
        XCTAssertEqual(reopened.state.hiddenScreenIDs, before.hiddenScreenIDs)
        XCTAssertEqual(reopened.state.bundledScreenSeeds, before.bundledScreenSeeds)
        XCTAssertEqual(reopened.state.screens.map(\.id), before.screens.map(\.id))
        XCTAssertEqual(reopened.state.screens.map(\.revision), before.screens.map(\.revision))
    }
    #endif
}
