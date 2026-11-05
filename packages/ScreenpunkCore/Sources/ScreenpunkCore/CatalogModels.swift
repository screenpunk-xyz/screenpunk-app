// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

public struct CatalogObjectDeclaration: Codable, Sendable, Equatable {
    public var byteLength: Int
    public var digest: String
    public init(byteLength: Int, digest: String) {
        self.byteLength = byteLength
        self.digest = digest
    }
}

public struct CatalogPreviewDeclaration: Codable, Sendable, Equatable {
    public var byteLength: Int
    public var digest: String
    public var mediaType: String
    public var width: Int
    public var height: Int
    public init(byteLength: Int, digest: String, mediaType: String, width: Int, height: Int) {
        self.byteLength = byteLength
        self.digest = digest
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

public struct CatalogGapDeclaration: Codable, Sendable, Equatable {
    public var checkpointCounter: Int
    public var checkpointRevisionID: String
    public var skippedFromCounter: Int
    public var skippedThroughCounter: Int
    public var reason: String
    public init(checkpointCounter: Int, checkpointRevisionID: String, skippedFromCounter: Int, skippedThroughCounter: Int, reason: String = "user_acknowledged_backup_pause") {
        self.checkpointCounter = checkpointCounter
        self.checkpointRevisionID = checkpointRevisionID
        self.skippedFromCounter = skippedFromCounter
        self.skippedThroughCounter = skippedThroughCounter
        self.reason = reason
    }
}

public struct CatalogBeginBackup: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var operationID: String
    public var libraryID: String
    public var localScreenID: String
    public var sourceRevisionID: String
    public var parentRevisionIDs: [String]
    public var predecessorRevisionID: String?
    public var commitCounter: Int
    public var origin: String
    public var sourceAppliedAt: String
    public var screenName: String
    public var versionName: String?
    public var note: String?
    public var gap: CatalogGapDeclaration?
    public var package: CatalogObjectDeclaration
    public var preview: CatalogPreviewDeclaration?
    public init(schemaVersion: Int = 1, operationID: String, libraryID: String, localScreenID: String, sourceRevisionID: String, parentRevisionIDs: [String], predecessorRevisionID: String?, commitCounter: Int, origin: String, sourceAppliedAt: String, screenName: String, versionName: String? = nil, note: String? = nil, gap: CatalogGapDeclaration? = nil, package: CatalogObjectDeclaration, preview: CatalogPreviewDeclaration? = nil) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.libraryID = libraryID
        self.localScreenID = localScreenID
        self.sourceRevisionID = sourceRevisionID
        self.parentRevisionIDs = parentRevisionIDs
        self.predecessorRevisionID = predecessorRevisionID
        self.commitCounter = commitCounter
        self.origin = origin
        self.sourceAppliedAt = sourceAppliedAt
        self.screenName = screenName
        self.versionName = versionName
        self.note = note
        self.gap = gap
        self.package = package
        self.preview = preview
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion,operationID,libraryID,localScreenID,sourceRevisionID,parentRevisionIDs,predecessorRevisionID,commitCounter,origin,sourceAppliedAt,screenName,versionName,note,gap,package,preview }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(libraryID, forKey: .libraryID)
        try c.encode(localScreenID, forKey: .localScreenID)
        try c.encode(sourceRevisionID, forKey: .sourceRevisionID)
        try c.encode(parentRevisionIDs, forKey: .parentRevisionIDs)
        try c.encode(predecessorRevisionID, forKey: .predecessorRevisionID)
        try c.encode(commitCounter, forKey: .commitCounter)
        try c.encode(origin, forKey: .origin)
        try c.encode(sourceAppliedAt, forKey: .sourceAppliedAt)
        try c.encode(screenName, forKey: .screenName)
        try c.encodeIfPresent(versionName, forKey: .versionName)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(gap, forKey: .gap)
        try c.encode(package, forKey: .package)
        try c.encodeIfPresent(preview, forKey: .preview)
    }
}

public struct CatalogPackageFile: Codable, Sendable, Equatable {
    public var path: String
    public var mediaType: String
    public var byteLength: Int
    public var digest: String
    public var contentBase64: String
    public init(path: String, mediaType: String, byteLength: Int, digest: String, contentBase64: String) {
        self.path = path
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.digest = digest
        self.contentBase64 = contentBase64
    }
}

public struct CatalogPackage: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var screen: CatalogPackageScreen
    public var files: [CatalogPackageFile]
    public init(schemaVersion: Int = 1, screen: CatalogPackageScreen, files: [CatalogPackageFile]) {
        self.schemaVersion = schemaVersion
        self.screen = screen
        self.files = files
    }
}

public struct CatalogError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var restartOperation: Bool?
    public var retryAfterSeconds: Int?
    public init(code: String, message: String, retryAfterSeconds: Int? = nil, restartOperation: Bool? = nil) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.restartOperation = restartOperation
    }
}

public struct CatalogEntitlement: Codable, Sendable, Equatable {
    public var backupEnabled: Bool
    public var reason: String
    public var versionsPerScreen: Int
    public var screensPerAccount: Int
    public var packageBytes: Int
    public var previewBytes: Int
    public var previewDimension: Int
    public var accountBytes: Int
    public var publicationOverlapBytes: Int
    public init(backupEnabled: Bool, reason: String, versionsPerScreen: Int, screensPerAccount: Int, packageBytes: Int, previewBytes: Int, previewDimension: Int, accountBytes: Int, publicationOverlapBytes: Int) {
        self.backupEnabled = backupEnabled
        self.reason = reason
        self.versionsPerScreen = versionsPerScreen
        self.screensPerAccount = screensPerAccount
        self.packageBytes = packageBytes
        self.previewBytes = previewBytes
        self.previewDimension = previewDimension
        self.accountBytes = accountBytes
        self.publicationOverlapBytes = publicationOverlapBytes
    }
}

public struct CatalogCapability: Codable, Sendable, Equatable {
    public var version: String
    public var feature: String
    public var entitlement: CatalogEntitlement
    public var previewBackfillVersion: String?
    public var previewMediaTypes: [String]
    public init(version: String = "1", feature: String = "catalog-backup-v1", entitlement: CatalogEntitlement, previewMediaTypes: [String], previewBackfillVersion: String? = nil) {
        self.version = version
        self.feature = feature
        self.entitlement = entitlement
        self.previewMediaTypes = previewMediaTypes
        self.previewBackfillVersion = previewBackfillVersion
    }
}

public struct CatalogBackupStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var operationID: String
    public var state: String
    public var catalogScreenID: String
    public var uploadID: String?
    public var versionID: String?
    public var displayVersion: Int?
    public var expiresAt: String?
    public var error: CatalogError?
    public init(schemaVersion: Int = 1, operationID: String, state: String, catalogScreenID: String, uploadID: String? = nil, versionID: String? = nil, displayVersion: Int? = nil, expiresAt: String? = nil, error: CatalogError? = nil) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.state = state
        self.catalogScreenID = catalogScreenID
        self.uploadID = uploadID
        self.versionID = versionID
        self.displayVersion = displayVersion
        self.expiresAt = expiresAt
        self.error = error
    }
}

public struct CatalogCompleteBackup: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var operationID: String
    public init(schemaVersion: Int = 1, operationID: String) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
    }
}

public struct CatalogVersion: Codable, Sendable, Equatable {
    public var versionID: String
    public var catalogScreenID: String
    public var displayVersion: Int
    public var sourceRevisionID: String
    public var parentRevisionIDs: [String]
    public var copyID: String
    public var commitCounter: Int
    public var screenName: String
    public var versionName: String?
    public var note: String?
    public var sourceAppliedAt: String
    public var backedUpAt: String
    public var packageSchema: Int
    public var packageDigest: String
    public var sizeBytes: Int
    public var deviceDisplayName: String
    public var integrity: String?
    public var deviceLinked: Bool
    public var preview: CatalogPreview
    public init(versionID: String, catalogScreenID: String, displayVersion: Int, sourceRevisionID: String, parentRevisionIDs: [String], copyID: String, commitCounter: Int, screenName: String, versionName: String? = nil, note: String? = nil, sourceAppliedAt: String, backedUpAt: String, packageSchema: Int = 1, packageDigest: String, sizeBytes: Int, deviceDisplayName: String, deviceLinked: Bool, preview: CatalogPreview, integrity: String? = nil) {
        self.versionID = versionID
        self.catalogScreenID = catalogScreenID
        self.displayVersion = displayVersion
        self.sourceRevisionID = sourceRevisionID
        self.parentRevisionIDs = parentRevisionIDs
        self.copyID = copyID
        self.commitCounter = commitCounter
        self.screenName = screenName
        self.versionName = versionName
        self.note = note
        self.sourceAppliedAt = sourceAppliedAt
        self.backedUpAt = backedUpAt
        self.packageSchema = packageSchema
        self.packageDigest = packageDigest
        self.sizeBytes = sizeBytes
        self.deviceDisplayName = deviceDisplayName
        self.deviceLinked = deviceLinked
        self.integrity = integrity
        self.preview = preview
    }
}

public struct CatalogScreen: Codable, Sendable, Equatable {
    public var catalogScreenID: String
    public var latest: CatalogVersion
    public var history: [CatalogVersion]
    public init(catalogScreenID: String, latest: CatalogVersion, history: [CatalogVersion]) {
        self.catalogScreenID = catalogScreenID
        self.latest = latest
        self.history = history
    }
}

public struct CatalogList: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var catalogRevision: Int
    public var entitlement: CatalogEntitlement
    public var usage: CatalogListUsage
    public var screens: [CatalogScreen]
    public var nextCursor: String?
    public init(schemaVersion: Int = 1, catalogRevision: Int, entitlement: CatalogEntitlement, usage: CatalogListUsage, screens: [CatalogScreen], nextCursor: String? = nil) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.entitlement = entitlement
        self.usage = usage
        self.screens = screens
        self.nextCursor = nextCursor
    }
}

public struct CatalogDeleteResult: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var catalogScreenID: String
    public var versionID: String
    public var deleted: Bool
    public var catalogRevision: Int
    public init(schemaVersion: Int = 1, catalogScreenID: String, versionID: String, deleted: Bool = true, catalogRevision: Int) {
        self.schemaVersion = schemaVersion
        self.catalogScreenID = catalogScreenID
        self.versionID = versionID
        self.deleted = deleted
        self.catalogRevision = catalogRevision
    }
}

public struct CatalogListUsage: Codable, Sendable, Equatable {
    public var storedBytes: Int
    public var reservedBytes: Int
    public var cleanupBytes: Int
    public init(storedBytes: Int, reservedBytes: Int, cleanupBytes: Int) {
        self.storedBytes = storedBytes
        self.reservedBytes = reservedBytes
        self.cleanupBytes = cleanupBytes
    }
}

public struct CatalogPackageScreen: Codable, Sendable, Equatable {
    public var title: String
    public var entry: String
    public var requiredAssets: [String]
    public var externalDependencies: [String]
    public init(title: String, entry: String = "index.html", requiredAssets: [String], externalDependencies: [String]) {
        self.title = title
        self.entry = entry
        self.requiredAssets = requiredAssets
        self.externalDependencies = externalDependencies
    }
}

/// Preview bytes require a real bounded raster decoder at the server before available status.
public struct CatalogPreview: Codable, Sendable, Equatable {
    public var source: String?
    public var capturedAt: String?
    public var status: String
    public var reason: String?
    public var mediaType: String?
    public var byteLength: Int?
    public var digest: String?
    public var width: Int?
    public var height: Int?
    public init(status: String = "unavailable", reason: String? = "not_provided", mediaType: String? = nil, byteLength: Int? = nil, digest: String? = nil, width: Int? = nil, height: Int? = nil, source: String? = nil, capturedAt: String? = nil) {
        self.source=source; self.capturedAt=capturedAt; self.status=status; self.reason=reason; self.mediaType=mediaType; self.byteLength=byteLength; self.digest=digest; self.width=width; self.height=height
    }
}
public enum CatalogContract {
    public static let version = "1"
    public static let feature = "catalog-backup-v1"
    public static let capabilitiesPath = "/api/catalog/capabilities"
    public static let beginPath = "/api/catalog/backups/begin"
    public static let uploadsPath = "/api/catalog/backups/"
    public static let operationsPath = "/api/catalog/backups/operations/"
    public static let packageBytes = 10 * 1024 * 1024
    public static let previewBytes = 512 * 1024
    public static let previewDimension = 2048
    public static let queueRevisions = 100
    public static let queueBytes = 100 * 1024 * 1024
    public enum ValidationError: Error { case invalid(String) }
    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f.string(from: date)
    }
    public static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func canonical<T: Encodable>(_ value: T) throws -> Data { try AuthoringContract.encodedCanonical(value) }
    public static func safePath(_ path: String) -> Bool {
        path.utf8.count <= 160 && path.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }
    public static func containsCredentials(path: String, content: String) -> Bool {
        let patterns = ["(?:^|/)(?:credentials|secrets?|id_rsa|id_ed25519|keychain)(?:[./_-]|$)", "-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----", "\\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,})\\b"]
        return path.range(of: patterns[0], options: [.regularExpression,.caseInsensitive]) != nil || patterns.dropFirst().contains { content.range(of: $0, options: .regularExpression) != nil }
    }
    public static func encodePackage(_ package: CatalogPackage) throws -> Data {
        guard package.schemaVersion == 1, package.screen.entry == "index.html", !package.files.isEmpty, package.files.count <= 20, package.screen.requiredAssets.count <= 20, package.screen.externalDependencies.count <= 20 else { throw ValidationError.invalid("package metadata") }
        var previous = ""; var paths = Set<String>(); var files: [AuthoringScreenFile] = []
        let media = ["html":"text/html","css":"text/css","js":"text/javascript","json":"application/json","svg":"image/svg+xml","txt":"text/plain"]
        for file in package.files {
            guard safePath(file.path), file.path > previous, paths.insert(file.path.lowercased()).inserted, file.byteLength >= 0, file.byteLength <= 204800, media[String(file.path.split(separator: ".").last ?? "")] == file.mediaType, let bytes = Data(base64Encoded: file.contentBase64), bytes.base64EncodedString() == file.contentBase64, bytes.count == file.byteLength, digest(bytes) == file.digest, let content = String(data: bytes, encoding: .utf8), !containsCredentials(path: file.path, content: content) else { throw ValidationError.invalid("package file") }
            previous = file.path; files.append(AuthoringScreenFile(path: file.path, content: content))
        }
        guard Set(package.screen.requiredAssets).count == package.screen.requiredAssets.count, package.screen.requiredAssets.allSatisfy({ p in safePath(p) && package.files.contains { $0.path == p } }), package.screen.externalDependencies.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 }) else { throw ValidationError.invalid("package dependencies") }
        try AuthoringPackageDependencies.validate(files: files)
        try AuthoringPackageDependencies.validateManifest(files: files)
        _ = try AuthoringContract.validateScreen(JSONEncoder().encode(AuthoringScreen(title: package.screen.title, entry: package.screen.entry, files: files)))
        let bytes = try canonical(package); guard bytes.count <= packageBytes else { throw ValidationError.invalid("package bytes") }; return bytes
    }
    public static func verifyPackage(_ bytes: Data, declaration: CatalogObjectDeclaration) throws -> CatalogPackage {
        guard bytes.count > 0, bytes.count <= packageBytes, bytes.count == declaration.byteLength, digest(bytes) == declaration.digest else { throw ValidationError.invalid("package digest") }
        let value = try JSONDecoder().decode(CatalogPackage.self, from: bytes)
        guard try encodePackage(value) == bytes else { throw ValidationError.invalid("noncanonical package") }; return value
    }
}

extension CatalogContract {
    public static func validateBegin(_ value: CatalogBeginBackup) throws {
        func id(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil }
        func reject() throws { throw ValidationError.invalid("begin metadata") }
        guard value.schemaVersion == 1, [value.operationID,value.libraryID,value.localScreenID,value.sourceRevisionID].allSatisfy(id), value.commitCounter > 0, value.commitCounter <= 9_007_199_254_740_991, ["applied","seed"].contains(value.origin), !value.screenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.screenName.utf16.count <= 100, value.parentRevisionIDs.count <= 8, value.parentRevisionIDs.allSatisfy(id), Set(value.parentRevisionIDs).count == value.parentRevisionIDs.count, !value.parentRevisionIDs.contains(value.sourceRevisionID) else { return try reject() }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; f.isLenient = false
        guard let date = f.date(from: value.sourceAppliedAt), timestamp(date) == value.sourceAppliedAt, value.package.byteLength > 0, value.package.byteLength <= packageBytes, value.package.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return try reject() }
        if let previous = value.predecessorRevisionID, !id(previous) || !value.parentRevisionIDs.contains(previous) || previous == value.sourceRevisionID { return try reject() }
        if let label = value.versionName, label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.utf16.count > 100 { return try reject() }
        if let note = value.note, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf16.count > 1000 { return try reject() }
        if let p = value.preview {
            guard p.byteLength > 0, p.byteLength <= previewBytes, p.width > 0, p.height > 0, p.width <= previewDimension, p.height <= previewDimension, ["image/png","image/jpeg"].contains(p.mediaType), p.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return try reject() }
        }
        if let g = value.gap {
            guard value.origin == "seed", g.checkpointCounter > 0, g.checkpointCounter < 9_007_199_254_740_991, id(g.checkpointRevisionID), g.skippedFromCounter == g.checkpointCounter + 1, g.skippedThroughCounter >= g.skippedFromCounter, g.skippedThroughCounter < 9_007_199_254_740_991, value.commitCounter == g.skippedThroughCounter + 1, value.predecessorRevisionID == g.checkpointRevisionID, g.reason == "user_acknowledged_backup_pause" else { return try reject() }
        }
    }
}

extension CatalogContract {
    public static func validateStatus(_ value: CatalogBackupStatus) throws {
        if let restart = value.error?.restartOperation {
            guard restart, value.state == "failed", value.error?.code == "retry_later" else { throw ValidationError.invalid("restart requires failed expired operation") }
        }
    }
}

public struct CatalogPreviewCandidate: Codable, Sendable, Equatable {
    public var catalogScreenID: String
    public var versionID: String
    public var libraryID: String
    public var localScreenID: String
    public var sourceRevisionID: String
    public var packageDigest: String
    public var packageBytes: Int
    public init(catalogScreenID: String, versionID: String, libraryID: String, localScreenID: String, sourceRevisionID: String, packageDigest: String, packageBytes: Int) {
        self.catalogScreenID = catalogScreenID
        self.versionID = versionID
        self.libraryID = libraryID
        self.localScreenID = localScreenID
        self.sourceRevisionID = sourceRevisionID
        self.packageDigest = packageDigest
        self.packageBytes = packageBytes
    }
}

public struct CatalogPreviewCandidates: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var candidates: [CatalogPreviewCandidate]
    public var nextCursor: String?
    public init(schemaVersion: Int = 1, candidates: [CatalogPreviewCandidate], nextCursor: String? = nil) {
        self.schemaVersion = schemaVersion
        self.candidates = candidates
        self.nextCursor = nextCursor
    }
}

public struct CatalogPNGPreviewDeclaration: Codable, Sendable, Equatable {
    public var byteLength: Int
    public var digest: String
    public var mediaType: String
    public var width: Int
    public var height: Int
    public init(byteLength: Int, digest: String, mediaType: String = "image/png", width: Int, height: Int) {
        self.byteLength = byteLength
        self.digest = digest
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

public struct CatalogPreviewBegin: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var operationID: String
    public var catalogScreenID: String
    public var versionID: String
    public var libraryID: String
    public var localScreenID: String
    public var sourceRevisionID: String
    public var packageDigest: String
    public var capturedAt: String
    public var source: String
    public var preview: CatalogPNGPreviewDeclaration
    public init(schemaVersion: Int = 1, operationID: String, catalogScreenID: String, versionID: String, libraryID: String, localScreenID: String, sourceRevisionID: String, packageDigest: String, capturedAt: String, source: String = "exact_package", preview: CatalogPNGPreviewDeclaration) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.catalogScreenID = catalogScreenID
        self.versionID = versionID
        self.libraryID = libraryID
        self.localScreenID = localScreenID
        self.sourceRevisionID = sourceRevisionID
        self.packageDigest = packageDigest
        self.capturedAt = capturedAt
        self.source = source
        self.preview = preview
    }
}

public struct CatalogPreviewStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var operationID: String
    public var catalogScreenID: String
    public var versionID: String
    public var state: String
    public var uploadID: String?
    public var expiresAt: String?
    public var error: CatalogError?
    public init(schemaVersion: Int = 1, operationID: String, catalogScreenID: String, versionID: String, state: String, uploadID: String? = nil, expiresAt: String? = nil, error: CatalogError? = nil) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.catalogScreenID = catalogScreenID
        self.versionID = versionID
        self.state = state
        self.uploadID = uploadID
        self.expiresAt = expiresAt
        self.error = error
    }
}

extension CatalogContract {
    public static let previewCandidatesPath = "/api/catalog/preview-candidates"
    public static let previewBeginPath = "/api/catalog/previews/begin"
    public static let previewUploadsPath = "/api/catalog/previews/"
    public static let previewOperationsPath = "/api/catalog/previews/operations/"
    public static func validatePreviewBegin(_ value: CatalogPreviewBegin) throws {
        let ids = [value.operationID,value.catalogScreenID,value.versionID,value.libraryID,value.localScreenID,value.sourceRevisionID]
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard value.schemaVersion == 1, value.source == "exact_package", ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil }), value.packageDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let captured = date.date(from: value.capturedAt), timestamp(captured) == value.capturedAt, value.preview.mediaType == "image/png", value.preview.byteLength > 0, value.preview.byteLength <= previewBytes, value.preview.width > 0, value.preview.height > 0, value.preview.width <= previewDimension, value.preview.height <= previewDimension, value.preview.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ValidationError.invalid("preview binding/declaration") }
    }
    public static func previewBeginDigest(_ value: CatalogPreviewBegin) throws -> String { try validatePreviewBegin(value); return digest(try canonical(value)) }
    public static func validateStatus(_ value: CatalogPreviewStatus) throws {
        if let restart = value.error?.restartOperation {
            guard restart, value.state == "failed", value.error?.code == "retry_later" else { throw ValidationError.invalid("restart requires failed expired preview") }
        }
    }
}
