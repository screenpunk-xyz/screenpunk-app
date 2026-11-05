import XCTest
import ScreenpunkCore

final class CatalogPreviewIdentityTests: XCTestCase {
    func testRenderedPixelsCannotBeAssignedToOtherAccountLibraryRevisionGenerationOrBytes() throws {
        let data = Data("<html><body>Exact source</body></html>".utf8)
        let package = CatalogPackage(screen: .init(title: "Fixture", requiredAssets: [], externalDependencies: []), files: [.init(path: "index.html", mediaType: "text/html", byteLength: data.count, digest: CatalogContract.digest(data), contentBase64: data.base64EncodedString())])
        let digest = CatalogContract.digest(try CatalogContract.encodePackage(package))
        let scope = CatalogPreviewScope(origin: "https://staging.screenpunk.xyz", accountID: "account", profileID: "profile", libraryID: "library", deviceID: "device")
        let revision = UUID().uuidString, generation = UUID()
        let proof = CatalogPreviewCaptureProof(scope: scope, revision: revision, generation: generation, files: ["index.html": .init(byteLength: data.count, digest: CatalogContract.digest(data))])
        func allowed(_ actual: CatalogPreviewCaptureProof) -> Bool { CatalogPreviewCapturePolicy.allows(actual, scope: scope, revision: revision, generation: generation, package: package, packageDigest: digest) }
        XCTAssertTrue(allowed(proof))
        let identities: [WritableKeyPath<CatalogPreviewScope, String>] = [\.origin, \.accountID, \.profileID, \.libraryID, \.deviceID]
        for key in identities { var changed = proof; changed.scope?[keyPath: key] = "other"; XCTAssertFalse(allowed(changed)) }
        var changed = proof; changed.scope = nil; XCTAssertFalse(allowed(changed))
        changed = proof; changed.revision = UUID().uuidString; XCTAssertFalse(allowed(changed))
        changed = proof; changed.generation = UUID(); XCTAssertFalse(allowed(changed), "Navigation/replacement during snapshot invalidates the screenshot.")
        changed = proof; changed.files["index.html"]?.digest = String(repeating: "0", count: 64); XCTAssertFalse(allowed(changed))
        changed = proof; changed.files["extra.js"] = .init(byteLength: 0, digest: CatalogContract.digest(Data())); XCTAssertFalse(allowed(changed))
        XCTAssertFalse(CatalogPreviewCapturePolicy.allows(proof, scope: scope, revision: revision, generation: generation, package: package, packageDigest: String(repeating: "0", count: 64)))
    }
}
