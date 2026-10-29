import Foundation
import ScreenpunkCore

/// The shared native contract remains authoritative. This projection accounts for
/// Structured Outputs requiring all object properties and closed object schemas.
/// Only originally optional Result fields and Mutation.record use null-as-omitted.
enum LocalResultWireContract {
    static let optionalResultFields: Set<String> = ["screen", "answer", "preferenceMutations", "durablePreferenceAuthorization"]
    static func schema(for request: AuthoringRequestV1) throws -> JSON {
        guard let canonical = AuthoringContract.definition.schemas["Result"],
              case .object(let definitions) = canonical["$defs"],
              case .object(let root) = definitions["Result"] else { throw LocalAuthoringError.protocolViolation }
        return try schema(root: root, definitions: definitions, requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision, preferences: request.preferences, version: 1)
    }
    static func schema(for request: AuthoringRequestV2) throws -> JSON {
        let canonical = AuthoringV2Contract.resultSchema
        let definitions = canonical["$defs"].object
        let root = definitions["Result"]?.object ?? canonical.object
        return try schema(root: root, definitions: definitions, requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision, preferences: request.preferences, version: 2)
    }
    private static func schema(root original: [String: JSON], definitions: [String: JSON], requestID: String, inputDigest: String, baseRevision: String?, preferences: [PreferenceRecordV1], version: Int) throws -> JSON {
        var root = original
        var properties = root["properties"]!.object
        properties["schemaVersion"] = .object(["type": .string("integer"), "enum": .array([.number(Double(version))])])
        properties["requestID"] = .object(["type": .string("string"), "enum": .array([.string(requestID)])])
        properties["inputDigest"] = .object(["type": .string("string"), "enum": .array([.string(inputDigest)])])
        properties["baseRevision"] = baseRevision.map { .object(["type": .string("string"), "enum": .array([.string($0)])]) } ?? .object(["type": .string("null")])
        let revisions = Dictionary(uniqueKeysWithValues: preferences.map { ($0.id, JSON.object(["type": .string("integer"), "enum": .array([.number(Double($0.revision))])])) })
        properties["preferenceRevisions"] = .object(["type": .string("object"), "properties": .object(revisions), "required": .array(revisions.keys.sorted().map(JSON.string)), "additionalProperties": .bool(false)])
        root["properties"] = .object(properties)
        var reachable = Set<String>()
        func collect(_ value: JSON) throws {
            switch value {
            case .object(let object):
                if let ref = object["$ref"]?.string {
                    guard ref.hasPrefix("#/$defs/"), let name = ref.split(separator: "/").last.map(String.init), let definition = definitions[name] else { throw LocalAuthoringError.protocolViolation }
                    if reachable.insert(name).inserted { try collect(definition) }
                }
                for child in object.values { try collect(child) }
            case .array(let array): for child in array { try collect(child) }
            default: break
            }
        }
        try collect(.object(root))
        var projected = try project(.object(root)).object
        if !reachable.isEmpty {
            projected["$defs"] = .object(try Dictionary(uniqueKeysWithValues: reachable.sorted().map { ($0, try project(definitions[$0]!)) }))
        }
        return .object(projected)
    }
    static func project(_ schema: JSON) throws -> JSON {
        switch schema {
        case .array(let array): return .array(try array.map(project))
        case .object(let object):
            // Native validation still enforces byte and UTF-16 limits. These are
            // client keywords, not Structured Outputs schema keywords.
            let omitted: Set<String> = ["$schema", "$id", "maxBytes", "x-screenpunk-max-utf16-code-units", "propertyNames", "minProperties", "maxProperties"]
            var result: [String: JSON] = [:]
            for (key, value) in object where !omitted.contains(key) { result[key] = try project(value) }
            if let union = result.removeValue(forKey: "oneOf") { result["anyOf"] = union }
            if let constant = result.removeValue(forKey: "const") {
                result["enum"] = .array([constant])
                if result["type"] == nil {
                    switch constant { case .number: result["type"] = .string("integer"); case .string: result["type"] = .string("string"); case .bool: result["type"] = .string("boolean"); case .null: result["type"] = .string("null"); default: throw LocalAuthoringError.protocolViolation }
                }
            }
            if object["type"]?.string == "object" {
                guard let rawProperties = object["properties"], case .object(let properties) = rawProperties,
                      object["additionalProperties"] == .bool(false) else { throw LocalAuthoringError.protocolViolation }
                let required = Set(object["required"]?.array.compactMap(\.string) ?? [])
                var projectedProperties = result["properties"]!.object
                for key in properties.keys where !required.contains(key) {
                    projectedProperties[key] = .object(["anyOf": .array([projectedProperties[key]!, .object(["type": .string("null")])])])
                }
                result["properties"] = .object(projectedProperties)
                result["required"] = .array(properties.keys.sorted().map(JSON.string))
                result["additionalProperties"] = .bool(false)
            }
            return .object(result)
        default: return schema
        }
    }
    static func decode(_ data: Data, request: AuthoringRequestV1) throws -> AuthoringResultV1 {
        guard data.count <= AuthoringContract.resultBytes else { throw LocalAuthoringError.messageTooLarge }
        return try AuthoringContract.validateResult(normalized(data), request: request)
    }
    static func decode(_ data: Data, request: AuthoringRequestV2) throws -> AuthoringResultV2 {
        guard data.count <= AuthoringContract.resultBytes else { throw LocalAuthoringError.messageTooLarge }
        return try AuthoringV2Contract.validateResult(normalized(data, v2: true), request: request)
    }
    private static func normalized(_ data: Data, v2: Bool = false) throws -> Data {
        let wire = try JSONDecoder().decode(JSON.self, from: data)
        guard case .object(var result) = wire else { throw LocalAuthoringError.protocolViolation }
        for key in optionalResultFields where result[key] == .null { result.removeValue(forKey: key) }
        if case .array(let mutations) = result["preferenceMutations"] {
            result["preferenceMutations"] = .array(mutations.map { mutation in
                guard case .object(var value) = mutation else { return mutation }
                if value["record"] == .null { value.removeValue(forKey: "record") }
                // Preference.record.value can itself be null and must survive.
                return .object(value)
            })
        }
        if v2, case .object(var screen) = result["screen"], screen["requiredAssets"] == .null {
            screen.removeValue(forKey: "requiredAssets")
            result["screen"] = .object(screen)
        }
        return try JSONEncoder().encode(JSON.object(result))
    }
}
