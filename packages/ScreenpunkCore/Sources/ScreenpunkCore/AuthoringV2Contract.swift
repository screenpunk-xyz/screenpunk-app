import Foundation
import CoreFoundation

/// V2 adds request-scoped immutable source references; v1 remains whole replacement.
public enum AuthoringV2Contract {
    public static let definition: [String: AuthoringJSONValue] = {
        guard let url = Bundle.module.url(forResource: "authoring-v2", withExtension: "json", subdirectory: "AuthoringResources"), let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: AuthoringJSONValue].self, from: data) else { preconditionFailure("Bundled v2 authoring contract missing/corrupt") }
        return value
    }()
    private static var schemas: [String: AuthoringJSONValue] { guard case .object(let schemas) = definition["schemas"] else { preconditionFailure("Invalid v2 schemas") }; return schemas }
    public static var resultSchema: AuthoringJSONValue { schemas["Result"]! }
    public static var requestSchema: AuthoringJSONValue { schemas["Request"]! }
    public static let capabilities = AuthoringCapabilitiesV2()
    public static func mediaType(path: String) throws -> String {
        guard let ext = path.split(separator: ".").last, let media = ["html":"text/html","css":"text/css","js":"text/javascript","json":"application/json","svg":"image/svg+xml","txt":"text/plain"][String(ext)] else { throw AuthoringContractError("unsupported file extension") }
        return media
    }
    public static func reference(request: AuthoringRequestV2, file: AuthoringSourceFileV2) throws -> String {
        let value: [String: AuthoringJSONValue] = ["version":.number(2),"requestID":.string(request.requestID),"profileID":.string(request.context.profileID),"libraryID":.string(request.context.libraryID),"screenID":.string(request.context.screenID),"baseRevision":request.context.baseRevision.map(AuthoringJSONValue.string) ?? .null,"path":.string(file.path),"mediaType":.string(file.mediaType),"byteLength":.number(Double(file.byteLength)),"digest":.string(file.digest)]
        return AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(value))
    }
    public static func snapshotDigest(_ request: AuthoringRequestV2) throws -> String {
        var root = try json(JSONEncoder().encode(request)) as! [String: Any]
        var delivery = root["delivery"] as! [String: Any]; delivery.removeValue(forKey: "snapshotDigest"); root["delivery"] = delivery
        return AuthoringContract.contentDigest(try AuthoringContract.canonicalJSON(JSONSerialization.data(withJSONObject: root)))
    }
    public static func seal(_ request: AuthoringRequestV2) throws -> AuthoringRequestV2 {
        var sealed = request
        if var source = sealed.context.currentScreen { for index in source.files.indices { source.files[index].reference = try reference(request: sealed, file: source.files[index]) }; sealed.context.currentScreen = source }
        sealed.delivery.snapshotDigest = try snapshotDigest(sealed)
        return try validateRequest(JSONEncoder().encode(sealed))
    }
    /// The caller supplies its actual saved-library owner, not an account/profile alias.
    public static func makeRequest(from request: AuthoringRequestV1, libraryID: String, includeContent: (AuthoringScreenFile) -> Bool = { file in !(file.path.hasSuffix(".svg") && (file.content.range(of: "data:image/", options: .caseInsensitive) != nil || file.content.range(of: "base64,", options: .caseInsensitive) != nil)) }) throws -> AuthoringRequestV2 {
        _ = try AuthoringContract.validateRequest(JSONEncoder().encode(request))
        let source = try request.context.currentScreen.map { screen in
            AuthoringSourceScreenV2(title: screen.title, entry: screen.entry, files: try screen.files.map { file in .init(path: file.path, mediaType: try mediaType(path: file.path), byteLength: file.content.utf8.count, digest: AuthoringContract.contentDigest(Data(file.content.utf8)), content: includeContent(file) ? file.content : nil) })
        }
        return try seal(.init(requestID: request.requestID, createdAt: request.createdAt, deadlineAt: request.deadlineAt, designGuidance: request.designGuidance, runtime: request.runtime, services: request.services, preferences: request.preferences,
            context: .init(profileID: request.context.profileID, libraryID: libraryID, deviceID: request.context.deviceID, screenID: request.context.screenID, baseRevision: request.context.baseRevision, userRequest: request.context.userRequest, currentScreen: source, viewport: request.context.viewport), delivery: .init(route: request.delivery.route)))
    }
    public static func validateRequest(_ data: Data) throws -> AuthoringRequestV2 {
        guard data.count <= 393216 else { throw AuthoringContractError("request byte limit") }
        try validateSchema("Request", data: data)
        let request = try JSONDecoder().decode(AuthoringRequestV2.self, from: data)
        _ = try request.legacyRequest()
        guard (request.context.currentScreen != nil) == (request.context.baseRevision != nil) else { throw AuthoringContractError("base revision and source manifest must appear together") }
        if let source = request.context.currentScreen {
            guard !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.title.utf16.count <= 100 else { throw AuthoringContractError("invalid source title") }
            var paths = Set<String>(); var bytes = 0
            for file in source.files {
                guard paths.insert(file.path.lowercased()).inserted else { throw AuthoringContractError("duplicate source path") }
                guard file.mediaType == (try mediaType(path: file.path)), file.reference == (try reference(request: request, file: file)) else { throw AuthoringContractError("source scope/reference/media mismatch") }
                bytes += file.byteLength
                if let content = file.content { guard content.utf8.count == file.byteLength, AuthoringContract.contentDigest(Data(content.utf8)) == file.digest else { throw AuthoringContractError("source content hash/length mismatch") } }
            }
            guard bytes <= 204800, source.files.contains(where: { $0.path == "index.html" }) else { throw AuthoringContractError("source package limit/entry") }
        }
        guard try snapshotDigest(request) == request.delivery.snapshotDigest, try AuthoringContract.encodedCanonical(request).count <= 393216 else { throw AuthoringContractError("snapshot digest/request size mismatch") }
        return request
    }
    public static func validateResult(_ data: Data, request: AuthoringRequestV2? = nil) throws -> AuthoringResultV2 {
        guard data.count <= 393216 else { throw AuthoringContractError("result byte limit") }
        try validateSchema("Result", data: data)
        let result = try JSONDecoder().decode(AuthoringResultV2.self, from: data)
        guard result.screen != nil || result.answer != nil || !(result.preferenceMutations ?? []).isEmpty else { throw AuthoringContractError("empty result") }
        var legacy = result.legacyResult(); legacy.screen = nil
        if legacy.answer == nil && (legacy.preferenceMutations ?? []).isEmpty { legacy.answer = "v2 screen validation" }
        if let request {
            _ = try validateRequest(JSONEncoder().encode(request))
            guard result.requestID == request.requestID, result.inputDigest == request.delivery.snapshotDigest, result.baseRevision == request.context.baseRevision else { throw AuthoringContractError("result is not bound to request snapshot") }
            let old = try request.legacyRequest(); legacy.inputDigest = old.delivery.snapshotDigest
            _ = try AuthoringContract.validateResult(JSONEncoder().encode(legacy), request: old)
        } else { _ = try AuthoringContract.validateResult(JSONEncoder().encode(legacy)) }
        var metadata = result; metadata.screen = nil
        guard try AuthoringContract.encodedCanonical(result).count <= 393216, try AuthoringContract.encodedCanonical(metadata).count <= 131072 else { throw AuthoringContractError("result byte limit") }
        if let screen = result.screen {
            guard !screen.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, screen.title.utf16.count <= 100 else { throw AuthoringContractError("invalid screen title") }
            var destinations = Set<String>(); var deleted = Set<String>(); var bytes = 0
            let base = request?.context.currentScreen?.files ?? []
            for path in screen.deletedPaths { guard deleted.insert(path.lowercased()).inserted else { throw AuthoringContractError("duplicate delete path") } }
            for file in screen.files {
                guard destinations.insert(file.path.lowercased()).inserted, !deleted.contains(file.path.lowercased()) else { throw AuthoringContractError("duplicate/overlapping destination") }
                if file.kind == "write" { bytes += file.content!.utf8.count }
                else if request != nil {
                    guard let source = base.first(where: { $0.path == file.sourcePath && $0.reference == file.reference && $0.digest == file.digest }) else { throw AuthoringContractError("unknown/out-of-scope source reference") }; bytes += source.byteLength
                }
            }
            guard bytes <= 204800, screen.files.contains(where: { $0.path == "index.html" }) else { throw AuthoringContractError("materialized entry/byte limit") }
            var required = Set<String>()
            for path in screen.requiredAssets ?? [] { guard required.insert(path.lowercased()).inserted, screen.files.contains(where: { $0.path == path }) else { throw AuthoringContractError("missing/duplicate declared asset") } }
            if request != nil {
                for path in screen.deletedPaths { guard base.contains(where: { $0.path == path }) else { throw AuthoringContractError("delete outside base snapshot") } }
                for file in base { guard screen.files.contains(where: { $0.path == file.path }) || screen.deletedPaths.contains(file.path) else { throw AuthoringContractError("unaccounted base file") } }
            }
        }
        return result
    }
    /// Resolver receives an already validated manifest member, never a caller-supplied destination.
    public static func materialize(_ result: AuthoringResultV2, request: AuthoringRequestV2, resolve: (AuthoringSourceFileV2) throws -> Data) throws -> AuthoringScreen {
        _ = try validateResult(JSONEncoder().encode(result), request: request)
        guard let mutation = result.screen else { throw AuthoringContractError("result has no screen") }
        var files: [AuthoringScreenFile] = []
        for file in mutation.files {
            if file.kind == "write" { files.append(.init(path: file.path, content: file.content!)); continue }
            let source = request.context.currentScreen!.files.first(where: { $0.path == file.sourcePath })!
            let bytes = try resolve(source)
            guard bytes.count == source.byteLength, AuthoringContract.contentDigest(bytes) == source.digest, String(data: bytes, encoding: .utf8) != nil else { throw AuthoringContractError("pinned source missing/corrupt/not UTF8") }
            files.append(.init(path: file.path, content: String(decoding: bytes, as: UTF8.self)))
        }
        return try AuthoringContract.validateScreen(JSONEncoder().encode(AuthoringScreen(title: mutation.title, entry: mutation.entry, files: files)))
    }
    private static func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    private static func validateSchema(_ name: String, data: Data) throws {
        let root = try json(JSONEncoder().encode(schemas[name]!)) as! [String: Any]
        try check(root, value: json(data), defs: root["$defs"] as! [String: Any], path: "$")
    }
    private static func isBoolean(_ value: Any) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private static func check(_ schema: [String: Any], value: Any, defs: [String: Any], path: String, depth: Int = 0) throws {
        func reject(_ message: String) throws -> Never { throw AuthoringContractError(message, path: path) }
        guard depth <= 64 else { try reject("nesting limit") }
        if let ref = schema["$ref"] as? String, let key = ref.split(separator: "/").last {
            try check(defs[String(key)] as! [String: Any], value: value, defs: defs, path: path, depth: depth + 1); return
        }
        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            for alternative in alternatives { if (try? check(alternative, value: value, defs: defs, path: path, depth: depth + 1)) != nil { return } }
            try reject("does not match allowed value")
        }
        if let constant = schema["const"], try AuthoringContract.canonicalJSON(JSONSerialization.data(withJSONObject: constant, options: [.fragmentsAllowed])) != AuthoringContract.canonicalJSON(JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) { try reject("unexpected constant/version") }
        if let choices = schema["enum"] as? [String], !((value as? String).map(choices.contains) ?? false) { try reject("unsupported enum") }
        let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map { [$0] } ?? []
        func matches(_ type: String) -> Bool {
            switch type {
            case "null": return value is NSNull
            case "object": return value is [String: Any]
            case "array": return value is [Any]
            case "boolean": return isBoolean(value)
            case "string": return value is String
            case "integer": guard let number = value as? NSNumber, !isBoolean(value) else { return false }; let n = number.doubleValue; return n.isFinite && n.rounded() == n && abs(n) <= 9007199254740991
            case "number": return (value as? NSNumber).map { !isBoolean(value) && $0.doubleValue.isFinite } ?? false
            default: return false
            }
        }
        if !types.isEmpty && !types.contains(where: matches) { try reject("invalid type") }
        if let text = value as? String {
            let n = text.unicodeScalars.count
            if let min = schema["minLength"] as? Int, n < min { try reject("string size limit") }
            if let max = schema["maxLength"] as? Int, n > max { try reject("string size limit") }
            if let max = schema["maxBytes"] as? Int, text.utf8.count > max { try reject("string size limit") }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) != text.startIndex..<text.endIndex { try reject("invalid string") }
        }
        if let number = value as? NSNumber, !isBoolean(value) {
            if let min = schema["minimum"] as? NSNumber, number.doubleValue < min.doubleValue { try reject("number out of bounds") }
            if let max = schema["maximum"] as? NSNumber, number.doubleValue > max.doubleValue { try reject("number out of bounds") }
        }
        if let array = value as? [Any] {
            if let min = schema["minItems"] as? Int, array.count < min { try reject("array size limit") }
            if let max = schema["maxItems"] as? Int, array.count > max { try reject("array size limit") }
            if let item = schema["items"] as? [String: Any] { for (index,v) in array.enumerated() { try check(item, value: v, defs: defs, path: "\(path)[\(index)]", depth: depth + 1) } }
        }
        if let object = value as? [String: Any] {
            if let max = schema["maxProperties"] as? Int, object.count > max { try reject("object size limit") }
            for key in schema["required"] as? [String] ?? [] { if object[key] == nil { throw AuthoringContractError("missing required field", path: "\(path).\(key)") } }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for (key,v) in object {
                if let names = schema["propertyNames"] as? [String: Any] { try check(names, value: key, defs: defs, path: "\(path).\(key)", depth: depth + 1) }
                if let child = properties[key] { try check(child, value: v, defs: defs, path: "\(path).\(key)", depth: depth + 1) }
                else if let allow = schema["additionalProperties"] as? Bool, !allow { throw AuthoringContractError("unknown field", path: "\(path).\(key)") }
                else if let child = schema["additionalProperties"] as? [String: Any] { try check(child, value: v, defs: defs, path: "\(path).\(key)", depth: depth + 1) }
            }
        }
    }
}
