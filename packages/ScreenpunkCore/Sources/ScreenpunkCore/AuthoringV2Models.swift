import Foundation

public struct AuthoringSourceFileV2: Codable, Sendable, Equatable {
    public var path: String
    public var mediaType: String
    public var byteLength: Int
    public var digest: String
    public var reference: String
    public var content: String?
    public init(path: String, mediaType: String, byteLength: Int, digest: String, reference: String = "", content: String? = nil) {
        self.path = path; self.mediaType = mediaType; self.byteLength = byteLength; self.digest = digest; self.reference = reference; self.content = content
    }
}
public struct AuthoringSourceScreenV2: Codable, Sendable, Equatable {
    public var title: String
    public var entry: String
    public var files: [AuthoringSourceFileV2]
    public init(title: String, entry: String = "index.html", files: [AuthoringSourceFileV2]) { self.title = title; self.entry = entry; self.files = files }
}
public struct AuthoringContextV2: Codable, Sendable, Equatable {
    public var profileID: String
    public var libraryID: String
    public var deviceID: String
    public var screenID: String
    public var baseRevision: String?
    public var userRequest: String
    public var currentScreen: AuthoringSourceScreenV2?
    public var viewport: AuthoringViewportV1
    public init(profileID: String, libraryID: String, deviceID: String, screenID: String, baseRevision: String? = nil, userRequest: String, currentScreen: AuthoringSourceScreenV2? = nil, viewport: AuthoringViewportV1) {
        self.profileID = profileID; self.libraryID = libraryID; self.deviceID = deviceID; self.screenID = screenID; self.baseRevision = baseRevision; self.userRequest = userRequest; self.currentScreen = currentScreen; self.viewport = viewport
    }
    private enum CodingKeys: String, CodingKey { case profileID,libraryID,deviceID,screenID,baseRevision,userRequest,currentScreen,viewport }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID); try c.encode(libraryID, forKey: .libraryID); try c.encode(deviceID, forKey: .deviceID); try c.encode(screenID, forKey: .screenID)
        try c.encode(baseRevision, forKey: .baseRevision); try c.encode(userRequest, forKey: .userRequest); try c.encodeIfPresent(currentScreen, forKey: .currentScreen); try c.encode(viewport, forKey: .viewport)
    }
}
public struct AuthoringDeliveryV2: Codable, Sendable, Equatable {
    public var route: String
    public var contractVersion: String
    public var snapshotDigest: String
    public init(route: String, contractVersion: String = "2", snapshotDigest: String = "") { self.route = route; self.contractVersion = contractVersion; self.snapshotDigest = snapshotDigest }
}
public struct AuthoringRequestV2: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var requestID: String
    public var createdAt: Int64
    public var deadlineAt: Int64
    public var designGuidance: AuthoringDesignGuidanceV1
    public var runtime: AuthoringRuntimeV1
    public var services: [AuthoringServiceV1]
    public var preferences: [PreferenceRecordV1]
    public var context: AuthoringContextV2
    public var delivery: AuthoringDeliveryV2
    public init(schemaVersion: Int = 2, requestID: String, createdAt: Int64, deadlineAt: Int64, designGuidance: AuthoringDesignGuidanceV1 = AuthoringContract.designGuidance, runtime: AuthoringRuntimeV1 = AuthoringContract.runtime, services: [AuthoringServiceV1], preferences: [PreferenceRecordV1] = [], context: AuthoringContextV2, delivery: AuthoringDeliveryV2) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.createdAt = createdAt; self.deadlineAt = deadlineAt; self.designGuidance = designGuidance; self.runtime = runtime; self.services = services; self.preferences = preferences; self.context = context; self.delivery = delivery
    }
    /// A separately sealed v1 metadata projection for unchanged v1 preference validation.
    public func legacyRequest(currentScreen: AuthoringScreen? = nil) throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: requestID, createdAt: createdAt, deadlineAt: deadlineAt, designGuidance: designGuidance, runtime: runtime, services: services, preferences: preferences,
            context: .init(profileID: context.profileID, deviceID: context.deviceID, screenID: context.screenID, baseRevision: context.baseRevision, userRequest: context.userRequest, currentScreen: currentScreen, viewport: context.viewport), delivery: .init(route: delivery.route)))
    }
}
public struct AuthoringFileMutationV2: Codable, Sendable, Equatable {
    public var kind: String
    public var path: String
    public var content: String?
    public var sourcePath: String?
    public var reference: String?
    public var digest: String?
    public init(kind: String, path: String, content: String? = nil, sourcePath: String? = nil, reference: String? = nil, digest: String? = nil) { self.kind = kind; self.path = path; self.content = content; self.sourcePath = sourcePath; self.reference = reference; self.digest = digest }
    public static func write(path: String, content: String) -> Self { .init(kind: "write", path: path, content: content) }
    public static func retain(path: String, sourcePath: String, reference: String, digest: String) -> Self { .init(kind: "retain", path: path, sourcePath: sourcePath, reference: reference, digest: digest) }
}
public struct AuthoringScreenMutationV2: Codable, Sendable, Equatable {
    public var title: String
    public var entry: String
    public var files: [AuthoringFileMutationV2]
    public var deletedPaths: [String]
    public var requiredAssets: [String]?
    public init(title: String, entry: String = "index.html", files: [AuthoringFileMutationV2], deletedPaths: [String] = [], requiredAssets: [String]? = nil) { self.title = title; self.entry = entry; self.files = files; self.deletedPaths = deletedPaths; self.requiredAssets = requiredAssets }
}
public struct AuthoringResultV2: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var requestID: String
    public var inputDigest: String
    public var baseRevision: String?
    public var preferenceRevisions: [String: Int]
    public var operationID: String
    public var screen: AuthoringScreenMutationV2?
    public var answer: String?
    public var preferenceMutations: [PreferenceMutationV1]?
    public var durablePreferenceAuthorization: DurablePreferenceAuthorizationV1?
    public init(schemaVersion: Int = 2, requestID: String, inputDigest: String, baseRevision: String? = nil, preferenceRevisions: [String: Int], operationID: String, screen: AuthoringScreenMutationV2? = nil, answer: String? = nil, preferenceMutations: [PreferenceMutationV1]? = nil, durablePreferenceAuthorization: DurablePreferenceAuthorizationV1? = nil) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.inputDigest = inputDigest; self.baseRevision = baseRevision; self.preferenceRevisions = preferenceRevisions; self.operationID = operationID; self.screen = screen; self.answer = answer; self.preferenceMutations = preferenceMutations; self.durablePreferenceAuthorization = durablePreferenceAuthorization
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion,requestID,inputDigest,baseRevision,preferenceRevisions,operationID,screen,answer,preferenceMutations,durablePreferenceAuthorization }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestID, forKey: .requestID); try c.encode(inputDigest, forKey: .inputDigest); try c.encode(baseRevision, forKey: .baseRevision); try c.encode(preferenceRevisions, forKey: .preferenceRevisions); try c.encode(operationID, forKey: .operationID)
        try c.encodeIfPresent(screen, forKey: .screen); try c.encodeIfPresent(answer, forKey: .answer); try c.encodeIfPresent(preferenceMutations, forKey: .preferenceMutations); try c.encodeIfPresent(durablePreferenceAuthorization, forKey: .durablePreferenceAuthorization)
    }
    public func legacyResult(screen: AuthoringScreen? = nil) -> AuthoringResultV1 {
        .init(requestID: requestID, inputDigest: inputDigest, baseRevision: baseRevision, preferenceRevisions: preferenceRevisions, operationID: operationID, screen: screen, answer: answer, preferenceMutations: preferenceMutations, durablePreferenceAuthorization: durablePreferenceAuthorization)
    }
}
public struct AuthoringCapabilitiesV2: Codable, Sendable, Equatable {
    public var contractVersions: [String]
    public var features: [String]
    public init(contractVersions: [String] = ["1","2"], features: [String] = ["asset-references-v2"]) { self.contractVersions = contractVersions; self.features = features }
    public var supportsV2: Bool { contractVersions.contains("2") && features.contains("asset-references-v2") }
}
