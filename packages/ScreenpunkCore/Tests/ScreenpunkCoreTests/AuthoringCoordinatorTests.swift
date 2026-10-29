import Foundation
import XCTest
@testable import ScreenpunkCore

final class AuthoringCoordinatorTests: XCTestCase {
    @MainActor private final class DurableFixture {
        let root: URL
        let journal: AuthoringJournal
        var state: AuthoringStoreState
        var acknowledgements = 0
        var cancelled: Set<String> = []
        init(root: URL) throws {
            self.root = root; journal = try AuthoringJournal(root: root)
            state = try journal.recover().map { try JSONDecoder().decode(AuthoringStoreState.self, from: $0) } ?? AuthoringStoreState()
        }
        func save(_ request: AuthoringRequestV1) throws {
            var next = state; try AuthoringStore.saveRequest(request, in: &next)
            try journal.commit(JSONEncoder().encode(next)); state = next
        }
        func apply(_ result: AuthoringResultV1) throws -> ApplicationReceiptV1 {
            var next = state
            let receipt = try AuthoringStore.apply(result, to: &next, currentScreenRevision: nil, cancelled: cancelled.contains(result.requestID), now: 2_000)
            try journal.commit(JSONEncoder().encode(next)); state = next
            return receipt
        }
        func coordinator(_ transport: any AuthoringTransport) -> AuthoringCoordinator {
            AuthoringCoordinator(transport: transport, persistRequest: save, applyResult: apply,
                                 persistCancellation: { self.cancelled.insert($0) },
                                 acknowledged: { _ in self.acknowledgements += 1 })
        }
    }

    private func request(id: String = "fixture-request", preferences: [PreferenceRecordV1] = []) throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(AuthoringRequestV1(
            requestID: id, createdAt: 1_000, deadlineAt: 601_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime,
            services: [], preferences: preferences,
            context: AuthoringContextV1(profileID: "local-fixture-profile", deviceID: "fixture-device", screenID: "fixture-screen", userRequest: "Remember to always use large labels on this device.", viewport: .init(width: 1024, height: 768, orientation: "landscape")),
            delivery: .init(route: "fixture")))
    }

    @MainActor func testFixtureTransportUsesDurableApplicationAndNextAgentSeesPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = try DurableFixture(root: root)
        let transport = FixtureAuthoringTransport { request in
            AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest,
                              preferenceRevisions: [:], operationID: "fixture-operation",
                              preferenceMutations: [.init(kind: "upsert", id: "fixture-labels", expectedRevision: nil,
                                  record: .init(id: "fixture-labels", scope: "device", targetID: request.context.deviceID, category: "typography", value: .string("large labels"), revision: 1, originRequestID: request.requestID))],
                              durablePreferenceAuthorization: .init(requestID: request.requestID, quote: request.context.userRequest))
        }
        let coordinator = durable.coordinator(transport)
        let input = try request()
        let ready = try await coordinator.readiness()
        XCTAssertTrue(ready)
        _ = try await coordinator.submit(input)
        _ = try await coordinator.submit(input)
        XCTAssertEqual(transport.productionCount, 1)
        guard case .completed(let result) = try await coordinator.reconcile(requestID: input.requestID) else { return XCTFail("Expected complete fixture result") }
        let receipt = try coordinator.apply(result)
        XCTAssertEqual(receipt.status, "applied")
        XCTAssertEqual(try coordinator.apply(result), receipt)
        try await coordinator.acknowledge(receipt)
        XCTAssertEqual(transport.receipts[input.requestID], receipt)
        XCTAssertEqual(durable.acknowledgements, 1)

        let restarted = try DurableFixture(root: root)
        XCTAssertEqual(restarted.state.records["fixture-labels"]?.revision, 1)
        XCTAssertEqual(restarted.state.outbox.count, 1)
        let applicable = AuthoringStore.preferences(in: restarted.state, profileID: input.context.profileID, deviceID: input.context.deviceID, screenID: input.context.screenID)
        let next = try request(id: "next-agent-request", preferences: applicable)
        let anotherAgent = FixtureAuthoringTransport { request in
            XCTAssertEqual(request.preferences.first?.value, .string("large labels"))
            return AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id, $0.revision) }), operationID: "next-agent-operation", answer: "I will use your saved preference.")
        }
        let nextCoordinator = restarted.coordinator(anotherAgent)
        _ = try await nextCoordinator.submit(next)
        guard case .completed(let nextResult) = try await nextCoordinator.reconcile(requestID: next.requestID) else { return XCTFail("Expected second result") }
        XCTAssertEqual(try nextCoordinator.apply(nextResult).status, "applied")
    }

    @MainActor func testCancelledFixtureCannotApplyLateResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = try DurableFixture(root: root)
        let input = try request()
        let result = AuthoringResultV1(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "cancelled-operation", answer: "late answer")
        let transport = FixtureAuthoringTransport { _ in result }
        let coordinator = durable.coordinator(transport)
        _ = try await coordinator.submit(input)
        try await coordinator.cancel(requestID: input.requestID)
        let reconciled = try await coordinator.reconcile(requestID: input.requestID)
        XCTAssertEqual(reconciled, .ended(status: "cancelled", message: nil))
        XCTAssertEqual(try coordinator.apply(result).status, "rejected")
        XCTAssertTrue(durable.state.records.isEmpty)
    }

    @MainActor func testPersistenceFailurePreventsSubmission() async throws {
        enum DiskFailure: Error { case full }
        let transport = FixtureAuthoringTransport { request in
            AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "should-never-run", answer: "unexpected")
        }
        let coordinator = AuthoringCoordinator(transport: transport, persistRequest: { _ in throw DiskFailure.full }, applyResult: { _ in throw DiskFailure.full }, persistCancellation: { _ in }, acknowledged: { _ in })
        do { _ = try await coordinator.submit(request()); XCTFail("Expected disk failure") }
        catch DiskFailure.full { }
        XCTAssertEqual(transport.productionCount, 0)
    }
}
