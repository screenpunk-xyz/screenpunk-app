import Foundation
import XCTest
@testable import ScreenpunkCore

final class LegacyGeneratorConnectionTests: XCTestCase {
    private func manifest() -> DashboardManifest {
        .init(schemaVersion: 1, dashboardId: "generator-studio", name: "Generator", revision: "installed-revision",
              entrypoint: "index.html", sdkVersion: "1",
              target: .init(profileId: "device", width: 1112, height: 834, scale: 2, orientation: "landscape"),
              connections: [.init(alias: "generator", required: true, operations: [.init(name: "telemetry", kind: "http")])],
              files: [
                .init(path: "app.js", bytes: 4_816, sha256: "7aaccfc711e5ea74a9dfe2b0cb9e4641abe08b48ebd2c0aac59f9c7a90deee3f"),
                .init(path: "index.html", bytes: 2_810, sha256: "e5b004facd9b1ffcfc79d0259688a03d6166058f0190fee15714f35dbe4d68ff"),
                .init(path: "screenpunk.js", bytes: 18_230, sha256: "d2bdb067c9151f47ad63fbd6392d45eb6b8dc07cabd7a72725ba3580d93e86c4"),
                .init(path: "style.css", bytes: 7_303, sha256: "442a2d3281a5d4fe47d81a9ee58b155165ac61d161556a58d41e28c05fc2b53a")
              ])
    }

    func testPromotesOnlyRecognizedUnconfiguredGeneratorPackage() throws {
        let original = manifest()
        let appDigest = original.files.first?.sha256
        let enriched = LegacyGeneratorConnection.enrich(original, appDigest: appDigest)
        try assertDescriptor(enriched)
        XCTAssertEqual(enriched.files, original.files)
        XCTAssertEqual(enriched.revision, original.revision)
        XCTAssertNil(original.connections.first?.customHTTP)
        XCTAssertEqual(LegacyGeneratorConnection.enrich(enriched, appDigest: appDigest), enriched)
        XCTAssertEqual(LegacyGeneratorConnection.enrich(original, appDigest: nil), original)
        XCTAssertEqual(LegacyGeneratorConnection.enrich(original, appDigest: "wrong"), original)

        var changed = original
        changed.files[1].sha256 = String(repeating: "a", count: 64)
        XCTAssertEqual(LegacyGeneratorConnection.enrich(changed, appDigest: appDigest), changed)
        changed = original
        changed.connections[0].operations?.append(.init(name: "extra", kind: "http"))
        XCTAssertEqual(LegacyGeneratorConnection.enrich(changed, appDigest: appDigest), changed)
        changed = original
        changed.dashboardId = "another-screen"
        XCTAssertEqual(LegacyGeneratorConnection.enrich(changed, appDigest: appDigest), changed)
    }

    func testFirstEditKeepsLegacyOperationButHonorsAnExplicitRemoval() throws {
        let original = manifest()
        let effective = LegacyGeneratorConnection.enrich(original, appDigest: original.files.first?.sha256)
        let declaration = try XCTUnwrap(effective.connections.first)
        var edited = original
        edited.files[0].sha256 = String(repeating: "a", count: 64)
        let bytes = try CatalogContract.canonical(edited)
        let updated = try LegacyGeneratorConnection.carryForward(declaration, into: bytes)
        let restored = try JSONDecoder().decode(DashboardManifest.self, from: updated)
        XCTAssertEqual(restored.connections, effective.connections)
        XCTAssertEqual(restored.files, edited.files)

        edited.connections = []
        let removed = try CatalogContract.canonical(edited)
        XCTAssertEqual(try LegacyGeneratorConnection.carryForward(declaration, into: removed), removed)
    }

    func testRetainedGeneratorCatalogFixtureWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_GENERATOR_FIXTURE"] else {
            throw XCTSkip("No retained Generator fixture supplied")
        }
        let url = URL(fileURLWithPath: path)
        let bytes = try Data(contentsOf: url)
        let package = try JSONDecoder().decode(CatalogPackage.self, from: bytes)
        _ = try CatalogContract.encodePackage(package)
        let manifestFile = try XCTUnwrap(package.files.first { $0.path == "manifest.json" })
        let manifestBytes = try XCTUnwrap(Data(base64Encoded: manifestFile.contentBase64))
        let original = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
        let app = try XCTUnwrap(package.files.first { $0.path == "app.js" })
        let source = try XCTUnwrap(Data(base64Encoded: app.contentBase64))
        XCTAssertTrue(String(decoding: source, as: UTF8.self).contains("screenpunk.connections.request('generator','telemetry')"))
        try assertDescriptor(LegacyGeneratorConnection.enrich(original, appDigest: CatalogContract.digest(source)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func assertDescriptor(_ manifest: DashboardManifest) throws {
        try PackageValidator.validate(manifest)
        let connection = try XCTUnwrap(manifest.connections.first)
        XCTAssertEqual(connection.alias, "generator")
        XCTAssertTrue(connection.required)
        XCTAssertNil(connection.operations)
        let descriptor = try XCTUnwrap(connection.customHTTP)
        XCTAssertEqual(descriptor.auth, .init(field: "credential"))
        XCTAssertEqual(descriptor.fields.map(\.type), ["url", "secret"])
        XCTAssertEqual(descriptor.originField, "origin")
        XCTAssertEqual(descriptor.operations, [.init(name: "telemetry", path: "/telemetry")])
    }
}
