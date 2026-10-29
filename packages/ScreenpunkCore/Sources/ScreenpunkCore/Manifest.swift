import Foundation

public struct SafeAreaInsets: Codable, Sendable, Equatable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

public struct ManifestTarget: Codable, Sendable, Equatable {
    public var profileId: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var orientation: String
    public var safeArea: SafeAreaInsets?

    public init(
        profileId: String,
        width: Int,
        height: Int,
        scale: Double,
        orientation: String,
        safeArea: SafeAreaInsets? = nil
    ) {
        self.profileId = profileId
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
        self.safeArea = safeArea
    }
}

public struct ManifestOperation: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var maxAgeSeconds: Int?

    public init(name: String, kind: String, maxAgeSeconds: Int? = nil) {
        self.name = name
        self.kind = kind
        self.maxAgeSeconds = maxAgeSeconds
    }
}

public struct ManifestConnection: Codable, Sendable, Equatable {
    public var alias: String
    public var required: Bool
    public var operations: [ManifestOperation]?
    public var serviceCalls: [HomeAssistantServiceGrant]?
    public var cameraEntities: [String]?
    public var publicHTTP: PublicReadDeclaration?

    public init(alias: String, required: Bool, operations: [ManifestOperation]? = nil, serviceCalls: [HomeAssistantServiceGrant]? = nil) {
        self.alias = alias
        self.required = required
        self.operations = operations
        self.serviceCalls = serviceCalls
    }
}

public struct ManifestFile: Codable, Sendable, Equatable {
    public var path: String
    public var bytes: Int
    public var sha256: String

    public init(path: String, bytes: Int, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct DashboardManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var dashboardId: String
    public var name: String
    public var revision: String
    public var entrypoint: String
    public var sdkVersion: String
    public var digest: String?
    public var target: ManifestTarget
    public var connections: [ManifestConnection]
    public var files: [ManifestFile]
    public var pages: [DashboardPage]?
    public var defaultPageId: String?
    public var eventRules: [ManifestEventRule]?
    public var deviceBehavior: DeviceBehavior?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dashboardId, name, revision, entrypoint, sdkVersion, digest, target, connections, files, pages, defaultPageId, eventRules, deviceBehavior
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        dashboardId = try values.decode(String.self, forKey: .dashboardId)
        name = try values.decode(String.self, forKey: .name)
        revision = try values.decode(String.self, forKey: .revision)
        entrypoint = try values.decode(String.self, forKey: .entrypoint)
        // Accept the equivalent JSON integer emitted by some screen authors.
        // Validation still rejects every unsupported SDK version.
        if let value = try? values.decode(String.self, forKey: .sdkVersion) { sdkVersion = value }
        else { sdkVersion = String(try values.decode(Int.self, forKey: .sdkVersion)) }
        digest = try values.decodeIfPresent(String.self, forKey: .digest)
        target = try values.decode(ManifestTarget.self, forKey: .target)
        connections = try values.decode([ManifestConnection].self, forKey: .connections)
        files = try values.decode([ManifestFile].self, forKey: .files)
        pages = try values.decodeIfPresent([DashboardPage].self, forKey: .pages)
        defaultPageId = try values.decodeIfPresent(String.self, forKey: .defaultPageId)
        eventRules = try values.decodeIfPresent([ManifestEventRule].self, forKey: .eventRules)
        deviceBehavior = try values.decodeIfPresent(DeviceBehavior.self, forKey: .deviceBehavior)
    }

    public init(
        schemaVersion: Int,
        dashboardId: String,
        name: String,
        revision: String,
        entrypoint: String,
        sdkVersion: String,
        digest: String? = nil,
        target: ManifestTarget,
        connections: [ManifestConnection],
        files: [ManifestFile],
        pages: [DashboardPage]? = nil,
        defaultPageId: String? = nil,
        eventRules: [ManifestEventRule]? = nil,
        deviceBehavior: DeviceBehavior? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.dashboardId = dashboardId
        self.name = name
        self.revision = revision
        self.entrypoint = entrypoint
        self.sdkVersion = sdkVersion
        self.digest = digest
        self.target = target
        self.connections = connections
        self.files = files
        self.pages = pages
        self.defaultPageId = defaultPageId
        self.eventRules = eventRules
        self.deviceBehavior = deviceBehavior
    }
}
