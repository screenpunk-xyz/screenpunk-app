import Foundation
import XCTest
import ScreenpunkApple
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryAuthoringTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-authoring-\(UUID().uuidString)") }
    private func artifact(_ title: String) -> AuthoringScreen {
        .init(title: title, files: [.init(path: "index.html", content: "<!doctype html><html><body><h1>\(title)</h1></body></html>")])
    }
    @MainActor private func request(_ library: ScreenLibrary, id: String = "fixture-request") throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: id, createdAt: 1_000, deadlineAt: 601_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            preferences: library.preferences(profileID: "fixture-profile", deviceID: "fixture-device", screenID: "fixture-screen"),
            context: .init(profileID: "fixture-profile", deviceID: "fixture-device", screenID: "fixture-screen", baseRevision: library.selected?.revision,
                           userRequest: "Remember to always use large text on this device, and update the screen.", currentScreen: library.selected?.artifact,
                           viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "fixture")))
    }
    private func result(_ request: AuthoringRequestV1) -> AuthoringResultV1 {
        .init(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
              preferenceRevisions: Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id, $0.revision) }), operationID: "operation-" + request.requestID,
              screen: artifact("Updated fixture"), preferenceMutations: [.init(kind: "upsert", id: "large-text", expectedRevision: nil,
                record: .init(id: "large-text", scope: "device", targetID: "fixture-device", category: "typography", value: .string("large"), revision: 1, originRequestID: request.requestID))],
              durablePreferenceAuthorization: .init(requestID: request.requestID, quote: request.context.userRequest))
    }

    @MainActor func testRemoteCreateKeepsTheCurrentScreenAndNormalPendingWork() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.install(artifact("Current"), requestID: "current", replacing: "current")
        try library.selectVisible("current")
        var input = try request(library, id: UUID().uuidString.lowercased())
        input.delivery.route = "cloud"
        input.context.baseRevision = nil
        input.context.currentScreen = nil
        let snapshot = try library.makeAuthoringRequestV2(from: input)
        try library.saveRemoteAuthoringRequest(snapshot)
        try library.savePending(id: "normal-pending", screenID: "current", consumedID: nil)
        let result = AuthoringResultV2(requestID: snapshot.requestID, inputDigest: snapshot.delivery.snapshotDigest,
            preferenceRevisions: [:], operationID: UUID().uuidString,
            screen: .init(title: "Remote", files: [.write(path: "index.html", content: "<html><body>Remote</body></html>")]))
        let receipt = try library.applyAuthoringResult(result, remoteApprovalRotation: { _, _ in }, now: 2_000)
        XCTAssertEqual(receipt.status, "applied", String(describing: receipt))
        XCTAssertEqual(library.selected?.id, "current")
        XCTAssertEqual(library.state.pendingID, "normal-pending")
        XCTAssertEqual(library.state.screens.first { $0.id == snapshot.context.screenID }?.artifact.title, "Remote")
    }

    @MainActor func testRemoteEditWithUnchangedConnectionRequiresFreshApproval() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let owner = "fixture-owner"
        let screenID = "fixture-screen"
        let alias = "synthetic"
        let declaration = CustomHTTPDeclaration(id: "synthetic", version: 1, label: "Synthetic service",
            fields: [.init(id: "origin", label: "Server", type: "url"), .init(id: "credential", label: "Token", type: "secret")],
            originField: "origin", auth: .init(field: "credential"), operations: [.init(name: "status", path: "/status")])
        let html = "<!doctype html><html><body>Original</body></html>"
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: screenID, name: "Synthetic", revision: "1", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "fixture-profile", width: 1024, height: 768, scale: 1, orientation: "landscape"),
            connections: [.init(alias: alias, required: true, customHTTP: declaration)],
            files: [.init(path: "index.html", bytes: html.utf8.count, sha256: AuthoringContract.contentDigest(Data(html.utf8)))])
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        try library.install(.init(title: "Synthetic", files: [.init(path: "index.html", content: html), .init(path: "manifest.json", content: manifestJSON)]),
                            requestID: "install-synthetic", replacing: screenID)
        let original = try XCTUnwrap(library.state.screens.first { $0.id == screenID })
        XCTAssertTrue(library.supportsRemoteAuthoringEdit(original))
        let vault = CustomHTTPDeviceVault(store: MemoryCredentialStore())
        try vault.save(owner: owner, declaration: declaration, fields: ["origin": "https://10.0.0.40"],
                       secret: "synthetic-bearer", allowInsecureHTTP: false)
        let generation = try XCTUnwrap(vault.status(owner: owner, declaration: declaration)?.generation)
        try vault.approve(owner: owner, screenID: screenID, manifest: manifest, alias: alias, expectedGeneration: generation)
        var input = try request(library, id: UUID().uuidString.lowercased())
        input.delivery.route = "cloud"
        input.context.baseRevision = original.revision
        input.context.currentScreen = original.artifact
        let snapshot = try library.makeAuthoringRequestV2(from: input)
        try library.saveRemoteAuthoringRequest(snapshot)
        XCTAssertNil(library.recoverableCloudCompletion([snapshot.requestID], profileID: snapshot.context.profileID, deviceID: snapshot.context.deviceID))
        let revisedHTML = "<!doctype html><html><body><script>void 0;</script>Updated</body></html>"
        var revisedManifest = manifest
        revisedManifest.files = [.init(path: "index.html", bytes: revisedHTML.utf8.count,
            sha256: AuthoringContract.contentDigest(Data(revisedHTML.utf8)))]
        let revisedJSON = String(decoding: try JSONEncoder().encode(revisedManifest), as: UTF8.self)
        let result = AuthoringResultV2(requestID: snapshot.requestID, inputDigest: snapshot.delivery.snapshotDigest,
            baseRevision: original.revision, preferenceRevisions: [:], operationID: UUID().uuidString,
            screen: .init(title: "Updated", files: [
                .write(path: "index.html", content: revisedHTML), .write(path: "manifest.json", content: revisedJSON)]))
        XCTAssertThrowsError(try library.applyAuthoringResult(result, now: 2_000))
        try library.install(artifact("Unrelated"), requestID: "unrelated", replacing: "other-screen")
        try library.selectVisible("other-screen")
        let rotateApproval = { (prior: String, next: String) in
            try vault.rotateScreenApprovalScope(owner: owner, priorScope: prior, nextScope: next)
        }
        let receipt = try library.applyAuthoringResult(result, remoteApprovalRotation: rotateApproval, now: 2_000)
        XCTAssertEqual(receipt.status, "applied", String(describing: receipt))
        guard receipt.status == "applied" else { return }
        XCTAssertEqual(library.selected?.id, "other-screen")
        let reopened = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let installed = try XCTUnwrap(reopened.state.screens.first { $0.id == screenID })
        XCTAssertNotEqual(installed.revision, original.revision)
        let scope = reopened.customHTTPApprovalScope(screenID: screenID)
        XCTAssertNotEqual(scope, screenID)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration)?.generation, generation)
        let transport = RemoteApprovalTransport()
        let runtime = CustomHTTPDeviceRuntime(owner: owner, screenID: scope, manifest: manifest, vault: vault, transport: transport)
        do {
            _ = try await runtime.request(alias: alias, operation: "status", parameters: [:])
            XCTFail("The revised script inherited connection access")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        let before = await transport.sends
        XCTAssertEqual(before, 0)
        try vault.approve(owner: owner, screenID: scope, manifest: manifest, alias: alias, expectedGeneration: generation)
        _ = try await runtime.request(alias: alias, operation: "status", parameters: [:])
        let after = await transport.sends
        XCTAssertEqual(after, 1)
        XCTAssertEqual(try reopened.applyAuthoringResult(result, remoteApprovalRotation: rotateApproval, now: 2_000), receipt)
        XCTAssertEqual(reopened.customHTTPApprovalScope(screenID: screenID), scope)
    }

    @MainActor func testRemoteEditsRejectExistingWriteManifest() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let html = "<html><body>Home</body></html>"
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "fixture-screen", name: "Home", revision: "1", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "fixture-profile", width: 1024, height: 768, scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.utf8.count, sha256: AuthoringContract.contentDigest(Data(html.utf8)))])
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        try library.install(.init(title: "Home", files: [.init(path: "index.html", content: html), .init(path: "manifest.json", content: manifestJSON)]),
                            requestID: "install-home", replacing: "fixture-screen")
        let installed = try XCTUnwrap(library.state.screens.first { $0.id == "fixture-screen" })
        XCTAssertFalse(library.supportsRemoteAuthoringEdit(installed))
    }

    @MainActor func testAppliedConnectionProposalRetainsExactSetupAcrossReopenWithoutAgentAnnouncement() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        var input = try request(library)
        input.delivery.route = "cloud"
        input.runtime = AuthoringContract.runtime(supportsScreenData: false, supportsCustomHTTP: true, supportsConnectionPrefill: true,
            supportsCredentialRegistration: true)
        input.designGuidance = AuthoringContract.designGuidance(supportsScreenData: false, supportsCustomHTTP: true, supportsConnectionPrefill: true,
            supportsCredentialRegistration: true)
        // The upgrade must accept the sealed guidance previously used by installed screens.
        input.designGuidance.rules[input.designGuidance.rules.count - 1] =
            "For a Cloud V2 request advertising credential-registration-v1, first complete the request with the matching HTTPS bearer connectionSetupProposals entry. If this is a source you are independently authorized and able to configure to accept a device-generated SHA-256 verifier, call announce_credential_registration with the request ID and alias. Do not announce provider-issued credentials as configurable. The device must separately initiate registration. Do not request or handle the bearer. The agent must independently confirm source configuration and the exact endpoint certificate before reporting success. Manual entry remains available."
        input = try AuthoringContract.seal(input)
        let snapshot = try library.makeAuthoringRequestV2(from: input)
        try library.saveAuthoringRequest(snapshot)
        let declaration = CustomHTTPDeclaration(id: "synthetic", version: 1, label: "Synthetic service",
            fields: [.init(id: "origin", label: "Server", type: "url"), .init(id: "credential", label: "Token", type: "secret")],
            originField: "origin", auth: .init(field: "credential"), operations: [.init(name: "status", path: "/status")])
        let proposal = CustomHTTPSetupProposal(alias: "synthetic", declaration: declaration, fields: ["origin":"https://synthetic.example"])
        let html = "<html><body>Synthetic</body></html>"
        let metadata = DashboardManifest(schemaVersion: 1, dashboardId: "fixture-screen", name: "Synthetic", revision: "1", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "fixture-profile", width: 1024, height: 768, scale: 1, orientation: "landscape"),
            connections: [.init(alias: "synthetic", required: true, customHTTP: declaration)],
            files: [.init(path: "index.html", bytes: html.utf8.count, sha256: AuthoringContract.contentDigest(Data(html.utf8)))])
        let manifest = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        let result = AuthoringResultV2(requestID: snapshot.requestID, inputDigest: snapshot.delivery.snapshotDigest,
            preferenceRevisions: [:], operationID: "proposal-operation", screen: .init(title: "Synthetic", files: [
                .write(path: "index.html", content: "<html><body>Synthetic</body></html>"), .write(path: "manifest.json", content: manifest)]),
            connectionSetupProposals: [proposal])
        for mutation in ["credential", "unknown", "origin"] {
            var invalid = result
            invalid.connectionSetupProposals?[0].fields[mutation] = "invalid-value"
            XCTAssertThrowsError(try library.applyAuthoringResult(invalid, now: 2000))
        }
        let expired = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root.appendingPathComponent("expired"))
        try expired.saveAuthoringRequest(snapshot)
        XCTAssertEqual(try expired.applyAuthoringResult(result, now: snapshot.deadlineAt).status, "rejected")
        XCTAssertNil(expired.state.connectionSetupDrafts?["fixture-screen"])
        let receipt = try library.applyAuthoringResult(result, now: 2000)
        XCTAssertEqual(receipt.status, "applied", String(describing: receipt))
        let saved = try XCTUnwrap(library.state.screens.first { $0.id == "fixture-screen" })
        let reopened = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertEqual(reopened.connectionSetupProposal(screenID: saved.id, revision: saved.revision, alias: "synthetic", declaration: declaration), proposal)
        let binding = try XCTUnwrap(reopened.connectionCredentialRegistrationSource(screenID: saved.id, revision: saved.revision))
        XCTAssertEqual(binding.requestID, snapshot.requestID)
        XCTAssertEqual(binding.inputDigest, snapshot.delivery.snapshotDigest)
        XCTAssertEqual(binding.operationID, result.operationID)
        XCTAssertEqual(binding.deviceID, snapshot.context.deviceID)
        XCTAssertEqual(reopened.credentialRegistrationRevision(for: receipt), saved.revision)
        XCTAssertFalse(saved.artifact.files.contains { $0.content.contains("announce_credential_registration") })
        try reopened.acknowledgeReceipt(receipt)
        let afterAck = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertEqual(afterAck.connectionCredentialRegistrationSource(screenID: saved.id, revision: saved.revision), binding)
        XCTAssertFalse(saved.artifact.files.contains { $0.content.contains("https://synthetic.example") })
        XCTAssertNil(reopened.connectionSetupProposal(screenID: "other", revision: saved.revision, alias: "synthetic", declaration: declaration))
        XCTAssertNil(reopened.connectionSetupProposal(screenID: saved.id, revision: "stale", alias: "synthetic", declaration: declaration))
        var changed = declaration; changed.operations[0].path = "/other"
        XCTAssertNil(reopened.connectionSetupProposal(screenID: saved.id, revision: saved.revision, alias: "synthetic", declaration: changed))
        XCTAssertEqual(try reopened.applyAuthoringResult(result, now: 2000).status, "applied")
        try reopened.install(artifact("Replacement"), requestID: "replacement", replacing: saved.id)
        XCTAssertNil(reopened.connectionSetupProposal(screenID: saved.id, revision: saved.revision, alias: "synthetic", declaration: declaration))
        XCTAssertNil(reopened.connectionCredentialRegistrationSource(screenID: saved.id, revision: saved.revision))
    }

    @MainActor func testKeyboardDraftSurvivesReopenAndNewScreenPreservesExistingPackages() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        for id in ["weather", "nasa"] {
            try library.install(artifact(id), requestID: "install-" + id, replacing: id)
        }
        let ids = library.state.screens.map(\.id)
        let revisions = library.state.screens.map(\.revision)
        let contents = library.state.screens.map { $0.artifact.files.map(\.content) }
        var backupCommits = 0
        library.onCatalogRevisionCommitted = { backupCommits += 1 }
        try library.saveKeyboardDraft("Make a separate counter.", screenID: nil)
        try library.saveKeyboardDraft("Keep this weather draft.", screenID: "weather")
        XCTAssertEqual(backupCommits, 0, "Private drafts are not screen revisions or backup packages")
        try library.newScreen()
        let reopened = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertNil(reopened.selected)
        XCTAssertEqual(reopened.keyboardDraft(screenID: nil), "Make a separate counter.")
        XCTAssertEqual(reopened.keyboardDraft(screenID: "weather"), "Keep this weather draft.")
        XCTAssertEqual(reopened.state.screens.map(\.id), ids)
        XCTAssertEqual(reopened.state.screens.map(\.revision), revisions)
        XCTAssertEqual(reopened.state.screens.map { $0.artifact.files.map(\.content) }, contents)
        let other = try ScreenLibrary(accountID: "other-account", rootDirectory: root.appendingPathComponent("other-account"))
        XCTAssertNil(other.keyboardDraft(screenID: nil))
    }

    @MainActor func testOversizedKeyboardDraftCannotReplaceSavedDraft() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.saveKeyboardDraft("Saved instructions", screenID: nil)
        XCTAssertThrowsError(try library.saveKeyboardDraft(String(repeating: "x", count: 65_537), screenID: nil))
        XCTAssertEqual(library.keyboardDraft(screenID: nil), "Saved instructions")
    }

    @MainActor func testCompletionRecoveryRequiresLocallyOwnedUnsettledSnapshot() throws {
        for version in [1, 2] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            var input = try request(library)
            input.delivery.route = "cloud"
            input = try AuthoringContract.seal(input)
            if version == 2 {
                try library.saveAuthoringRequest(AuthoringV2Contract.makeRequest(from: input, libraryID: "fixture-account"))
            } else { try library.saveAuthoringRequest(input) }
            let ids = ["unrelated-history", input.requestID]
            XCTAssertNil(library.recoverableCloudCompletion(ids, profileID: "other-profile", deviceID: "fixture-device"))
            XCTAssertNil(library.recoverableCloudCompletion(ids, profileID: "fixture-profile", deviceID: "other-device"))
            XCTAssertEqual(library.recoverableCloudCompletion(ids, profileID: "fixture-profile", deviceID: "fixture-device"), input.requestID)
            try library.savePending(id: "another-request", screenID: nil, consumedID: nil)
            XCTAssertNil(library.recoverableCloudCompletion(ids, profileID: "fixture-profile", deviceID: "fixture-device"))
            try library.savePending(id: nil, screenID: nil, consumedID: nil)
            try library.cancelRequest(input.requestID)
            XCTAssertNil(library.recoverableCloudCompletion(ids, profileID: "fixture-profile", deviceID: "fixture-device"))
        }
    }

    @MainActor func testLocalRestartRecoversUnsentSubmissionAndReceiptWithoutDeadline() throws {
        for version in [1, 2] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            var input = try request(library)
            input.delivery.route = "local"; input = try AuthoringContract.seal(input)
            let v2 = try AuthoringV2Contract.makeRequest(from: input, libraryID: "fixture-account")
            if version == 2 { try library.saveAuthoringRequest(v2) }
            else { try library.saveAuthoringRequest(input) }
            try library.saveSubmission(key: input.requestID, text: input.context.userRequest, screen: nil)
            try library.savePending(id: input.requestID, screenID: "fixture-screen", consumedID: nil)
            library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            XCTAssertTrue(library.isUnsentLocalRequest(input.requestID, ledgerRecordExists: false))
            XCTAssertFalse(library.hasCloudSubmission)
            XCTAssertFalse(AuthoringRefreshPolicy.retryFailedRead(hasPendingWork: library.hasCloudSubmission, hasCloudSocket: false))
            if version == 1 { XCTAssertEqual(library.authoringRequest(id: input.requestID), input) }
            XCTAssertFalse(library.isUnsentLocalRequest(input.requestID, ledgerRecordExists: true))
            XCTAssertFalse(library.isUnsentLocalRequest("other", ledgerRecordExists: false))
            // Authoritative running state clears submission even without legacy deadline metadata.
            try library.submissionAccepted(deadline: nil)
            library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            XCTAssertNil(library.state.submissionKey); XCTAssertNil(library.state.submissionText)
            let receipt: ApplicationReceiptV1
            if version == 2 {
                receipt = try library.applyAuthoringResult(AuthoringResultV2(requestID: v2.requestID, inputDigest: v2.delivery.snapshotDigest,
                    baseRevision: nil, preferenceRevisions: [:], operationID: "local-operation", answer: "Done"), now: 60_000_000)
            } else { receipt = try library.applyAuthoringResult(result(input), now: 60_000_000) }
            library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            XCTAssertTrue(library.hasApplicationReceipt(requestID: input.requestID))
            XCTAssertEqual(library.unacknowledgedLocalReceiptIDs, [input.requestID])
            XCTAssertFalse(library.isUnsentLocalRequest(input.requestID, ledgerRecordExists: false))
            try library.acknowledgeReceipt(receipt)
            XCTAssertTrue(library.unacknowledgedLocalReceiptIDs.isEmpty)
        }
    }

    @MainActor func testCombinedScreenPreferenceReceiptOutboxAndReplaySurviveRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        let output = result(input)
        let receipt = try library.applyAuthoringResult(output, now: 60_000_000)
        XCTAssertEqual(receipt.status, "applied", String(describing: receipt))
        XCTAssertEqual(library.selected?.id, "fixture-screen")
        XCTAssertEqual(library.selected?.artifact.title, "Updated fixture")
        XCTAssertEqual(library.state.previous?.artifact.title, "Original fixture")
        XCTAssertEqual(library.preferences.first?.value, .string("large"))
        XCTAssertEqual(library.preferenceOutbox.count, 1)
        XCTAssertEqual(library.pendingReceipts, [receipt])
        let revision = library.selected?.revision
        let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertEqual(try restarted.applyAuthoringResult(output, now: 60_001_000), receipt)
        XCTAssertEqual(restarted.selected?.revision, revision)
        XCTAssertEqual(restarted.preferences.first?.revision, 1)
        try restarted.acknowledgeReceipt(receipt)
        let acknowledged = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertTrue(acknowledged.pendingReceipts.isEmpty)
        XCTAssertEqual(try acknowledged.applyAuthoringResult(output, now: 60_002_000), receipt)
        var reused = output; reused.answer = "different content"
        XCTAssertThrowsError(try acknowledged.applyAuthoringResult(reused, now: 60_002_000))
    }

    @MainActor func testEveryCrashCutRecoversEntireCombinedTransaction() throws {
        enum SimulatedCrash: Error { case powerLoss }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root, journalFault: { current in
                if armed && current == cut { throw SimulatedCrash.powerLoss }
            })
            try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
            let input = try request(library); try library.saveAuthoringRequest(input)
            armed = true
            XCTAssertThrowsError(try library.applyAuthoringResult(result(input), now: 2_000), cut.rawValue)
            let recovered = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertEqual(recovered.selected?.artifact.title, "Original fixture")
                XCTAssertTrue(recovered.preferences.isEmpty)
                XCTAssertTrue(recovered.pendingReceipts.isEmpty)
            } else {
                XCTAssertEqual(recovered.selected?.artifact.title, "Updated fixture", cut.rawValue)
                XCTAssertEqual(recovered.preferences.first?.value, .string("large"), cut.rawValue)
                XCTAssertEqual(recovered.preferenceOutbox.count, 1, cut.rawValue)
                XCTAssertEqual(recovered.pendingReceipts.first?.status, "applied", cut.rawValue)
                XCTAssertNotNil(try recovered.selected.map { try recovered.store(for: $0).assets["index.html"] })
                XCTAssertEqual(try recovered.applyAuthoringResult(result(input), now: 3_000).status, "applied")
            }
        }
    }

    @MainActor func testStaleScreenConflictsWithoutSavingPreference() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.install(artifact("Newer fixture"), requestID: "concurrent", replacing: "fixture-screen")
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        XCTAssertEqual(receipt.status, "conflict")
        XCTAssertEqual(library.selected?.artifact.title, "Newer fixture")
        XCTAssertTrue(library.preferences.isEmpty)
        XCTAssertEqual(library.pendingReceipts, [receipt])
    }

    @MainActor func testCancellationAndUnboundLegacyRestoreCannotInstall() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.cancelRequest(input.requestID)
        XCTAssertEqual(try library.applyAuthoringResult(result(input), now: 2_000).status, "rejected")
        XCTAssertNil(library.selected)
        XCTAssertTrue(library.preferences.isEmpty)
        let legacy = try request(library, id: "legacy-request"); try library.saveAuthoringRequest(legacy)
        XCTAssertEqual(try library.rejectAuthoringResult(result(legacy), reason: "Resend this request to bind its screen revision.", now: 2_000).status, "rejected")
        XCTAssertNil(library.selected)
    }

    @MainActor func testExistingLibraryMetadataMigratesAndAccountsStaySeparate() throws {
        let first = directory(), second = directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let library = try ScreenLibrary(accountID: "first-account", rootDirectory: first)
        try library.install(artifact("Existing fixture"), requestID: "legacy-install", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        _ = try library.applyAuthoringResult(result(input), now: 2_000)
        let other = try ScreenLibrary(accountID: "second-account", rootDirectory: second)
        XCTAssertTrue(other.preferences.isEmpty); XCTAssertTrue(other.state.screens.isEmpty)
        XCTAssertTrue(other.pendingReceipts.isEmpty)
        // Old indexes did not contain authoring metadata. Decode them in the same directory.
        let data = try JSONEncoder().encode(library.state)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "authoring")
        try JSONSerialization.data(withJSONObject: old).write(to: first.appendingPathComponent("library.json"), options: .atomic)
        let migrated = try ScreenLibrary(accountID: "first-account", rootDirectory: first)
        XCTAssertEqual(migrated.selected?.artifact.title, "Updated fixture")
        XCTAssertTrue(migrated.preferences.isEmpty)
        XCTAssertNotNil(try migrated.selected.map { try migrated.store(for: $0).assets["index.html"] })
    }

    @MainActor func testRawWireRejectsUnknownNestedFieldsBeforeCodableDropsThem() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        var output = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result(input))) as? [String: Any])
        let valid = try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "authoringResult": output])
        XCTAssertNoThrow(try DeviceAuthoringWire.validateResponse(valid))
        output["constructor"] = "unexpected"
        let unknown = try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "authoringResult": output])
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(unknown))
        var preference = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result(input).preferenceMutations![0].record!)) as? [String: Any])
        preference["extra"] = true
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(JSONSerialization.data(withJSONObject: ["records": [preference]])))
    }

    @MainActor func testReenrollmentQuarantinesOldDeliveryAndPreservesSavedPreferences() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        let pending = try request(library, id: "old-device-pending"); try library.saveAuthoringRequest(pending)
        try library.savePending(id: pending.requestID, screenID: pending.context.screenID, consumedID: nil)
        try library.saveSubmission(key: pending.requestID, text: pending.context.userRequest, screen: pending.context.currentScreen)
        try library.activateAuthoringDevice(deviceID: "new-fixture-device")
        XCTAssertNil(library.state.pendingID)
        XCTAssertNil(library.state.submissionKey)
        XCTAssertEqual(library.preferences.first?.value, .string("large"))
        XCTAssertTrue(library.pendingReceipts(deviceID: "new-fixture-device").isEmpty)
        XCTAssertEqual(library.pendingReceipts(deviceID: "fixture-device"), [receipt])
        XCTAssertEqual(library.selected?.artifact.title, "Updated fixture")
        let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertNil(restarted.authoringRequest(id: pending.requestID))
        XCTAssertEqual(restarted.preferences.first?.value, .string("large"))
    }

    @MainActor func testLostSubmissionResponseCannotLeaveTerminalRequestBlockingNewInstructions() throws {
        for terminal in ["completed", "rejected", "ended"] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            let input = try request(library)
            try library.saveSubmission(key: input.requestID, text: input.context.userRequest, screen: input.context.currentScreen)
            try library.saveAuthoringRequest(input)
            // HTTP acceptance was lost, so there was never a submissionAccepted call.
            switch terminal {
            case "completed": _ = try library.applyAuthoringResult(result(input), now: 2_000)
            case "rejected": _ = try library.rejectAuthoringResult(result(input), reason: "Explicit rejection", now: 2_000)
            default: try library.retireAuthoringRequest(id: input.requestID)
            }
            let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            XCTAssertNil(restarted.state.submissionKey, terminal)
            XCTAssertNil(restarted.state.submissionText, terminal)
            XCTAssertNil(restarted.state.submissionScreen, terminal)
            try restarted.saveSubmission(key: "next-request", text: "Different instructions", screen: restarted.selected?.artifact)
            XCTAssertEqual(restarted.state.submissionKey, "next-request")
        }
    }
}


private actor RemoteApprovalTransport: HTTPTransport {
    private(set) var sends = 0

    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        sends += 1
        return .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
    }
}
