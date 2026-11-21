import Foundation

/// Supplies a setup descriptor for known legacy Generator packages. This is applied
/// to the native view of the installed manifest; the saved package stays immutable.
public enum LegacyGeneratorConnection {
    private static let legacy = ManifestConnection(alias: "generator", required: true,
                                                   operations: [.init(name: "telemetry", kind: "http")])

    // Hashes of the sorted path and SHA-256 pairs from retained Generator revisions.
    private static let knownFiles: Set<String> = [
        "b698539bb8e05b94b24024a26b062d71b4f3b275cffe0bb6490a991ea881afea",
        "d797db964f345cccd4572408bff1344c423ac680083b4ee2263459630a5af1c3",
        "fe32451a5939b3c6998f2509c28cd30e6369a4934c69e600ae373bb33860ec8f"
    ]

    public static func enrich(_ manifest: DashboardManifest, appDigest: String?) -> DashboardManifest {
        guard manifest.dashboardId == "generator-studio", manifest.entrypoint == "index.html",
              manifest.schemaVersion == 1, manifest.sdkVersion == "1",
              manifest.connections == [legacy],
              let appDigest, manifest.files.first(where: { $0.path == "app.js" })?.sha256 == appDigest,
              manifest.files.count == 4 else { return manifest }

        let files = manifest.files.sorted { $0.path < $1.path }.map { "\($0.path):\($0.sha256)" }.joined(separator: "\n")
        guard knownFiles.contains(CatalogContract.digest(Data(files.utf8))) else { return manifest }

        var effective = manifest
        effective.connections = [.init(alias: legacy.alias, required: legacy.required, customHTTP: .init(
            id: "generator-telemetry", version: 1, label: "Generator",
            fields: [.init(id: "origin", label: "Server address", type: "url"),
                     .init(id: "credential", label: "Bearer token", type: "secret")],
            originField: "origin", auth: .init(field: "credential"),
            operations: [.init(name: "telemetry", path: "/telemetry")]
        ))]
        return effective
    }

    /// Materializes the compatibility descriptor in a newly authored revision if
    /// the result retains the legacy operation. Explicit connection changes win.
    public static func carryForward(_ descriptor: ManifestConnection, into bytes: Data) throws -> Data {
        guard descriptor.alias == legacy.alias, descriptor.customHTTP != nil,
              let next = try? JSONDecoder().decode(DashboardManifest.self, from: bytes),
              next.dashboardId == "generator-studio", next.entrypoint == "index.html", next.sdkVersion == "1",
              let index = next.connections.firstIndex(of: legacy),
              var document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var connections = document["connections"] as? [[String: Any]],
              let replacement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any] else { return bytes }
        try CustomHTTPDeclaration.validateConnections(next.connections.enumerated().map { $0.offset == index ? descriptor : $0.element })
        connections[index] = replacement
        document["connections"] = connections
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }

}
