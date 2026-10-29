import Foundation

public enum AuthoringRoute: String, Codable, Sendable { case local, cloud }
public enum AuthoringRoutePreference: String, Codable, CaseIterable, Sendable { case automatic, local, cloud }
public struct LocalCloudBinding: Codable, Equatable, Sendable {
    public var accountID: String
    public var profileID: String
    public var deviceID: String
    public init(accountID: String, profileID: String, deviceID: String) {
        self.accountID = accountID; self.profileID = profileID; self.deviceID = deviceID
    }
}
public struct LocalProfileDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var libraryOwner: String
    public var permissionOwner: String
    public var localDeviceID: String
    public var cloudBinding: LocalCloudBinding?
    public var preferredRoute: AuthoringRoute
    public var routePreference: AuthoringRoutePreference
    public init(id: String, libraryOwner: String, permissionOwner: String, localDeviceID: String, cloudBinding: LocalCloudBinding? = nil, preferredRoute: AuthoringRoute? = nil, routePreference: AuthoringRoutePreference? = nil) {
        self.id = id; self.libraryOwner = libraryOwner; self.permissionOwner = permissionOwner
        self.localDeviceID = localDeviceID; self.cloudBinding = cloudBinding; self.preferredRoute = preferredRoute ?? .local
        self.routePreference = routePreference ?? preferredRoute.map { $0 == .local ? .local : .cloud } ?? .automatic
    }
    private enum CodingKeys: String, CodingKey { case id, libraryOwner, permissionOwner, localDeviceID, cloudBinding, preferredRoute, routePreference }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), libraryOwner: try c.decode(String.self, forKey: .libraryOwner), permissionOwner: try c.decode(String.self, forKey: .permissionOwner), localDeviceID: try c.decode(String.self, forKey: .localDeviceID), cloudBinding: try c.decodeIfPresent(LocalCloudBinding.self, forKey: .cloudBinding), preferredRoute: try c.decodeIfPresent(AuthoringRoute.self, forKey: .preferredRoute), routePreference: try c.decodeIfPresent(AuthoringRoutePreference.self, forKey: .routePreference))
    }
    public var authoringProfileID: String { cloudBinding?.profileID ?? id }
    public var authoringDeviceID: String { cloudBinding?.deviceID ?? localDeviceID }
}
public struct LocalProfileState: Codable, Equatable, Sendable {
    public var installationID: String
    public var localDeviceID: String
    public var profiles: [LocalProfileDescriptor]
    public var activeProfileID: String?
    public var activeProfile: LocalProfileDescriptor? { profiles.first { $0.id == activeProfileID } }
    public init(installationID: String = UUID().uuidString, localDeviceID: String = UUID().uuidString, profiles: [LocalProfileDescriptor] = [], activeProfileID: String? = nil) {
        self.installationID = installationID; self.localDeviceID = localDeviceID; self.profiles = profiles; self.activeProfileID = activeProfileID
    }
}

/// Local identity survives sign-out. Account selection chooses a distinct library without moving credentials.
public final class LocalProfileRepository: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let file: LocalDurableFile<LocalProfileState>
    public init(rootDirectory: URL? = nil) throws {
        file = try .init(kind: "profiles", rootDirectory: rootDirectory)
        if try file.load() == nil { try file.save(.init()) }
    }
    public func snapshot() throws -> LocalProfileState { try lock.locallyLocked { try load() } }
    private func load() throws -> LocalProfileState {
        guard let state = try file.load() else { throw LocalPersistenceError.invalid("Local identity is missing.") }
        return state
    }
    @discardableResult public func createLocalProfile() throws -> LocalProfileDescriptor {
        try lock.locallyLocked {
            var state = try load(); let id = UUID().uuidString
            let profile = LocalProfileDescriptor(id: id, libraryOwner: "local:" + id, permissionOwner: "local:" + id, localDeviceID: state.localDeviceID)
            state.profiles.append(profile); state.activeProfileID = id; try file.save(state); return profile
        }
    }
    public func activateProfile(id: String) throws {
        try lock.locallyLocked {
            var state = try load()
            guard state.profiles.contains(where: { $0.id == id }) else { throw LocalPersistenceError.invalid("This local profile is missing.") }
            state.activeProfileID = id; try file.save(state)
        }
    }
    /// Opens a known signed-in legacy account library even before profile enrollment is reachable.
    @discardableResult public func activateAccountProfile(accountID: String, deviceID: String) throws -> LocalProfileDescriptor {
        try lock.locallyLocked {
            guard !accountID.isEmpty, !deviceID.isEmpty, !accountID.hasPrefix("local:") else { throw LocalPersistenceError.invalid("The existing account identity is incomplete.") }
            var state = try load()
            if let existing = state.profiles.first(where: { $0.cloudBinding?.accountID == accountID || ($0.libraryOwner == accountID && $0.permissionOwner == accountID) }) {
                state.activeProfileID = existing.id; try file.save(state); return existing
            }
            let profile = LocalProfileDescriptor(id: UUID().uuidString, libraryOwner: accountID, permissionOwner: accountID, localDeviceID: deviceID, preferredRoute: .cloud, routePreference: .automatic)
            state.profiles.append(profile); state.activeProfileID = profile.id; try file.save(state); return profile
        }
    }
    @discardableResult public func activateCloudProfile(accountID: String, profileID: String, deviceID: String) throws -> LocalProfileDescriptor {
        try lock.locallyLocked {
            guard !accountID.isEmpty, !profileID.isEmpty, !deviceID.isEmpty else { throw LocalPersistenceError.invalid("Cloud identity is incomplete.") }
            var state = try load()
            if let existing = state.profiles.first(where: { $0.cloudBinding?.accountID == accountID || ($0.cloudBinding == nil && $0.libraryOwner == accountID && $0.permissionOwner == accountID) }) {
                guard existing.cloudBinding == nil || existing.cloudBinding?.profileID == profileID else { throw LocalPersistenceError.conflict("This account is already bound to another profile.") }
                state.activeProfileID = existing.id
                var updated = existing; updated.cloudBinding = .init(accountID: accountID, profileID: profileID, deviceID: deviceID)
                state.profiles[state.profiles.firstIndex(where: { $0.id == existing.id })!] = updated
                try file.save(state); return updated
            }
            let profile = LocalProfileDescriptor(id: UUID().uuidString, libraryOwner: accountID, permissionOwner: accountID, localDeviceID: state.localDeviceID, cloudBinding: .init(accountID: accountID, profileID: profileID, deviceID: deviceID), preferredRoute: .cloud, routePreference: .automatic)
            state.profiles.append(profile); state.activeProfileID = profile.id; try file.save(state); return profile
        }
    }
    public func setPreferredRoute(_ route: AuthoringRoute, profileID: String) throws {
        try lock.locallyLocked {
            var state = try load()
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { throw LocalPersistenceError.invalid("This local profile is missing.") }
            guard route != .cloud || state.profiles[index].cloudBinding != nil || !state.profiles[index].libraryOwner.hasPrefix("local:") else { throw LocalPersistenceError.invalid("Link this profile to Cloud first.") }
            state.profiles[index].preferredRoute = route; state.profiles[index].routePreference = route == .local ? .local : .cloud; try file.save(state)
        }
    }
    public func setRoutePreference(_ preference: AuthoringRoutePreference, profileID: String) throws {
        try lock.locallyLocked {
            var state = try load()
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { throw LocalPersistenceError.invalid("This local profile is missing.") }
            guard preference != .cloud || state.profiles[index].cloudBinding != nil || !state.profiles[index].libraryOwner.hasPrefix("local:") else { throw LocalPersistenceError.invalid("Link this profile to Cloud first.") }
            state.profiles[index].routePreference = preference
            if preference != .automatic { state.profiles[index].preferredRoute = preference == .local ? .local : .cloud }
            try file.save(state)
        }
    }
    /// Preflight before committing a native link; rejects a separate existing account library.
    public func validateLink(profileID: String, binding: LocalCloudBinding) throws {
        try lock.locallyLocked {
            let state = try load()
            guard let profile = state.profiles.first(where: { $0.id == profileID }), !binding.accountID.isEmpty, !binding.profileID.isEmpty, !binding.deviceID.isEmpty else { throw LocalPersistenceError.invalid("The local or Cloud profile is incomplete.") }
            guard profile.cloudBinding == nil || profile.cloudBinding == binding,
                  !state.profiles.contains(where: { $0.id != profileID && ($0.cloudBinding?.accountID == binding.accountID || ($0.libraryOwner == binding.accountID && $0.permissionOwner == binding.accountID)) }) else { throw LocalPersistenceError.conflict("An existing account library cannot be merged automatically. Choose that account library instead.") }
        }
    }
    /// Adopt only the descriptor committed alongside preferences by ScreenLibrary.linkLocalProfile.
    public func adoptLinkedProfile(_ profile: LocalProfileDescriptor) throws {
        try lock.locallyLocked {
            var state = try load()
            guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }), let binding = profile.cloudBinding else { throw LocalPersistenceError.invalid("The linked local profile is missing.") }
            let old = state.profiles[index]
            try validateLink(profileID: profile.id, binding: binding)
            guard !binding.accountID.isEmpty, !binding.profileID.isEmpty, !binding.deviceID.isEmpty, old.libraryOwner == profile.libraryOwner, old.permissionOwner == profile.permissionOwner, old.localDeviceID == profile.localDeviceID,
                  old.cloudBinding == nil || old.cloudBinding == binding,
                  !state.profiles.contains(where: { $0.id != profile.id && ($0.cloudBinding?.accountID == binding.accountID || ($0.libraryOwner == binding.accountID && $0.permissionOwner == binding.accountID)) }) else { throw LocalPersistenceError.conflict("An existing account library cannot be merged automatically.") }
            state.profiles[index] = profile; try file.save(state)
        }
    }
    public func signOut() throws {
        try lock.locallyLocked {
            var state = try load()
            if let index = state.profiles.firstIndex(where: { $0.id == state.activeProfileID }) { state.profiles[index].preferredRoute = .local; if state.profiles[index].routePreference == .cloud { state.profiles[index].routePreference = .local } }
            try file.save(state)
        }
    }
}
