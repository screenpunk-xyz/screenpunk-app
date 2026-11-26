import Foundation
import CoreFoundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct AuthoringContractError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let path: String
    public init(_ message: String, path: String = "$") { self.message = message; self.path = path }
    public var errorDescription: String? { "\(path): \(message)" }
}

/// Canonical authoring v1. Definitions and conformance vectors are mirrored by sync-authoring.mjs.
public enum AuthoringContract {
    public static let definition: AuthoringDefinitionV1 = {
        guard let url = Bundle.module.url(forResource: "authoring-v1", withExtension: "json", subdirectory: "AuthoringResources"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(AuthoringDefinitionV1.self, from: data) else {
            preconditionFailure("Bundled authoring contract is missing or corrupt")
        }
        return value
    }()
    public static let designGuidance = definition.designGuidance
    public static let runtime = definition.runtime
    public static var browserRuntime: AuthoringRuntimeV1 {
        guard let value = definition.browser?.runtime else { preconditionFailure("Bundled browser runtime missing") }
        return value
    }
    public static var browserDesignGuidance: AuthoringDesignGuidanceV1 {
        guard let value = definition.browser?.designGuidance else { preconditionFailure("Bundled browser guidance missing") }
        return value
    }
    public static let serviceCatalog = definition.serviceCatalog
    public static let screenAuthoringGuidance = definition.designGuidance.rules
    public static let resultMetadataBytes = 131072
    public static let resultBytes = 393216

    public static let publicPageTextFeature = "public-page-text-v1"
    public static let publicPageTextRule = "Prefer a documented structured feed when it provides the same information. With public-page-text-v1, a server-rendered public HTTPS page can use publicHTTP with an operation such as {\"name\":\"status\",\"path\":\"/status\",\"response\":\"text\",\"parameters\":{},\"maxAgeSeconds\":900,\"staleSeconds\":3600}. Use the actual fixed path without query or fragment and mark the connection required for an inline approval prompt. If a documented month-paged calendar requires cal_date, declare it as a bounded integer query parameter and pass the documented date value as a string. Call await screenpunk.connections.read(alias, operation, parameters, {signal}) with {} for unparameterized pages and read result.text. The native host fetches UTF-8 HTML or plain text directly and returns the decoded response as text, up to 256 KiB. Website scripts, subresources, forms, sign-in and redirects are unavailable. Parse expected labels or values as inert data. Render only the extracted values with textContent. Never insert response markup into a document. Keep private data in supported native integrations or documented custom HTTP JSON operations whose origin and credentials the user configures in Settings. Refresh on open and when visible on the requested cadence, honor retryAfterSeconds, keep one read in flight, and stop while inactive. After a stale result or transient error, show the timestamped last valid reading, or an unavailable state if there is none. Ask the user to approve the source when permission is required."
    public static let credentialRegistrationFeature = "credential-registration-v1"
    public static let credentialRegistrationRule: String = {
        guard case .object(let config) = AuthoringV2Contract.definition["credentialRegistration"],
              case .string(let rule) = config["rule"] else { preconditionFailure("Bundled credential registration rule missing") }
        return rule
    }()
    static var legacyCredentialRegistrationRule: String? {
        guard case .object(let config) = AuthoringV2Contract.definition["credentialRegistration"],
              case .string(let rule) = config["legacyRule"] else { return nil }
        return rule
    }
    public static let credentialHandoffFeature = "credential-handoff-v1"
    public static let credentialHandoffRule = "For a Cloud V2 request advertising credential-handoff-v1, a paired helper can deliver a bearer for an HTTPS custom connection. After complete_request succeeds with the matching connectionSetupProposals entry, call request_credential_handoff with the request ID, connection alias and operator-configured credential name. The name identifies the entry on the helper. Never read the bearer or include it in a tool call, screen, setup proposal, progress message or result. Delivery requires separate review on the requesting device. Manual entry is available."
    public static let connectionPrefillFeature = "custom-http-prefill-v1"
    public static let connectionPrefillRule = "When runtime.features includes custom-http-prefill-v1 and schemaVersion is 2, complete_request may include connectionSetupProposals: [{version:1,alias,declaration,fields}]. Write manifest.json in the same result; declaration must exactly equal that alias’s customHTTP declaration. fields contains only nonsecret declared field IDs and string values validated by their types; include the origin URL. Never include credentials, credential references, tokens, headers, or private-network approvals. These are device-local form suggestions for this request’s device and screen, never saved settings or permission. Existing settings remain unchanged. The user reviews setup and access in native UI before any request."
    public static let customHTTPFeature = "custom-http-v1"

    public static func designGuidance(supportsScreenData: Bool, supportsCustomHTTP: Bool = false, supportsConnectionPrefill: Bool = false, supportsCredentialHandoff: Bool = false, supportsCredentialRegistration: Bool = false, supportsPublicPageText: Bool = false) -> AuthoringDesignGuidanceV1 {
        var guidance = designGuidance
        if supportsScreenData { guidance.rules += definition.screenData?.rules ?? [] }
        if supportsCustomHTTP { guidance.rules += definition.customHTTP?.rules ?? [] }
        if supportsConnectionPrefill { guidance.rules.append(connectionPrefillRule) }
        if supportsCredentialHandoff { guidance.rules.append(credentialHandoffRule) }
        if supportsCredentialRegistration { guidance.rules.append(credentialRegistrationRule) }
        if supportsPublicPageText { guidance.rules.append(publicPageTextRule) }
        return guidance
    }

    public static func runtime(supportsScreenData: Bool, supportsCustomHTTP: Bool = false, supportsConnectionPrefill: Bool = false, supportsCredentialHandoff: Bool = false, supportsCredentialRegistration: Bool = false, supportsPublicPageText: Bool = false) -> AuthoringRuntimeV1 {
        var runtime = runtime
        if supportsScreenData { runtime.features += definition.screenData?.features ?? [] }
        if supportsCustomHTTP { runtime.features.append(customHTTPFeature) }
        if supportsConnectionPrefill { runtime.features.append(connectionPrefillFeature) }
        if supportsCredentialHandoff { runtime.features.append(credentialHandoffFeature) }
        if supportsCredentialRegistration { runtime.features.append(credentialRegistrationFeature) }
        if supportsPublicPageText { runtime.features.append(publicPageTextFeature) }
        return runtime
    }

    static func validateManifest(_ content: String, previous: String? = nil, runtime: AuthoringRuntimeV1? = nil) throws {
        let screenData = runtime.map { candidate in
            definition.screenData?.features.allSatisfy(candidate.features.contains) == true
        } ?? true
        try ScreenDataContract.validateManifestDeclaration(content, previous: previous, supportsScreenData: screenData)
        try CustomHTTPDeclaration.validateManifest(content, previous: previous, supported: runtime?.features.contains(customHTTPFeature) ?? true)
    }

    public static func makeServices(observedAt: Int64) -> [AuthoringServiceV1] {
        serviceCatalog.map { service in
            let unknown = AuthoringCapabilityStateV1(observedAt: observedAt)
            return AuthoringServiceV1(id: service.id, provider: service.provider, operations: service.operations,
                supported: .init(state: "yes", observedAt: observedAt),
                configured: .init(state: service.provider == "googleCalendar" ? "no" : "unknown", observedAt: observedAt),
                authorized: unknown, entitled: unknown, reachable: unknown)
        }
    }
    public static func validatePreferenceRecord(_ data: Data) throws -> PreferenceRecordV1 {
        try validateSchema("Preference", data: data)
        return try JSONDecoder().decode(PreferenceRecordV1.self, from: data)
    }
    public static func validateApplicationReceipt(_ data: Data) throws -> ApplicationReceiptV1 {
        try validateSchema("Receipt", data: data)
        return try JSONDecoder().decode(ApplicationReceiptV1.self, from: data)
    }
    public static func validateRequest(_ data: Data) throws -> AuthoringRequestV1 {
        guard data.count <= runtime.limits.requestBytes else { throw AuthoringContractError("request byte limit") }
        try validateSchema("Request", data: data)
        let request = try JSONDecoder().decode(AuthoringRequestV1.self, from: data)
        guard request.deadlineAt > request.createdAt else { throw AuthoringContractError("deadline must follow creation") }
        let screenData = definition.screenData?.features.allSatisfy(request.runtime.features.contains) == true
        let customHTTP = request.runtime.features.contains(customHTTPFeature)
        let prefill = request.runtime.features.contains(connectionPrefillFeature)
        let handoff = request.runtime.features.contains(credentialHandoffFeature)
        let registration = request.runtime.features.contains(credentialRegistrationFeature)
        let pageText = request.runtime.features.contains(publicPageTextFeature)
        guard !(handoff || registration) || (prefill && request.delivery.route == "cloud") else {
            throw AuthoringContractError("credential handoff requires Cloud connection prefill")
        }
        guard !prefill || customHTTP else { throw AuthoringContractError("prefill requires custom HTTP") }
        let browser = request.runtime == browserRuntime
        let guidance = browser ? browserDesignGuidance : designGuidance(supportsScreenData: screenData,
            supportsCustomHTTP: customHTTP, supportsConnectionPrefill: prefill,
            supportsCredentialHandoff: handoff, supportsCredentialRegistration: registration, supportsPublicPageText: pageText)
        var legacyGuidance: AuthoringDesignGuidanceV1?
        if !browser, registration, let legacyRule = legacyCredentialRegistrationRule,
           let index = guidance.rules.firstIndex(of: credentialRegistrationRule) {
            var previous = guidance
            previous.rules[index] = legacyRule
            legacyGuidance = previous
        }
        guard request.runtime == (browser ? browserRuntime : runtime(supportsScreenData: screenData, supportsCustomHTTP: customHTTP, supportsConnectionPrefill: prefill, supportsCredentialHandoff: handoff, supportsCredentialRegistration: registration, supportsPublicPageText: pageText)),
              request.designGuidance == guidance || request.designGuidance == legacyGuidance else {
            throw AuthoringContractError("unsupported guidance/runtime definition")
        }
        if browser, !request.services.isEmpty || !request.preferences.isEmpty {
            throw AuthoringContractError("browser runtime requires empty services and preferences")
        }
        var services = Set<String>()
        for service in request.services {
            guard services.insert(service.id).inserted,
                  let catalog = serviceCatalog.first(where: { $0.provider == service.provider }),
                  service.operations == catalog.operations else { throw AuthoringContractError("unsupported/duplicate service definition") }
            for state in [service.supported,service.configured,service.authorized,service.entitled,service.reachable] {
                guard state.observedAt <= request.createdAt else { throw AuthoringContractError("capability observation is in the future") }
            }
        }
        var preferences = Set<String>()
        for preference in request.preferences {
            guard preferences.insert(preference.id).inserted,
                  preference.targetID == target(scope: preference.scope, context: request.context) else { throw AuthoringContractError("duplicate/out-of-scope preference") }
        }
        if let screen = request.context.currentScreen { try validateScreen(screen) }
        var metadata = request; metadata.context.currentScreen = nil
        guard try encodedCanonical(metadata).count <= runtime.limits.metadataBytes,
              try encodedCanonical(request).count <= runtime.limits.requestBytes else { throw AuthoringContractError("request byte limit") }
        guard try snapshotDigest(request) == request.delivery.snapshotDigest else { throw AuthoringContractError("snapshot digest mismatch") }
        return request
    }
    public static func validateResult(_ data: Data, request: AuthoringRequestV1? = nil) throws -> AuthoringResultV1 {
        guard data.count <= runtime.limits.requestBytes else { throw AuthoringContractError("result byte limit") }
        try validateSchema("Result", data: data)
        let result = try JSONDecoder().decode(AuthoringResultV1.self, from: data)
        if let answer = result.answer, answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.utf16.count > 16000 { throw AuthoringContractError("answer requires 1–16000 UTF16 code units", path:"$.answer") }
        guard try encodedCanonical(result).count <= resultBytes else { throw AuthoringContractError("result byte limit") }
        var metadata = result; metadata.screen = nil
        guard try encodedCanonical(metadata).count <= resultMetadataBytes else { throw AuthoringContractError("result metadata byte limit") }
        guard result.screen != nil || result.answer != nil || !(result.preferenceMutations ?? []).isEmpty else { throw AuthoringContractError("empty result") }
        if let screen = result.screen { try validateScreen(screen) }
        let mutations = result.preferenceMutations ?? []
        if !mutations.isEmpty {
            guard let authorization = result.durablePreferenceAuthorization,
                  authorization.requestID == result.requestID,
                  authorization.quote.range(of: "\\b(remember|always)\\b", options: [.regularExpression,.caseInsensitive]) != nil else {
                throw AuthoringContractError("explicit durable preference authorization required")
            }
        }
        var ids = Set<String>()
        for mutation in mutations {
            guard ids.insert(mutation.id).inserted else { throw AuthoringContractError("duplicate preference mutation") }
            if mutation.kind == "upsert" {
                guard let record = mutation.record, record.id == mutation.id, record.revision == (mutation.expectedRevision ?? 0) + 1,
                      record.originRequestID == result.requestID, !record.deleted else { throw AuthoringContractError("invalid upsert revision/record") }
            } else {
                guard mutation.record == nil, mutation.expectedRevision != nil else { throw AuthoringContractError("invalid delete mutation") }
            }
        }
        if let request {
            _ = try validateRequest(JSONEncoder().encode(request))
            if request.runtime == browserRuntime, !mutations.isEmpty {
                throw AuthoringContractError("browser runtime does not support preference mutations")
            }
            if let manifest = result.screen?.files.first(where: { $0.path == "manifest.json" }) {
                try validateManifest(manifest.content,
                    previous: request.context.currentScreen?.files.first(where: { $0.path == "manifest.json" })?.content,
                    runtime: request.runtime)
            }
            guard result.requestID == request.requestID, result.inputDigest == request.delivery.snapshotDigest,
                  result.baseRevision == request.context.baseRevision else { throw AuthoringContractError("result is not bound to request snapshot") }
            let revisions = Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id,$0.revision) })
            guard result.preferenceRevisions == revisions else { throw AuthoringContractError("preference revisions differ from snapshot") }
            if !mutations.isEmpty {
                guard let authorization = result.durablePreferenceAuthorization, request.context.userRequest.contains(authorization.quote) else { throw AuthoringContractError("authorization quote not present in user request") }
            }
            for mutation in mutations {
                let old = request.preferences.first { $0.id == mutation.id }
                guard old?.revision == mutation.expectedRevision else { throw AuthoringContractError("mutation expected revision differs from snapshot") }
                if let record = mutation.record {
                    guard record.targetID == target(scope: record.scope, context: request.context),
                          old == nil || (old?.scope == record.scope && old?.targetID == record.targetID) else { throw AuthoringContractError("mutation target outside request scope") }
                }
            }
        }
        return result
    }
    public static func seal(_ request: AuthoringRequestV1) throws -> AuthoringRequestV1 {
        var sealed = request
        sealed.delivery.snapshotDigest = try snapshotDigest(sealed)
        return try validateRequest(JSONEncoder().encode(sealed))
    }
    public static func snapshotDigest(_ request: AuthoringRequestV1) throws -> String {
        var object = try json(JSONEncoder().encode(request)) as! [String: Any]
        var delivery = object["delivery"] as! [String: Any]
        delivery.removeValue(forKey: "snapshotDigest"); object["delivery"] = delivery
        return contentDigest(Data(try canonical(object).utf8))
    }
    public static func contentDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        preconditionFailure("SHA256 requires CryptoKit on supported Apple platforms")
        #endif
    }
    /// Canonicalize JSON bytes for stable operation fingerprints across TS and Swift.
    public static func canonicalJSON(_ data: Data) throws -> Data { Data(try canonical(json(data)).utf8) }
    public static func encodedCanonical<T: Encodable>(_ value: T) throws -> Data { try canonicalJSON(JSONEncoder().encode(value)) }
    private static func target(scope: String, context: AuthoringContextV1) -> String {
        scope == "profile" ? context.profileID : scope == "device" ? context.deviceID : context.screenID
    }
    public static func validateScreen(_ data: Data) throws -> AuthoringScreen {
        let root = try json(JSONEncoder().encode(definition.schemas["Request"]!)) as! [String: Any]
        let defs = root["$defs"] as! [String: Any]
        try check(defs["Screen"] as! [String: Any], value: json(data), defs: defs, path: "$.screen")
        let screen = try JSONDecoder().decode(AuthoringScreen.self, from: data)
        try validateScreen(screen); return screen
    }
    private static func validateScreen(_ screen: AuthoringScreen) throws {
        guard !screen.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, screen.title.utf16.count <= 100 else { throw AuthoringContractError("screen title requires 1–100 UTF16 code units") }
        var paths = Set<String>()
        for file in screen.files {
            let path = file.path
            guard path.range(of: "^[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*\\.(?:html|css|js|json|svg|txt)$", options: .regularExpression) != nil,
                  paths.insert(path.lowercased()).inserted else { throw AuthoringContractError("unsafe/duplicate screen path") }
        }
        guard screen.files.contains(where: { $0.path == "index.html" }), try encodedCanonical(screen).count <= runtime.limits.screenBytes else { throw AuthoringContractError("screen entry/serialized size limit") }
        if let manifest = screen.files.first(where: { $0.path == "manifest.json" }) {
            try validateManifest(manifest.content)
        }
    }
    private static func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    private static func validateSchema(_ name: String, data: Data) throws {
        guard data.count <= runtime.limits.requestBytes else { throw AuthoringContractError("byte limit") }
        let root = try json(JSONEncoder().encode(definition.schemas[name]!)) as! [String: Any]
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
        if let constant = schema["const"], try canonical(constant) != canonical(value) { try reject("unexpected constant/version") }
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
    private static func canonical(_ value: Any, depth: Int = 0) throws -> String {
        guard depth <= 64 else { throw AuthoringContractError("JSON nesting exceeds 64") }
        if value is NSNull { return "null" }
        if let string = value as? String { return String(decoding: try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed,.withoutEscapingSlashes]), as: UTF8.self) }
        if let number = value as? NSNumber {
            if isBoolean(value) { return number.boolValue ? "true" : "false" }
            return try numberString(number.doubleValue)
        }
        if let array = value as? [Any] { return "[" + (try array.map { try canonical($0, depth: depth + 1) }).joined(separator: ",") + "]" }
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { try canonical($0) + ":" + canonical(object[$0]!, depth: depth + 1) }).joined(separator: ",") + "}"
        }
        throw AuthoringContractError("unsupported JSON value")
    }
    /// ECMAScript JSON number display thresholds, using Swift's shortest roundtrip digits.
    private static func numberString(_ value: Double) throws -> String {
        guard value.isFinite else { throw AuthoringContractError("nonfinite number") }
        if value == 0 { return "0" }
        let sign = value < 0 ? "-" : ""
        let parts = String(abs(value)).lowercased().split(separator: "e")
        let mantissa = String(parts[0]); let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let halves = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(halves[0]) + (halves.count == 2 ? String(halves[1]) : "")
        var decimal = halves[0].count + exponent
        while digits.count > 1 && digits.first == "0" { digits.removeFirst(); decimal -= 1 }
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }
        if abs(value) >= 1e-6 && abs(value) < 1e21 {
            if decimal <= 0 { return sign + "0." + String(repeating: "0", count: -decimal) + digits }
            if decimal >= digits.count { return sign + digits + String(repeating: "0", count: decimal - digits.count) }
            let at = digits.index(digits.startIndex, offsetBy: decimal)
            return sign + digits[..<at] + "." + digits[at...]
        }
        let first = String(digits.removeFirst()); let tail = digits.isEmpty ? "" : "." + digits
        let power = decimal - 1
        return sign + first + tail + "e" + (power >= 0 ? "+" : "") + String(power)
    }
}
