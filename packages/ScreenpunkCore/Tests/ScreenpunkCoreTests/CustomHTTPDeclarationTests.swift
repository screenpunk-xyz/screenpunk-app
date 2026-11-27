import Foundation
import XCTest
@testable import ScreenpunkCore

final class CustomHTTPDeclarationTests: XCTestCase {
    private static let manifest = #"""
    {"connections":[{"alias":"generator","required":true,"customHTTP":{
      "id":"generator-telemetry","version":1,"label":"Generator telemetry",
      "fields":[{"id":"server","label":"Address","type":"url"},{"id":"credential","label":"Token","type":"secret"}],
      "originField":"server","auth":{"mode":"bearer","field":"credential"},
      "operations":[{"name":"telemetry","method":"GET","path":"/telemetry","response":"json","parameters":{}}]}}]}
    """#

    func testDeclarationRequiresRuntimeOptInOnlyForNewAccess() throws {
        let oldRuntime = AuthoringContract.runtime(supportsScreenData: true)
        let newRuntime = AuthoringContract.runtime(supportsScreenData: true, supportsCustomHTTP: true)
        XCTAssertThrowsError(try AuthoringContract.validateManifest(Self.manifest, runtime: oldRuntime))
        XCTAssertNoThrow(try AuthoringContract.validateManifest(Self.manifest, previous: Self.manifest, runtime: oldRuntime))
        XCTAssertNoThrow(try AuthoringContract.validateManifest(Self.manifest, runtime: newRuntime))
    }

    func testRejectsDestinationOverridesCredentialValuesAndUndeclaredMethods() {
        let mutants = [
            Self.manifest.replacingOccurrences(of: "/telemetry", with: "/../telemetry"),
            Self.manifest.replacingOccurrences(of: "/telemetry", with: "//other.example/telemetry"),
            Self.manifest.replacingOccurrences(of: #""method":"GET""#, with: #""method":"POST""#),
            Self.manifest.replacingOccurrences(of: #""type":"secret""#, with: #""type":"secret","value":"embedded""#),
            Self.manifest.replacingOccurrences(of: #""parameters":{}"#, with: #""parameters":{"authorization":{"type":"text"}}"#)
        ]
        for mutant in mutants { XCTAssertThrowsError(try AuthoringContract.validateManifest(mutant), mutant) }
    }

    func testValidatesNativeSetupValues() throws {
        let origin = CustomHTTPField(id: "server", label: "Server", type: "url")
        XCTAssertNoThrow(try origin.validate("http://192.168.1.10:8080/"))
        XCTAssertThrowsError(try origin.validate("https://user:secret@example.com/data"))
        XCTAssertThrowsError(try origin.validate("https://example.com/?target=other"))
        let secret = CustomHTTPField(id: "credential", label: "Token", type: "secret")
        XCTAssertNoThrow(try secret.validate("test-token_0123"))
        XCTAssertThrowsError(try secret.validate("value\r\nInjected: header"))
    }
    func testJSONPostRequiresBearerAndRuntimeFeature() throws {
        let post = Self.manifest.replacingOccurrences(of: #""method":"GET""#, with: #""method":"POST","body":"json""#)
            .replacingOccurrences(of: "/telemetry", with: "/v1/chat/completions")
        let legacy = AuthoringContract.runtime(supportsScreenData: false, supportsCustomHTTP: true)
        let capable = AuthoringContract.runtime(supportsScreenData: false, supportsCustomHTTP: true, supportsCustomHTTPJSONPost: true)
        XCTAssertTrue(capable.features.contains(AuthoringContract.customHTTPJSONPostFeature))
        XCTAssertThrowsError(try AuthoringContract.validateManifest(post, runtime: legacy))
        XCTAssertNoThrow(try AuthoringContract.validateManifest(post, previous: post, runtime: legacy))
        XCTAssertNoThrow(try AuthoringContract.validateManifest(post, runtime: capable))
        for invalid in [
            post.replacingOccurrences(of: #""body":"json""#, with: #""body":null"#),
            post.replacingOccurrences(of: #""parameters":{}"#, with: #""parameters":{"model":{"type":"text"}}"#),
            post.replacingOccurrences(of: #","auth":{"mode":"bearer","field":"credential"}"#, with: "")
        ] { XCTAssertThrowsError(try AuthoringContract.validateManifest(invalid, runtime: capable)) }
    }

    func testJSONPostBodyBoundsAndNestedData() throws {
        let post = CustomHTTPOperation(name: "submit", method: "POST", path: "/v1/chat/completions", body: "json")
        let request = #"{"model":"synthetic","messages":[{"role":"user","content":"Hello"}],"metadata":{"optional":null,"enabled":true,"score":0.25}}"#
        let decoded = try JSONSerialization.jsonObject(with: Data(request.utf8))
        let encoded = try post.validatedJSONBody(decoded)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary, decoded as? NSDictionary)
        for invalid: Any in [[], ["messages":[["Authorization":"synthetic"]]], ["Headers":[:]], ["n":Double.infinity],
                             ["oversize":String(repeating:"x", count:48*1024)],
                             ["nested": (0..<13).reduce(0 as Any) { child, _ in [child] }]] {
            XCTAssertThrowsError(try post.validatedJSONBody(invalid))
        }
        let read = CustomHTTPOperation(name: "status", path: "/status")
        XCTAssertThrowsError(try read.validatedJSONBody(decoded))
    }
}
