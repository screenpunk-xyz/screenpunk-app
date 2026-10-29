import XCTest
import CryptoKit
@testable import ScreenpunkCore

final class LocalPairingTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000
    enum Cut: Error { case crash }
    final class Vault: LocalPairingCredentialStore {
        var values: [String: String] = ["identity": "old-working-bearer"]
        var forgotten: [String] = []
        func stagePairingCredential(appServerToken: String, identityReference: String, stagedReference: String) throws {
            guard values[identityReference] != nil else { throw Cut.crash }
            if let existing = values[stagedReference], existing != appServerToken { throw Cut.crash }
            values[stagedReference] = appServerToken
        }
        func hasPairingCredential(reference: String) throws -> Bool { values[reference] != nil }
        func forgetPairingCredential(reference: String) throws { forgotten.append(reference); values.removeValue(forKey: reference) }
    }
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Screenpunk-LocalPairingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func key() -> String {
        let blob = Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + Data(repeating: 7, count: 32)
        return "ssh-ed25519 " + blob.base64EncodedString() + " Screenpunk-iPad"
    }
    func reply(_ request: LocalPairingRequest, _ edits: [String: Any] = [:]) throws -> Data {
        var json: [String: Any] = ["type": "screenpunk.pairing-reply.v1", "schemaVersion": 1, "pairingID": request.pairingID, "nonce": request.nonce, "publicKeySHA256": request.publicKeySHA256, "issuedAt": now, "expiresAt": now + 300_000, "computerName": "Fixture Mac", "host": "fixture.local", "sshPort": 22, "username": "fixture", "hostKeySHA256": request.publicKeySHA256, "appServerPort": 4500, "macWorkspace": "/Users/fixture/Screenpunk", "codexVersion": LocalPairingLimits.codexVersion, "protocolProfile": LocalPairingLimits.protocolProfile, "appServerToken": "synthetic-pairing-bearer"]
        json.merge(edits) { _, new in new }; return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }
    func oldConfiguration() -> LocalAgentConfiguration { .init(id: "working", host: "old.local", username: "old", hostKeySHA256: "old-pin", macWorkspace: "/old", credentialReference: "identity") }
    func setup(checkpoint: ((LocalPairingCheckpoint) throws -> Void)? = nil) throws -> (URL, LocalAgentConfigurationRepository, LocalPairingRepository, LocalPairingRequest, Vault) {
        let root = try directory(), configs = try LocalAgentConfigurationRepository(rootDirectory: root.appendingPathComponent("config"))
        try configs.save(oldConfiguration())
        let repo = try LocalPairingRepository(rootDirectory: root, configurationRepository: configs, checkpoint: checkpoint)
        return (root, configs, repo, try repo.begin(publicKeyOpenSSH: key(), identityReference: "identity", deviceName: "Fixture iPad", now: now), Vault())
    }
    func testPublicRequestPersistedBoundedAndNoSecret() throws {
        let (root, configs, _, request, _) = try setup()
        XCTAssertEqual(request.publicKeySHA256, "SHA256:gNSIRW+2Iyiuvsdp/bgjy38bvWHw6wQm3tuoXrl3WjQ")
        XCTAssertEqual(request.nonce.count, 43)
        XCTAssertEqual(request.expiresAt - request.issuedAt, 1_800_000)
        XCTAssertEqual(try LocalPairingParser.decodeRequest(request.encoded(), now: now), request)
        let reopened = try LocalPairingRepository(rootDirectory: root, configurationRepository: configs)
        XCTAssertEqual(try reopened.pendingRequest(now: now), request)
        XCTAssertFalse(String(data: try request.encoded(), encoding: .utf8)!.contains("bearer"))
    }
    func testCancelAndFailedTestPreserveWorkingEndpoint() throws {
        let (_, configs, repo, request, vault) = try setup()
        let candidate = try repo.stageReply(reply(request), source: .qr, now: now, credentials: vault)
        XCTAssertEqual(try configs.load(), oldConfiguration())
        XCTAssertNotEqual(candidate.configuration.credentialReference, "identity")
        XCTAssertEqual(vault.values["identity"], "old-working-bearer")
        try repo.cancel(credentials: vault)
        XCTAssertEqual(vault.forgotten, [candidate.configuration.credentialReference])
        XCTAssertEqual(try configs.load(), oldConfiguration())
        XCTAssertEqual(vault.values["identity"], "old-working-bearer")
    }
    func testEveryCrashCutRecoversWithoutConsumingBeforeCommit() throws {
        for cut in [LocalPairingCheckpoint.intentSaved, .credentialStaged, .candidateSaved, .endpointCommitted, .pendingCleared] {
            let (root, configs, repo, request, vault) = try setup { point in if point == cut { throw Cut.crash } }
            let data = try reply(request)
            var candidate: LocalPairingImport?
            do { candidate = try repo.stageReply(data, source: .qr, now: now, credentials: vault) } catch {}
            if let candidate { XCTAssertThrowsError(try repo.commit(importID: candidate.id, replyDigest: candidate.replyDigest, now: now, credentials: vault)) }
            let reopened = try LocalPairingRepository(rootDirectory: root, configurationRepository: configs)
            if try configs.pairingCommit(pairingID: request.pairingID) != nil {
                XCTAssertNotNil(try configs.pairingCommit(pairingID: request.pairingID)?.nonceDigest)
                XCTAssertNil(try reopened.recover(now: now, credentials: vault))
                XCTAssertNotEqual(try configs.load()?.id, "working")
                XCTAssertThrowsError(try reopened.stageReply(data, source: .qr, now: now, credentials: vault))
            } else {
                XCTAssertEqual(try configs.load(), oldConfiguration())
                _ = try reopened.recover(now: now, credentials: vault)
                let resumed = try reopened.stageReply(data, source: .qr, now: now, credentials: vault)
                _ = try reopened.commit(importID: resumed.id, replyDigest: resumed.replyDigest, now: now, credentials: vault)
                XCTAssertEqual(try configs.load()?.id, resumed.id)
            }
            XCTAssertEqual(vault.values["identity"], "old-working-bearer")
        }
    }
    func testConflictingReplayAndNewerEndpointFence() throws {
        let (_, configs, repo, request, vault) = try setup()
        let candidate = try repo.stageReply(reply(request), source: .qr, now: now, credentials: vault)
        XCTAssertThrowsError(try repo.stageReply(reply(request, ["computerName": "Different"]), source: .qr, now: now, credentials: vault)) { XCTAssertEqual($0 as? LocalPairingError, .conflictingReply) }
        var newer = oldConfiguration(); newer.id = "newer"; try configs.save(newer)
        XCTAssertThrowsError(try repo.commit(importID: candidate.id, replyDigest: candidate.replyDigest, now: now, credentials: vault))
        XCTAssertEqual(try configs.load()?.id, "newer")
        XCTAssertThrowsError(try repo.recover(now: now, credentials: vault))
        XCTAssertNil(vault.values[candidate.configuration.credentialReference])
        XCTAssertNotNil(vault.values["identity"])
    }
    func testExpiryAndClockAndUnknownBinding() throws {
        let (_, _, repo, request, vault) = try setup()
        for edits in [["nonce": String(repeating: "A", count: 43)], ["publicKeySHA256": "SHA256:" + String(repeating: "A", count: 43)], ["expiresAt": now + 300_001], ["issuedAt": now + 120_001, "expiresAt": now + 300_000]] as [[String: Any]] {
            XCTAssertThrowsError(try repo.stageReply(reply(request, edits), source: .qr, now: now, credentials: vault))
        }
        XCTAssertNotNil(try repo.pendingRequest(now: now))
        let candidate = try repo.stageReply(reply(request), source: .qr, now: now, credentials: vault)
        try repo.expire(now: now + 420_001, credentials: vault)
        XCTAssertNil(vault.values[candidate.configuration.credentialReference])
        XCTAssertNotNil(vault.values["identity"])
    }
    func testStrictParserBoundsAndRedaction() throws {
        let (_, _, _, request, _) = try setup()
        for edits in [["extra": "value"], ["schemaVersion": 2], ["macWorkspace": "/Users/../secret"], ["host": "host\ncommand"], ["username": "-option"], ["computerName": "Mac\u{202e}"], ["sshPort": 0], ["appServerToken": "has spaces"], ["codexVersion": "unknown"]] as [[String: Any]] {
            XCTAssertThrowsError(try LocalPairingParser.decodeReply(reply(request, edits), source: .privateFile))
        }
        let valid = try reply(request)
        XCTAssertLessThan(valid.count, 1024)
        let parsed = try LocalPairingParser.decodeReply(valid, source: .qr)
        XCTAssertFalse(String(describing: parsed).contains("synthetic")); XCTAssertFalse(String(reflecting: parsed).contains("synthetic"))
        var text = String(data: valid, encoding: .utf8)!; text.removeFirst(); text = "{\"host\":\"evil\"," + text
        XCTAssertThrowsError(try LocalPairingParser.decodeReply(Data(text.utf8), source: .qr))
        XCTAssertThrowsError(try LocalPairingParser.decodeReply(Data(repeating: 32, count: 1537), source: .qr))
        XCTAssertThrowsError(try LocalPairingParser.decodeReply(Data(repeating: 32, count: 8193), source: .privateFile))
    }
    func testNonsecretPersistenceAndMissingCredentialReject() throws {
        let (root, _, repo, request, vault) = try setup()
        let candidate = try repo.stageReply(reply(request), source: .qr, now: now, credentials: vault)
        for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            let url = file as! URL
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                XCTAssertFalse((try? String(contentsOf: url))?.contains("synthetic-pairing-bearer") ?? false)
            }
        }
        vault.values.removeValue(forKey: candidate.configuration.credentialReference)
        XCTAssertThrowsError(try repo.commit(importID: candidate.id, replyDigest: candidate.replyDigest, now: now, credentials: vault))
    }
    func testLegacyConfigurationAndReplyDefaultToForeground() throws {
        let (_, _, _, request, _) = try setup()
        XCTAssertEqual(try LocalPairingParser.decodeReply(reply(request), source: .qr).serverLifecycle, .foreground)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldConfiguration())) as! [String: Any]
        legacy.removeValue(forKey: "serverLifecycle")
        let decoded = try JSONDecoder().decode(LocalAgentConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.serverLifecycle, .foreground)
        XCTAssertEqual(decoded.host, "old.local")
        XCTAssertEqual(decoded.credentialReference, "identity")
        var background = decoded; background.serverLifecycle = .background
        XCTAssertEqual(try JSONDecoder().decode(LocalAgentConfiguration.self, from: JSONEncoder().encode(background)), background)
    }
    func testOptionalLifecycleReplyIsStrictAndPublicRequestUnchanged() throws {
        let (_, _, _, request, _) = try setup()
        for source in [LocalPairingSource.qr, .privateFile] {
            for lifecycle in [LocalAgentServerLifecycle.foreground, .background] {
                let data = try reply(request, ["serverLifecycle": lifecycle.rawValue])
                XCTAssertLessThan(data.count, 1024)
                let decoded = try LocalPairingParser.decodeReply(data, source: source)
                XCTAssertEqual(decoded.serverLifecycle, lifecycle)
                XCTAssertFalse(String(reflecting: decoded).contains("synthetic-pairing-bearer"))
            }
            for invalid in ["", "Background", "launchAgent", 1, false, NSNull(), ["background"], ["mode": "background"]] as [Any] {
                XCTAssertThrowsError(try LocalPairingParser.decodeReply(reply(request, ["serverLifecycle": invalid]), source: source)) { XCTAssertEqual($0 as? LocalPairingError, .malformed) }
            }
        }
        var duplicate = String(data: try reply(request, ["serverLifecycle": "background"]), encoding: .utf8)!
        duplicate.removeFirst(); duplicate = "{\"serverLifecycle\":\"foreground\"," + duplicate
        XCTAssertThrowsError(try LocalPairingParser.decodeReply(Data(duplicate.utf8), source: .qr))
        var publicJSON = try JSONSerialization.jsonObject(with: request.encoded()) as! [String: Any]
        XCTAssertNil(publicJSON["serverLifecycle"])
        publicJSON["serverLifecycle"] = "background"
        XCTAssertThrowsError(try LocalPairingParser.decodeRequest(JSONSerialization.data(withJSONObject: publicJSON), now: now))
    }
    func testConfigurationRejectsPresentInvalidLifecycle() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldConfiguration())) as! [String: Any]
        for invalid in ["", "unknown", 1, false, NSNull()] as [Any] {
            json["serverLifecycle"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(LocalAgentConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }
    func testBackgroundLifecycleSurvivesStagedRecoveryAndAtomicCommit() throws {
        let (root, configs, repo, request, vault) = try setup()
        let candidate = try repo.stageReply(reply(request, ["serverLifecycle": "background"]), source: .qr, now: now, credentials: vault)
        XCTAssertEqual(candidate.configuration.serverLifecycle, .background)
        XCTAssertEqual(try configs.load()?.serverLifecycle, .foreground)
        XCTAssertEqual(vault.values["identity"], "old-working-bearer")
        XCTAssertThrowsError(try repo.stageReply(reply(request, ["serverLifecycle": "foreground"]), source: .qr, now: now, credentials: vault)) { XCTAssertEqual($0 as? LocalPairingError, .conflictingReply) }
        let reopened = try LocalPairingRepository(rootDirectory: root, configurationRepository: configs)
        XCTAssertEqual(try reopened.recover(now: now, credentials: vault)?.configuration.serverLifecycle, .background)
        let committed = try reopened.commit(importID: candidate.id, replyDigest: candidate.replyDigest, now: now, credentials: vault)
        XCTAssertEqual(committed.serverLifecycle, .background)
        let restored = try LocalAgentConfigurationRepository(rootDirectory: root.appendingPathComponent("config")).load()
        XCTAssertEqual(restored, committed)
        XCTAssertEqual(try configs.pairingCommit(pairingID: request.pairingID)?.replyDigest, candidate.replyDigest)
        XCTAssertNotEqual(committed.credentialReference, "identity")
        XCTAssertEqual(vault.values["identity"], "old-working-bearer")
    }

}
