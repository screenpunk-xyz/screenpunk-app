import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkLocalAuthoring

final class WireContractTests: XCTestCase {
    private func request(preferences: [PreferenceRecordV1] = []) throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: "wire-request", createdAt: 1_000, deadlineAt: 601_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], preferences: preferences, context: .init(profileID: "profile", deviceID: "device", screenID: "screen", userRequest: "Remember to always use my preferred contrast.", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "local")))
    }
    private func wire(_ result: AuthoringResultV1) throws -> Data {
        var object = try JSON.encoded(result).object
        for field in LocalResultWireContract.optionalResultFields where object[field] == nil { object[field] = .null }
        if case .array(let mutations) = object["preferenceMutations"] {
            object["preferenceMutations"] = .array(mutations.map { item in var value = item.object; if value["record"] == nil { value["record"] = .null }; return .object(value) })
        }
        return try JSON.object(object).data()
    }
    func testAnswerAndScreenNullOmissionPreserveCanonicalResult() throws {
        let request = try request()
        let answer = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "answer", answer: "Ready")
        XCTAssertEqual(try LocalResultWireContract.decode(wire(answer), request: request), answer)
        let screen = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "screen", screen: .init(title: "Hello", files: [.init(path: "index.html", content: "<h1>Hello</h1>")]))
        XCTAssertEqual(try LocalResultWireContract.decode(wire(screen), request: request), screen)
    }
    func testMutationRecordOmissionPreservesMeaningfulPreferenceValueNull() throws {
        let old = PreferenceRecordV1(id: "old", scope: "profile", targetID: "profile", category: "contrast", value: .string("dark"), revision: 1, originRequestID: "previous")
        let request = try request(preferences: [old])
        let result = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: ["old": 1], operationID: "mutation", preferenceMutations: [
            .init(kind: "delete", id: "old", expectedRevision: 1),
            .init(kind: "upsert", id: "new", expectedRevision: nil, record: .init(id: "new", scope: "profile", targetID: "profile", category: "contrast", value: .null, revision: 1, originRequestID: request.requestID))
        ], durablePreferenceAuthorization: .init(requestID: request.requestID, quote: request.context.userRequest))
        let decoded = try LocalResultWireContract.decode(wire(result), request: request)
        XCTAssertNil(decoded.preferenceMutations?[0].record)
        XCTAssertEqual(decoded.preferenceMutations?[1].record?.value, .null)
        XCTAssertEqual(decoded, result)
    }
    func testProjectionHasClosedObjectsRequiredPropertiesReachableDefinitionsAndExactBindings() throws {
        let preference = PreferenceRecordV1(id: "pref", scope: "profile", targetID: "profile", category: "contrast", value: .null, revision: 3, originRequestID: "previous")
        let request = try request(preferences: [preference])
        let schema = try LocalResultWireContract.schema(for: request)
        XCTAssertEqual(schema["type"].string, "object"); XCTAssertEqual(schema["$ref"], .null)
        XCTAssertEqual(schema["properties"]["requestID"]["enum"], .array([.string(request.requestID)]))
        XCTAssertEqual(schema["properties"]["inputDigest"]["enum"], .array([.string(request.delivery.snapshotDigest)]))
        XCTAssertEqual(schema["properties"]["preferenceRevisions"]["properties"]["pref"]["enum"], .array([.number(3)]))
        XCTAssertNil(schema["$defs"].object["Operation"]); XCTAssertNil(schema["$defs"].object["Request"])
        func inspect(_ value: JSON) {
            switch value {
            case .object(let object):
                for key in ["maxBytes", "x-screenpunk-max-utf16-code-units", "$schema", "$id", "propertyNames"] { XCTAssertNil(object[key]) }
                if object["type"]?.string == "object" {
                    XCTAssertEqual(object["additionalProperties"], .bool(false))
                    XCTAssertEqual(Set(object["required"]!.array.compactMap(\.string)), Set(object["properties"]!.object.keys))
                }
                for child in object.values { inspect(child) }
            case .array(let values): for child in values { inspect(child) }
            default: break
            }
        }
        inspect(schema)
    }
    func testAdaptationCannotRemoveUnknownNullOrChangeRequestBinding() throws {
        let request = try request()
        let result = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "answer", answer: "Ready")
        var value = try JSONDecoder().decode(JSON.self, from: wire(result)).object
        value["unexpected"] = .null
        XCTAssertThrowsError(try LocalResultWireContract.decode(JSON.object(value).data(), request: request))
        value.removeValue(forKey: "unexpected"); value["inputDigest"] = .string(String(repeating: "0", count: 64))
        XCTAssertThrowsError(try LocalResultWireContract.decode(JSON.object(value).data(), request: request))
    }
}

extension WireContractTests {
    func testV2StrictProjectionPreservesWriteRetainBranchesAndRejectsIrrelevantNull() throws {
        var original = try request()
        original.context.baseRevision = "base"
        original.context.currentScreen = .init(title: "Base", files: [.init(path: "index.html", content: "<img src=\"asset.svg\">"), .init(path: "asset.svg", content: "<svg/>")])
        original = try AuthoringContract.seal(original)
        let request = try AuthoringV2Contract.makeRequest(from: original, libraryID: "library")
        let source = request.context.currentScreen!.files[1]
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: "base", preferenceRevisions: [:], operationID: "operation-v2", screen: .init(title: "Updated", files: [.write(path: "index.html", content: "<h1>New</h1><img src=\"asset.svg\">"), .retain(path: "asset.svg", sourcePath: source.path, reference: source.reference, digest: source.digest)]))
        var wire = try JSON.encoded(result).object
        for field in LocalResultWireContract.optionalResultFields where wire[field] == nil { wire[field] = .null }
        var screen = wire["screen"]!.object; screen["requiredAssets"] = .null; wire["screen"] = .object(screen)
        XCTAssertEqual(try LocalResultWireContract.decode(JSON.object(wire).data(), request: request), result)
        let schema = try LocalResultWireContract.schema(for: request)
        let variants = schema["$defs"]["FileMutation"]["anyOf"].array
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(Set(variants[0]["properties"].object.keys), ["kind", "path", "content"])
        XCTAssertEqual(Set(variants[1]["properties"].object.keys), ["kind", "path", "sourcePath", "reference", "digest"])
        XCTAssertEqual(schema["properties"]["schemaVersion"]["enum"], .array([.number(2)]))
        var files = screen["files"]!.array; var wrong = files[0].object; wrong["sourcePath"] = .null
        files[0] = .object(wrong); screen["files"] = .array(files); wire["screen"] = .object(screen)
        XCTAssertThrowsError(try LocalResultWireContract.decode(JSON.object(wire).data(), request: request))
    }
}
