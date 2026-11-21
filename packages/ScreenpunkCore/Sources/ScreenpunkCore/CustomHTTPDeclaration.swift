import Foundation

/// Untrusted package metadata. Configured field values are stored separately by the native device.
public struct CustomHTTPDeclaration: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var label: String
    public var fields: [CustomHTTPField]
    public var originField: String
    public var auth: CustomHTTPAuth?
    public var operations: [CustomHTTPOperation]

    public init(id: String, version: Int, label: String, fields: [CustomHTTPField], originField: String,
                auth: CustomHTTPAuth? = nil, operations: [CustomHTTPOperation]) {
        self.id = id
        self.version = version
        self.label = label
        self.fields = fields
        self.originField = originField
        self.auth = auth
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, version, label, fields, originField, auth, operations }
    public init(from decoder: Decoder) throws {
        let values = try strict(decoder, keys: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), version: try values.decode(Int.self, forKey: .version),
                  label: try values.decode(String.self, forKey: .label), fields: try values.decode([CustomHTTPField].self, forKey: .fields),
                  originField: try values.decode(String.self, forKey: .originField), auth: try values.optional(CustomHTTPAuth.self, .auth),
                  operations: try values.decode([CustomHTTPOperation].self, forKey: .operations))
    }

    public func validate(alias: String) throws {
        guard validName(alias), !["home", "googletv", "googlecalendar", "applemaps"].contains(alias.lowercased()),
              matches(id, #"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*\z"#, max: 64),
              (1...2_147_483_647).contains(version), validLabel(label),
              (1...12).contains(fields.count), (1...16).contains(operations.count),
              Set(fields.map(\.id)).count == fields.count, Set(operations.map(\.name)).count == operations.count else {
            throw ConnectionFailure.validationFailed
        }
        for field in fields { try field.validateDescriptor() }
        let byID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        guard fields.filter({ $0.type == "url" }).map(\.id) == [originField] else { throw ConnectionFailure.validationFailed }
        let secretFields = fields.filter { $0.type == "secret" }.map(\.id)
        if let auth {
            guard auth.mode == "bearer", secretFields == [auth.field] else { throw ConnectionFailure.validationFailed }
        } else if !secretFields.isEmpty {
            throw ConnectionFailure.validationFailed
        }
        for operation in operations { try operation.validate(fields: byID) }
    }

    static func validateConnectionKeys(_ decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCustomKey.self)
        guard Set(values.allKeys.map(\.stringValue)) == ["alias", "required", "customHTTP"] else {
            throw ConnectionFailure.validationFailed
        }
    }

    public static func validateConnections(_ connections: [ManifestConnection]) throws {
        let custom = connections.filter { $0.customHTTP != nil }
        guard custom.count <= 8, Set(custom.compactMap { $0.customHTTP?.id }).count == custom.count,
              custom.allSatisfy({ connection in
                  connections.filter { $0.alias.caseInsensitiveCompare(connection.alias) == .orderedSame }.count == 1
              }) else { throw ConnectionFailure.validationFailed }
        for connection in custom {
            guard connection.publicHTTP == nil, connection.operations == nil, connection.serviceCalls == nil,
                  connection.cameraEntities == nil else { throw ConnectionFailure.validationFailed }
            try connection.customHTTP?.validate(alias: connection.alias)
        }
    }

    static func validateManifest(_ content: String, previous: String? = nil, supported: Bool = true) throws {
        struct Extensions: Decodable {
            var connections: [ManifestConnection]?
        }
        func read(_ content: String) throws -> [ManifestConnection] {
            guard let manifest = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let connections = manifest["connections"] as? [[String: Any]],
                  connections.contains(where: { $0.keys.contains("customHTTP") }) else { return [] }
            guard !connections.contains(where: { $0.keys.contains("customHTTP") && $0["customHTTP"] is NSNull }) else {
                throw ConnectionFailure.validationFailed
            }
            let decoded = try JSONDecoder().decode(Extensions.self, from: Data(content.utf8)).connections ?? []
            try validateConnections(decoded)
            return decoded.filter { $0.customHTTP != nil }
        }
        let current = try read(content)
        if !supported, !current.isEmpty, try previous.map(read) != current {
            throw AuthoringContractError("target runtime does not advertise custom HTTP")
        }
    }
}

public struct CustomHTTPField: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var type: String
    public var options: [String]?

    public init(id: String, label: String, type: String, options: [String]? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, label, type, options }
    public init(from decoder: Decoder) throws {
        let values = try strict(decoder, keys: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), label: try values.decode(String.self, forKey: .label),
                  type: try values.decode(String.self, forKey: .type), options: try values.optional([String].self, .options))
    }

    func validateDescriptor() throws {
        guard validName(id), validLabel(label) else { throw ConnectionFailure.validationFailed }
        try validateType(type, options: options, configuration: true)
    }

    public func validate(_ value: String) throws {
        try validateDescriptor()
        try validateValue(value, type: type, options: options)
    }
}

public struct CustomHTTPAuth: Codable, Equatable, Sendable {
    public var mode: String
    public var field: String
    public init(mode: String = "bearer", field: String) {
        self.mode = mode
        self.field = field
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case mode, field }
    public init(from decoder: Decoder) throws {
        let values = try strict(decoder, keys: CodingKeys.self)
        self.init(mode: try values.decode(String.self, forKey: .mode), field: try values.decode(String.self, forKey: .field))
    }
}

public struct CustomHTTPOperation: Codable, Equatable, Sendable {
    public var name: String
    public var method: String
    public var path: String
    public var response: String
    public var parameters: [String: CustomHTTPParameter]

    public init(name: String, method: String = "GET", path: String, response: String = "json",
                parameters: [String: CustomHTTPParameter] = [:]) {
        self.name = name
        self.method = method
        self.path = path
        self.response = response
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, method, path, response, parameters }
    public init(from decoder: Decoder) throws {
        let values = try strict(decoder, keys: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name), method: try values.decode(String.self, forKey: .method),
                  path: try values.decode(String.self, forKey: .path), response: try values.decode(String.self, forKey: .response),
                  parameters: try values.decode([String: CustomHTTPParameter].self, forKey: .parameters))
    }

    func validate(fields: [String: CustomHTTPField]) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard validName(name), method == "GET", response == "json", path.utf8.count <= 512,
              path == "/" || (path.hasPrefix("/") && components.dropFirst().allSatisfy({ part in
                  part != "." && part != ".." && matches(String(part), #"^[A-Za-z0-9._~-]+\z"#, max: 256)
              })), parameters.count <= 12 else { throw ConnectionFailure.validationFailed }
        for (key, parameter) in parameters {
            guard validName(key), !ConnectionAuthKeys.isOverride(key), !ConnectionAuthKeys.isDestination(key) else {
                throw ConnectionFailure.validationFailed
            }
            try validateType(parameter.type, options: parameter.options, configuration: false)
            if let field = parameter.field {
                guard let descriptor = fields[field], descriptor.type == parameter.type, descriptor.options == parameter.options else {
                    throw ConnectionFailure.validationFailed
                }
            }
        }
    }
}

public struct CustomHTTPParameter: Codable, Equatable, Sendable {
    public var type: String
    public var options: [String]?
    public var field: String?

    public init(type: String, options: [String]? = nil, field: String? = nil) {
        self.type = type
        self.options = options
        self.field = field
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case type, options, field }
    public init(from decoder: Decoder) throws {
        let values = try strict(decoder, keys: CodingKeys.self)
        self.init(type: try values.decode(String.self, forKey: .type), options: try values.optional([String].self, .options),
                  field: try values.optional(String.self, .field))
    }

    public func validate(_ value: String) throws {
        try validateType(type, options: options, configuration: false)
        try validateValue(value, type: type, options: options)
    }
}

private func validateType(_ type: String, options: [String]?, configuration: Bool) throws {
    switch type {
    case "choice":
        guard let options, (1...32).contains(options.count), Set(options).count == options.count,
              options.allSatisfy({ validText($0, max: 128) }) else { throw ConnectionFailure.validationFailed }
    case "text", "number", "toggle":
        guard options == nil else { throw ConnectionFailure.validationFailed }
    case "url", "secret":
        guard configuration, options == nil else { throw ConnectionFailure.validationFailed }
    default: throw ConnectionFailure.validationFailed
    }
}

private func validateValue(_ value: String, type: String, options: [String]?) throws {
    let valid: Bool
    switch type {
    case "text": valid = validText(value, max: 512)
    case "number":
        valid = matches(value, #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z"#, max: 32)
            && Double(value).map { $0.isFinite && abs($0) <= 9_007_199_254_740_991 } == true
    case "toggle": valid = value == "true" || value == "false"
    case "choice": valid = options?.contains(value) == true
    case "secret": valid = matches(value, #"^[A-Za-z0-9._~+/=-]+\z"#, max: 4096)
    case "url":
        if validText(value, max: 512), !value.contains("%"), !value.contains("\\"),
           let url = URLComponents(string: value), ["http", "https"].contains(url.scheme ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
           url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
           url.port.map({ (1...65535).contains($0) }) != false {
            valid = true
        } else {
            valid = false
        }
    default: valid = false
    }
    guard valid else { throw ConnectionFailure.validationFailed }
}

private func validText(_ value: String, max: Int) -> Bool {
    (1...max).contains(value.utf8.count) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}
private func validLabel(_ value: String) -> Bool { validText(value, max: 96) }
private func validName(_ value: String) -> Bool { matches(value, #"^[A-Za-z][A-Za-z0-9_-]*\z"#, max: 64) }
private func matches(_ value: String, _ pattern: String, max: Int) -> Bool {
    value.utf8.count <= max && value.range(of: pattern, options: .regularExpression) != nil
}

private struct AnyCustomKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func strict<Key: CodingKey & CaseIterable>(_ decoder: Decoder, keys: Key.Type) throws -> KeyedDecodingContainer<Key> {
    let supplied = try decoder.container(keyedBy: AnyCustomKey.self)
    guard Set(supplied.allKeys.map(\.stringValue)).isSubset(of: Set(Key.allCases.map(\.stringValue))) else {
        throw ConnectionFailure.validationFailed
    }
    return try decoder.container(keyedBy: keys)
}

private extension KeyedDecodingContainer {
    func optional<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        try contains(key) ? decode(type, forKey: key) : nil
    }
}
