import XCTest
@testable import ScreenpunkCore

final class ScreenDataContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "AuthoringResources"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testSharedDeclarationsThroughPackageAndAuthoringValidators() throws {
        let old = try fixture("conformance-v1")
        let result = try JSONDecoder().decode(AuthoringResultV1.self, from: JSONSerialization.data(withJSONObject: old["result"]!))
        let screen = try XCTUnwrap(result.screen)
        let manifest = try XCTUnwrap(screen.files.first { $0.path == "manifest.json" })
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifest.content.utf8)) as? [String: Any])
        let vectors = try XCTUnwrap(fixture("conformance-screen-data-v1")["manifestCases"] as? [[String: Any]])
        for vector in vectors {
            let name = try XCTUnwrap(vector["name"] as? String)
            let extra = try XCTUnwrap(vector["manifest"] as? [String: Any])
            let combined = source.merging(extra) { _, updated in updated }
            let content = String(decoding: try JSONSerialization.data(withJSONObject: combined), as: UTF8.self)
            var changed = screen
            changed.files[try XCTUnwrap(changed.files.firstIndex { $0.path == "manifest.json" })].content = content
            func checkPackage() throws {
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(content.utf8))
                try PackageValidator.validate(manifest)
                if extra.isEmpty { XCTAssertNil(manifest.screenData) }
            }
            func checkAuthoring() throws { _ = try AuthoringContract.validateScreen(JSONEncoder().encode(changed)) }
            if vector["accepted"] as? Bool == true {
                XCTAssertNoThrow(try checkPackage(), name)
                XCTAssertNoThrow(try checkAuthoring(), name)
            } else {
                XCTAssertThrowsError(try checkPackage(), name)
                XCTAssertThrowsError(try checkAuthoring(), name)
            }
        }
    }

    func testSharedCapabilityDigestInBothAuthoringVersionsAndRoutes() throws {
        let base1 = try JSONSerialization.data(withJSONObject: fixture("conformance-v1")["request"]!)
        let base2 = try JSONSerialization.data(withJSONObject: fixture("conformance-v2")["request"]!)
        let legacy1 = try AuthoringContract.validateRequest(base1)
        let legacy2 = try AuthoringV2Contract.validateRequest(base2)
        XCTAssertFalse(legacy1.runtime.features.contains("data.query"))
        XCTAssertFalse(legacy2.runtime.features.contains("data.query"))
        let vectors = try XCTUnwrap(fixture("conformance-screen-data-v1")["requestDigests"] as? [[String: Any]])
        let runtime = AuthoringContract.runtime(supportsScreenData: true)
        let guidance = AuthoringContract.designGuidance(supportsScreenData: true)
        XCTAssertEqual(Array(runtime.features.suffix(3)), ["data.publish", "data.remove", "data.query"])
        for vector in vectors {
            let route = try XCTUnwrap(vector["route"] as? String)
            let digest = try XCTUnwrap(vector["digest"] as? String)
            if vector["version"] as? Int == 1 {
                var request = legacy1
                request.delivery.route = route; request.runtime = runtime; request.designGuidance = guidance
                XCTAssertEqual(try AuthoringContract.seal(request).delivery.snapshotDigest, digest)
                request.runtime = legacy1.runtime
                XCTAssertThrowsError(try AuthoringContract.seal(request))
            } else {
                var request = legacy2
                request.delivery.route = route; request.runtime = runtime; request.designGuidance = guidance
                XCTAssertEqual(try AuthoringV2Contract.seal(request).delivery.snapshotDigest, digest)
                request.runtime = legacy2.runtime
                XCTAssertThrowsError(try AuthoringV2Contract.seal(request))
            }
        }
    }

    func testSharedJSONBounds() throws {
        let vectors = try XCTUnwrap(fixture("conformance-screen-data-v1")["valueCases"] as? [[String: Any]])
        for vector in vectors {
            let value: AuthoringJSONValue
            if let unit = vector["unit"] as? String, let count = vector["count"] as? Int {
                value = .string(String(repeating: unit, count: count))
            } else if let depth = vector["depth"] as? Int {
                value = (0..<depth).reduce(.bool(false)) { result, _ in .array([result]) }
            } else {
                value = try JSONDecoder().decode(AuthoringJSONValue.self, from: JSONSerialization.data(withJSONObject: vector["value"]!, options: [.fragmentsAllowed]))
            }
            if vector["accepted"] as? Bool == true { XCTAssertNoThrow(try ScreenDataContract.validateValue(value)) }
            else { XCTAssertThrowsError(try ScreenDataContract.validateValue(value)) }
        }
        XCTAssertThrowsError(try ScreenDataContract.validateValue(.number(.infinity)))
    }

    func testNewDeclarationsNeedCapableRuntimeInBothAuthoringVersions() throws {
        let content = #"{"screenData":{"exports":[{"name":"feeding","description":"Last recorded feeding"}]}}"#
        let old1 = try fixture("conformance-v1"), old2 = try fixture("conformance-v2")
        var request1 = try AuthoringContract.validateRequest(JSONSerialization.data(withJSONObject: old1["request"]!))
        var result1 = try JSONDecoder().decode(AuthoringResultV1.self, from: JSONSerialization.data(withJSONObject: old1["result"]!))
        let index = try XCTUnwrap(result1.screen?.files.firstIndex { $0.path == "manifest.json" })
        result1.screen?.files[index].content = content
        func validateV1() throws { _ = try AuthoringContract.validateResult(JSONEncoder().encode(result1), request: request1) }
        XCTAssertThrowsError(try validateV1()) { XCTAssertTrue(($0 as? AuthoringContractError)?.message.contains("does not advertise") == true) }
        request1.context.currentScreen = result1.screen
        request1 = try AuthoringContract.seal(request1)
        result1.inputDigest = request1.delivery.snapshotDigest
        XCTAssertNoThrow(try validateV1())

        var request2 = try AuthoringV2Contract.validateRequest(JSONSerialization.data(withJSONObject: old2["request"]!))
        var result2 = try JSONDecoder().decode(AuthoringResultV2.self, from: JSONSerialization.data(withJSONObject: old2["result"]!))
        result2.screen?.files.append(.write(path: "manifest.json", content: content))
        func validateV2() throws { _ = try AuthoringV2Contract.validateResult(JSONEncoder().encode(result2), request: request2) }
        XCTAssertThrowsError(try validateV2()) { XCTAssertTrue(($0 as? AuthoringContractError)?.message.contains("does not advertise") == true) }
        request2.runtime = AuthoringContract.runtime(supportsScreenData: true)
        request2.designGuidance = AuthoringContract.designGuidance(supportsScreenData: true)
        request2 = try AuthoringV2Contract.seal(request2)
        result2.inputDigest = request2.delivery.snapshotDigest
        XCTAssertNoThrow(try validateV2())
    }
}
