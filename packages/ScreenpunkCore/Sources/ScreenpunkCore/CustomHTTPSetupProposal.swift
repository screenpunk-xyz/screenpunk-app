import Foundation

/// Request-bound suggestions, never configuration, credentials or authorization.
public struct CustomHTTPSetupProposal: Codable, Equatable, Sendable {
    public var version: Int
    public var alias: String
    public var declaration: CustomHTTPDeclaration
    public var fields: [String: String]

    public init(version: Int = 1, alias: String, declaration: CustomHTTPDeclaration, fields: [String: String]) {
        self.version = version; self.alias = alias; self.declaration = declaration; self.fields = fields
    }

    public static func validate(result: AuthoringResultV2, request: AuthoringRequestV2?) throws {
        guard let proposals = result.connectionSetupProposals else { return }
        guard let request, request.runtime.features.contains(AuthoringContract.connectionPrefillFeature),
              request.runtime.features.contains(AuthoringContract.customHTTPFeature),
              let manifest = result.screen?.files.first(where: { $0.path == "manifest.json" }),
              manifest.kind == "write", let content = manifest.content,
              (1...8).contains(proposals.count), Set(proposals.map(\.alias)).count == proposals.count else {
            throw AuthoringContractError("unsupported or unbound connection setup proposal")
        }
        struct Connections: Decodable { var connections: [ManifestConnection] }
        let connections = try JSONDecoder().decode(Connections.self, from: Data(content.utf8)).connections
        try CustomHTTPDeclaration.validateConnections(connections)
        for proposal in proposals {
            guard proposal.version == 1,
                  connections.first(where: { $0.alias == proposal.alias })?.customHTTP == proposal.declaration,
                  proposal.fields[proposal.declaration.originField] != nil else {
                throw AuthoringContractError("connection setup declaration mismatch")
            }
            try proposal.declaration.validate(alias: proposal.alias)
            for (key, value) in proposal.fields {
                guard let field = proposal.declaration.fields.first(where: { $0.id == key }),
                      field.type != "secret", !ConnectionAuthKeys.isOverride(key) else {
                    throw AuthoringContractError("connection setup must contain only nonsecret fields")
                }
                try field.validate(value)
            }
        }
    }
}
