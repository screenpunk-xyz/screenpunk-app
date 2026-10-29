import Foundation

/// JSON on the authoring wire. Preference values are constrained to scalars by validation.
public enum AuthoringJSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([AuthoringJSONValue]), object([String: AuthoringJSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct AuthoringDesignGuidanceV1: Codable, Sendable, Equatable {
    public var version: String
    public var rules: [String]
    public init(version: String = "1", rules: [String]) {
        self.version = version
        self.rules = rules
    }
}

public struct AuthoringLimitsV1: Codable, Sendable, Equatable {
    public var metadataBytes: Int
    public var requestBytes: Int
    public var screenBytes: Int
    public var screenFiles: Int
    public init(metadataBytes: Int = 131072, requestBytes: Int = 393216, screenBytes: Int = 204800, screenFiles: Int = 20) {
        self.metadataBytes = metadataBytes
        self.requestBytes = requestBytes
        self.screenBytes = screenBytes
        self.screenFiles = screenFiles
    }
}

public struct AuthoringRuntimeV1: Codable, Sendable, Equatable {
    public var version: String
    public var packageFormat: String
    public var features: [String]
    public var limits: AuthoringLimitsV1
    public init(version: String = "1", packageFormat: String = "utf8-files-v1", features: [String], limits: AuthoringLimitsV1 = AuthoringLimitsV1()) {
        self.version = version
        self.packageFormat = packageFormat
        self.features = features
        self.limits = limits
    }
}

public struct AuthoringCapabilityStateV1: Codable, Sendable, Equatable {
    public var state: String
    public var observedAt: Int64
    public init(state: String = "unknown", observedAt: Int64) {
        self.state = state
        self.observedAt = observedAt
    }
}

public struct AuthoringOperationV1: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var inputSchema: AuthoringJSONValue
    public var outputSchema: AuthoringJSONValue
    public var requirements: [String]
    public var instructions: String
    public init(name: String, kind: String, inputSchema: AuthoringJSONValue, outputSchema: AuthoringJSONValue, requirements: [String], instructions: String) {
        self.name = name
        self.kind = kind
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.requirements = requirements
        self.instructions = instructions
    }
}

public struct AuthoringServiceV1: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var operations: [AuthoringOperationV1]
    public var supported: AuthoringCapabilityStateV1
    public var configured: AuthoringCapabilityStateV1
    public var authorized: AuthoringCapabilityStateV1
    public var entitled: AuthoringCapabilityStateV1
    public var reachable: AuthoringCapabilityStateV1
    public init(id: String, provider: String, operations: [AuthoringOperationV1], supported: AuthoringCapabilityStateV1, configured: AuthoringCapabilityStateV1, authorized: AuthoringCapabilityStateV1, entitled: AuthoringCapabilityStateV1, reachable: AuthoringCapabilityStateV1) {
        self.id = id
        self.provider = provider
        self.operations = operations
        self.supported = supported
        self.configured = configured
        self.authorized = authorized
        self.entitled = entitled
        self.reachable = reachable
    }
}

public struct AuthoringServiceDefinitionV1: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var operations: [AuthoringOperationV1]
    public var setupInstructions: String
    public init(id: String, provider: String, operations: [AuthoringOperationV1], setupInstructions: String) {
        self.id = id
        self.provider = provider
        self.operations = operations
        self.setupInstructions = setupInstructions
    }
}

public struct AuthoringViewportV1: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var scale: Double
    public var orientation: String
    public init(width: Double, height: Double, scale: Double = 1, orientation: String) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
    }
}

public struct AuthoringScreenFile: Codable, Sendable, Equatable {
    public var path: String
    public var content: String
    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

public struct AuthoringScreen: Codable, Sendable, Equatable {
    public var title: String
    public var entry: String
    public var files: [AuthoringScreenFile]
    public init(title: String, entry: String = "index.html", files: [AuthoringScreenFile]) {
        self.title = title
        self.entry = entry
        self.files = files
    }
}

public struct AuthoringContextV1: Codable, Sendable, Equatable {
    public var profileID: String
    public var deviceID: String
    public var screenID: String
    public var baseRevision: String?
    public var userRequest: String
    public var currentScreen: AuthoringScreen?
    public var viewport: AuthoringViewportV1
    public init(profileID: String, deviceID: String, screenID: String, baseRevision: String? = nil, userRequest: String, currentScreen: AuthoringScreen? = nil, viewport: AuthoringViewportV1) {
        self.profileID = profileID
        self.deviceID = deviceID
        self.screenID = screenID
        self.baseRevision = baseRevision
        self.userRequest = userRequest
        self.currentScreen = currentScreen
        self.viewport = viewport
    }
    private enum CodingKeys: String, CodingKey { case profileID, deviceID, screenID, baseRevision, userRequest, currentScreen, viewport }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(baseRevision, forKey: .baseRevision)
        try c.encode(userRequest, forKey: .userRequest)
        try c.encodeIfPresent(currentScreen, forKey: .currentScreen)
        try c.encode(viewport, forKey: .viewport)
    }
}

public struct AuthoringDeliveryV1: Codable, Sendable, Equatable {
    public var route: String
    public var contractVersion: String
    public var snapshotDigest: String
    public init(route: String, contractVersion: String = "1", snapshotDigest: String = "") {
        self.route = route
        self.contractVersion = contractVersion
        self.snapshotDigest = snapshotDigest
    }
}

public struct PreferenceRecordV1: Codable, Sendable, Equatable {
    public var id: String
    public var scope: String
    public var targetID: String
    public var category: String
    public var value: AuthoringJSONValue
    public var revision: Int
    public var originRequestID: String
    public var deleted: Bool
    public init(id: String, scope: String, targetID: String, category: String, value: AuthoringJSONValue, revision: Int, originRequestID: String, deleted: Bool = false) {
        self.id = id
        self.scope = scope
        self.targetID = targetID
        self.category = category
        self.value = value
        self.revision = revision
        self.originRequestID = originRequestID
        self.deleted = deleted
    }
}

public struct PreferenceMutationV1: Codable, Sendable, Equatable {
    public var kind: String
    public var id: String
    public var expectedRevision: Int?
    public var record: PreferenceRecordV1?
    public init(kind: String, id: String, expectedRevision: Int?, record: PreferenceRecordV1? = nil) {
        self.kind = kind
        self.id = id
        self.expectedRevision = expectedRevision
        self.record = record
    }
    private enum CodingKeys: String, CodingKey { case kind, id, expectedRevision, record }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encodeIfPresent(record, forKey: .record)
    }
}

public struct DurablePreferenceAuthorizationV1: Codable, Sendable, Equatable {
    public var requestID: String
    public var quote: String
    public init(requestID: String, quote: String) {
        self.requestID = requestID
        self.quote = quote
    }
}

public struct AuthoringRequestV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var requestID: String
    public var createdAt: Int64
    public var deadlineAt: Int64
    public var designGuidance: AuthoringDesignGuidanceV1
    public var runtime: AuthoringRuntimeV1
    public var services: [AuthoringServiceV1]
    public var preferences: [PreferenceRecordV1]
    public var context: AuthoringContextV1
    public var delivery: AuthoringDeliveryV1
    public init(schemaVersion: Int = 1, requestID: String, createdAt: Int64, deadlineAt: Int64, designGuidance: AuthoringDesignGuidanceV1, runtime: AuthoringRuntimeV1, services: [AuthoringServiceV1], preferences: [PreferenceRecordV1] = [], context: AuthoringContextV1, delivery: AuthoringDeliveryV1) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.createdAt = createdAt
        self.deadlineAt = deadlineAt
        self.designGuidance = designGuidance
        self.runtime = runtime
        self.services = services
        self.preferences = preferences
        self.context = context
        self.delivery = delivery
    }
}

public struct AuthoringResultV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var requestID: String
    public var inputDigest: String
    public var baseRevision: String?
    public var preferenceRevisions: [String: Int]
    public var operationID: String
    public var screen: AuthoringScreen?
    public var answer: String?
    public var preferenceMutations: [PreferenceMutationV1]?
    public var durablePreferenceAuthorization: DurablePreferenceAuthorizationV1?
    public init(schemaVersion: Int = 1, requestID: String, inputDigest: String, baseRevision: String? = nil, preferenceRevisions: [String: Int], operationID: String, screen: AuthoringScreen? = nil, answer: String? = nil, preferenceMutations: [PreferenceMutationV1]? = nil, durablePreferenceAuthorization: DurablePreferenceAuthorizationV1? = nil) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.inputDigest = inputDigest
        self.baseRevision = baseRevision
        self.preferenceRevisions = preferenceRevisions
        self.operationID = operationID
        self.screen = screen
        self.answer = answer
        self.preferenceMutations = preferenceMutations
        self.durablePreferenceAuthorization = durablePreferenceAuthorization
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, requestID, inputDigest, baseRevision, preferenceRevisions, operationID, screen, answer, preferenceMutations, durablePreferenceAuthorization }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(inputDigest, forKey: .inputDigest)
        try c.encode(baseRevision, forKey: .baseRevision)
        try c.encode(preferenceRevisions, forKey: .preferenceRevisions)
        try c.encode(operationID, forKey: .operationID)
        try c.encodeIfPresent(screen, forKey: .screen)
        try c.encodeIfPresent(answer, forKey: .answer)
        try c.encodeIfPresent(preferenceMutations, forKey: .preferenceMutations)
        try c.encodeIfPresent(durablePreferenceAuthorization, forKey: .durablePreferenceAuthorization)
    }
}

public struct ApplicationReceiptV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var requestID: String
    public var operationID: String
    public var inputDigest: String
    public var status: String
    public var appliedAt: Int64
    public var message: String?
    public init(schemaVersion: Int = 1, requestID: String, operationID: String, inputDigest: String, status: String, appliedAt: Int64, message: String? = nil) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.operationID = operationID
        self.inputDigest = inputDigest
        self.status = status
        self.appliedAt = appliedAt
        self.message = message
    }
}

public struct AuthoringDefinitionV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var designGuidance: AuthoringDesignGuidanceV1
    public var runtime: AuthoringRuntimeV1
    public var serviceCatalog: [AuthoringServiceDefinitionV1]
    public var schemas: [String: AuthoringJSONValue]
    public init(schemaVersion: Int, designGuidance: AuthoringDesignGuidanceV1, runtime: AuthoringRuntimeV1, serviceCatalog: [AuthoringServiceDefinitionV1], schemas: [String: AuthoringJSONValue]) {
        self.schemaVersion = schemaVersion
        self.designGuidance = designGuidance
        self.runtime = runtime
        self.serviceCatalog = serviceCatalog
        self.schemas = schemas
    }
}

