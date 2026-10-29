import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class NewRequestRoutePolicyTests: XCTestCase {
    func testAutomaticPrefersReadyComputerRegardlessOfCloudState() {
        for cloud in [NewRequestRoutePolicy.CloudState.notConfigured, .notReady, .ready(supportsV2: false), .ready(supportsV2: true)] {
            XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .ready, cloud: cloud, requiresV2: true), .use(.local, contractVersion: 2))
        }
    }
    func testAutomaticUnavailableComputerUsesOnlyReadyConfiguredCloud() {
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .unavailable, cloud: .unchecked, requiresV2: true), .checkCloud)
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .unavailable, cloud: .notConfigured, requiresV2: true), .connectCloud)
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .unavailable, cloud: .notReady, requiresV2: true), .listenCloud)
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .unavailable, cloud: .ready(supportsV2: true), requiresV2: true), .use(.cloud, contractVersion: 2))
    }
    func testIdentityOrCredentialRepairNeverFallsBackAutomatically() {
        for cloud in [NewRequestRoutePolicy.CloudState.notConfigured, .notReady, .ready(supportsV2: true)] {
            XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .automatic, local: .repairRequired, cloud: cloud, requiresV2: false), .repairComputer)
        }
    }
    func testExplicitLocalNeverWidensToCloud() {
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .local, local: .unavailable, cloud: .ready(supportsV2: true), requiresV2: false), .needsComputer)
        XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .local, local: .repairRequired, cloud: .ready(supportsV2: true), requiresV2: true), .repairComputer)
    }
    func testExplicitCloudCanBeSelectedWithoutAComputer() {
        for local in [NewRequestRoutePolicy.LocalState.ready, .unavailable, .repairRequired] {
            XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: .cloud, local: local, cloud: .ready(supportsV2: true), requiresV2: true), .use(.cloud, contractVersion: 2))
        }
    }
    func testNoAssetEditDowngradesToV1ToUseCloud() {
        for preference in [AuthoringRoutePreference.automatic, .cloud] {
            XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: preference, local: .unavailable, cloud: .ready(supportsV2: false), requiresV2: true), .updateCloud)
            XCTAssertEqual(NewRequestRoutePolicy.resolve(preference: preference, local: .unavailable, cloud: .ready(supportsV2: false), requiresV2: false), .use(.cloud, contractVersion: 1))
        }
    }
}

final class PreparedRequestRecoveryPolicyTests: XCTestCase {
    func testOnlyExactUnambiguousAcknowledgedNativeReceiptSettlesPending() {
        let receipt = ApplicationReceiptV1(requestID: "original-id", operationID: "operation-one", inputDigest: "bound-digest", status: "applied", appliedAt: 100)
        XCTAssertEqual(PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: "original-id", receipts: [receipt.operationID: receipt], acknowledgedReceiptIDs: [receipt.operationID]), receipt)
        XCTAssertNil(PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: "another-id", receipts: [receipt.operationID: receipt], acknowledgedReceiptIDs: [receipt.operationID]))
        XCTAssertNil(PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: "original-id", receipts: [receipt.operationID: receipt], acknowledgedReceiptIDs: []))
        XCTAssertNil(PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: "original-id", receipts: ["wrong-map-key": receipt], acknowledgedReceiptIDs: [receipt.operationID]))
        var duplicate = receipt; duplicate.operationID = "operation-two"
        XCTAssertNil(PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: "original-id", receipts: [receipt.operationID: receipt, duplicate.operationID: duplicate], acknowledgedReceiptIDs: [receipt.operationID, duplicate.operationID]))
    }
    func testPreparedCloudRetryKeepsOriginalRequestAndRoute() {
        XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: .cloud, deadlineAt: 200, now: 100, hasReceipt: false, submissionKey: "original-id", cancelled: false), .retrySameRequest(requestID: "original-id", route: .cloud))
        XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: .local, deadlineAt: 200, now: 100, hasReceipt: false, submissionKey: "original-id", cancelled: false), .retrySameRequest(requestID: "original-id", route: .local))
    }
    func testAcceptedOrMismatchedSubmissionIsOnlyReconciled() {
        for key in [nil, "another-id"] as [String?] {
            XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: .cloud, deadlineAt: 200, now: 100, hasReceipt: false, submissionKey: key, cancelled: false), .reconcile)
        }
    }
    func testNativeReceiptIsAcknowledgedEvenAfterDeadlineOrCancellation() {
        for route in [AuthoringRoute.cloud, .local] {
            XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: route, deadlineAt: 200, now: 300, hasReceipt: true, submissionKey: "original-id", cancelled: false), .acknowledgeReceipt)
            XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: route, deadlineAt: 200, now: 300, hasReceipt: true, submissionKey: "original-id", cancelled: true), .acknowledgeReceipt)
        }
    }
    func testExpiredOrCancelledPreparedDeliveryCannotBeRetried() {
        XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: .cloud, deadlineAt: 200, now: 200, hasReceipt: false, submissionKey: "original-id", cancelled: false), .cancelExpired)
        XCTAssertEqual(PreparedRequestRecoveryPolicy.action(requestID: "original-id", route: .cloud, deadlineAt: 200, now: 100, hasReceipt: false, submissionKey: "original-id", cancelled: true), .cancelled)
    }
}

@MainActor private final class ControlledLocalDisconnect {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finish: CheckedContinuation<Void, Never>?
    func run() async {
        started = true
        let waiters = startWaiters; startWaiters = []
        waiters.forEach { $0.resume() }
        if !released { await withCheckedContinuation { finish = $0 } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() { released = true; finish?.resume(); finish = nil }
}
final class LocalConnectionLifecycleBarrierTests: XCTestCase {
    @MainActor func testReconnectWaitsForV1AndV2DisconnectsQueuedDuringEarlierStop() async {
        let barrier = LocalConnectionLifecycleBarrier()
        let oldV1 = ControlledLocalDisconnect(), oldV2 = ControlledLocalDisconnect()
        var events: [String] = []
        barrier.enqueue { events.append("v1-start"); await oldV1.run(); events.append("v1-end") }
        await oldV1.waitUntilStarted()
        let reconnect = Task { await barrier.wait(); events.append("reconnect") }
        // A second stop can arrive while the first one is suspended. Reconnect
        // must drain this teardown too, rather than waiting for one captured task.
        barrier.enqueue { events.append("v2-start"); await oldV2.run(); events.append("v2-end") }
        oldV1.release()
        await oldV2.waitUntilStarted()
        XCTAssertEqual(events, ["v1-start", "v1-end", "v2-start"])
        oldV2.release()
        await reconnect.value
        XCTAssertEqual(events, ["v1-start", "v1-end", "v2-start", "v2-end", "reconnect"])
    }
    @MainActor func testLaterStopIsNotSkippedAfterEarlierTeardownCompleted() async {
        let barrier = LocalConnectionLifecycleBarrier()
        await barrier.wait()
        var events: [String] = []
        barrier.enqueue { events.append("first-close") }
        await barrier.wait()
        let later = ControlledLocalDisconnect()
        barrier.enqueue { events.append("later-close-start"); await later.run(); events.append("later-close-end") }
        await later.waitUntilStarted()
        let reconnect = Task { await barrier.wait(); events.append("later-reconnect") }
        XCTAssertEqual(events, ["first-close", "later-close-start"])
        later.release(); await reconnect.value
        XCTAssertEqual(events, ["first-close", "later-close-start", "later-close-end", "later-reconnect"])
    }
}

final class StatusMessagePresentationStateTests: XCTestCase {
    private func dismiss(_ state: inout StatusMessagePresentationState, id: UUID, busy: Bool = false, requestPending: Bool = false, routeChangeBlocked: Bool = false, canRetry: Bool = false, canCancelRequest: Bool = false) -> Bool {
        state.dismiss(id: id, busy: busy, requestPending: requestPending, routeChangeBlocked: routeChangeBlocked, canRetry: canRetry, canCancelRequest: canCancelRequest)
    }
    func testIdleDismissalPreservesOriginalMessageAndIsIdempotent() throws {
        var state = StatusMessagePresentationState()
        state.update("Background updated. The saved image is unchanged.")
        let message = try XCTUnwrap(state.presentedMessage)
        XCTAssertTrue(dismiss(&state, id: message.id))
        XCTAssertNil(state.presentedMessage)
        XCTAssertEqual(state.message, message)
        XCTAssertFalse(dismiss(&state, id: message.id))
    }
    func testOlderCallbackCannotDismissNewCompletionEvenWithIdenticalText() throws {
        var state = StatusMessagePresentationState()
        state.update("Preference saved")
        let original = try XCTUnwrap(state.presentedMessage)
        state.update("Preference saved")
        let next = try XCTUnwrap(state.presentedMessage)
        XCTAssertNotEqual(original.id, next.id)
        XCTAssertFalse(dismiss(&state, id: original.id))
        XCTAssertEqual(state.presentedMessage, next)
        state.update("Screen updated")
        let newest = try XCTUnwrap(state.presentedMessage)
        XCTAssertFalse(dismiss(&state, id: next.id))
        XCTAssertEqual(state.presentedMessage, newest)
    }
    func testAnyOutstandingWorkOrRecoveryControlPreventsDismissal() throws {
        var state = StatusMessagePresentationState()
        state.update("Delivery needs attention")
        let message = try XCTUnwrap(state.presentedMessage)
        XCTAssertFalse(dismiss(&state, id: message.id, busy: true))
        XCTAssertFalse(dismiss(&state, id: message.id, requestPending: true))
        XCTAssertFalse(dismiss(&state, id: message.id, routeChangeBlocked: true))
        XCTAssertFalse(dismiss(&state, id: message.id, canRetry: true))
        XCTAssertFalse(dismiss(&state, id: message.id, canCancelRequest: true))
        XCTAssertEqual(state.presentedMessage, message)
        XCTAssertTrue(dismiss(&state, id: message.id))
    }
    func testClearingOrReassigningInvalidatesDismissalIdentity() throws {
        var state = StatusMessagePresentationState()
        state.update("Screen updated")
        let original = try XCTUnwrap(state.presentedMessage)
        XCTAssertTrue(dismiss(&state, id: original.id))
        state.update(nil)
        XCTAssertNil(state.message)
        XCTAssertFalse(dismiss(&state, id: original.id))
        state.update("Screen updated")
        let next = try XCTUnwrap(state.presentedMessage)
        XCTAssertNotEqual(next.id, original.id)
        XCTAssertFalse(dismiss(&state, id: original.id))
        XCTAssertEqual(state.presentedMessage, next)
    }
}
