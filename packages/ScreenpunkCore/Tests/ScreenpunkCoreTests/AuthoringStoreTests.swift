import XCTest
@testable import ScreenpunkCore

final class AuthoringStoreTests: XCTestCase {
    private func preference(_ id: String = "theme", revision: Int = 1, value: String = "dark", scope: String = "profile", target: String = "profile-a") -> PreferenceRecordV1 {
        .init(id: id, scope: scope, targetID: target, category: "appearance", value: .string(value), revision: revision, originRequestID: "request-a")
    }
    private func insert(_ record: PreferenceRecordV1, in state: inout AuthoringStoreState) throws {
        try AuthoringStore.mutate(.init(kind: "upsert", id: record.id, expectedRevision: nil, record: record), originRequestID: record.originRequestID, in: &state)
    }
    func testRecordCASDoesNotReplaceUnrelatedRecordsAndDeleteIsTombstone() throws {
        var state = AuthoringStoreState()
        try insert(preference(), in: &state); try insert(preference("spacing"), in: &state)
        var updated = preference(revision: 2, value: "light")
        try AuthoringStore.mutate(.init(kind: "upsert", id: "theme", expectedRevision: 1, record: updated), originRequestID: "request-a", in: &state)
        XCTAssertEqual(state.records["spacing"]?.revision, 1)
        updated.revision = 3
        XCTAssertThrowsError(try AuthoringStore.mutate(.init(kind: "upsert", id: "theme", expectedRevision: 1, record: updated), originRequestID: "request-a", in: &state))
        try AuthoringStore.mutate(.init(kind: "delete", id: "theme", expectedRevision: 2), originRequestID: "settings-delete", in: &state)
        XCTAssertTrue(state.records["theme"]!.deleted)
        XCTAssertEqual(state.records["theme"]!.revision, 3)
        XCTAssertEqual(state.records["theme"]!.originRequestID, "settings-delete")
        XCTAssertEqual(state.records["spacing"]?.revision, 1)
    }
    func testScopeResolutionFiltersOtherOwnersAndTombstones() throws {
        var state = AuthoringStoreState()
        for p in [preference(), preference("device", scope: "device", target: "device-a"), preference("screen", scope: "screen", target: "screen-a"), preference("other-device", scope: "device", target: "device-b"), preference("other-profile", target: "profile-b")] { try insert(p, in: &state) }
        try AuthoringStore.mutate(.init(kind: "delete", id: "screen", expectedRevision: 1), originRequestID: "settings-delete", in: &state)
        XCTAssertEqual(AuthoringStore.preferences(in: state, profileID: "profile-a", deviceID: "device-a", screenID: "screen-a").map(\.id), ["device", "theme"])
    }
    func testCloudMergeUsesSeparateCloudCASAndRetainsConflictsAcrossRestart() throws {
        var state = AuthoringStoreState()
        try insert(preference(), in: &state)
        let sent = state.outbox
        var remote = preference(revision: 7)
        AuthoringStore.mergeCloud(records: [remote], accepted: ["theme": 7], sent: sent, conflicts: [:], in: &state)
        XCTAssertEqual(state.records["theme"]?.revision, 1)
        XCTAssertEqual(state.cloudRevisions["theme"], 7)
        XCTAssertTrue(state.outbox.isEmpty)
        let local = preference(revision: 2, value: "blue")
        try AuthoringStore.mutate(.init(kind: "upsert", id: "theme", expectedRevision: 1, record: local), originRequestID: "request-a", in: &state)
        XCTAssertEqual(state.outbox.first?.mutation.expectedRevision, 7)
        XCTAssertEqual(state.outbox.first?.mutation.record?.revision, 8)
        remote.revision = 8; remote.value = .string("red")
        AuthoringStore.mergeCloud(records: [remote, preference("independent", revision: 4)], accepted: [:], sent: [], conflicts: ["theme": remote], in: &state)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.records["theme"]?.value, .string("blue"))
        XCTAssertEqual(state.records["independent"]?.value, .string("dark"))
        XCTAssertEqual(state.conflicts.first?.remote?.value, .string("red"))
        try AuthoringStore.resolveConflict(id: "theme", keepingLocal: true, in: &state)
        XCTAssertEqual(state.outbox.first?.baseCloudRevision, 8)
        XCTAssertEqual(state.records["theme"]?.revision, 2)
    }
    func testCloudAcknowledgementDoesNotDropEditMadeDuringSync() throws {
        var state = AuthoringStoreState(); try insert(preference(), in: &state)
        let sent = state.outbox
        let local = preference(revision: 2, value: "blue")
        try AuthoringStore.mutate(.init(kind: "upsert", id: "theme", expectedRevision: 1, record: local), originRequestID: "request-a", in: &state)
        let overlapping = state.outbox
        AuthoringStore.mergeCloud(records: [preference(revision: 1)], accepted: ["theme": 1], sent: sent, conflicts: [:], in: &state)
        XCTAssertNotEqual(state.outbox.first?.id, overlapping.first?.id, "Rebased wire payload requires a fresh immutable operation ID")
        XCTAssertEqual(state.records["theme"]?.value, .string("blue"))
        XCTAssertEqual(state.outbox.count, 1)
        XCTAssertEqual(state.outbox[0].baseCloudRevision, 1)
        XCTAssertTrue(state.conflicts.isEmpty)
        let rebasedID = state.outbox[0].id
        // B may already have reached Cloud with its old nil base and received a conflict.
        AuthoringStore.mergeCloud(records: [preference(revision: 1)], accepted: [:], sent: overlapping, conflicts: ["theme": preference(revision: 1)], in: &state)
        XCTAssertEqual(state.outbox[0].id, rebasedID)
        XCTAssertTrue(state.conflicts.isEmpty, "A stale response must not conflict the freshly rebased payload")
    }
    func testDeleteWhileInitialCloudCreateIsInFlightIsNotRevived() throws {
        var state = AuthoringStoreState(); try insert(preference(), in: &state)
        let sent = state.outbox
        try AuthoringStore.mutate(.init(kind: "delete", id: "theme", expectedRevision: 1), originRequestID: "settings-delete", in: &state)
        AuthoringStore.mergeCloud(records: [preference()], accepted: ["theme": 1], sent: sent, conflicts: [:], in: &state)
        XCTAssertTrue(state.records["theme"]!.deleted)
        XCTAssertEqual(state.outbox.first?.mutation.kind, "delete")
        XCTAssertEqual(state.outbox.first?.baseCloudRevision, 1)
    }
    func testRestartAfterUnacknowledgedCloudCreatePreservesLocalDelete() throws {
        var state = AuthoringStoreState(); try insert(preference(), in: &state)
        try AuthoringStore.mutate(.init(kind: "delete", id: "theme", expectedRevision: 1), originRequestID: "settings-delete", in: &state)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        AuthoringStore.mergeCloud(records: [preference()], accepted: [:], sent: [], conflicts: [:], in: &state)
        XCTAssertTrue(state.records["theme"]!.deleted)
        XCTAssertEqual(state.conflicts.first?.remote?.revision, 1)
        try AuthoringStore.resolveConflict(id: "theme", keepingLocal: true, in: &state)
        XCTAssertEqual(state.outbox.first?.mutation.kind, "delete")
    }
    private func request(preferences: [PreferenceRecordV1] = [], base: String? = nil) throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: "request-a", createdAt: 1_000, deadlineAt: 10_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], preferences: preferences,
            context: .init(profileID: "profile-a", deviceID: "device-a", screenID: "screen-a", baseRevision: base, userRequest: "Remember to always use dark colors.", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "fixture")))
    }
    private func result(for request: AuthoringRequestV1) -> AuthoringResultV1 {
        .init(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
              preferenceRevisions: Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id, $0.revision) }), operationID: "operation-a", answer: "Done")
    }
    func testReceiptReplayAfterRestartAndOperationReuseRejected() throws {
        var state = AuthoringStoreState(); let input = try request()
        try AuthoringStore.saveRequest(input, in: &state)
        let output = result(for: input)
        let receipt = try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 2_000)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: "different", cancelled: true, now: 20_000), receipt)
        var reused = output; reused.answer = "Different content"
        XCTAssertThrowsError(try AuthoringStore.apply(reused, to: &state, currentScreenRevision: nil, now: 2_000))
        var changed = input; changed.context.userRequest = "Different request"
        changed = try AuthoringContract.seal(changed)
        XCTAssertThrowsError(try AuthoringStore.saveRequest(changed, in: &state))
    }
    func testStaleScreenPreferenceDeadlineAndBindingCannotApply() throws {
        let input = try request()
        var initial = AuthoringStoreState(); try AuthoringStore.saveRequest(input, in: &initial)
        var state = initial
        XCTAssertEqual(try AuthoringStore.apply(result(for: input), to: &state, currentScreenRevision: "newer", now: 2_000).status, "conflict")
        state = initial
        XCTAssertEqual(try AuthoringStore.apply(result(for: input), to: &state, currentScreenRevision: nil, now: 10_000).status, "rejected")
        state = initial
        XCTAssertEqual(try AuthoringStore.apply(result(for: input), to: &state, currentScreenRevision: nil, cancelled: true, now: 2_000).status, "rejected")
        state = initial; var altered = result(for: input); altered.inputDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try AuthoringStore.apply(altered, to: &state, currentScreenRevision: nil, now: 2_000))
        var withPreference = AuthoringStoreState(); try insert(preference(), in: &withPreference)
        let snapshot = try request(preferences: [preference()]); try AuthoringStore.saveRequest(snapshot, in: &withPreference)
        try AuthoringStore.mutate(.init(kind: "delete", id: "theme", expectedRevision: 1), originRequestID: "settings-delete", in: &withPreference)
        XCTAssertEqual(try AuthoringStore.apply(result(for: snapshot), to: &withPreference, currentScreenRevision: nil, now: 2_000).status, "conflict")
    }
    func testAcknowledgedSourceCompactionKeepsReplayAndRejectsRequestReuse() throws {
        var state = AuthoringStoreState(); let input = try request(); try AuthoringStore.saveRequest(input, in: &state)
        let output = result(for: input)
        let receipt = try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 2_000)
        state.acknowledgedReceiptIDs.insert(receipt.operationID)
        AuthoringStore.compactSources(in: &state)
        XCTAssertNil(state.requests[input.requestID])
        XCTAssertEqual(state.requestDeviceIDs?[input.requestID], input.context.deviceID)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 20_000), receipt)
        var reused = input; reused.context.userRequest = "Changed"; reused = try AuthoringContract.seal(reused)
        XCTAssertThrowsError(try AuthoringStore.saveRequest(reused, in: &state))
    }
    func testScreenScopedPreferenceRequiresInstalledOrResultScreen() throws {
        var state = AuthoringStoreState(); let input = try request(); try AuthoringStore.saveRequest(input, in: &state)
        var output = result(for: input)
        output.preferenceMutations = [.init(kind: "upsert", id: "screen-theme", expectedRevision: nil, record: preference("screen-theme", scope: "screen", target: "screen-a"))]
        output.durablePreferenceAuthorization = .init(requestID: input.requestID, quote: input.context.userRequest)
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 2_000).status, "rejected")
        XCTAssertTrue(state.records.isEmpty)
    }
    func testMoreThan32TerminalRequestsReleaseSourceWithoutLosingBindings() throws {
        var state = AuthoringStoreState()
        var first: AuthoringRequestV1?
        for index in 0..<65 {
            var input = try request(); input.requestID = "terminal-\(index)"; input = try AuthoringContract.seal(input)
            if first == nil { first = input }
            try AuthoringStore.saveRequest(input, in: &state)
            AuthoringStore.retireRequest(id: input.requestID, in: &state)
            state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        }
        XCTAssertTrue(state.requests.isEmpty)
        XCTAssertEqual(state.requestDigests.count, 65)
        XCTAssertEqual(state.retiredRequestIDs?.count, 65)
        XCTAssertEqual(state.requestDeviceIDs?.count, 65)
        XCTAssertTrue(state.knownScreenIDs?.contains("screen-a") == true)
        let retired = try XCTUnwrap(first)
        // Exact retry cannot restore a terminal snapshot and allow a late install.
        try AuthoringStore.saveRequest(retired, in: &state)
        XCTAssertNil(state.requests[retired.requestID])
        XCTAssertThrowsError(try AuthoringStore.apply(result(for: retired), to: &state, currentScreenRevision: nil, now: 2_000))
        var changed = retired; changed.context.userRequest = "Changed"; changed = try AuthoringContract.seal(changed)
        XCTAssertThrowsError(try AuthoringStore.saveRequest(changed, in: &state))
        let next = try request(); try AuthoringStore.saveRequest(next, in: &state)
        XCTAssertNotNil(state.requests[next.requestID])
    }
    func testNativePackageRejectionDoesNotCommitPreparedPreferenceMutations() throws {
        var state = AuthoringStoreState(); let input = try request(); try AuthoringStore.saveRequest(input, in: &state)
        var output = result(for: input)
        output.preferenceMutations = [.init(kind: "upsert", id: "theme", expectedRevision: nil, record: preference())]
        output.durablePreferenceAuthorization = .init(requestID: input.requestID, quote: input.context.userRequest)
        var prepared = state
        XCTAssertEqual(try AuthoringStore.apply(output, to: &prepared, currentScreenRevision: nil, now: 2_000).status, "applied")
        let rejected = try AuthoringStore.reject(output, reason: "Native manifest validation failed", in: &state, now: 2_000)
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertTrue(state.records.isEmpty); XCTAssertTrue(state.outbox.isEmpty)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 2_000), rejected)
    }
    func testJournalRecoveryAtEveryCrashCutCommitsWholeIndex() throws {
        struct Index: Codable, Equatable { var screen: String; var preferences: AuthoringStoreState }
        enum SimulatedCrash: Error { case stopped }
        for cut in AuthoringJournal.Cut.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Screenpunk-AuthoringStoreTests-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let initial = Index(screen: "old", preferences: .init())
            try AuthoringJournal(root: root).commit(JSONEncoder().encode(initial))
            let package = root.appendingPathComponent("new-package"); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("new screen".utf8).write(to: package.appendingPathComponent("index.html"))
            var next = initial; next.screen = "new-package"; try insert(preference(), in: &next.preferences)
            let interrupted = try AuthoringJournal(root: root, fault: { if $0 == cut { throw SimulatedCrash.stopped } })
            XCTAssertThrowsError(try interrupted.commit(JSONEncoder().encode(next), stagedDirectory: "new-package"))
            XCTAssertThrowsError(try interrupted.commit(JSONEncoder().encode(initial)), "An in-process second write must fail closed until recovery")
            let recovered = try JSONDecoder().decode(Index.self, from: XCTUnwrap(try AuthoringJournal(root: root).recover()))
            XCTAssertEqual(recovered, cut == .assetsDurable ? initial : next)
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("index.html").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("authoring-journal.json").path))
        }
    }
    func testV2RequestPinQuotaScopeAndOneTerminalOperation() throws {
        let screen = AuthoringScreen(title: "Fixture", files: [.init(path: "index.html", content: "<html></html>")])
        var legacy = try request(base: "revision"); legacy.context.currentScreen = screen; legacy = try AuthoringContract.seal(legacy)
        let input = try AuthoringV2Contract.makeRequest(from: legacy, libraryID: "library-a")
        let count = input.context.currentScreen!.files.reduce(0) { $0 + $1.byteLength }
        let pin = AuthoringRevisionPin(requestID: input.requestID, profileID: "profile-a", libraryID: "library-a", screenID: "screen-a", revision: "revision", byteLength: count)
        var state = AuthoringStoreState()
        XCTAssertThrowsError(try AuthoringStore.saveRequest(input, pin: nil, in: &state))
        var foreign = pin; foreign.libraryID = "foreign"
        XCTAssertThrowsError(try AuthoringStore.saveRequest(input, pin: foreign, in: &state))
        try AuthoringStore.saveRequest(input, pin: pin, in: &state)
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.revisionPins?[input.requestID], pin)
        let output = AuthoringResultV2(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, baseRevision: input.context.baseRevision, preferenceRevisions: [:], operationID: "operation-v2", answer: "Done")
        let receipt = try AuthoringStore.apply(output, to: &state, currentScreenRevision: "revision", now: 2000)
        XCTAssertEqual(receipt.status, "applied"); XCTAssertNil(state.revisionPins?[input.requestID])
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: "changed", now: 90000), receipt)
        var duplicate = output; duplicate.operationID = "second-operation"
        XCTAssertThrowsError(try AuthoringStore.apply(duplicate, to: &state, currentScreenRevision: "revision", now: 2000))
        state.acknowledgedReceiptIDs.insert(receipt.operationID); AuthoringStore.compactSources(in: &state)
        XCTAssertNil(state.requestsV2?[input.requestID])
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 90000), receipt)
        var unfinished = AuthoringStoreState()
        for index in 0..<32 {
            var value = input; value.requestID = "unfinished-\(index)"; value = try AuthoringV2Contract.seal(value)
            var owned = pin; owned.requestID = value.requestID
            try AuthoringStore.saveRequest(value, pin: owned, in: &unfinished)
        }
        var overflow = input; overflow.requestID = "overflow"; overflow = try AuthoringV2Contract.seal(overflow)
        var overflowPin = pin; overflowPin.requestID = overflow.requestID
        XCTAssertThrowsError(try AuthoringStore.saveRequest(overflow, pin: overflowPin, in: &unfinished))
        AuthoringStore.retireRequest(id: "unfinished-0", in: &unfinished)
        XCTAssertNil(unfinished.revisionPins?["unfinished-0"])
        try AuthoringStore.saveRequest(overflow, pin: overflowPin, in: &unfinished)
    }

    func testPermanentCancellationTombstoneRejectsV2WithoutOptionalCallerFlag() throws {
        let input = try AuthoringV2Contract.makeRequest(from: request(), libraryID: "library-a")
        var state = AuthoringStoreState(); try AuthoringStore.saveRequest(input, pin: nil, in: &state)
        state.cancelledRequestIDs = [input.requestID]
        state = try JSONDecoder().decode(AuthoringStoreState.self, from: JSONEncoder().encode(state))
        let output = AuthoringResultV2(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, baseRevision: nil, preferenceRevisions: [:], operationID: "cancelled-v2", answer: "Done")
        XCTAssertEqual(try AuthoringStore.apply(output, to: &state, currentScreenRevision: nil, now: 2000).status, "rejected")
    }

}
