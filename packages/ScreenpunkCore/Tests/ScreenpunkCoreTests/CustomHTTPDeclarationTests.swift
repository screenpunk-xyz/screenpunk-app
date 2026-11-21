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
}
