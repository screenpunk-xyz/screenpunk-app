import Foundation

public enum ScreenDataError: String, Error, Sendable {
    case permissionRequired = "permission_required"
    case notFound = "not_found"
    case unavailable
    case timeout
    case rateLimited = "rate_limited"
    case invalidRequest = "invalid_request"
}

public struct ScreenDataSnapshot: Codable, Sendable, Equatable {
    public var value: AuthoringJSONValue
    public var version: Int
    public var updatedAt: String
    public var readAt: String

    public init(value: AuthoringJSONValue, version: Int, updatedAt: String, readAt: String) {
        self.value = value; self.version = version; self.updatedAt = updatedAt; self.readAt = readAt
    }
}

// Dynamic keys make unknown fields visible instead of silently ignoring them.
private struct DeclarationKey: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private extension Decoder {
    func screenDataFields<Key: CodingKey>(_ type: Key.Type, allowed: Set<String>) throws -> KeyedDecodingContainer<Key> {
        let fields = try container(keyedBy: DeclarationKey.self)
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ScreenDataError.invalidRequest }
        return try container(keyedBy: type)
    }
}

public struct ManifestScreenDataExport: Codable, Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) { self.name = name; self.description = description }

    private enum CodingKeys: String, CodingKey { case name, description }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.screenDataFields(CodingKeys.self, allowed: ["name", "description"])
        self.init(name: try fields.decode(String.self, forKey: .name), description: try fields.decode(String.self, forKey: .description))
    }
}

public struct ManifestScreenDataQuery: Codable, Sendable, Equatable {
    public var alias: String
    public var deviceId: String?
    public var screenId: String
    public var exportName: String

    public init(alias: String, deviceId: String? = nil, screenId: String, exportName: String) {
        self.alias = alias; self.deviceId = deviceId; self.screenId = screenId; self.exportName = exportName
    }

    private enum CodingKeys: String, CodingKey { case alias, deviceId, screenId, exportName }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.screenDataFields(CodingKeys.self, allowed: ["alias", "deviceId", "screenId", "exportName"])
        self.init(alias: try fields.decode(String.self, forKey: .alias),
                  deviceId: fields.contains(.deviceId) ? try fields.decode(String.self, forKey: .deviceId) : nil,
                  screenId: try fields.decode(String.self, forKey: .screenId),
                  exportName: try fields.decode(String.self, forKey: .exportName))
    }
}

public struct ManifestScreenData: Codable, Sendable, Equatable {
    public var exports: [ManifestScreenDataExport]
    public var queries: [ManifestScreenDataQuery]

    public init(exports: [ManifestScreenDataExport] = [], queries: [ManifestScreenDataQuery] = []) {
        self.exports = exports; self.queries = queries
    }

    private enum CodingKeys: String, CodingKey { case exports, queries }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.screenDataFields(CodingKeys.self, allowed: ["exports", "queries"])
        self.init(exports: fields.contains(.exports) ? try fields.decode([ManifestScreenDataExport].self, forKey: .exports) : [],
                  queries: fields.contains(.queries) ? try fields.decode([ManifestScreenDataQuery].self, forKey: .queries) : [])
        try validate()
    }

    public func validate() throws {
        guard exports.count <= ScreenDataContract.maxDeclarations, queries.count <= ScreenDataContract.maxDeclarations,
              Set(exports.map(\.name)).count == exports.count, Set(queries.map(\.alias)).count == queries.count else {
            throw ScreenDataError.invalidRequest
        }
        for declaration in exports {
            let description = declaration.description
            guard ScreenDataContract.isName(declaration.name), description.utf8.count <= 240,
                  description.unicodeScalars.contains(where: { !$0.properties.isWhitespace }),
                  !description.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw ScreenDataError.invalidRequest }
        }
        for declaration in queries {
            guard ScreenDataContract.isName(declaration.alias), ScreenDataContract.isName(declaration.exportName),
                  ScreenDataContract.isInstalledID(declaration.screenId),
                  declaration.deviceId.map(ScreenDataContract.isInstalledID) ?? true else { throw ScreenDataError.invalidRequest }
        }
    }
}

public enum ScreenDataContract {
    public static let maxDeclarations = 16
    public static let maxValueBytes = 16 * 1024
    /// Number of array/object containers on the path from the root to any value.
    public static let maxDepth = 16
    public static let maxVersion = 9_007_199_254_740_991

    public static func isName(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count <= 64, let first = bytes.first, alpha(first) else { return false }
        return bytes.dropFirst().allSatisfy { alpha($0) || digit($0) || $0 == 45 || $0 == 95 }
    }

    public static func isInstalledID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count <= 128, let first = bytes.first, alpha(first) || digit(first) else { return false }
        return bytes.dropFirst().allSatisfy { alpha($0) || digit($0) || [45, 46, 58, 95].contains($0) }
    }

    private static func alpha(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    private static func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    /// Check this manifest extension on the authoring wire before installation's full package validation.
    static func validateManifestDeclaration(_ content: String, previous: String? = nil, supportsScreenData: Bool = true) throws {
        struct ManifestDeclaration: Decodable {
            enum Key: String, CodingKey { case screenData }
            let screenData: ManifestScreenData?
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: Key.self)
                screenData = fields.contains(.screenData) ? try fields.decode(ManifestScreenData.self, forKey: .screenData) : nil
            }
        }
        func declaration(_ content: String) throws -> ManifestScreenData? {
            try JSONDecoder().decode(ManifestDeclaration.self, from: Data(content.utf8)).screenData
        }
        if let current = try declaration(content), !supportsScreenData, try previous.flatMap(declaration) != current {
            throw AuthoringContractError("target runtime does not advertise screen data")
        }
    }

    public static func validateValue(_ value: AuthoringJSONValue) throws {
        // Bound the structure before encoding, even for input supplied directly by native code.
        var minimumBytes = 0
        func spend(_ count: Int) throws {
            guard count <= maxValueBytes - minimumBytes else { throw ScreenDataError.invalidRequest }
            minimumBytes += count
        }
        func visit(_ value: AuthoringJSONValue, depth: Int) throws {
            try spend(1)
            switch value {
            case .array(let children):
                guard depth < maxDepth else { throw ScreenDataError.invalidRequest }
                for child in children { try visit(child, depth: depth + 1) }
            case .object(let children):
                guard depth < maxDepth else { throw ScreenDataError.invalidRequest }
                for (key, child) in children { try spend(key.utf8.count); try visit(child, depth: depth + 1) }
            case .string(let string): try spend(string.utf8.count)
            case .number(let number): guard number.isFinite else { throw ScreenDataError.invalidRequest }
            case .bool, .null: break
            }
        }
        try visit(value, depth: 0)
        guard let encoded = try? AuthoringContract.encodedCanonical(value), encoded.count <= maxValueBytes else {
            throw ScreenDataError.invalidRequest
        }
    }
}
