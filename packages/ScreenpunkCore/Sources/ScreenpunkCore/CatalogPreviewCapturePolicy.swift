import Foundation

/// Ownership of the dashboard renderer, captured at view construction rather
/// than inferred from whichever account happens to be signed in during upload.
public struct CatalogPreviewScope: Codable, Equatable, Sendable {
    public var origin: String
    public var accountID: String
    public var profileID: String
    public var libraryID: String
    public var deviceID: String
    public init(origin: String, accountID: String, profileID: String, libraryID: String, deviceID: String) { self.origin = origin; self.accountID = accountID; self.profileID = profileID; self.libraryID = libraryID; self.deviceID = deviceID }
}
public struct CatalogPreviewCaptureProof: Sendable {
    public var scope: CatalogPreviewScope?
    public var revision: String
    public var generation: UUID
    public var files: [String: CatalogObjectDeclaration]
    public init(scope: CatalogPreviewScope?, revision: String, generation: UUID, files: [String: CatalogObjectDeclaration]) { self.scope = scope; self.revision = revision; self.generation = generation; self.files = files }
}
public enum CatalogPreviewCapturePolicy {
    public static func allows(_ actual: CatalogPreviewCaptureProof, scope: CatalogPreviewScope, revision: String, generation: UUID, package: CatalogPackage, packageDigest: String) -> Bool {
        guard actual.scope == scope, actual.revision == revision, actual.generation == generation,
              [scope.origin, scope.accountID, scope.profileID, scope.libraryID, scope.deviceID].allSatisfy({ !$0.isEmpty }),
              let canonical = try? CatalogContract.encodePackage(package), CatalogContract.digest(canonical) == packageDigest,
              Set(actual.files.keys) == Set(package.files.map(\.path)) else { return false }
        return package.files.allSatisfy { file in actual.files[file.path] == CatalogObjectDeclaration(byteLength: file.byteLength, digest: file.digest) }
    }
}
