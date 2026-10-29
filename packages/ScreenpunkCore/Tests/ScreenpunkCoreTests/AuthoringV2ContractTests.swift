import Foundation
import XCTest
@testable import ScreenpunkCore

final class AuthoringV2ContractTests: XCTestCase {
    private struct Recipe: Decodable { var prefix: String; var repeatCount: Int; var suffix: String }
    private struct Fixture: Decodable { var request: AuthoringRequestV2; var result: AuthoringResultV2; var assetRecipe: Recipe; var expectedAssetDigest: String; var expectedSnapshotDigest: String; var expectedReference: String }
    private func fixture() throws -> Fixture {
        let testFile = URL(fileURLWithPath: #filePath)
        let resources = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ScreenpunkCore/AuthoringResources/conformance-v2.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: resources))
    }
    func testSharedSealedSnapshotAndSyntheticAssetHashes() throws {
        let f = try fixture(); let request = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(f.request))
        XCTAssertEqual(try AuthoringV2Contract.snapshotDigest(request), f.expectedSnapshotDigest)
        XCTAssertEqual(try AuthoringV2Contract.reference(request: request, file: request.context.currentScreen!.files[2]), f.expectedReference)
        let asset = f.assetRecipe.prefix + String(repeating: "A", count: f.assetRecipe.repeatCount) + f.assetRecipe.suffix
        XCTAssertEqual(AuthoringContract.contentDigest(Data(asset.utf8)), f.expectedAssetDigest)
        XCTAssertNil(request.context.currentScreen!.files[2].content)
        XCTAssertFalse(try String(decoding: AuthoringContract.encodedCanonical(request), as: UTF8.self).contains("AAAA"))
        XCTAssertLessThan(try AuthoringContract.encodedCanonical(request.context).count, 32768)
        let materialized = try AuthoringV2Contract.materialize(f.result, request: request) { file in
            XCTAssertEqual(file.path, "art.svg"); return Data(asset.utf8)
        }
        XCTAssertEqual(materialized.files.first(where: { $0.path == "art.svg" })?.content, asset)
        XCTAssertThrowsError(try AuthoringV2Contract.materialize(f.result, request: request) { _ in Data((asset + "x").utf8) })
    }
    func testReferenceScopeStaleMissingAndBranchValidation() throws {
        let f = try fixture()
        func rejects(_ mutate: (inout AuthoringResultV2) -> Void) {
            var result = f.result; mutate(&result)
            XCTAssertThrowsError(try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: f.request))
        }
        rejects { $0.screen!.files.removeLast() }
        rejects { $0.screen!.files[2].reference = String(repeating: "a", count: 64) }
        rejects { $0.baseRevision = "other" }
        rejects { $0.screen!.deletedPaths = ["art.svg"] }
        rejects { $0.screen!.files[0].path = "../index.html" }
        rejects { $0.screen!.files.append(.write(path: "INDEX.html", content: "duplicate")) }
        rejects { $0.screen!.files[2].content = "wrong branch" }
        rejects { $0.screen!.requiredAssets = ["missing.svg"] }
        var other = f.request; other.context.libraryID = "other-library"; other = try AuthoringV2Contract.seal(other)
        var result = f.result; result.inputDigest = other.delivery.snapshotDigest
        XCTAssertThrowsError(try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: other))
    }
    func testExplicitCopyRenameNewScreenAndMaterializedLimit() throws {
        let f = try fixture(); var copy = f.result
        var copied = copy.screen!.files[2]; copied.path = "copy.svg"; copy.screen!.files.append(copied)
        XCTAssertNoThrow(try AuthoringV2Contract.validateResult(JSONEncoder().encode(copy), request: f.request))
        var renamed = f.result; renamed.screen!.files[2].path = "renamed.svg"; renamed.screen!.requiredAssets = ["renamed.svg"]
        XCTAssertThrowsError(try AuthoringV2Contract.validateResult(JSONEncoder().encode(renamed), request: f.request))
        renamed.screen!.deletedPaths = ["art.svg"]
        XCTAssertNoThrow(try AuthoringV2Contract.validateResult(JSONEncoder().encode(renamed), request: f.request))
        copied.path = "copy2.svg"; copy.screen!.files.append(copied)
        XCTAssertThrowsError(try AuthoringV2Contract.validateResult(JSONEncoder().encode(copy), request: f.request))
        var new = f.request; new.context.baseRevision = nil; new.context.currentScreen = nil; new = try AuthoringV2Contract.seal(new)
        var result = f.result; result.baseRevision = nil; result.inputDigest = new.delivery.snapshotDigest
        XCTAssertThrowsError(try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: new))
    }
    func testIncludedContentHashAndCapabilitiesFailClosed() throws {
        let f = try fixture(); var request = f.request; request.context.currentScreen!.files[0].content! += "x"
        XCTAssertThrowsError(try AuthoringV2Contract.seal(request))
        XCTAssertTrue(AuthoringCapabilitiesV2().supportsV2)
        XCTAssertFalse(AuthoringCapabilitiesV2(contractVersions: ["2"], features: []).supportsV2)
        XCTAssertFalse(AuthoringCapabilitiesV2(contractVersions: ["1"], features: ["asset-references-v2"]).supportsV2)
    }
    func testBOMBytesSurviveAndEscapingCannotExceedMaterializedLimit() throws {
        let f = try fixture(); var request = f.request
        let asset = "\u{FEFF}" + f.assetRecipe.prefix + String(repeating: "A", count: f.assetRecipe.repeatCount) + f.assetRecipe.suffix
        let bytes = Data(asset.utf8)
        request.context.currentScreen!.files[2].byteLength = bytes.count
        request.context.currentScreen!.files[2].digest = AuthoringContract.contentDigest(bytes)
        request = try AuthoringV2Contract.seal(request)
        var result = f.result; result.inputDigest = request.delivery.snapshotDigest
        result.screen!.files[2].reference = request.context.currentScreen!.files[2].reference
        result.screen!.files[2].digest = request.context.currentScreen!.files[2].digest
        let screen = try AuthoringV2Contract.materialize(result, request: request) { _ in bytes }
        XCTAssertEqual(Data(screen.files.first(where: { $0.path == "art.svg" })!.content.utf8), bytes)
        var new = request; new.context.baseRevision = nil; new.context.currentScreen = nil; new = try AuthoringV2Contract.seal(new)
        let huge = AuthoringResultV2(requestID: new.requestID, inputDigest: new.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "escaped", screen: .init(title: "Escaped", files: [.write(path: "index.html", content: String(repeating: "\"", count: 110000))]))
        XCTAssertNoThrow(try AuthoringV2Contract.validateResult(JSONEncoder().encode(huge), request: new))
        XCTAssertThrowsError(try AuthoringV2Contract.materialize(huge, request: new) { _ in XCTFail("new screen must never resolve"); return Data() })
    }

}
