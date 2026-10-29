import Foundation
import XCTest
@testable import DeviceAuthoring

final class LocalAgentMacSetupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var bin: URL { root.appendingPathComponent("bin") }
        var policy: URL { root.appendingPathComponent("policy.conf") }
        var keys: URL { home.appendingPathComponent(".ssh/authorized_keys") }
    }
    private func fixture() throws -> Fixture {
        let value = Fixture(root: FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-mac-setup-" + UUID().uuidString))
        for path in [value.home, value.bin, value.root.appendingPathComponent("tmp")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try executable("#!/bin/sh\nexec \"$@\"\n", at: value.bin.appendingPathComponent("sudo"))
        try executable("#!/bin/sh\nprintf '%s\\n' screenpunkfixture\n", at: value.bin.appendingPathComponent("id"))
        try executable("#!/bin/sh\nif test \"$1\" = -t; then exit \"${SCREENPUNK_TEST_SSHD_STATUS:-0}\"; fi\nprintf '%s\\n' \"$SCREENPUNK_TEST_EFFECTIVE\"\n", at: value.bin.appendingPathComponent("sshd"))
        return value
    }
    private func executable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    @discardableResult private func shell(_ command: String, fixture: Fixture, variables: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.currentDirectoryURL = fixture.root
        process.environment = ["HOME": fixture.home.path, "TMPDIR": fixture.root.appendingPathComponent("tmp").path, "PATH": fixture.bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "SCREENPUNK_TEST_EFFECTIVE": "allowtcpforwarding local\npermitlisten none\nallowstreamlocalforwarding no\ndisableforwarding no"].merging(variables) { _, value in value }
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private var publicKey: String {
        let bytes: [UInt8] = [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + Array(repeating: 7, count: 32)
        return "ssh-ed25519 " + Data(bytes).base64EncodedString()
    }
    private func authorize(_ fixture: Fixture, key: String? = nil) -> String {
        LocalAgentMacSetup.authorizeKeyCommand(publicKey: key ?? publicKey)
            .replacingOccurrences(of: "/etc/ssh/sshd_config.d/090-screenpunk-local.conf", with: fixture.policy.path)
            .replacingOccurrences(of: "/usr/sbin/sshd", with: fixture.bin.appendingPathComponent("sshd").path)
    }
    func testPublicSetupURLContainsOnlyOriginAndPublicPath() {
        let input = URL(string: "https://example.test/private/path?bearer=do-not-copy#private")!
        XCTAssertEqual(LocalAgentMacSetup.setupURL(baseURL: input).absoluteString, "https://example.test/local/setup")
        XCTAssertEqual(LocalAgentMacSetup.setupCommand(baseURL: input), "/usr/bin/open 'https://example.test/local/setup'")
        XCTAssertFalse(LocalAgentMacSetup.setupCommand(baseURL: input).contains("bearer"))
    }
    func testShellQuotingRoundTripsLiteralInputWithoutEvaluation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for value in ["", "normal", "apostrophe's", "$(touch injected)`touch injected`", "line\n'\" \\ $HOME; touch injected"] {
            let result = try shell("printf '%s' " + LocalAgentMacSetup.quote(value), fixture: f)
            XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, value)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("injected").path))
    }
    func testPublicKeyBoundsAndMalformedOrMultilineKeysFailClosed() {
        for key in ["", "ssh-rsa AAAA", publicKey + "\n" + publicKey, publicKey + "\0bad", publicKey + String(repeating: "x", count: 4096), "command=bad " + publicKey, "ssh-ed25519 " + Data(repeating: 0, count: 51).base64EncodedString()] {
            let command = LocalAgentMacSetup.authorizeKeyCommand(publicKey: key)
            XCTAssertTrue(command.hasPrefix("#")); XCTAssertFalse(command.contains("sudo"))
        }
        let command = LocalAgentMacSetup.authorizeKeyCommand(publicKey: publicKey + " '$(touch injected)' user-comment")
        XCTAssertTrue(command.contains("restrict,port-forwarding,permitopen=\"127.0.0.1:4500\",command=\"/usr/bin/false\""))
        XCTAssertFalse(command.contains("touch injected")); XCTAssertFalse(command.contains("user-comment"))
    }
    func testAuthorizationIsIdempotentAndRevocationOnlyRemovesExactRestrictedKey() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(try shell(authorize(f), fixture: f).0, 0)
        let first = try String(contentsOf: f.keys)
        XCTAssertEqual(try shell(authorize(f), fixture: f).0, 0)
        XCTAssertEqual(try String(contentsOf: f.keys), first)
        XCTAssertTrue(try String(contentsOf: f.policy).contains("Match User screenpunkfixture"))
        let other = "ssh-ed25519 AAAA Other-device\n"
        try Data((first + other).utf8).write(to: f.keys)
        XCTAssertEqual(try shell(LocalAgentMacSetup.revokeKeyCommand(publicKey: publicKey), fixture: f).0, 0)
        XCTAssertEqual(try String(contentsOf: f.keys).trimmingCharacters(in: .whitespacesAndNewlines), other.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func testPolicyCollisionFailsBeforeAddingKeyAndPreservesExistingConfig() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let otherPolicy = "Match User another\n    AllowTcpForwarding yes\n"
        try Data(otherPolicy.utf8).write(to: f.policy)
        let result = try shell(authorize(f), fixture: f)
        XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.1.contains("different settings"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.keys.path)); XCTAssertEqual(try String(contentsOf: f.policy), otherPolicy)
    }
    func testInvalidEffectiveSettingsOrSyntaxNeverGrantKeyAndRollbackOnlyNewPolicy() throws {
        for variables in [["SCREENPUNK_TEST_EFFECTIVE": "allowtcpforwarding yes\npermitlisten any\nallowstreamlocalforwarding yes"], ["SCREENPUNK_TEST_SSHD_STATUS": "1"], ["SCREENPUNK_TEST_EFFECTIVE": "allowtcpforwarding local\npermitlisten none\nallowstreamlocalforwarding no\ndisableforwarding yes"]] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertNotEqual(try shell(authorize(f), fixture: f, variables: variables).0, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.keys.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: f.policy.path))
        }
        let existing = try fixture(); defer { try? FileManager.default.removeItem(at: existing.root) }
        XCTAssertEqual(try shell(authorize(existing), fixture: existing).0, 0)
        let saved = try Data(contentsOf: existing.policy); try FileManager.default.removeItem(at: existing.keys)
        XCTAssertNotEqual(try shell(authorize(existing), fixture: existing, variables: ["SCREENPUNK_TEST_SSHD_STATUS": "1"]).0, 0)
        XCTAssertEqual(try Data(contentsOf: existing.policy), saved); XCTAssertFalse(FileManager.default.fileExists(atPath: existing.keys.path))
    }
    func testStartRejectsMalformedOrSymlinkTokenBeforeClipboardOrAppServer() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let codex = f.bin.appendingPathComponent("codex")
        try executable("#!/bin/sh\nif test \"$1\" = --version; then printf 'codex %s\\n' \"$SCREENPUNK_TEST_VERSION\"; else touch \"$HOME/server-executed\"; fi\n", at: codex)
        try executable("#!/bin/sh\nprintf '%s  codex\\n' \"$SCREENPUNK_TEST_DIGEST\"\n", at: f.bin.appendingPathComponent("shasum"))
        try executable("#!/bin/sh\ncat > \"$HOME/clipboard\"\n", at: f.bin.appendingPathComponent("pbcopy"))
        let localRoot = f.home.appendingPathComponent(".codex/screenpunk-local")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let token = localRoot.appendingPathComponent("transport-token")
        let command = LocalAgentMacSetup.startCommands().replacingOccurrences(of: LocalAgentMacSetup.binary, with: codex.path)
        let variables = ["SCREENPUNK_TEST_VERSION": LocalAgentMacSetup.pinnedVersion, "SCREENPUNK_TEST_DIGEST": LocalAgentMacSetup.pinnedSHA256]
        try Data("invalid-token\n".utf8).write(to: token)
        XCTAssertNotEqual(try shell(command, fixture: f, variables: variables).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("clipboard").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("server-executed").path))
        try FileManager.default.removeItem(at: token)
        let target = f.root.appendingPathComponent("unrelated-file"); try Data("leave this intact".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: token, withDestinationURL: target)
        XCTAssertNotEqual(try shell(command, fixture: f, variables: variables).0, 0)
        XCTAssertEqual(try String(contentsOf: target), "leave this intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("clipboard").path))
        try FileManager.default.removeItem(at: token)
        XCTAssertEqual(try shell(command, fixture: f, variables: variables).0, 0)
        XCTAssertEqual(try Data(contentsOf: token).count, 65)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("clipboard").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: token.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("server-executed").path))
    }
    func testVersionAndDigestMismatchStopBeforeLoginAndCommandsContainNoBearerOrPrivateKey() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let codex = f.bin.appendingPathComponent("codex")
        try executable("#!/bin/sh\nif test \"$1\" = --version; then printf 'codex %s\\n' \"$SCREENPUNK_TEST_VERSION\"; else touch \"$HOME/login-executed\"; fi\n", at: codex)
        try executable("#!/bin/sh\nprintf '%s  codex\\n' \"$SCREENPUNK_TEST_DIGEST\"\n", at: f.bin.appendingPathComponent("shasum"))
        let command = LocalAgentMacSetup.prepareCommands().replacingOccurrences(of: LocalAgentMacSetup.binary, with: codex.path)
        XCTAssertNotEqual(try shell(command, fixture: f, variables: ["SCREENPUNK_TEST_VERSION": "wrong", "SCREENPUNK_TEST_DIGEST": LocalAgentMacSetup.pinnedSHA256]).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("login-executed").path))
        XCTAssertNotEqual(try shell(command, fixture: f, variables: ["SCREENPUNK_TEST_VERSION": LocalAgentMacSetup.pinnedVersion, "SCREENPUNK_TEST_DIGEST": "wrong"]).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("login-executed").path))
        XCTAssertEqual(try shell(command, fixture: f, variables: ["SCREENPUNK_TEST_VERSION": LocalAgentMacSetup.pinnedVersion, "SCREENPUNK_TEST_DIGEST": LocalAgentMacSetup.pinnedSHA256]).0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("login-executed").path))
        let start = LocalAgentMacSetup.startCommands()
        XCTAssertTrue(start.contains("ws://127.0.0.1:4500")); XCTAssertTrue(start.contains("--ws-token-file")); XCTAssertFalse(start.contains("PRIVATE KEY"))
        XCTAssertFalse(start.contains("cat \"$CODEX_HOME/transport-token\"")); XCTAssertFalse(start.contains("pbcopy"))
    }
}
