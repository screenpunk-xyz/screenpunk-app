import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class HomeAssistantSharedCredentialTests: XCTestCase {
    private func manifest(_ id: String = "one", revision: String = "r1", writes: Bool = false) -> DashboardManifest {
        .init(schemaVersion: 1, dashboardId: id, name: id, revision: revision, entrypoint: "index.html", sdkVersion: "1",
              target: .init(profileId: "ipad", width: 1024, height: 768, scale: 1, orientation: "landscape"),
              connections: [.init(alias: "home", required: true, serviceCalls: writes ? [.init(domain: "light", service: "turn_on", entityIds: ["light.room"])] : [])], files: [])
    }
    func testMultipleScreensSameRevisionAndCodeEditsKeepApprovedScope() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.saveCredential(owner: "user", origin: "https://ha.example", token: "fixture-token")
        try vault.approve(manifest: manifest(), owner: "user")
        try vault.approve(manifest: manifest("two"), owner: "user")
        XCTAssertTrue(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r1"))
        XCTAssertTrue(vault.isConfigured(owner: "user", dashboardID: "two", revision: "r1"))
        XCTAssertTrue(vault.synchronize(manifest: manifest(revision: "r2"), owner: "user"))
        XCTAssertFalse(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r1"))
        XCTAssertTrue(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r2"))
        XCTAssertTrue(vault.isConfigured(owner: "user", dashboardID: "two", revision: "r1"))
        XCTAssertFalse(vault.synchronize(manifest: manifest(revision: "r3", writes: true), owner: "user"))
        XCTAssertFalse(vault.synchronize(manifest: manifest(revision: "r2"), owner: "user"))
        try vault.approve(manifest: manifest(revision: "r3", writes: true), owner: "user")
        XCTAssertTrue(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r3"))
    }
    func testReorderAndNarrowingRetainApprovalButCannotRestoreRemovedPermission() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.saveCredential(owner: "user", origin: "https://ha.example", token: "fixture-token")
        var screen = manifest()
        screen.connections[0].serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.a", "light.b"])]
        screen.connections[0].cameraEntities = ["camera.a", "camera.b"]
        try vault.approve(manifest: screen, owner: "user")
        screen.revision = "r2"
        screen.connections[0].serviceCalls?[0].entityIds.reverse()
        screen.connections[0].cameraEntities?.reverse()
        XCTAssertTrue(vault.synchronize(manifest: screen, owner: "user"))
        screen.revision = "r3"
        screen.connections[0].serviceCalls?[0].entityIds = ["light.a"]
        screen.connections[0].cameraEntities = ["camera.a"]
        XCTAssertTrue(vault.synchronize(manifest: screen, owner: "user"))
        screen.revision = "r4"
        screen.connections[0].serviceCalls?[0].entityIds = ["light.a", "light.b"]
        XCTAssertFalse(vault.synchronize(manifest: screen, owner: "user"))
        XCTAssertFalse(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r3"))
    }
    func testIsolationRevocationAndCredentialReuseCannotMoveSecret() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.saveCredential(owner: "user", origin: "https://ha.example", token: "fixture-token")
        try vault.approve(manifest: manifest(), owner: "user")
        XCTAssertNil(vault.credentialStatus(owner: "other"))
        XCTAssertThrowsError(try vault.approve(manifest: manifest(), owner: "other"))
        try vault.saveCredential(owner: "user", origin: "https://ha.example", token: "")
        XCTAssertThrowsError(try vault.saveCredential(owner: "user", origin: "https://other.example", token: ""))
        try vault.revokeCredential(owner: "user")
        XCTAssertNil(vault.credentialStatus(owner: "user"))
        XCTAssertFalse(vault.isConfigured(owner: "user", dashboardID: "one", revision: "r1"))
    }
    func testLegacyMigrationCarriesCredentialAndUnchangedApprovalToNewRevision() throws {
        let store = MemoryCredentialStore()
        var config = HomeAssistantProvisioning(schemaVersion: 3, dashboardId: "one", connectionId: "home", provisioningId: "p", revision: "old", origin: "https://ha.example", token: "fixture-token")
        config.serviceCalls = []; config.cameraEntities = []
        let record = HomeAssistantDeviceVault.Record(owner: "user", configuration: config, generation: UUID())
        try store.put(JSONEncoder().encode(record), for: "provisioning-v1")
        let vault = HomeAssistantDeviceVault(store: store)
        XCTAssertNil(vault.credentialStatus(owner: "other"))
        XCTAssertTrue(vault.synchronize(manifest: manifest(revision: "new"), owner: "user"))
        XCTAssertEqual(vault.credentialStatus(owner: "user")?.origin, "https://ha.example")
        XCTAssertNil(try store.secret(for: "provisioning-v1"))
        try vault.revokeCredential(owner: "user")
        XCTAssertNil(HomeAssistantDeviceVault(store: store).credentialStatus(owner: "user"))
    }
}
