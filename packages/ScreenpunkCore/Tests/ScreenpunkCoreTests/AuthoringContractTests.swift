import XCTest
@testable import ScreenpunkCore

final class AuthoringContractTests: XCTestCase {
    func testLocalRouteHasItsOwnImmutableDigest() throws {
        let f = try fixtures()
        let original = try AuthoringContract.validateRequest(data(f["request"]!))
        var local = original
        local.delivery.route = "local"
        local = try AuthoringContract.seal(local)
        XCTAssertEqual(try AuthoringContract.validateRequest(JSONEncoder().encode(local)), local)
        XCTAssertNotEqual(local.delivery.snapshotDigest, original.delivery.snapshotDigest)
        XCTAssertEqual(try AuthoringContract.snapshotDigest(original), original.delivery.snapshotDigest)
    }
    private func fixtures() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "conformance-v1", withExtension: "json", subdirectory: "AuthoringResources"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed,.withoutEscapingSlashes]) }
    private func change(_ value: Any, path: ArraySlice<Any>, replacement: Any?, remove: Bool) -> Any {
        let key = path.first!
        if let key = key as? String, var object = value as? [String: Any] {
            if path.count == 1 { if remove { object.removeValue(forKey: key) } else { object[key] = replacement } }
            else { object[key] = change(object[key]!, path: path.dropFirst(), replacement: replacement, remove: remove) }
            return object
        }
        var array = value as! [Any]; let index = (key as! NSNumber).intValue
        if path.count == 1 { if remove { array.remove(at: index) } else { array[index] = replacement! } }
        else { array[index] = change(array[index], path: path.dropFirst(), replacement: replacement, remove: remove) }
        return array
    }
    func testSharedSafeVectorsDecodeValidateAndRetainNullFields() throws {
        let f = try fixtures()
        let request = try AuthoringContract.validateRequest(data(f["request"]!))
        XCTAssertEqual(try AuthoringContract.snapshotDigest(request), request.delivery.snapshotDigest)
        XCTAssertEqual(try AuthoringContract.seal(request), request)
        let result = try AuthoringContract.validateResult(data(f["result"]!), request: request)
        XCTAssertEqual(result.requestID, request.requestID)
        _ = try AuthoringContract.validateResult(data(f["preferenceResult"]!), request: request)
        _ = try AuthoringContract.validatePreferenceRecord(data(f["preference"]!))
        _ = try AuthoringContract.validateApplicationReceipt(data(f["receipt"]!))
        var noBase = request; noBase.context.baseRevision = nil
        noBase = try AuthoringContract.seal(noBase)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(noBase)) as? [String: Any])
        XCTAssertTrue((encoded["context"] as! [String: Any])["baseRevision"] is NSNull)
        let mutation = PreferenceMutationV1(kind: "upsert", id: "preference-new", expectedRevision: nil)
        XCTAssertTrue((try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as! [String: Any])["expectedRevision"] is NSNull)
    }
    func testSharedCanonicalJSONAndSHA256Vectors() throws {
        let f = try fixtures()
        for vector in f["canonicalVectors"] as! [[String: Any]] {
            let canonical = try AuthoringContract.canonicalJSON(data(vector["input"]!))
            XCTAssertEqual(String(decoding: canonical, as: UTF8.self), vector["canonical"] as! String)
            XCTAssertEqual(AuthoringContract.contentDigest(canonical), vector["sha256"] as! String)
        }
    }
    func testSharedInvalidConformanceCasesReject() throws {
        let f = try fixtures()
        let request = try AuthoringContract.validateRequest(data(f["request"]!))
        for invalid in f["invalidCases"] as! [[String: Any]] {
            let kind = invalid["kind"] as! String
            var changed = change(f[kind]!, path: (invalid["path"] as! [Any])[...], replacement: invalid["value"], remove: invalid["remove"] as? Bool ?? false)
            if let digest = invalid["snapshotDigest"] as? String { changed = change(changed, path: ["delivery","snapshotDigest"][...], replacement: digest, remove: false) }
            XCTAssertThrowsError(try {
                switch kind {
                case "request": _ = try AuthoringContract.validateRequest(data(changed))
                case "preference": _ = try AuthoringContract.validatePreferenceRecord(data(changed))
                case "receipt": _ = try AuthoringContract.validateApplicationReceipt(data(changed))
                default: _ = try AuthoringContract.validateResult(data(changed), request: request)
                }
            }(), invalid["name"] as! String)
        }
    }
    func testDigestIncludesRequestScopeCapabilitiesPreferencesAndRoute() throws {
        let f = try fixtures()
        let request = try AuthoringContract.validateRequest(data(f["request"]!))
        let paths: [[Any]] = [["context","userRequest"],["context","baseRevision"],["delivery","route"],["services",0,"reachable","state"],["preferences",0,"value"]]
        for path in paths {
            let replacement = path.last as? String == "route" ? "cloud" : path.last as? String == "state" ? "no" : "tampered"
            let changed = change(f["request"]!, path: path[...], replacement: replacement, remove: false)
            let decoded = try JSONDecoder().decode(AuthoringRequestV1.self, from: data(changed))
            XCTAssertNotEqual(try AuthoringContract.snapshotDigest(decoded),request.delivery.snapshotDigest)
            XCTAssertThrowsError(try AuthoringContract.validateRequest(data(changed)))
        }
    }
    func testCapabilityFactsRemainIndependentAndUnknownDoesNotGrantReadiness() throws {
        let f = try fixtures()
        var request = try AuthoringContract.validateRequest(data(f["request"]!))
        request.services[0].configured.state = "yes"; request.services[0].reachable.state = "no"
        XCTAssertEqual(try AuthoringContract.seal(request).services[0].configured.state,"yes")
        request.services[0].reachable.state = "unknown"
        XCTAssertEqual(try AuthoringContract.seal(request).services[0].reachable.state,"unknown")
        XCTAssertEqual(AuthoringContract.makeServices(observedAt: request.createdAt).first { $0.provider == "googleCalendar" }?.configured.state,"no")
    }
    func testUTF8AndSerializedScreenBounds() throws {
        let f = try fixtures()
        var preference = f["preference"] as! [String: Any]
        preference["value"] = String(repeating: "😀", count: 1025)
        XCTAssertThrowsError(try AuthoringContract.validatePreferenceRecord(data(preference)))
        let screen = AuthoringScreen(title: "Bounded", files: [.init(path:"index.html",content:String(repeating:"\"",count:102400))])
        XCTAssertThrowsError(try AuthoringContract.validateScreen(JSONEncoder().encode(screen)))
        let within = AuthoringScreen(title:"Bounded", files:[.init(path:"index.html",content:String(repeating:"é",count:100000))])
        XCTAssertNoThrow(try AuthoringContract.validateScreen(JSONEncoder().encode(within)))
    }
    func testSharedSerializedScreenBoundaryVectors() throws {
        for vector in try fixtures()["screenBoundaryVectors"] as! [[String: Any]] {
            let screen = AuthoringScreen(title:"Boundary", files:[.init(path:"index.html",content:String(repeating: vector["character"] as! String,count:vector["count"] as! Int))])
            if vector["accepted"] as! Bool { XCTAssertNoThrow(try AuthoringContract.validateScreen(JSONEncoder().encode(screen)),vector["name"] as! String) }
            else { XCTAssertThrowsError(try AuthoringContract.validateScreen(JSONEncoder().encode(screen)),vector["name"] as! String) }
        }
    }
    func testSharedSerializedResultBoundaryVectors() throws {
        let f = try fixtures()
        let request = try AuthoringContract.validateRequest(data(f["request"]!))
        let base = try JSONDecoder().decode(AuthoringResultV1.self, from: data(f["result"]!))
        let preference = try JSONDecoder().decode(PreferenceRecordV1.self, from: data(f["preference"]!))
        let authorized = try JSONDecoder().decode(AuthoringResultV1.self, from: data(f["preferenceResult"]!))
        for vector in f["resultBoundaryVectors"] as! [[String: Any]] {
            var result = base; result.screen = nil; result.preferenceMutations = []; result.answer! += String(repeating:"a",count:vector["answerPadding"] as! Int)
            result.durablePreferenceAuthorization = authorized.durablePreferenceAuthorization
            var remaining = vector["metadataCharacterCount"] as! Int
            for i in 0..<16 {
                let count = min(4096,remaining); remaining -= count
                var record = preference; record.id = "boundary-pref-\(i)"; record.value = .string(String(repeating:vector["metadataCharacter"] as! String,count:count)); record.revision = 1; record.originRequestID = result.requestID
                result.preferenceMutations!.append(.init(kind:"upsert",id:record.id,expectedRevision:nil,record:record))
            }
            if vector["includeScreen"] as! Bool { result.screen = .init(title:"Boundary",files:[.init(path:"index.html",content:String(repeating:vector["screenCharacter"] as! String,count:vector["screenCharacterCount"] as! Int))]) }
            var metadata = result; metadata.screen = nil
            XCTAssertEqual(try AuthoringContract.encodedCanonical(metadata).count,vector["metadataBytes"] as! Int)
            XCTAssertEqual(try AuthoringContract.encodedCanonical(result).count,vector["fullBytes"] as! Int)
            if vector["accepted"] as! Bool { XCTAssertNoThrow(try AuthoringContract.validateResult(JSONEncoder().encode(result),request:request),vector["name"] as! String) }
            else { XCTAssertThrowsError(try AuthoringContract.validateResult(JSONEncoder().encode(result),request:request),vector["name"] as! String) }
        }
    }
    func testSharedLegacyUnicodeEnvelopeCompatibility() throws {
        let f = try fixtures()
        let request = try AuthoringContract.validateRequest(data(f["request"]!))
        let base = try JSONDecoder().decode(AuthoringResultV1.self, from: data(f["result"]!))
        for vector in f["unicodeCompatibilityVectors"] as! [[String: Any]] {
            var result = base
            let text = String(repeating:vector["character"] as! String,count:vector["count"] as! Int)
            if vector["kind"] as! String == "title" { result.screen!.title = text } else { result.answer = text }
            if vector["accepted"] as! Bool { XCTAssertNoThrow(try AuthoringContract.validateResult(JSONEncoder().encode(result),request:request),vector["name"] as! String) }
            else { XCTAssertThrowsError(try AuthoringContract.validateResult(JSONEncoder().encode(result),request:request),vector["name"] as! String) }
        }
    }
    func testCatalogDeclaresOnlyImplementedProvidersAndOperations() {
        XCTAssertEqual(AuthoringContract.serviceCatalog.map(\.provider),["home","googleTV","googleCalendar","appleMaps","publicHTTP"])
        XCTAssertEqual(AuthoringContract.serviceCatalog.first { $0.provider == "googleTV" }?.operations.map(\.name),["status","key","launchLink","voice","launchChannel","togglePower"])
        XCTAssertFalse(AuthoringContract.runtime.features.contains("fetch"))
    }
}
