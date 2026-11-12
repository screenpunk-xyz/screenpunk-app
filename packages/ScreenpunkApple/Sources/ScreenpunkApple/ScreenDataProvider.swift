import Foundation
import ScreenpunkCore

/// Implemented by the native host for one installed screen and session generation.
/// Its bound identity and current declarations must be revalidated by the host;
/// the browser can supply only the name, alias, or published value.
@MainActor
public protocol ScreenDataProvider: AnyObject {
    func publish(name: String, value: AuthoringJSONValue) throws
    func remove(name: String) throws
    func query(alias: String) async throws -> ScreenDataSnapshot
}

enum ScreenDataBridgeRequest: Equatable {
    case publish(String, AuthoringJSONValue)
    case remove(String)
    case query(String)

    init(body: [String: Any]) throws {
        let envelope: Set = ["protocolVersion", "kind", "id", "method"]
        let keys = Set(body.keys)
        switch body["method"] as? String {
        case "data.publish":
            guard keys == envelope.union(["name", "value"]),
                  let name = body["name"] as? String, ScreenDataContract.isName(name), let raw = body["value"],
                  let bytes = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let value = try? JSONDecoder().decode(AuthoringJSONValue.self, from: bytes) else { throw ScreenDataError.invalidRequest }
            try ScreenDataContract.validateValue(value)
            self = .publish(name, value)
        case "data.remove":
            guard keys == envelope.union(["name"]), let name = body["name"] as? String,
                  ScreenDataContract.isName(name) else { throw ScreenDataError.invalidRequest }
            self = .remove(name)
        case "data.query":
            guard keys == envelope.union(["alias"]), let alias = body["alias"] as? String,
                  ScreenDataContract.isName(alias) else { throw ScreenDataError.invalidRequest }
            self = .query(alias)
        default: throw ScreenDataError.invalidRequest
        }
    }

    @MainActor
    func authorizedProvider(_ provider: (any ScreenDataProvider)?, declaration: ManifestScreenData?, active: Bool) throws -> any ScreenDataProvider {
        guard active, let provider else { throw ScreenDataError.unavailable }
        let declared: Bool
        switch self {
        case .publish(let name, _), .remove(let name): declared = declaration?.exports.contains { $0.name == name } == true
        case .query(let alias): declared = declaration?.queries.contains { $0.alias == alias } == true
        }
        guard declared else { throw ScreenDataError.permissionRequired }
        return provider
    }
}
