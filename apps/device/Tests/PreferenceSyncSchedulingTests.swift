import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

@MainActor private final class SyncGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() }
        if !released { await withCheckedContinuation { completion = $0 } }
    }
    func untilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; completion?.resume(); completion = nil }
}
@MainActor private final class SyncSleeper {
    private var delays: [UInt64] = []
    private var gates: [SyncGate] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep(_ delay: UInt64) async throws {
        let gate = SyncGate(); delays.append(delay); gates.append(gate)
        let ready = countWaiters.filter { $0.0 <= delays.count }; countWaiters.removeAll { $0.0 <= delays.count }; ready.forEach { $0.1.resume() }
        await gate.wait()
        try Task.checkCancellation()
    }
    func untilCount(_ count: Int) async { if delays.count < count { await withCheckedContinuation { countWaiters.append((count, $0)) } } }
    func release(_ index: Int) { gates[index].release() }
    func releaseAll() { gates.forEach { $0.release() } }
    func delay(_ index: Int) -> UInt64 { delays[index] }
}

final class PreferenceSyncSchedulingTests: XCTestCase {
    func testCloudPreferenceEligibilityRequiresTheSameOriginEvenForTheSameServerUser() {
        let staging = CloudOriginScope(origin: "https://staging.screenpunk.xyz")!
        let production = CloudOriginScope(origin: "https://api.screenpunk.xyz")!
        let stagingAccount = staging.localAccountID(serverUserID: "same-google-sub")
        let productionAccount = production.localAccountID(serverUserID: "same-google-sub")
        // Hold wire identifiers equal to prove the local account namespace is sufficient.
        let binding = LocalCloudBinding(accountID: stagingAccount, profileID: "profile", deviceID: "device")
        let profile = LocalProfileDescriptor(id: "staging", libraryOwner: stagingAccount, permissionOwner: stagingAccount, localDeviceID: "installation", cloudBinding: binding)
        XCTAssertTrue(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: stagingAccount, deviceID: "device", profileID: "profile"))
        XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: productionAccount, deviceID: "device", profileID: "profile"))
        XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: nil, deviceID: nil, profileID: nil))
    }
    func testEveryAuthoringRouteCanSyncOnlyItsMatchingCloudBinding() {
        let binding = LocalCloudBinding(accountID: "account", profileID: "wire-profile", deviceID: "device")
        for route in AuthoringRoutePreference.allCases {
            let profile = LocalProfileDescriptor(id: "local-descriptor", libraryOwner: "saved-library", permissionOwner: "saved-library", localDeviceID: "installation", cloudBinding: binding, routePreference: route)
            XCTAssertTrue(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: "account", deviceID: "device", profileID: "wire-profile"))
            XCTAssertTrue(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: "account", deviceID: "device", profileID: nil))
            XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: nil, deviceID: "device", profileID: "wire-profile"))
            XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: "other", deviceID: "device", profileID: "wire-profile"))
            XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: "account", deviceID: "other", profileID: "wire-profile"))
            XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: profile, accountID: "account", deviceID: "device", profileID: "other"))
        }
        let localOnly = LocalProfileDescriptor(id: "offline", libraryOwner: "local", permissionOwner: "local", localDeviceID: "installation")
        XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: localOnly, accountID: "account", deviceID: "device", profileID: "profile"))
        XCTAssertFalse(CloudPreferenceSyncEligibility.matches(profile: nil, accountID: nil, deviceID: nil, profileID: nil))
    }
    @MainActor func testSameBindingCallsShareOneMutationFlight() async {
        let flight = PreferenceSyncSingleFlight<String>(), gate = SyncGate()
        var calls = 0
        let first = Task { await flight.run(binding: "account-a") { calls += 1; await gate.wait(); return false } }
        await gate.untilStarted()
        let second = Task { await flight.run(binding: "account-a") { XCTFail("duplicate mutation call"); return true } }
        await Task.yield(); gate.release()
        let one = await first.value, two = await second.value
        XCTAssertFalse(one); XCTAssertFalse(two); XCTAssertEqual(calls, 1)
    }
    @MainActor func testReplacementBindingWaitsForCancelledFlightBeforeSending() async {
        let flight = PreferenceSyncSingleFlight<String>(), old = SyncGate(), replacement = SyncGate()
        var events: [String] = []
        let first = Task { await flight.run(binding: "old-account") { events.append("old-start"); await old.wait(); XCTAssertTrue(Task.isCancelled); events.append("old-drained"); return true } }
        await old.untilStarted(); flight.cancel()
        let next = Task { await flight.run(binding: "new-account") { events.append("new-start"); await replacement.wait(); return true } }
        await Task.yield(); XCTAssertEqual(events, ["old-start"])
        old.release(); await replacement.untilStarted()
        XCTAssertEqual(events, ["old-start", "old-drained", "new-start"])
        replacement.release(); _ = await first.value; _ = await next.value
    }
    @MainActor func testPumpDoesNotBlockLocalWorkAndCoalescesWakeupsDuringCloudIO() async {
        let sleeper = SyncSleeper(), io = SyncGate()
        let pump = PreferenceSyncPump(sleep: { try await sleeper.sleep($0) })
        defer { pump.cancel(); sleeper.releaseAll() }
        var calls = 0, localApplied = false
        let operation: @MainActor () async -> Bool = { calls += 1; if calls == 1 { await io.wait() }; return true }
        pump.wake(operation); await io.untilStarted()
        // The request/receipt path can proceed while the Cloud operation is suspended.
        localApplied = true
        for _ in 0..<20 { pump.wake(operation) }
        XCTAssertTrue(localApplied); XCTAssertEqual(calls, 1)
        io.release(); await sleeper.untilCount(1)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(sleeper.delay(0), 60_000_000_000)
    }
    @MainActor func testIdlePumpPullsRemoteChangesWithoutLocalEventsAndBacksOffFailures() async {
        let sleeper = SyncSleeper()
        let pump = PreferenceSyncPump(sleep: { try await sleeper.sleep($0) })
        defer { pump.cancel(); sleeper.releaseAll() }
        var calls = 0
        pump.wake { calls += 1; return calls >= 3 }
        await sleeper.untilCount(1); XCTAssertEqual(sleeper.delay(0), 2_000_000_000)
        sleeper.release(0)
        await sleeper.untilCount(2); XCTAssertEqual(sleeper.delay(1), 4_000_000_000)
        sleeper.release(1)
        await sleeper.untilCount(3); XCTAssertEqual(sleeper.delay(2), 60_000_000_000)
        // No edit or authoring event occurs: the idle cadence still performs a pull.
        sleeper.release(2); await sleeper.untilCount(4)
        XCTAssertEqual(calls, 4)
    }
    @MainActor func testCancelledPumpCannotRestartFromAnOldTimer() async {
        let sleeper = SyncSleeper()
        let pump = PreferenceSyncPump(sleep: { try await sleeper.sleep($0) })
        var oldCalls = 0, newCalls = 0
        pump.wake { oldCalls += 1; return true }
        await sleeper.untilCount(1); pump.cancel()
        pump.wake { newCalls += 1; return true }
        await sleeper.untilCount(2)
        sleeper.release(0); await Task.yield()
        XCTAssertEqual(oldCalls, 1); XCTAssertEqual(newCalls, 1)
        pump.cancel(); sleeper.releaseAll()
    }
    @MainActor func testNativeLocalPreferenceCommitSyncsBeforeAckAndOfflineOutboxSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-preference-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "saved-library", rootDirectory: root)
        let request = try AuthoringContract.seal(AuthoringRequestV1(requestID: "local-preference", createdAt: 1_000, deadlineAt: 100_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], context: .init(profileID: "profile", deviceID: "device", screenID: "screen", userRequest: "Always use blue backgrounds", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "local")))
        try library.saveAuthoringRequest(request)
        let record = PreferenceRecordV1(id: "theme", scope: "profile", targetID: "profile", category: "appearance", value: .string("blue"), revision: 1, originRequestID: request.requestID)
        let result = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "local-operation", answer: "Remembered", preferenceMutations: [.init(kind: "upsert", id: record.id, expectedRevision: nil, record: record)], durablePreferenceAuthorization: .init(requestID: request.requestID, quote: request.context.userRequest))
        XCTAssertEqual(try library.applyAuthoringResult(result, now: 2_000).status, "applied")
        // This is the order used by DeviceModel's apply paths: durable commit,
        // pump wake, then awaited Local acknowledgement. No Mac response is needed.
        let ack = SyncGate(), sleeper = SyncSleeper()
        let acknowledgement = Task { await ack.wait() }
        await ack.untilStarted()
        let pump = PreferenceSyncPump(sleep: { try await sleeper.sleep($0) })
        defer { pump.cancel(); sleeper.releaseAll(); ack.release() }
        var calls = 0
        pump.wake {
            calls += 1
            if calls == 1 { return false } // Offline: no local state is discarded.
            let sent = library.preferenceOutbox
            do { try library.applyPreferenceSync(records: [record], accepted: [record.id: 1], sent: sent, conflicts: [:], profileID: "profile", deviceID: "device"); return true }
            catch { XCTFail("unexpected synchronization error: \(error)"); return false }
        }
        await sleeper.untilCount(1)
        XCTAssertEqual(library.preferenceOutbox.count, 1)
        XCTAssertEqual(try ScreenLibrary(accountID: "saved-library", rootDirectory: root).preferenceOutbox.count, 1)
        sleeper.release(0); await sleeper.untilCount(2)
        XCTAssertTrue(library.preferenceOutbox.isEmpty)
        XCTAssertEqual(library.state.authoring?.cloudRevisions[record.id], 1)
        try library.retireAuthoringRequest(id: request.requestID)
        XCTAssertNil(library.authoringRequest(id: request.requestID))
        XCTAssertTrue(library.pendingReceipts(deviceID: "device").isEmpty, "Local receipts must never enter Cloud sync, even after their snapshot retires")
        ack.release(); await acknowledgement.value
    }

}
