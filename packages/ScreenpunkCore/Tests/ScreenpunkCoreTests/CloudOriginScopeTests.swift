import XCTest
@testable import ScreenpunkCore

final class CloudOriginScopeTests: XCTestCase {
    private let staging = CloudOriginScope(origin: "https://staging.screenpunk.xyz")!
    private let production = CloudOriginScope(origin: "https://api.screenpunk.xyz")!

    func testCanonicalHTTPSOriginAndValidation() {
        XCTAssertEqual(staging, CloudOriginScope(origin: "HTTPS://STAGING.SCREENPUNK.XYZ:443/"))
        XCTAssertEqual(staging.keychainService, CloudOriginScope(origin: "https://staging.screenpunk.xyz/")?.keychainService)
        XCTAssertNotEqual(staging.keychainService, production.keychainService)
        XCTAssertNotEqual(staging, CloudOriginScope(origin: "https://staging.screenpunk.xyz:8443"))
        for invalid in ["http://staging.screenpunk.xyz", "https://", "https://user@staging.screenpunk.xyz", "https://staging.screenpunk.xyz/api", "https://staging.screenpunk.xyz?env=prod", "https://staging.screenpunk.xyz#fragment", "https://staging.screenpunk.xyz:0"] {
            XCTAssertNil(CloudOriginScope(origin: invalid), invalid)
        }
    }

    func testProductionNeverReadsOrChangesLegacyOrStagingCredentials() throws {
        let vault = FixtureVault()
        let legacy = CloudOriginScope.legacyKeychainService
        for account in ["session", "installation-key"] {
            try vault.write(Data("legacy-\(account)".utf8), service: legacy, account: account)
            try vault.write(Data("staging-\(account)".utf8), service: staging.keychainService, account: account)
        }
        vault.accesses = []
        let store = OriginScopedCloudCredentials(scope: production)
        XCTAssertNil(try store.load(account: "session", vault: vault))
        XCTAssertNil(try store.load(account: "installation-key", vault: vault))
        try store.save(Data("production-session".utf8), account: "session", vault: vault)
        try store.save(Data("production-installation".utf8), account: "installation-key", vault: vault)
        try store.clear(account: "session", vault: vault)
        XCTAssertTrue(vault.accesses.allSatisfy { $0 == production.keychainService })
        XCTAssertEqual(try vault.read(service: legacy, account: "session"), Data("legacy-session".utf8))
        XCTAssertEqual(try vault.read(service: staging.keychainService, account: "installation-key"), Data("staging-installation-key".utf8))
        XCTAssertEqual(try store.load(account: "installation-key", vault: vault), Data("production-installation".utf8))
    }

    func testStagingMigratesBothItemsWithoutLosingIdentityAndSignoutCannotResurrect() throws {
        let vault = FixtureVault()
        let legacy = CloudOriginScope.legacyKeychainService
        let store = OriginScopedCloudCredentials(scope: staging)
        for account in ["session", "installation-key"] {
            let value = Data("old-\(account)".utf8)
            try vault.write(value, service: legacy, account: account)
            XCTAssertEqual(try store.load(account: account, vault: vault), value)
            XCTAssertEqual(try vault.read(service: staging.keychainService, account: account), value)
            XCTAssertNil(try vault.read(service: legacy, account: account))
        }
        // Simulate an interrupted cleanup or an older app writing the legacy slot.
        try vault.write(Data("stale-session".utf8), service: legacy, account: "session")
        vault.failDeletes = true
        try store.clear(account: "session", vault: vault)
        XCTAssertNil(try store.load(account: "session", vault: vault))
        try store.save(Data("next-sign-in".utf8), account: "session", vault: vault)
        XCTAssertEqual(try store.load(account: "session", vault: vault), Data("next-sign-in".utf8))
        XCTAssertEqual(try store.load(account: "installation-key", vault: vault), Data("old-installation-key".utf8))
    }

    func testFailedMigrationPreservesLegacyAndRetryUsesDurableScopedCopy() throws {
        let vault = FixtureVault()
        let store = OriginScopedCloudCredentials(scope: staging)
        let legacy = CloudOriginScope.legacyKeychainService
        try vault.write(Data("legacy".utf8), service: legacy, account: "session")
        vault.failWrites = true
        XCTAssertThrowsError(try store.load(account: "session", vault: vault))
        XCTAssertEqual(try vault.read(service: legacy, account: "session"), Data("legacy".utf8))
        vault.failWrites = false; vault.failDeletes = true
        XCTAssertEqual(try store.load(account: "session", vault: vault), Data("legacy".utf8))
        try store.save(Data("rotated".utf8), account: "session", vault: vault)
        XCTAssertEqual(try store.load(account: "session", vault: vault), Data("rotated".utf8))
    }

    func testUnavailableSecureStorageCannotReportSuccessfulPersistentSignout() throws {
        let vault = FixtureVault()
        let store = OriginScopedCloudCredentials(scope: staging)
        try store.save(Data("session".utf8), account: "session", vault: vault)
        vault.failWrites = true
        XCTAssertThrowsError(try store.clear(account: "session", vault: vault))
        XCTAssertEqual(try store.load(account: "session", vault: vault), Data("session".utf8))
        vault.failWrites = false
        try store.clear(account: "session", vault: vault)
        XCTAssertNil(try store.load(account: "session", vault: vault))
    }

    func testSameServerUserGetsSeparateLocalLibrariesAndWireBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOriginScopeTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalProfileRepository(rootDirectory: root)
        let serverUserID = String(repeating: "a", count: 64)
        let stagingAccount = staging.localAccountID(serverUserID: serverUserID)
        let productionAccount = production.localAccountID(serverUserID: serverUserID)
        XCTAssertEqual(stagingAccount, serverUserID)
        XCTAssertNotEqual(stagingAccount, productionAccount)
        XCTAssertEqual(productionAccount, CloudOriginScope(origin: "https://API.SCREENPUNK.XYZ:443/")!.localAccountID(serverUserID: serverUserID))
        let old = try repository.activateCloudProfile(accountID: stagingAccount, profileID: "staging-profile", deviceID: "staging-device")
        let new = try repository.activateCloudProfile(accountID: productionAccount, profileID: "production-profile", deviceID: "production-device")
        XCTAssertNotEqual(old.id, new.id)
        XCTAssertNotEqual(old.libraryOwner, new.libraryOwner)
        XCTAssertNotEqual(old.permissionOwner, new.permissionOwner)
        XCTAssertEqual(old.authoringProfileID, "staging-profile")
        XCTAssertEqual(new.authoringProfileID, "production-profile")
        XCTAssertEqual(new.authoringDeviceID, "production-device")
        let request = try AuthoringContract.seal(AuthoringRequestV1(requestID: "origin-test", createdAt: 1_000, deadlineAt: 100_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], context: .init(profileID: new.authoringProfileID, deviceID: new.authoringDeviceID, screenID: "screen", userRequest: "Create a clock", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "cloud")))
        let wire = try AuthoringV2Contract.makeRequest(from: request, libraryID: new.libraryOwner)
        XCTAssertEqual(wire.context.libraryID, productionAccount)
        XCTAssertEqual(wire.context.profileID, "production-profile")
        XCTAssertEqual(wire.context.deviceID, "production-device")
        XCTAssertEqual(try repository.activateAccountProfile(accountID: stagingAccount, deviceID: "staging-device").id, old.id)
        XCTAssertEqual(try repository.activateAccountProfile(accountID: productionAccount, deviceID: "production-device").id, new.id)
    }

    func testAlternatingOriginLaunchesRestoreEachCloudLibraryWithoutSigningInAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOriginLaunchTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalProfileRepository(rootDirectory: root)
        let serverUserID = "same-google-sub"
        let stagingProfile = try repository.activateCloudProfile(accountID: staging.localAccountID(serverUserID: serverUserID), profileID: "staging-profile", deviceID: "staging-device")
        let productionProfile = try repository.activateCloudProfile(accountID: production.localAccountID(serverUserID: serverUserID), profileID: "production-profile", deviceID: "production-device")
        for (scope, expected) in [(staging, stagingProfile), (production, productionProfile), (staging, stagingProfile), (production, productionProfile)] {
            let selected = try repository.snapshot().activeProfile
            XCTAssertTrue(scope.shouldRestoreAccountProfile(activeProfile: selected, serverUserID: serverUserID))
            let restored = try repository.activateAccountProfile(accountID: scope.localAccountID(serverUserID: serverUserID), deviceID: expected.authoringDeviceID)
            XCTAssertEqual(restored, expected)
            XCTAssertEqual(try repository.snapshot().activeProfile?.id, expected.id)
            XCTAssertFalse(scope.shouldRestoreAccountProfile(activeProfile: restored, serverUserID: serverUserID))
        }
        XCTAssertTrue(staging.shouldRestoreAccountProfile(activeProfile: stagingProfile, serverUserID: "different-account"))
        XCTAssertEqual(try repository.snapshot().profiles.count, 2)
    }

    func testPreviousCloudLibraryRemainsSelectableForLocalUseAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOriginPreviousLibraryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalProfileRepository(rootDirectory: root)
        let previous = try repository.activateCloudProfile(accountID: staging.localAccountID(serverUserID: "same-google-sub"), profileID: "previous-profile", deviceID: "previous-device")
        let current = try repository.activateCloudProfile(accountID: production.localAccountID(serverUserID: "same-google-sub"), profileID: "current-profile", deviceID: "current-device")
        XCTAssertTrue(production.shouldRestoreAccountProfile(activeProfile: previous, serverUserID: "same-google-sub"))
        try repository.setRoutePreference(.local, profileID: previous.id)
        try repository.activateProfile(id: previous.id)
        let restarted = try LocalProfileRepository(rootDirectory: root).snapshot()
        let selected = try XCTUnwrap(restarted.activeProfile)
        XCTAssertEqual(selected.id, previous.id)
        XCTAssertEqual(selected.cloudBinding, previous.cloudBinding)
        XCTAssertEqual(selected.libraryOwner, previous.libraryOwner)
        XCTAssertEqual(selected.permissionOwner, previous.permissionOwner)
        XCTAssertEqual(selected.routePreference, .local)
        XCTAssertFalse(production.shouldRestoreAccountProfile(activeProfile: selected, serverUserID: "same-google-sub"))
        XCTAssertNotEqual(selected.cloudBinding?.accountID, current.cloudBinding?.accountID)
        XCTAssertEqual(restarted.profiles.count, 2)
    }

    func testRestoredSessionPreservesIntentionalLocalOnlySelectionButReselectsForeignLinkedProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOriginLocalSelectionTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalProfileRepository(rootDirectory: root)
        let local = try repository.createLocalProfile()
        for scope in [staging, production] {
            XCTAssertFalse(scope.shouldRestoreAccountProfile(activeProfile: local, serverUserID: "same-google-sub"))
            XCTAssertTrue(scope.shouldRestoreAccountProfile(activeProfile: nil, serverUserID: "same-google-sub"))
        }
        var linked = local
        linked.cloudBinding = .init(accountID: staging.localAccountID(serverUserID: "same-google-sub"), profileID: "staging-profile", deviceID: "staging-device")
        XCTAssertFalse(staging.shouldRestoreAccountProfile(activeProfile: linked, serverUserID: "same-google-sub"))
        XCTAssertTrue(production.shouldRestoreAccountProfile(activeProfile: linked, serverUserID: "same-google-sub"))
        XCTAssertEqual(try repository.snapshot().activeProfile, local)
    }
}

private final class FixtureVault: CloudCredentialVault {
    private var values: [String: Data] = [:]
    var accesses: [String] = []
    var failWrites = false
    var failDeletes = false
    private enum Failure: Error { case unavailable }
    private func key(_ service: String, _ account: String) -> String { service + "\n" + account }
    func read(service: String, account: String) throws -> Data? {
        accesses.append(service); return values[key(service, account)]
    }
    func write(_ data: Data, service: String, account: String) throws {
        accesses.append(service)
        if failWrites { throw Failure.unavailable }
        values[key(service, account)] = data
    }
    func delete(service: String, account: String) throws {
        accesses.append(service)
        if failDeletes { throw Failure.unavailable }
        values.removeValue(forKey: key(service, account))
    }
}
