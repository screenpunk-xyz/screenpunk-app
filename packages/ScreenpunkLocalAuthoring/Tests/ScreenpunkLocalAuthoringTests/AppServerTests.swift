import XCTest
import Foundation
import CryptoKit
import ScreenpunkCore
import ScreenpunkLocalTransport
@testable import ScreenpunkLocalAuthoring

private actor Peer {
    var stream: AsyncThrowingStream<String, Error>.Continuation?
    var requests: [JSON] = []
    var turns: [JSON] = []
    var items: [String: [JSON]] = [:]
    var resultText = "{}"
    var loseStartResponse = false
    var completes = true
    var unsupportedRequest = false
    var wrongVersion = false
    var globalHome = false
    var historyCursorLoop = false
    var wrongItemTurn = false
    var unsafePolicy = false
    var mcpConfigured = false
    var malformedResult = false
    var rejectsEmptyResume = false
    var materializedThreads: Set<String> = []
    var threadStartCount = 0
    var resumeError: (Int, String)?
    var holdThreadStart = false
    var heldThreadStarts: [JSON] = []
    var openCount = 0
    var initializeCount = 0
    var startCount = 0
    var interruptCount = 0
    var deniedCount = 0
    func set(result: String, lose: Bool = false, completes: Bool = true, approval: Bool = false) { resultText = result; loseStartResponse = lose; self.completes = completes; unsupportedRequest = approval }
    func setWrongVersion() { wrongVersion = true }
    func setGlobalHome() { globalHome = true }
    func setHistoryCursorLoop() { historyCursorLoop = true }
    func setWrongItemTurn() { wrongItemTurn = true }
    func setUnsafePolicy() { unsafePolicy = true }
    func setMCPConfigured() { mcpConfigured = true }
    func rejectEmptyResumes() { rejectsEmptyResume = true }
    func setResumeError(code: Int, message: String) { resumeError = (code, message) }
    func holdNextThreadStart() { holdThreadStart = true }
    func hasHeldThreadStart() -> Bool { !heldThreadStarts.isEmpty }
    func releaseThreadStarts() throws { let held = heldThreadStarts; heldThreadStarts = []; for packet in held { try emit(packet) } }
    func finishSocket() { stream?.finish() }
    func completePersistedTurn(_ id: String) {
        for index in turns.indices where turns[index]["id"].string == id {
            var turn = turns[index].object; turn["status"] = .string("completed"); turns[index] = .object(turn)
        }
    }
    func emitRaw(_ text: String) { stream?.yield(text) }
    func socket() -> AppServerSocket {
        openCount += 1
        let (messages, c) = AsyncThrowingStream<String, Error>.makeStream(); stream = c
        return .init(messages: messages, send: { [weak self] text in try await self?.receive(text) }, close: { c.finish() })
    }
    func emit(_ v: JSON) throws { stream?.yield(String(decoding: try v.data(), as: UTF8.self)) }
    func inject(_ v: JSON) throws { try emit(v) }
    func receive(_ text: String) throws {
        let p = try JSONDecoder().decode(JSON.self, from: Data(text.utf8)); requests.append(p)
        guard let method = p["method"].string else { if p["error"] != .null { deniedCount += 1 }; return }
        guard p["id"] != .null else { return }
        let params = p["params"], id = p["id"]
        func reply(_ value: JSON) throws { try emit(.object(["id": id, "result": value])) }
        switch method {
        case "initialize": initializeCount += 1; try reply(.object(["userAgent": .string("Codex Desktop/" + (wrongVersion ? "0.145.0" : AppServerClient.pinnedVersion) + " (Mac OS)"), "codexHome": .string(globalHome ? "/Users/test/.codex" : "/Users/test/.codex/screenpunk-local")]))
        case "account/read": try reply(.object(["account": .object(["type": .string("chatgpt")]), "requiresOpenaiAuth": .bool(true)]))
        case "model/list": try reply(.object(["data": .array([.object(["id": .string(AppServerClient.model), "model": .string(AppServerClient.model), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("high")])])])]), "nextCursor": .null]))
        case "mcpServerStatus/list": try reply(.object(["data": .array(mcpConfigured ? [.object(["name": .string("unexpected-server")])] : []), "nextCursor": .null]))
        case "thread/start", "thread/resume":
            if method == "thread/resume", let threadID = params["threadId"].string {
                if let error = resumeError { try emit(.object(["id": id, "error": .object(["code": .number(Double(error.0)), "message": .string(error.1)])])); break }
                if rejectsEmptyResume && !materializedThreads.contains(threadID) {
                    try emit(.object(["id": id, "error": .object(["code": .number(-32600), "message": .string("no rollout found for thread id " + threadID)])])); break
                }
            }
            if method == "thread/start" { threadStartCount += 1 }
            let generatedID = params["developerInstructions"] == .null ? "owned-thread" : "owned-v2-thread"
            let threadID = params["threadId"].string ?? (rejectsEmptyResume ? generatedID + "-" + String(threadStartCount) : generatedID)
            let threadResponse: JSON = .object(["thread": .object(["id": .string(threadID)]), "model": .string(AppServerClient.model), "reasoningEffort": .string("high"), "serviceTier": .string("priority"), "modelProvider": .string("openai"), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string(unsafePolicy ? "auto_review" : "user"), "sandbox": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]), "instructionSources": .array([])])
            if method == "thread/start" && holdThreadStart { holdThreadStart = false; heldThreadStarts.append(.object(["id": id, "result": threadResponse])) }
            else { try reply(threadResponse) }
        case "turn/start":
            startCount += 1; let turnID = "turn-\(startCount)", threadID = params["threadId"].string!, prompt = params["input"].array[0]["text"].string!
            materializedThreads.insert(threadID)
            var text = resultText
            if prompt.hasPrefix("SCREENPUNK_TEST ") {
                let request = params["outputSchema"]["properties"]["requestID"]["enum"].array[0].string!
                text = String(decoding: try JSON.object(["status": .string("ok"), "requestID": .string(request)]).data(), as: UTF8.self)
            }
            let user: JSON = .object(["id": .string("u"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(prompt)])])])
            let final: JSON = .object(["id": .string("a"), "type": .string("agentMessage"), "phase": .string("final_answer"), "text": .string(text)])
            let status = completes ? "completed" : "inProgress"
            items[turnID] = [user, final]; turns.insert(.object(["id": .string(turnID), "status": .string(status), "items": .array([user, final])]), at: 0)
            if !loseStartResponse { try reply(.object(["turn": .object(["id": .string(turnID), "status": .string("inProgress")])])) }
            try emit(.object(["method": .string("turn/started"), "params": .object(["threadId": .string(threadID), "turn": .object(["id": .string(turnID), "status": .string("inProgress")])])]))
            if unsupportedRequest { try emit(.object(["id": .string("approval"), "method": .string("item/commandExecution/requestApproval"), "params": .object(["threadId": .string(threadID), "turnId": .string(turnID)])])) }
            if completes {
                try emit(.object(["method": .string("item/completed"), "params": .object(["threadId": .string(threadID), "turnId": .string(turnID), "item": final])]))
                try emit(.object(["method": .string("turn/completed"), "params": .object(["threadId": .string(threadID), "turn": .object(["id": .string(turnID), "status": .string("completed")])])]))
            }
            if loseStartResponse { stream?.finish() }
        case "huge-code": try emit(.object(["id": id, "error": .object(["code": .number(1e100)])]))
        case "silent": break
        case "thread/turns/list" where historyCursorLoop: try reply(.object(["data": .array([]), "nextCursor": .string("loop")]))
        case "thread/turns/list":
            let data = turns.map { turn -> JSON in var value = turn.object; value["items"] = .array([]); return .object(value) }
            try reply(.object(["data": .array(data), "nextCursor": .null]))
        case "thread/items/list":
            if historyCursorLoop { try reply(.object(["data": .array([]), "nextCursor": .string("loop")])); break }
            var entries: [JSON] = []
            if let turn = params["turnId"].string {
                entries = (items[turn] ?? []).map { .object(["turnId": .string(wrongItemTurn ? "another-turn" : turn), "item": $0]) }
            } else {
                entries = turns.flatMap { turn in (items[turn["id"].string!] ?? []).reversed().map { .object(["turnId": turn["id"], "item": $0]) } }
            }
            let offset = Int(params["cursor"].string ?? "0") ?? 0
            let data = offset < entries.count ? [entries[offset]] : []
            let next: JSON = offset + 1 < entries.count ? .string(String(offset + 1)) : .null
            try reply(.object(["data": .array(data), "nextCursor": next]))
        case "turn/interrupt": interruptCount += 1; try reply(.object([:]))
        default: try reply(params)
        }
    }
}
private actor ReadyGate {
    private var reached = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async { reached = true; await withCheckedContinuation { releaseContinuation = $0 } }
    func hasReached() -> Bool { reached }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}
final class AppServerTests: XCTestCase {
    func testVersionPinRejectsOlderAndSuffixVersions() {
        XCTAssertTrue(AppServerClient.versionMatches("Codex Desktop/0.164.0-alpha.11.1 (Mac OS)"))
        XCTAssertFalse(AppServerClient.versionMatches("Codex Desktop/0.145.0 (Mac OS)"))
        XCTAssertFalse(AppServerClient.versionMatches("Codex Desktop/0.164.0-alpha.11.1-unsafe"))
    }
    func testRequiresOpenAIAuthDoesNotOverrideChatGPTAccount() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect(); let ready = await client.ready; XCTAssertTrue(ready)
        await client.disconnect(); try await client.connect()
        let count = await peer.initializeCount; XCTAssertEqual(count, 2)
        await client.disconnect()
    }
    func testUnsupportedVersionFailsBeforeAccountOrModel() async throws {
        let peer = Peer(); await peer.setWrongVersion()
        let client = AppServerClient(openSocket: { await peer.socket() })
        do { try await client.connect(); XCTFail("Expected version rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .unsupportedVersion) }
        let methods = await peer.requests.compactMap { $0["method"].string }; XCTAssertEqual(methods, ["initialize"])
    }
    func testCorrelationAndUnsolicitedResponseIsolation() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect()
        try await peer.inject(.object(["id": .string("unknown"), "result": .string("ignored")]))
        async let a = client.call("echo", .object(["value": .string("first")]))
        async let b = client.call("echo", .object(["value": .string("second")]))
        let (one, two) = try await (a, b); XCTAssertEqual(one["value"].string, "first"); XCTAssertEqual(two["value"].string, "second")
        await client.disconnect()
    }
    func testGlobalCodexHomeIsRejectedBeforeAccountRead() async throws {
        let peer = Peer(); await peer.setGlobalHome()
        let client = AppServerClient(openSocket: { await peer.socket() })
        do { try await client.connect(); XCTFail("Expected isolated home rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .unsafeMacConfiguration) }
        let methods = await peer.requests.compactMap { $0["method"].string }; XCTAssertEqual(methods, ["initialize"])
    }
    func testTimeoutAndOversizedFrameCloseWithoutAcceptingResult() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() }, rpcTimeoutNanoseconds: 20_000_000)
        try await client.connect()
        do { _ = try await client.call("silent", .object([:])); XCTFail("Expected bounded timeout") } catch { XCTAssertEqual(error as? LocalAuthoringError, .timeout) }
        await peer.emitRaw(String(repeating: "x", count: 2_097_153))
        try await Task.sleep(nanoseconds: 20_000_000)
        let ready = await client.ready; XCTAssertFalse(ready)
        await client.disconnect()
    }
    func testHistoryCursorLoopIsRejectedAndForeignTurnItemsCannotBeRecovered() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect(); await peer.setHistoryCursorLoop()
        do { _ = try await client.history(threadID: "owned-thread", turnID: nil, marker: "marker\n"); XCTFail("Expected cursor-loop rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .uncertain) }
        await client.disconnect()
        let second = Peer(), c = AppServerClient(openSocket: { await second.socket() })
        try await c.connect(); _ = try await c.ensureThread(nil, workspace: "/tmp/Screenpunk")
        let id = try await c.start(threadID: "owned-thread", prompt: "marker\n", schema: .object([:]))
        await second.setWrongItemTurn()
        do { _ = try await c.history(threadID: "owned-thread", turnID: id, marker: "marker\n"); XCTFail("Expected foreign turn rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .protocolViolation) }
        await c.disconnect()
    }
    func testUnexpectedApprovalReviewerRejectsThreadBeforeAnyTurn() async throws {
        let peer = Peer(); await peer.setUnsafePolicy()
        let client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect()
        do { _ = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk"); XCTFail("Expected policy rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .unsafeMacConfiguration) }
        let count = await peer.startCount; XCTAssertEqual(count, 0)
        await client.disconnect()
    }
    func testHugeNumericRPCIDAndErrorCodeAreRejectedWithoutIntegerTrap() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect()
        do { _ = try await client.call("huge-code", .object([:])); XCTFail("Expected invalid error code rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .protocolViolation) }
        try await peer.inject(.object(["id": .number(1e100), "result": .object([:])]))
        try await Task.sleep(nanoseconds: 20_000_000)
        let ready = await client.ready; XCTAssertFalse(ready)
        await client.disconnect()
    }
    func testConcurrentConnectUsesOneSocketAndInitialize() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { try await Task.sleep(nanoseconds: 20_000_000); return await peer.socket() })
        async let first: Void = client.connect()
        async let second: Void = client.connect()
        async let third: Void = client.connect()
        _ = try await (first, second, third)
        let opens = await peer.openCount, initializations = await peer.initializeCount
        XCTAssertEqual(opens, 1); XCTAssertEqual(initializations, 1)
        await client.disconnect()
        let ready = await client.ready; XCTAssertFalse(ready)
    }
    func testDisconnectCancelsInFlightConnectAndClosesLateSocket() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { try await Task.sleep(nanoseconds: 100_000_000); return await peer.socket() })
        let task = Task { try await client.connect() }
        try await Task.sleep(nanoseconds: 10_000_000); await client.disconnect()
        do { try await task.value; XCTFail("Expected connection cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await peer.initializeCount; XCTAssertEqual(count, 0)
        let ready = await client.ready; XCTAssertFalse(ready)
    }
    func testConfiguredMCPServerPreventsReadiness() async throws {
        let peer = Peer(); await peer.setMCPConfigured()
        let client = AppServerClient(openSocket: { await peer.socket() })
        do { try await client.connect(); XCTFail("Expected MCP isolation rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .unsafeMacConfiguration) }
        let ready = await client.ready; XCTAssertFalse(ready)
        let count = await peer.startCount; XCTAssertEqual(count, 0)
    }
    func testLargePriorTurnsUseMetadataAndSingleItemPages() async throws {
        let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
        try await client.connect(); _ = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk")
        let final = String(repeating: "\"", count: 200_000)
        await peer.set(result: final)
        var last = ""
        for index in 0..<4 {
            last = try await client.start(threadID: "owned-thread", prompt: "large-\(index)\n" + String(repeating: "\"", count: 450_000), schema: .object([:]))
        }
        let saved = try await client.history(threadID: "owned-thread", turnID: last, marker: "large-3\n")
        XCTAssertEqual(saved?.1.finalText, final)
        let recovered = try await client.history(threadID: "owned-thread", turnID: nil, marker: "large-3\n")
        XCTAssertEqual(recovered?.0, last)
        let requests = await peer.requests
        XCTAssertTrue(requests.filter { $0["method"].string == "thread/turns/list" }.allSatisfy { $0["params"]["itemsView"].string == "notLoaded" })
        XCTAssertTrue(requests.filter { $0["method"].string == "thread/items/list" }.allSatisfy { $0["params"]["limit"] == .number(1) })
        await client.disconnect()
    }
    func testDisconnectAfterMCPResponseCannotRestoreReadyWithoutSocket() async throws {
        let peer = Peer(), gate = ReadyGate()
        let client = AppServerClient(openSocket: { await peer.socket() }, beforeReady: { await gate.pause() })
        let connection = Task { try await client.connect() }
        for _ in 0..<100 {
            if await gate.hasReached() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let reached = await gate.hasReached(); XCTAssertTrue(reached)
        await client.disconnect(); await gate.release()
        do { try await connection.value; XCTFail("Expected cancelled initialization") } catch { XCTAssertTrue(error is CancellationError) }
        let ready = await client.ready; XCTAssertFalse(ready)
    }
    func testCredentialSecretsRedactedAndExactForget() throws {
        let vault = MemoryLocalCredentialStore()
        let one = try vault.create(appServerToken: "private-token-one"), two = try vault.create(appServerToken: "private-token-two")
        XCTAssertTrue(one.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        let privateBytes = try vault.load(reference: one.reference).privateKey
        let publicBytes = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes).publicKey.rawRepresentation
        let wire = Data(base64Encoded: one.publicKeyOpenSSH.split(separator: " ")[1].description)!
        XCTAssertEqual(wire.suffix(32), publicBytes)
        XCTAssertFalse(String(describing: try vault.load(reference: one.reference)).contains("private-token"))
        XCTAssertThrowsError(try vault.updateToken("bad\r\nAuthorization: bad", reference: one.reference))
        try vault.forget(reference: one.reference)
        XCTAssertThrowsError(try vault.load(reference: one.reference))
        XCTAssertEqual(try vault.load(reference: two.reference).appServerToken, "private-token-two")
    }
    @MainActor private func fixture(_ peer: Peer, client injectedClient: AppServerClient? = nil) throws -> (URL, LocalDeliveryLedger, LocalAgentConfigurationRepository, LocalAuthoringTransport, AuthoringRequestV1) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-client-" + UUID().uuidString)
        let ledger = try LocalDeliveryLedger(rootDirectory: root.appendingPathComponent("delivery")), config = try LocalAgentConfigurationRepository(rootDirectory: root.appendingPathComponent("config"))
        try config.save(.init(host: "localhost", username: "test", hostKeySHA256: "SHA256:" + String(repeating: "A", count: 43), macWorkspace: "/tmp/Screenpunk", credentialReference: "test"))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let request = try AuthoringContract.seal(.init(requestID: "request-" + UUID().uuidString, createdAt: now, deadlineAt: now + 600_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], context: .init(profileID: "profile", deviceID: "device", screenID: "screen", userRequest: "Make large labels", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "local")))
        let client = injectedClient ?? AppServerClient(openSocket: { await peer.socket() }, rpcTimeoutNanoseconds: 100_000_000)
        let adapter = LocalAuthoringTransport(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { $0 == request.requestID ? request : nil }, client: client)
        return (root, ledger, config, adapter, request)
    }
    private func result(_ request: AuthoringRequestV1) throws -> String {
        String(decoding: try JSONEncoder().encode(AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "operation", answer: "Ready")), as: UTF8.self)
    }
    @MainActor func testResponseLossRecoversExactHistoryWithoutResubmittingAndAcknowledgesNativeReceipt() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: try result(request), lose: true)
        _ = try await adapter.submit(request)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .deliveryUncertain)
        _ = try await adapter.submit(request)
        guard case .completed(let output) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected recovered result") }
        XCTAssertEqual(output.requestID, request.requestID)
        let count = await peer.startCount; XCTAssertEqual(count, 1)
        let receipt = ApplicationReceiptV1(requestID: output.requestID, operationID: output.operationID, inputDigest: output.inputDigest, status: "applied", appliedAt: 99)
        try await adapter.acknowledge(receipt)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.receipt, receipt)
        await adapter.disconnect()
    }
    @MainActor func testCancellationTombstoneBlocksLateOutput() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: try result(request), completes: false)
        _ = try await adapter.submit(request); try await adapter.cancel(requestID: request.requestID)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .cancelled)
        guard case .ended(let status, _) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected cancellation") }
        XCTAssertEqual(status, "cancelled"); let count = await peer.interruptCount; XCTAssertEqual(count, 1)
        await adapter.disconnect()
    }
    @MainActor func testServerApprovalIsDeniedAndRequiresMacAttention() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: try result(request), completes: false, approval: true)
        _ = try await adapter.submit(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .needsAttention = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected attention") }
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .needsAttention)
        let denied = await peer.deniedCount; XCTAssertEqual(denied, 1)
        await adapter.disconnect()
    }
    @MainActor func testInvalidFinalResultNeverCompletes() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: "{\"requestID\":\"wrong\"}")
        _ = try await adapter.submit(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .ended(let status, _) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected schema failure") }
        XCTAssertEqual(status, "failed"); XCTAssertNil(try ledger.record(requestID: request.requestID)?.finalResult)
        await adapter.disconnect()
    }
    @MainActor func testReceiptReplaySucceedsAfterResultCompactionAndRejectsChangedReceipt() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: try result(request)); _ = try await adapter.submit(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .completed(let output) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected complete result") }
        let receipt = ApplicationReceiptV1(requestID: output.requestID, operationID: output.operationID, inputDigest: output.inputDigest, status: "applied", appliedAt: 99)
        try await adapter.acknowledge(receipt)
        let old = try XCTUnwrap(ledger.record(requestID: request.requestID))
        for index in 0..<33 {
            let id = "compaction-\(index)"
            var record = LocalDeliveryRecord(requestID: id, inputDigest: old.inputDigest, connectionID: old.connectionID, profileID: old.profileID, hostKeySHA256: old.hostKeySHA256, deadlineAt: old.deadlineAt + Int64(index) + 1)
            try ledger.prepare(record); record.status = .submitting; try ledger.update(record)
            var final = output; final.requestID = id
            record.status = .completed; record.finalResult = final; try ledger.update(record)
            record.status = .applied; record.receipt = .init(requestID: id, operationID: final.operationID, inputDigest: final.inputDigest, status: "applied", appliedAt: 100)
            try ledger.update(record)
        }
        try ledger.compactSources(); XCTAssertNil(try ledger.record(requestID: request.requestID)?.finalResult)
        try await adapter.acknowledge(receipt)
        var changed = receipt; changed.appliedAt = 101
        do { try await adapter.acknowledge(changed); XCTFail("Expected changed receipt rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .wrongBinding) }
        await adapter.disconnect()
    }
    @MainActor func testCancelledConnectionTestInterruptsOwnedTurnWithoutDeliveryRecord() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, _) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: "{}", completes: false)
        let task = Task { try await adapter.testConnection() }
        for _ in 0..<100 {
            if await peer.startCount > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancelled connection test") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await peer.interruptCount; XCTAssertEqual(count, 1)
        XCTAssertTrue(try ledger.records().isEmpty)
    }
    @MainActor func testCloudRouteCannotCrossIntoLocalSubmission() async throws {
        let peer = Peer(); let (root, ledger, _, adapter, request) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        var cloud = request; cloud.delivery.route = "cloud"; cloud = try AuthoringContract.seal(cloud)
        do { _ = try await adapter.submit(cloud); XCTFail("Expected route rejection") } catch { XCTAssertEqual(error as? LocalAuthoringError, .wrongBinding) }
        XCTAssertTrue(try ledger.records().isEmpty)
    }
    @MainActor func testConnectionRoundtripReconnectDoesNotCreateDeliveryRecord() async throws {
        let peer = Peer(); let (root, ledger, configuration, adapter, _) = try fixture(peer); defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try await adapter.testConnection()
        XCTAssertTrue(receipt.reconnected); XCTAssertEqual(receipt.requestedServiceTier, "priority")
        XCTAssertTrue(try ledger.records().isEmpty)
        XCTAssertNotNil(try configuration.load()?.lastSuccessfulConnectionAt)
        let count = await peer.initializeCount; XCTAssertEqual(count, 2)
        await adapter.disconnect()
    }
    func testPinnedProtocolSnapshotHashesAndRequiredBoundedHistoryFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ProtocolPin")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["version"] as? String, AppServerClient.pinnedVersion)
        for (name, expected) in manifest["schemas"] as! [String: String] {
            let hash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expected, name)
        }
        let schema = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: root.appendingPathComponent("ThreadItemsListParams.json")))
        XCTAssertNotEqual(schema["properties"]["turnId"], .null)
        XCTAssertNotEqual(schema["properties"]["cursor"], .null)
    }
}

extension AppServerTests {
    @MainActor private func fixtureV2(_ peer: Peer, resultSource: Bool = false, client injectedClient: AppServerClient? = nil) throws -> (URL, LocalDeliveryLedger, LocalAgentConfigurationRepository, LocalAuthoringTransportV2, AuthoringRequestV2) {
        let (root, ledger, config, _, old) = try fixture(peer)
        var legacy = old
        if resultSource {
            legacy.context.baseRevision = "base-revision"
            legacy.context.currentScreen = .init(title: "Synthetic Cosmo", files: [
                .init(path: "index.html", content: "<html><img src=\"cosmo.svg\"></html>"),
                .init(path: "cosmo.svg", content: "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"data:image/png;base64," + String(repeating: "A", count: 73_000) + "\"/></svg>")
            ])
            legacy = try AuthoringContract.seal(legacy)
        }
        let request = try AuthoringV2Contract.makeRequest(from: legacy, libraryID: "saved-library")
        let client = injectedClient ?? AppServerClient(openSocket: { await peer.socket() }, rpcTimeoutNanoseconds: 100_000_000)
        let adapter = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { $0 == request.requestID ? request : nil }, client: client)
        return (root, ledger, config, adapter, request)
    }
    @MainActor func testV2PreflightHasNoInferenceOrUserSnapshotAndIsolatesV1History() async throws {
        let peer = Peer(); let (root, ledger, config, adapter, request) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(config.load()); try config.setThreadID("v1-history-with-large-assets", profileID: "profile", configurationID: old.id)
        let readiness = await adapter.preflight(); XCTAssertEqual(readiness, .ready)
        let sent = await peer.requests
        XCTAssertFalse(sent.contains { $0["method"].string == "turn/start" })
        XCTAssertFalse(sent.description.contains(request.context.userRequest))
        let start = try XCTUnwrap(sent.first { $0["method"].string == "thread/start" })
        XCTAssertEqual(start["params"]["developerInstructions"].string, AppServerClient.v2DeveloperInstructions)
        XCTAssertEqual(try config.load()?.profileThreads["profile"], "v1-history-with-large-assets")
        XCTAssertNil(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")], "Readiness-only empty threads are not durable history")
        XCTAssertTrue(try ledger.records().isEmpty)
        let prompt = try LocalAuthoringTransportV2.prompt(request)
        XCTAssertLessThan(prompt.utf8.count, 32_768)
        XCTAssertFalse(prompt.contains(String(repeating: "A", count: 100)))
        XCTAssertFalse(prompt.contains("$defs")); XCTAssertFalse(prompt.contains(AppServerClient.v2DeveloperInstructions))
        await adapter.disconnect()
    }
    @MainActor func testV2LostStartResponseRecoversOnceAcrossRestartAndAcknowledges() async throws {
        let peer = Peer(); let (root, ledger, config, adapter, request) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(request.context.currentScreen?.files.first { $0.path == "cosmo.svg" })
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision, preferenceRevisions: [:], operationID: "v2-operation", screen: .init(title: "Synthetic Cosmo", files: [
            .write(path: "index.html", content: "<html><h1>New caption</h1><img src=\"cosmo.svg\"></html>"),
            .retain(path: "cosmo.svg", sourcePath: source.path, reference: source.reference, digest: source.digest)
        ]))
        await peer.set(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), lose: true)
        _ = try await adapter.submit(request)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .deliveryUncertain)
        await adapter.disconnect()
        let reopened = try LocalDeliveryLedger(rootDirectory: root.appendingPathComponent("delivery"))
        let recovered = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: reopened, credentialStore: MemoryLocalCredentialStore(), requestLookup: { $0 == request.requestID ? request : nil }, client: AppServerClient(openSocket: { await peer.socket() }, rpcTimeoutNanoseconds: 100_000_000))
        _ = try await recovered.submit(request)
        guard case .completed(let output) = try await recovered.reconcile(requestID: request.requestID) else { return XCTFail("Expected durable v2 history recovery") }
        XCTAssertEqual(output, result)
        let starts = await peer.startCount; XCTAssertEqual(starts, 1)
        let record = try XCTUnwrap(reopened.record(requestID: request.requestID))
        XCTAssertEqual(record.contractVersion, 2); XCTAssertNil(record.finalResult); XCTAssertEqual(record.finalResultV2, result)
        let receipt = ApplicationReceiptV1(requestID: request.requestID, operationID: result.operationID, inputDigest: result.inputDigest, status: "applied", appliedAt: 99)
        try await recovered.acknowledge(receipt); try await recovered.acknowledge(receipt)
        XCTAssertEqual(try reopened.record(requestID: request.requestID)?.receipt, receipt)
        await recovered.disconnect()
    }
    @MainActor func testV2CancellationRejectsLateOutputAndWrongContractCannotRecover() async throws {
        let peer = Peer(); let (root, ledger, config, adapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "v2-operation", answer: "Ready")
        await peer.set(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self), completes: false)
        _ = try await adapter.submit(request)
        let v1 = LocalAuthoringTransport(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in nil }, client: AppServerClient(openSocket: { await peer.socket() }))
        let legacy = try request.legacyRequest()
        do { _ = try await v1.submit(legacy); XCTFail("V1 must not consume V2") } catch { XCTAssertEqual(error as? LocalAuthoringError, .wrongBinding) }
        try await adapter.cancel(requestID: request.requestID)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .cancelled)
        XCTAssertNil(try ledger.record(requestID: request.requestID)?.finalResultV2)
        guard case .ended(let status, _) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Expected cancellation tombstone") }
        XCTAssertEqual(status, "cancelled"); let count = await peer.interruptCount; XCTAssertEqual(count, 1)
        await adapter.disconnect()
    }
    @MainActor func testCandidateConnectionTestPreservesActivePairingAndHistory() async throws {
        let peer = Peer(); let (root, _, config, adapter, _) = try fixture(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        var active = try XCTUnwrap(config.load()); active.profileThreads["profile"] = "old-working-thread"; try config.save(active)
        var candidate = active; candidate.id = "candidate"; candidate.credentialReference = "new-staged-credential"; candidate.profileThreads = [:]
        let receipt = try await adapter.testConnection(configuration: candidate)
        XCTAssertTrue(receipt.reconnected)
        XCTAssertEqual(try config.load(), active)
        await adapter.disconnect()
    }
    func testPairingCredentialStagingCopiesIdentityAndPreservesWorkingCredential() throws {
        let vault = MemoryLocalCredentialStore()
        let old = try vault.create(appServerToken: "fixture-old-token")
        let oldCredential = try vault.load(reference: old.reference)
        let staged = "pairing-" + UUID().uuidString
        try vault.stagePairingCredential(appServerToken: "fixture-new-token", identityReference: old.reference.rawValue, stagedReference: staged)
        let newCredential = try vault.load(reference: .init(rawValue: staged))
        XCTAssertEqual(newCredential.privateKey, oldCredential.privateKey)
        XCTAssertEqual(newCredential.appServerToken, "fixture-new-token")
        XCTAssertEqual(try vault.load(reference: old.reference).appServerToken, "fixture-old-token")
        try vault.stagePairingCredential(appServerToken: "fixture-new-token", identityReference: old.reference.rawValue, stagedReference: staged)
        XCTAssertThrowsError(try vault.stagePairingCredential(appServerToken: "fixture-conflicting-token", identityReference: old.reference.rawValue, stagedReference: staged))
        try vault.forget(reference: .init(rawValue: staged))
        XCTAssertEqual(try vault.load(reference: old.reference).appServerToken, "fixture-old-token")
    }
    func testReadinessTypedIdentityFailuresNeverBecomeOrdinaryUnavailability() {
        XCTAssertEqual(LocalAgentReadiness.classify(SSHTransportError.hostKeyMismatch(expected: "fixture", observed: "other")), .repairRequired(.hostIdentityChanged))
        XCTAssertEqual(LocalAgentReadiness.classify(LocalAuthoringError.unsupportedVersion), .repairRequired(.unsupportedVersion))
        XCTAssertEqual(LocalAgentReadiness.classify(SSHTransportError.unreachable), .unavailable(.unreachable))
        XCTAssertEqual(LocalAgentReadiness.classify(LocalAuthoringError.signInOnMac), .unavailable(.signInRequired))
    }
}

extension AppServerTests {
    @MainActor func testV2PreflightDeadlineReturnsWithoutInferenceAndCannotInstallLateThread() async throws {
        let peer = Peer(); let (root, ledger, config, _, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = AppServerClient(openSocket: { try await Task.sleep(nanoseconds: 100_000_000); return await peer.socket() })
        let adapter = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in request }, client: client)
        let started = Date()
        let readiness = await adapter.preflight(timeoutNanoseconds: 5_000_000)
        XCTAssertEqual(readiness, .unavailable(.timedOut)); XCTAssertLessThan(Date().timeIntervalSince(started), 0.08)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")])
        let count = await peer.startCount; XCTAssertEqual(count, 0)
        XCTAssertTrue(try ledger.records().isEmpty)
        await adapter.disconnect()
    }
}

extension AppServerTests {
    @MainActor func testV2RepeatedCosmoPromptsStaySmallWithoutRejectingLegitimateLargeEditableSource() throws {
        let peer = Peer(); let (root, _, _, _, base) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var lengths: [Int] = []
        for index in 0..<8 {
            var next = base; next.requestID = "repeated-edit-\(index)"; next.context.userRequest = "Change caption \(index) and CSS color"
            next = try AuthoringV2Contract.seal(next)
            let prompt = try LocalAuthoringTransportV2.prompt(next)
            lengths.append(prompt.utf8.count)
            XCTAssertLessThan(prompt.utf8.count, 32_768)
            XCTAssertFalse(prompt.contains(String(repeating: "A", count: 100)))
        }
        XCTAssertLessThanOrEqual(lengths.max()! - lengths.min()!, 8)
        print("Synthetic Cosmo V2 per-edit UTF8 prompt bytes: \(lengths)")
        var large = try base.legacyRequest()
        large.context.currentScreen = .init(title: "Large editable source", files: [.init(path: "index.html", content: "<html>" + String(repeating: "A", count: 50_000) + "</html>")])
        large = try AuthoringContract.seal(large)
        let v2 = try AuthoringV2Contract.makeRequest(from: large, libraryID: "saved-library")
        XCTAssertGreaterThan(try LocalAuthoringTransportV2.prompt(v2).utf8.count, 32_768)
    }
}

extension AppServerTests {
    @MainActor func testLinkedProfileUsesWireOwnerAndRetainsDescriptorLedgerThreadScope() async throws {
        let peer = Peer(); let (root, ledger, config, _, local) = try fixture(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        var linked = local; linked.context.profileID = "cloud-owner-profile"; linked = try AuthoringContract.seal(linked)
        let v1 = LocalAuthoringTransport(profileID: "descriptor-profile", authoringProfileID: "cloud-owner-profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in linked }, client: AppServerClient(openSocket: { await peer.socket() }))
        await peer.set(result: try result(linked), completes: false)
        _ = try await v1.submit(linked)
        XCTAssertEqual(try ledger.record(requestID: linked.requestID)?.profileID, "descriptor-profile")
        XCTAssertEqual(try config.load()?.profileThreads["descriptor-profile"], "owned-thread")
        XCTAssertNil(try config.load()?.profileThreads["cloud-owner-profile"])
        try await v1.cancel(requestID: linked.requestID); await v1.disconnect()
        var next = linked; next.requestID = "linked-v2"; next = try AuthoringContract.seal(next)
        let request = try AuthoringV2Contract.makeRequest(from: next, libraryID: "saved-library")
        let v2 = LocalAuthoringTransportV2(profileID: "descriptor-profile", authoringProfileID: "cloud-owner-profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in request }, client: AppServerClient(openSocket: { await peer.socket() }))
        let resultV2 = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "linked-v2-operation", answer: "Ready")
        await peer.set(result: String(decoding: try JSONEncoder().encode(resultV2), as: UTF8.self), completes: false)
        _ = try await v2.submit(request)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.profileID, "descriptor-profile")
        XCTAssertEqual(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "descriptor-profile")], "owned-v2-thread")
        XCTAssertNil(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "cloud-owner-profile")])
        try await v2.cancel(requestID: request.requestID); await v2.disconnect()
    }
}

extension AppServerTests {
    func testVerifiedLiveEmptyThreadIsReusedOnlyOnItsSocketAndSettings() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes()
        let client = AppServerClient(openSocket: { await peer.socket() })
        let id = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let reused = try await client.ensureThread(id, workspace: "/tmp/Screenpunk", contractVersion: 2)
        XCTAssertEqual(reused, id)
        var calls = await peer.requests
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/resume" }.count, 0)
        do { _ = try await client.ensureThread(id, workspace: "/tmp/AnotherWorkspace", contractVersion: 2); XCTFail("A cached thread must not cross workspace settings") }
        catch { XCTAssertEqual(error as? LocalAuthoringError, .unmaterializedThread) }
        await client.disconnect()
        do { _ = try await client.ensureThread(id, workspace: "/tmp/Screenpunk", contractVersion: 2); XCTFail("A new socket must revalidate persisted history") }
        catch { XCTAssertEqual(error as? LocalAuthoringError, .unmaterializedThread) }
        calls = await peer.requests
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/resume" }.count, 2)
        await client.disconnect()
    }
    @MainActor func testV2FirstSubmissionUsesReadinessThreadWithoutResumingEmptyHistory() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes()
        let (root, ledger, config, adapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try XCTUnwrap(config.load())
        try config.setThreadID("preserved-v1-history", profileID: "profile", configurationID: configuration.id)
        let first = await adapter.preflight(); let second = await adapter.preflight()
        XCTAssertEqual(first, .ready); XCTAssertEqual(second, .ready)
        XCTAssertNil(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")])
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "first-v2", answer: "Ready")
        await peer.set(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        _ = try await adapter.submit(request)
        guard case .completed(let received) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("First V2 turn must succeed after readiness") }
        XCTAssertEqual(received, result)
        let calls = await peer.requests
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/resume" }.count, 0)
        XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.threadID, try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")])
        XCTAssertEqual(try config.load()?.profileThreads["profile"], "preserved-v1-history")
        await adapter.disconnect()
    }
    @MainActor func testRelaunchRecoversOnlyUnboundOrphanAndKeepsOldFailedRequestTerminal() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes()
        let (root, ledger, config, firstAdapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try XCTUnwrap(config.load())
        let key = LocalAuthoringTransportV2.threadKey(profileID: "profile")
        try config.setThreadID("legacy-empty-readiness-id", profileID: key, configurationID: configuration.id)
        var failed = LocalDeliveryRecord(requestID: "old-preacceptance-failure", inputDigest: "old-digest", connectionID: configuration.id, profileID: "profile", hostKeySHA256: configuration.hostKeySHA256, deadlineAt: request.deadlineAt, contractVersion: 2)
        try ledger.prepare(failed); failed.status = .failed; failed.failure = "Previous thread/resume failure"; try ledger.update(failed)
        let readiness = await firstAdapter.preflight(); XCTAssertEqual(readiness, .ready)
        await firstAdapter.disconnect()
        XCTAssertEqual(try config.load()?.profileThreads[key], "legacy-empty-readiness-id", "Do not save another readiness-only empty ID")
        let reopened = try LocalDeliveryLedger(rootDirectory: root.appendingPathComponent("delivery"))
        let adapter = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: reopened, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in request }, client: AppServerClient(openSocket: { await peer.socket() }))
        let retryReadiness = await adapter.preflight(); XCTAssertEqual(retryReadiness, .ready)
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "new-request-only", answer: "Ready")
        await peer.set(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        _ = try await adapter.submit(request)
        XCTAssertNotEqual(try config.load()?.profileThreads[key], "legacy-empty-readiness-id")
        XCTAssertEqual(try reopened.record(requestID: failed.requestID), failed)
        let calls = await peer.requests
        XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
        XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 2)
        XCTAssertTrue(calls.filter { $0["method"].string == "thread/resume" }.allSatisfy { $0["params"]["threadId"].string == "legacy-empty-readiness-id" })
        await adapter.disconnect()
    }
    @MainActor func testBoundUncertainOrTerminalThreadIsNeverReplacedWhenRolloutIsMissing() async throws {
        for terminal in [false, true] {
            let peer = Peer(); await peer.rejectEmptyResumes()
            let (root, ledger, config, adapter, request) = try fixtureV2(peer)
            defer { try? FileManager.default.removeItem(at: root) }
            let c = try XCTUnwrap(config.load()), id = "bound-missing-history"
            try config.setThreadID(id, profileID: LocalAuthoringTransportV2.threadKey(profileID: "profile"), configurationID: c.id)
            var record = LocalDeliveryRecord(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, connectionID: c.id, profileID: "profile", hostKeySHA256: c.hostKeySHA256, deadlineAt: request.deadlineAt, contractVersion: 2)
            try ledger.prepare(record); record.threadID = id; record.status = .submitting; try ledger.update(record)
            record.status = .deliveryUncertain; try ledger.update(record)
            if terminal { try ledger.cancel(requestID: request.requestID) }
            let before = try ledger.record(requestID: request.requestID)
            let readiness = await adapter.preflight(); XCTAssertEqual(readiness, .repairRequired(.missingConversationHistory))
            XCTAssertEqual(try ledger.record(requestID: request.requestID), before)
            XCTAssertEqual(try config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")], id)
            if !terminal {
                _ = try await adapter.submit(request)
                guard case .deliveryUncertain(let message) = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Unknown acceptance must remain uncertain") }
                XCTAssertTrue(message.contains("no saved history"))
            }
            let calls = await peer.requests
            XCTAssertFalse(calls.contains { ["thread/start", "turn/start"].contains($0["method"].string ?? "") })
            await adapter.disconnect()
        }
    }
    @MainActor func testMaterializedV2ThreadReconnectsToSameHistoryWithoutAnotherTurn() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes()
        let (root, ledger, config, adapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        await peer.set(result: String(decoding: try JSONEncoder().encode(AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "saved-turn", answer: "Ready")), as: UTF8.self))
        _ = await adapter.preflight(); _ = try await adapter.submit(request)
        let threadID = try XCTUnwrap(config.load()?.profileThreads[LocalAuthoringTransportV2.threadKey(profileID: "profile")])
        await adapter.disconnect()
        let reopened = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in request }, client: AppServerClient(openSocket: { await peer.socket() }))
        guard case .completed = try await reopened.reconcile(requestID: request.requestID) else { return XCTFail("Materialized history must resume") }
        await reopened.disconnect()
        let calls = await peer.requests
        XCTAssertTrue(calls.contains { $0["method"].string == "thread/resume" && $0["params"]["threadId"].string == threadID })
        XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
        await adapter.disconnect()
    }
    @MainActor func testOnlyExactPinnedMissingRolloutErrorCanReplaceUnusedThread() async throws {
        for (code, message) in [(-32600, "sensitive source must not appear in diagnostics"), (-32000, "no rollout found for thread id old-empty"), (-32600, "no rollout found for thread id another-thread")] {
            let peer = Peer(); await peer.setResumeError(code: code, message: message)
            let (root, _, config, adapter, _) = try fixtureV2(peer)
            defer { try? FileManager.default.removeItem(at: root) }
            let c = try XCTUnwrap(config.load())
            try config.setThreadID("old-empty", profileID: LocalAuthoringTransportV2.threadKey(profileID: "profile"), configurationID: c.id)
            let readiness = await adapter.preflight(); XCTAssertEqual(readiness, .repairRequired(.unsupportedProtocol))
            let calls = await peer.requests; XCTAssertFalse(calls.contains { $0["method"].string == "thread/start" })
            let client = AppServerClient(openSocket: { await peer.socket() })
            do { _ = try await client.ensureThread("old-empty", workspace: "/tmp/Screenpunk", contractVersion: 2); XCTFail("Expected a sanitized RPC rejection") }
            catch {
                XCTAssertEqual(error as? LocalAuthoringError, .rpcRejected(method: "thread/resume", code: code))
                XCTAssertFalse(error.localizedDescription.contains(message))
                XCTAssertTrue(error.localizedDescription.contains("thread/resume"))
            }
            await client.disconnect(); await adapter.disconnect()
        }
    }
}

extension AppServerTests {
    @MainActor func testThreadMappingCASPreservesNewerMappingOtherProfilesAndEndpoint() throws {
        let peer = Peer(); let (root, _, config, _, _) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(config.load())
        try config.setThreadID("v1-history", profileID: "profile", configurationID: original.id)
        let key = LocalAuthoringTransportV2.threadKey(profileID: "profile")
        try config.replaceThreadID("first", profileID: key, configurationID: original.id, expectedThreadID: nil)
        XCTAssertThrowsError(try config.replaceThreadID("stale-check", profileID: key, configurationID: original.id, expectedThreadID: nil))
        XCTAssertEqual(try config.load()?.profileThreads[key], "first")
        try config.replaceThreadID("next", profileID: key, configurationID: original.id, expectedThreadID: "first")
        XCTAssertEqual(try config.load()?.profileThreads["profile"], "v1-history")
        XCTAssertThrowsError(try config.replaceThreadID("v1-history", profileID: key, configurationID: original.id, expectedThreadID: "next"))
        var newer = try XCTUnwrap(config.load()); newer.id = "newer-endpoint"; newer.profileThreads = [:]
        try config.save(newer)
        XCTAssertThrowsError(try config.replaceThreadID("old-endpoint-thread", profileID: key, configurationID: original.id, expectedThreadID: nil))
        XCTAssertEqual(try config.load(), newer)
    }
}

extension AppServerTests {
    @MainActor func testOrphanRecoveryRechecksLedgerAfterSuspendedThreadStart() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes(); await peer.holdNextThreadStart()
        let (root, ledger, config, adapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try XCTUnwrap(config.load()), savedID = "missing-before-another-adapter-binds"
        let key = LocalAuthoringTransportV2.threadKey(profileID: "profile")
        try config.setThreadID(savedID, profileID: key, configurationID: c.id)
        let probe = Task { await adapter.preflight() }
        for _ in 0..<100 { if await peer.hasHeldThreadStart() { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let held = await peer.hasHeldThreadStart(); XCTAssertTrue(held)
        var other = LocalDeliveryRecord(requestID: "other-accepted-request", inputDigest: "other-input", connectionID: c.id, profileID: "profile", hostKeySHA256: c.hostKeySHA256, deadlineAt: request.deadlineAt, contractVersion: 2)
        try ledger.prepare(other); other.threadID = savedID; other.status = .submitting; try ledger.update(other)
        other.status = .deliveryUncertain; try ledger.update(other)
        try await peer.releaseThreadStarts()
        let readiness = await probe.value; XCTAssertEqual(readiness, .repairRequired(.missingConversationHistory))
        XCTAssertEqual(try config.load()?.profileThreads[key], savedID)
        XCTAssertEqual(try ledger.record(requestID: other.requestID)?.status, .deliveryUncertain)
        let calls = await peer.requests; XCTAssertFalse(calls.contains { $0["method"].string == "turn/start" })
        await adapter.disconnect()
    }
    @MainActor func testCachedOrphanReplacementRechecksOldThreadBeforeSubmission() async throws {
        let peer = Peer(); await peer.rejectEmptyResumes()
        let (root, ledger, config, adapter, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try XCTUnwrap(config.load()), savedID = "old-thread-bound-after-readiness"
        let key = LocalAuthoringTransportV2.threadKey(profileID: "profile")
        try config.setThreadID(savedID, profileID: key, configurationID: c.id)
        let readiness = await adapter.preflight(); XCTAssertEqual(readiness, .ready)
        var other = LocalDeliveryRecord(requestID: "other-cancelled-after-acceptance", inputDigest: "other-input", connectionID: c.id, profileID: "profile", hostKeySHA256: c.hostKeySHA256, deadlineAt: request.deadlineAt, contractVersion: 2)
        try ledger.prepare(other); other.threadID = savedID; other.turnID = "accepted-other-turn"; other.status = .submitting; try ledger.update(other)
        try ledger.cancel(requestID: other.requestID)
        do { _ = try await adapter.submit(request); XCTFail("Cached readiness must not replace newly bound history") }
        catch { XCTAssertEqual(error as? LocalAuthoringError, .unmaterializedThread) }
        XCTAssertEqual(try config.load()?.profileThreads[key], savedID)
        XCTAssertEqual(try ledger.record(requestID: other.requestID)?.status, .cancelled)
        XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .failed)
        let calls = await peer.requests; XCTAssertFalse(calls.contains { $0["method"].string == "turn/start" })
        await adapter.disconnect()
    }
}

extension AppServerTests {
    @MainActor private func contextRequests(_ base: AuthoringRequestV2) throws -> [AuthoringRequestV2] {
        var first = base
        first.requestID = "synthetic-context-request-1"
        first.context.userRequest = "Answer only: explain the Home Assistant getStates freshness requirement using the current service facts and saved contrast preference. Do not create a screen or mutate preferences."
        first.services = AuthoringContract.makeServices(observedAt: first.createdAt)
        if let home = first.services.firstIndex(where: { $0.provider == "home" }) {
            first.services[home].configured = .init(state: "yes", observedAt: first.createdAt)
            first.services[home].authorized = .init(state: "no", observedAt: first.createdAt)
        }
        first.preferences = [.init(id: "contrast", scope: "profile", targetID: first.context.profileID, category: "contrast", value: .string("blue"), revision: 1, originRequestID: "earlier-fixture-request")]
        first = try AuthoringV2Contract.seal(first)
        var second = first
        second.requestID = "synthetic-context-request-2"; second.createdAt += 1; second.deadlineAt += 1
        second.context.userRequest = "Answer only: explain the current Home Assistant facts and latest saved contrast preference. Do not reuse old authorization or preference values. Do not create a screen or mutate preferences."
        if let home = second.services.firstIndex(where: { $0.provider == "home" }) {
            second.services[home].authorized = .init(state: "yes", observedAt: second.createdAt)
            second.services[home].reachable = .init(state: "no", observedAt: second.createdAt)
        }
        second.preferences[0].value = .string("green"); second.preferences[0].revision = 2
        return [first, try AuthoringV2Contract.seal(second)]
    }
    private func expandedContextProjection(_ payload: JSON) throws -> AuthoringRequestV2 {
        var request = payload["request"].object
        for name in ["designGuidance", "runtime"] where request[name]?["localDefinition"].string == name { request[name] = LocalAuthoringContext.definitions[name] }
        request["services"] = .array((request["services"]?.array ?? []).map { service in
            var value = service.object
            if value["operations"]?["localDefinition"].string == "serviceCatalog.operations", let provider = value["provider"]?.string,
               let definition = LocalAuthoringContext.definitions["serviceCatalog"].array.first(where: { $0["provider"].string == provider }) { value["operations"] = definition["operations"] }
            return .object(value)
        })
        return try AuthoringV2Contract.validateRequest(JSON.object(request).data())
    }
    @MainActor func testCompactContextReconstructsOriginalDigestAndCurrentDynamicFacts() async throws {
        let peer = Peer(); let (root, _, _, _, base) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = AppServerClient(openSocket: { await peer.socket() })
        let thread = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let bound = await client.definitionBinding(threadID: thread), binding = try XCTUnwrap(bound)
        let requests = try contextRequests(base)
        var lengths: [Int] = []
        for request in requests {
            let payload = try LocalAuthoringContext.payload(request, binding: binding)
            XCTAssertEqual(payload["projectionVersion"].string, LocalAuthoringContext.version)
            XCTAssertEqual(payload["definitionDigest"].string, LocalAuthoringContext.digest)
            XCTAssertEqual(payload["request"]["context"], try JSON.encoded(request.context))
            XCTAssertEqual(payload["request"]["preferences"], try JSON.encoded(request.preferences))
            XCTAssertEqual(payload["request"]["delivery"], try JSON.encoded(request.delivery))
            XCTAssertEqual(try expandedContextProjection(payload), request)
            let services = payload["request"]["services"].array
            for (index, service) in request.services.enumerated() {
                XCTAssertEqual(services[index]["id"].string, service.id)
                XCTAssertEqual(services[index]["provider"].string, service.provider)
                for field in ["supported", "configured", "authorized", "entitled", "reachable"] { XCTAssertEqual(services[index][field], try JSON.encoded(service)[field]) }
                XCTAssertEqual(services[index]["operations"]["localDefinition"].string, "serviceCatalog.operations")
            }
            let full = try LocalAuthoringTransportV2.prompt(request), compact = try LocalAuthoringTransportV2.prompt(request, binding: binding)
            XCTAssertLessThan(compact.utf8.count, full.utf8.count / 2)
            XCTAssertFalse(compact.contains(AuthoringContract.designGuidance.rules[0]))
            XCTAssertFalse(compact.contains(request.services[0].operations[0].instructions))
            XCTAssertFalse(compact.contains(String(repeating: "A", count: 100)))
            lengths.append(compact.utf8.count)
        }
        XCTAssertNotEqual(requests[0].delivery.snapshotDigest, requests[1].delivery.snapshotDigest)
        XCTAssertNotEqual(try LocalAuthoringContext.payload(requests[0], binding: binding)["request"]["services"], try LocalAuthoringContext.payload(requests[1], binding: binding)["request"]["services"])
        print("Local compact context prompt UTF8 bytes: \(lengths); trusted context UTF8 bytes: \(AppServerClient.v2DeveloperInstructions.utf8.count)")
        await client.disconnect()
    }
    @MainActor func testNoEstablishedContextKeepsFullDefinitionsAndV1HasNoCompactBinding() async throws {
        let peer = Peer(); let (root, _, _, _, base) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try contextRequests(base)[0]
        XCTAssertEqual(try LocalAuthoringContext.payload(request, binding: nil), try JSON.encoded(request))
        let client = AppServerClient(openSocket: { await peer.socket() })
        let thread = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk")
        let binding = await client.definitionBinding(threadID: thread); XCTAssertNil(binding)
        let calls = await peer.requests
        XCTAssertEqual(calls.first { $0["method"].string == "thread/start" }?["params"]["developerInstructions"], .null)
        await client.disconnect()
    }
    @MainActor func testNoncanonicalDefinitionIsNeverSilentlyOmittedByLocalProjection() async throws {
        let peer = Peer(); let (root, _, _, _, request) = try fixtureV2(peer)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = AppServerClient(openSocket: { await peer.socket() })
        let thread = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let bound = await client.definitionBinding(threadID: thread), binding = try XCTUnwrap(bound)
        var changed = try contextRequests(request)[0]
        changed.runtime.features.append("future.inline.feature")
        changed.designGuidance.rules.append("Future inline guidance")
        changed.services[0].operations[0].instructions = "Future inline operation definition"
        let value = try LocalAuthoringContext.payload(changed, binding: binding)["request"]
        XCTAssertEqual(value["runtime"], try JSON.encoded(changed.runtime))
        XCTAssertEqual(value["designGuidance"], try JSON.encoded(changed.designGuidance))
        XCTAssertEqual(value["services"].array[0]["operations"], try JSON.encoded(changed.services[0].operations))
        XCTAssertThrowsError(try AuthoringV2Contract.validateRequest(JSONEncoder().encode(changed)), "Current native contract still rejects unsupported definitions")
        await client.disconnect()
    }
    func testStaticContextIsReinstalledOnResumeAndStaleBindingCannotSend() async throws {
        let peer = Peer(); let client = AppServerClient(openSocket: { await peer.socket() })
        let thread = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let first = await client.definitionBinding(threadID: thread), binding = try XCTUnwrap(first)
        _ = try await client.start(threadID: thread, prompt: "fixture-marker\n", schema: .object([:]), definitionBinding: binding)
        _ = try await client.ensureThread(thread, workspace: "/tmp/Screenpunk", contractVersion: 2)
        await client.disconnect(); try await client.connect()
        let missing = await client.definitionBinding(threadID: thread); XCTAssertNil(missing)
        do { _ = try await client.start(threadID: thread, prompt: "must not send", schema: .object([:]), definitionBinding: binding); XCTFail("A stale context cannot authorize compact data") }
        catch { XCTAssertEqual(error as? LocalAuthoringError, .wrongBinding) }
        _ = try await client.ensureThread(thread, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let rebound = await client.definitionBinding(threadID: thread), current = try XCTUnwrap(rebound)
        XCTAssertNotEqual(binding, current)
        do { _ = try await client.start(threadID: "other-thread", prompt: "must not send", schema: .object([:]), definitionBinding: current); XCTFail("Context cannot cross threads") }
        catch { XCTAssertEqual(error as? LocalAuthoringError, .wrongBinding) }
        let calls = await peer.requests
        let setups = calls.filter { ["thread/start", "thread/resume"].contains($0["method"].string ?? "") }
        XCTAssertEqual(setups.count, 2)
        XCTAssertTrue(setups.allSatisfy { $0["params"]["developerInstructions"].string == LocalAuthoringContext.developerInstructions })
        XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
        XCTAssertTrue(LocalAuthoringContext.developerInstructions.contains(LocalAuthoringContext.digest))
        XCTAssertLessThan(LocalAuthoringContext.developerInstructions.utf8.count, AuthoringContract.runtime.limits.metadataBytes)
        await client.disconnect()
    }
    @MainActor func testProductionTransportSendsCompactPromptWithInstalledContext() async throws {
        let peer = Peer(); let (root, _, config, _, base) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try contextRequests(base)[0], ledger = try LocalDeliveryLedger(rootDirectory: root.appendingPathComponent("compact-delivery"))
        let adapter = LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in request }, client: AppServerClient(openSocket: { await peer.socket() }))
        await peer.set(result: String(decoding: try JSONEncoder().encode(AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision, preferenceRevisions: ["contrast": 1], operationID: "compact-result", answer: "Ready")), as: UTF8.self))
        _ = try await adapter.submit(request)
        guard case .completed = try await adapter.reconcile(requestID: request.requestID) else { return XCTFail("Compact prompt must retain unchanged native result binding") }
        let calls = await peer.requests, start = try XCTUnwrap(calls.first { $0["method"].string == "turn/start" })
        let text = try XCTUnwrap(start["params"]["input"].array.first?["text"].string)
        XCTAssertTrue(text.contains("REQUEST SNAPSHOT PROJECTION DATA"))
        XCTAssertTrue(text.contains(LocalAuthoringContext.digest))
        XCTAssertFalse(text.contains(AuthoringContract.designGuidance.rules[0]))
        await adapter.disconnect()
    }
}

extension AppServerTests {
    @MainActor func testExportProductionLocalContextProbeWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_LOCAL_CONTEXT_PROBE_OUT"] else { throw XCTSkip("Synthetic context export requires an explicit output path") }
        guard path.hasPrefix("/") else { throw AuthoringContractError("Use an absolute synthetic probe output path") }
        let peer = Peer(); let (root, _, _, _, base) = try fixtureV2(peer, resultSource: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = AppServerClient(openSocket: { await peer.socket() })
        let thread = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk", contractVersion: 2)
        let established = await client.definitionBinding(threadID: thread), binding = try XCTUnwrap(established)
        let cases = try contextRequests(base).map { request -> JSON in
            .object(["request": try .encoded(request), "prompt": .string(try LocalAuthoringTransportV2.prompt(request, binding: binding)), "outputSchema": try LocalResultWireContract.schema(for: request)])
        }
        let export: JSON = .object(["contextVersion": .string(LocalAuthoringContext.version), "definitionDigest": .string(LocalAuthoringContext.digest), "developerInstructions": .string(AppServerClient.v2DeveloperInstructions), "baseInstructions": .string(AppServerClient.baseInstructions), "threadConfig": AppServerClient.threadConfig, "requestedModel": .string(AppServerClient.model), "requestedEffort": .string("high"), "requestedServiceTier": .string("priority"), "pinnedVersion": .string(AppServerClient.pinnedVersion), "cases": .array(cases)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(export).write(to: URL(fileURLWithPath: path), options: .atomic)
        await client.disconnect()
        print("Exported2 synthetic production Local compact prompts. No live inference, credentials or service operations.")
    }
    func testValidateProductionLocalContextProbeResultsWhenExplicitlySupplied() throws {
        guard let resultsPath = ProcessInfo.processInfo.environment["SCREENPUNK_LOCAL_CONTEXT_PROBE_RESULTS"] else { throw XCTSkip("Synthetic wire validation requires explicitly supplied results") }
        let exportPath = try XCTUnwrap(ProcessInfo.processInfo.environment["SCREENPUNK_LOCAL_CONTEXT_PROBE_EXPORT"])
        guard resultsPath.hasPrefix("/"), exportPath.hasPrefix("/") else { throw AuthoringContractError("Use absolute synthetic probe paths") }
        let exported = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: URL(fileURLWithPath: exportPath)))
        let entries = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: URL(fileURLWithPath: resultsPath))).array
        let cases = exported["cases"].array
        guard entries.count == cases.count, !entries.isEmpty else { throw AuthoringContractError("Expected one wire result for every exported synthetic request") }
        var seen = Set<String>(), normalized: [JSON] = []
        for entry in entries {
            guard let id = entry["requestID"].string, seen.insert(id).inserted,
                  let item = cases.first(where: { $0["request"]["requestID"].string == id }) else { throw AuthoringContractError("Unknown or duplicate synthetic result binding") }
            let request = try AuthoringV2Contract.validateRequest(item["request"].data())
            let wire = try entry["wire"].string.map { Data($0.utf8) } ?? entry["wire"].data()
            let result = try LocalResultWireContract.decode(wire, request: request)
            _ = try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: request)
            if result.screen != nil {
                let materialized = try AuthoringV2Contract.materialize(result, request: request) { file in
                    if let content = file.content { return Data(content.utf8) }
                    guard file.path == "cosmo.svg" else { throw AuthoringContractError("Unknown omitted synthetic source") }
                    return Data(("<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"data:image/png;base64," + String(repeating: "A", count: 73_000) + "\"/></svg>").utf8)
                }
                if let asset = request.context.currentScreen?.files.first(where: { $0.path == "cosmo.svg" }) {
                    let saved = try XCTUnwrap(materialized.files.first { $0.path == asset.path })
                    guard AuthoringContract.contentDigest(Data(saved.content.utf8)) == asset.digest else { throw AuthoringContractError("Synthetic retained asset bytes changed") }
                }
            }
            normalized.append(.object(["requestID": .string(id), "result": try .encoded(result)]))
        }
        let output = ProcessInfo.processInfo.environment["SCREENPUNK_LOCAL_CONTEXT_PROBE_NATIVE_OUT"] ?? resultsPath + ".native.json"
        guard output.hasPrefix("/") else { throw AuthoringContractError("Use an absolute native validation output path") }
        try AuthoringContract.encodedCanonical(JSON.array(normalized)).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Native production Local wire validation passed for \(normalized.count) synthetic context results")
    }
}


extension AppServerTests {
    private func waitForRemoteDisconnect(_ client: AppServerClient, peer: Peer) async throws {
        await peer.finishSocket()
        for _ in 0..<100 {
            if !(await client.ready) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The simulated remote socket closure was not processed")
    }
    @MainActor func testSameV1AdapterReconnectRecoversOfflineCompletionWithoutReplayingTurn() async throws {
        for remoteClose in [false, true] {
            let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
            let (root, ledger, _, adapter, request) = try fixture(peer, client: client)
            defer { try? FileManager.default.removeItem(at: root) }
            let outputText = try result(request)
            await peer.set(result: outputText, completes: false)
            _ = try await adapter.submit(request)
            guard case .pending = try await adapter.reconcile(requestID: request.requestID) else { XCTFail("The accepted turn must first be in progress"); continue }
            let before = try XCTUnwrap(ledger.record(requestID: request.requestID))
            let turnID = try XCTUnwrap(before.turnID), threadID = try XCTUnwrap(before.threadID)
            let cached = await client.snapshot(threadID: threadID, turnID: turnID)
            XCTAssertEqual(cached.status, "inProgress")
            let beforeCalls = await peer.requests
            if remoteClose { try await waitForRemoteDisconnect(client, peer: peer) }
            else { await adapter.disconnect() }
            await peer.completePersistedTurn(turnID) // No completion notification reaches the disconnected client.
            let resumed = try await adapter.reconcile(requestID: request.requestID)
            guard case .completed(let output) = resumed else { XCTFail("The same V1 adapter must recover offline completion after reconnect (remoteClose=\(remoteClose))"); await adapter.disconnect(); continue }
            XCTAssertEqual(output, try JSONDecoder().decode(AuthoringResultV1.self, from: Data(outputText.utf8)))
            let after = try XCTUnwrap(ledger.record(requestID: request.requestID))
            XCTAssertEqual(after.requestID, before.requestID); XCTAssertEqual(after.inputDigest, before.inputDigest)
            XCTAssertEqual(after.threadID, threadID); XCTAssertEqual(after.turnID, turnID); XCTAssertEqual(after.finalResult, output)
            let calls = await peer.requests, reopenedCalls = Array(calls.dropFirst(beforeCalls.count))
            XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
            XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/resume" && $0["params"]["threadId"].string == threadID })
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/turns/list" })
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/items/list" })
            await adapter.disconnect()
        }
    }
    @MainActor func testSameV2AdapterReconnectRecoversOfflineCompletionWithoutReplayingTurn() async throws {
        for remoteClose in [false, true] {
            let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
            let (root, ledger, _, adapter, request) = try fixtureV2(peer, client: client)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "offline-v2-completion", answer: "Recovered")
            await peer.set(result: String(decoding: try JSONEncoder().encode(output), as: UTF8.self), completes: false)
            _ = try await adapter.submit(request)
            guard case .pending = try await adapter.reconcile(requestID: request.requestID) else { XCTFail("The accepted turn must first be in progress"); continue }
            let before = try XCTUnwrap(ledger.record(requestID: request.requestID))
            let turnID = try XCTUnwrap(before.turnID), threadID = try XCTUnwrap(before.threadID)
            let cached = await client.snapshot(threadID: threadID, turnID: turnID)
            XCTAssertEqual(cached.status, "inProgress")
            let beforeCalls = await peer.requests
            if remoteClose { try await waitForRemoteDisconnect(client, peer: peer) }
            else { await adapter.disconnect() }
            await peer.completePersistedTurn(turnID)
            let resumed = try await adapter.reconcile(requestID: request.requestID)
            guard case .completed(let recovered) = resumed else { XCTFail("The same V2 adapter must recover offline completion after reconnect (remoteClose=\(remoteClose))"); await adapter.disconnect(); continue }
            XCTAssertEqual(recovered, output)
            let after = try XCTUnwrap(ledger.record(requestID: request.requestID))
            XCTAssertEqual(after.requestID, before.requestID); XCTAssertEqual(after.inputDigest, before.inputDigest)
            XCTAssertEqual(after.threadID, threadID); XCTAssertEqual(after.turnID, turnID); XCTAssertEqual(after.finalResultV2, output)
            let calls = await peer.requests, reopenedCalls = Array(calls.dropFirst(beforeCalls.count))
            XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
            XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/resume" && $0["params"]["threadId"].string == threadID })
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/turns/list" })
            XCTAssertTrue(reopenedCalls.contains { $0["method"].string == "thread/items/list" })
            await adapter.disconnect()
        }
    }
    func testDisconnectKeepsAlreadyReceivedCompletedTurnSnapshots() async throws {
        for remoteClose in [false, true] {
            let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
            let threadID = try await client.ensureThread(nil, workspace: "/tmp/Screenpunk")
            await peer.set(result: "completed-result")
            let turnID = try await client.start(threadID: threadID, prompt: "completed-marker", schema: .object([:]))
            for _ in 0..<100 {
                if await client.snapshot(threadID: threadID, turnID: turnID).status == "completed" { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let before = await client.snapshot(threadID: threadID, turnID: turnID)
            XCTAssertEqual(before.status, "completed"); XCTAssertEqual(before.finalText, "completed-result")
            if remoteClose { try await waitForRemoteDisconnect(client, peer: peer) }
            else { await client.disconnect() }
            try await client.connect()
            let after = await client.snapshot(threadID: threadID, turnID: turnID)
            XCTAssertEqual(after.status, "completed"); XCTAssertEqual(after.finalText, before.finalText)
            let calls = await peer.requests
            XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
            XCTAssertFalse(calls.contains { ["thread/turns/list", "thread/items/list"].contains($0["method"].string ?? "") })
            await client.disconnect()
        }
    }
}

extension AppServerTests {
    @MainActor func testV1CancelAfterDisconnectHydratesKnownTurnWithoutReplaying() async throws {
        for reconstructed in [false, true] {
            let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
            let (root, ledger, config, adapter, request) = try fixture(peer, client: client)
            defer { try? FileManager.default.removeItem(at: root) }
            await peer.set(result: try result(request), completes: false)
            _ = try await adapter.submit(request)
            guard case .pending = try await adapter.reconcile(requestID: request.requestID) else { XCTFail("Expected accepted running turn"); continue }
            let before = try XCTUnwrap(ledger.record(requestID: request.requestID))
            let turnID = try XCTUnwrap(before.turnID), threadID = try XCTUnwrap(before.threadID)
            await adapter.disconnect()
            let cancelling = reconstructed ? LocalAuthoringTransport(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in nil }, client: AppServerClient(openSocket: { await peer.socket() })) : adapter
            let beforeCalls = await peer.requests
            do { try await cancelling.cancel(requestID: request.requestID) }
            catch { XCTFail("Known V1 running turn must be interrupted after disconnect (reconstructed=\(reconstructed)): \(error)") }
            XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .cancelled)
            let calls = await peer.requests, cancellationCalls = Array(calls.dropFirst(beforeCalls.count))
            let history = cancellationCalls.firstIndex { $0["method"].string == "thread/turns/list" }
            let interrupt = cancellationCalls.firstIndex { $0["method"].string == "turn/interrupt" }
            XCTAssertNotNil(history); XCTAssertNotNil(interrupt)
            if let history, let interrupt { XCTAssertLessThan(history, interrupt) }
            let interrupts = calls.filter { $0["method"].string == "turn/interrupt" }
            XCTAssertEqual(interrupts.count, 1)
            XCTAssertEqual(interrupts.first?["params"]["threadId"].string, threadID)
            XCTAssertEqual(interrupts.first?["params"]["turnId"].string, turnID)
            XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
            XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
            await cancelling.disconnect()
        }
    }
    @MainActor func testV2CancelAfterDisconnectHydratesKnownTurnWithoutReplaying() async throws {
        for reconstructed in [false, true] {
            let peer = Peer(), client = AppServerClient(openSocket: { await peer.socket() })
            let (root, ledger, config, adapter, request) = try fixtureV2(peer, client: client)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "cancel-running-v2", answer: "Ready")
            await peer.set(result: String(decoding: try JSONEncoder().encode(output), as: UTF8.self), completes: false)
            _ = try await adapter.submit(request)
            guard case .pending = try await adapter.reconcile(requestID: request.requestID) else { XCTFail("Expected accepted running turn"); continue }
            let before = try XCTUnwrap(ledger.record(requestID: request.requestID))
            let turnID = try XCTUnwrap(before.turnID), threadID = try XCTUnwrap(before.threadID)
            await adapter.disconnect()
            let cancelling = reconstructed ? LocalAuthoringTransportV2(profileID: "profile", configurationRepository: config, ledger: ledger, credentialStore: MemoryLocalCredentialStore(), requestLookup: { _ in nil }, client: AppServerClient(openSocket: { await peer.socket() })) : adapter
            let beforeCalls = await peer.requests
            do { try await cancelling.cancel(requestID: request.requestID) }
            catch { XCTFail("Known V2 running turn must be interrupted after disconnect (reconstructed=\(reconstructed)): \(error)") }
            XCTAssertEqual(try ledger.record(requestID: request.requestID)?.status, .cancelled)
            let calls = await peer.requests, cancellationCalls = Array(calls.dropFirst(beforeCalls.count))
            let history = cancellationCalls.firstIndex { $0["method"].string == "thread/turns/list" }
            let interrupt = cancellationCalls.firstIndex { $0["method"].string == "turn/interrupt" }
            XCTAssertNotNil(history); XCTAssertNotNil(interrupt)
            if let history, let interrupt { XCTAssertLessThan(history, interrupt) }
            let interrupts = calls.filter { $0["method"].string == "turn/interrupt" }
            XCTAssertEqual(interrupts.count, 1)
            XCTAssertEqual(interrupts.first?["params"]["threadId"].string, threadID)
            XCTAssertEqual(interrupts.first?["params"]["turnId"].string, turnID)
            XCTAssertEqual(calls.filter { $0["method"].string == "turn/start" }.count, 1)
            XCTAssertEqual(calls.filter { $0["method"].string == "thread/start" }.count, 1)
            await cancelling.disconnect()
        }
    }
}
