import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class LinkedCatalogWireTests: XCTestCase {
    let digest = String(repeating: "a", count: 64)

    func testRegistrationReceiptBindsExactRequestedVersionEvenWhenLaterHeadExists() throws {
        let request = CatalogLinkedInstallRequest(catalogScreenID: "catalog-screen", versionID: "version-one",
            sourceRevisionID: "remote-revision", packageDigest: digest, libraryID: "library-one",
            localScreenID: "local-screen", localRevisionID: "local-revision", commitCounter: 3)
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "catalogScreenID", "versionID", "sourceRevisionID",
                                          "packageDigest", "libraryID", "localScreenID", "localRevisionID", "commitCounter"])
        var receipt = makeReceipt()
        receipt.current = makeVersion(id: "version-two", display: 2)
        try receipt.validate()
        XCTAssertTrue(receipt.matches(request))

        receipt.localRevisionID = "another-local-revision"
        XCTAssertFalse(receipt.matches(request))
        receipt.localRevisionID = request.localRevisionID
        receipt.installedPackageDigest = String(repeating: "b", count: 64)
        XCTAssertFalse(receipt.matches(request))
        receipt.installedPackageDigest = digest
        receipt.libraryID = "other-library"
        XCTAssertFalse(receipt.matches(request))
    }

    func testFollowerReceiptMustMatchImmutableCopyAndLocalCheckpoint() throws {
        let binding = ScreenLibrary.CatalogBinding(origin: "https://cloud.example", accountID: "account", userID: "owner",
                                                  deviceID: "device", libraryID: "profile-library")
        let version = makeVersion(id: "version-one", display: 1)
        var link = ScreenLibrary.LinkedCatalogInstall(screenID: "local-screen", version: version,
                    libraryID: "library-one", binding: binding, localRevision: "local-revision")
        link.copyID = "copy-one"
        link.commitCounter = 3
        var receipt = makeReceipt()
        try receipt.validate()
        XCTAssertTrue(receipt.matches(link))
        receipt.copyID = "copy-two"
        XCTAssertFalse(receipt.matches(link))
        receipt.copyID = "copy-one"
        receipt.commitCounter = 2
        XCTAssertFalse(receipt.matches(link))
        receipt.commitCounter = 3
        receipt.installedDisplayVersion = 2
        XCTAssertFalse(receipt.matches(link))
    }

    func testRejectsMalformedServerIdentifiersAndCrossCatalogCurrentHead() {
        XCTAssertFalse(CatalogLinkedInstall.validIdentifier("screen\n"))
        XCTAssertFalse(CatalogLinkedInstall.validIdentifier("../screen"))
        XCTAssertFalse(CatalogLinkedInstall.validIdentifier("screen?copyID=other"))
        var receipt = makeReceipt()
        receipt.linkedDeviceCount = 0
        XCTAssertThrowsError(try receipt.validate())
        receipt = makeReceipt()
        receipt.current = makeVersion(id: "version-two", display: 2, catalogID: "unrelated-screen")
        XCTAssertThrowsError(try receipt.validate())
    }

    private func makeVersion(id: String, display: Int, catalogID: String = "catalog-screen") -> CatalogVersion {
        .init(versionID: id, catalogScreenID: catalogID, displayVersion: display, sourceRevisionID: "remote-revision",
              parentRevisionIDs: [], copyID: "copy-one", commitCounter: 3, screenName: "Linked screen",
              sourceAppliedAt: "2026-11-20T10:00:00.000Z", backedUpAt: "2026-11-20T10:00:00.000Z",
              packageDigest: digest, sizeBytes: 64, deviceDisplayName: "iPad", deviceLinked: true,
              preview: CatalogPreview())
    }

    private func makeReceipt() -> CatalogLinkedInstall {
        .init(schemaVersion: 1, catalogScreenID: "catalog-screen", libraryID: "library-one",
              localScreenID: "local-screen", localRevisionID: "local-revision", commitCounter: 3,
              copyID: "copy-one", installedVersionID: "version-one", installedSourceRevisionID: "remote-revision",
              installedDisplayVersion: 1, installedPackageDigest: digest, linkedDeviceCount: 2, current: nil)
    }
}
