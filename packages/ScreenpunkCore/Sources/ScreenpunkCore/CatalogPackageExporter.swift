// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exports only the immutable committed package. Never traverses preferences,
/// enrollment state, credentials, authoring transcripts or the library index.
public enum CatalogPackageExporter {
    public struct Export: Sendable {
        public var package: CatalogPackage
        public var bytes: Data
        public var declaration: CatalogObjectDeclaration
    }
    public static func export(directory: URL, title: String, entry: String, paths: [String], schemaVersion: Int = 1) throws -> Export {
        try validateDirectory(directory, entry: entry, paths: paths, fileLimit: 20)
        var files: [CatalogPackageFile] = []
        var source: [AuthoringScreenFile] = []
        for path in paths.sorted() {
            let raw = try read(directory: directory, path: path)
            let media = try CatalogContract.mediaType(path: path, extended: schemaVersion == 2)
            if schemaVersion == 2 && media.hasPrefix("audio/") {
                files.append(.init(path: path, mediaType: media, byteLength: raw.count, digest: CatalogContract.digest(raw), contentBase64: raw.base64EncodedString()))
                source.append(.init(path: path, content: "")); continue
            }
            guard let text = String(data: raw, encoding: .utf8), !CatalogContract.containsCredentials(path: path, content: text) else { throw invalid("This package contains unsupported bytes or credential markers. Remove credentials from source before backing up.") }
            files.append(.init(path: path, mediaType: media, byteLength: raw.count, digest: CatalogContract.digest(raw), contentBase64: raw.base64EncodedString()))
            source.append(.init(path: path, content: text))
        }
        let dependencies = try AuthoringPackageDependencies.catalogDependencies(files: source, extended: schemaVersion == 2)
        let package = CatalogPackage(schemaVersion: schemaVersion, screen: .init(title: title, entry: entry, requiredAssets: dependencies.local, externalDependencies: dependencies.external), files: files)
        let bytes = try CatalogContract.encodePackage(package)
        return Export(package: package, bytes: bytes, declaration: .init(byteLength: bytes.count, digest: CatalogContract.digest(bytes)))
    }
    public struct AssetExport: Sendable {
        public let manifest: CatalogAssetManifest
        public let declaration: CatalogObjectDeclaration
        private let directory: URL

        fileprivate init(manifest: CatalogAssetManifest, declaration: CatalogObjectDeclaration, directory: URL) {
            self.manifest = manifest
            self.declaration = declaration
            self.directory = directory
        }

        public func chunk(file: CatalogAssetFile, offset: Int) throws -> Data {
            guard offset >= 0, offset < file.byteLength, offset % CatalogContract.assetChunkBytes == 0 else {
                throw invalid("Invalid catalog asset offset.")
            }
            return try withAsset(directory: directory, path: file.path) { fd, size in
                guard size == file.byteLength else { throw invalid("The immutable backup asset size changed.") }
                return try read(fd: fd, count: min(CatalogContract.assetChunkBytes, size - offset), offset: offset)
            }
        }
    }

    public static func exportAssets(directory: URL, title: String, entry: String, paths: [String], schemaVersion: Int) throws -> AssetExport {
        try validateDirectory(directory, entry: entry, paths: paths, fileLimit: CatalogContract.assetFileCount)
        var files: [CatalogAssetFile] = []
        var source: [AuthoringScreenFile] = []
        var sourceBudget = CatalogContract.expandedPackageBytes
        var hasCompleteSource = true
        for path in paths.sorted() {
            let media = try AuthoringV2Contract.mediaType(path: path, extended: true)
            let asset = try withAsset(directory: directory, path: path) { fd, size -> CatalogAssetFile in
                guard !CatalogContract.containsCredentials(path: path, content: "") else { throw invalid("The screen contains a credential file.") }
                var hash = SHA256()
                var offset = 0
                var tail = Data()
                var textBytes = Data()
                let sourcePath = ["html", "svg", "css"].contains((path as NSString).pathExtension.lowercased())
                let analyzeSource = sourcePath && hasCompleteSource && size <= sourceBudget
                if sourcePath && !analyzeSource {
                    hasCompleteSource = false
                    source.removeAll()
                }
                while offset < size {
                    try Task.checkCancellation()
                    let chunk = try read(fd: fd, count: min(CatalogContract.assetChunkBytes, size - offset), offset: offset)
                    hash.update(data: chunk)
                    tail.append(chunk)
                    guard !CatalogContract.containsCredentials(path: path, content: String(decoding: tail, as: UTF8.self)) else {
                        throw invalid("The screen contains credential markers.")
                    }
                    tail = Data(tail.suffix(128))
                    if analyzeSource { textBytes.append(chunk) }
                    offset += chunk.count
                }
                if hasCompleteSource {
                    guard let text = String(data: textBytes, encoding: .utf8) else { throw invalid("Invalid text source.") }
                    source.append(.init(path: path, content: text))
                    sourceBudget -= textBytes.count
                }
                return .init(path: path, mediaType: media, byteLength: size, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
            }
            files.append(asset)
        }
        // Large documents still back up exactly. Conservatively include all local paths
        // when their dependency inventory would exceed the parser's memory budget.
        let dependencies = try hasCompleteSource ? AuthoringPackageDependencies.catalogAssetDependencies(files: source)
                                                 : (local: paths.filter { $0 != entry }.sorted(), external: [])
        let manifest = CatalogAssetManifest(schemaVersion: schemaVersion, screen: .init(title: title, entry: entry, requiredAssets: dependencies.local, externalDependencies: dependencies.external), files: files)
        let total = try CatalogContract.validateAssetManifest(manifest)
        let bytes = try CatalogContract.canonical(manifest)
        guard bytes.count <= CatalogContract.assetManifestBytes else { throw invalid("Invalid catalog asset manifest size.") }
        return .init(manifest: manifest, declaration: .init(byteLength: total, digest: CatalogContract.digest(bytes)), directory: directory)
    }

    private static func validateDirectory(_ directory: URL, entry: String, paths: [String], fileLimit: Int) throws {
        guard entry == "index.html", !paths.isEmpty, paths.count <= fileLimit,
              Set(paths.map { $0.lowercased() }).count == paths.count,
              paths.allSatisfy(CatalogContract.safePath) else { throw invalid("Invalid package paths or entrypoint.") }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("The immutable package directory is unsafe.") }
        let directories = Set(paths.flatMap { path in
            let components = path.split(separator: "/")
            return (1..<components.count).map { components.prefix($0).joined(separator: "/") }
        })
        var actual = Set<String>()
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { throw invalid("The immutable package is missing.") }
        let memberLimit = directories.count + paths.count
        var members = 0
        for case let path as String in enumerator {
            members += 1
            guard members <= memberLimit else { throw invalid("Too many package directory entries.") }
            let url = directory.appendingPathComponent(path)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true else { throw invalid("Symbolic links cannot be backed up.") }
            if info.isDirectory == true {
                guard directories.contains(path) else { throw invalid("Unexpected package directory.") }
                continue
            }
            guard info.isRegularFile == true, CatalogContract.safePath(path), actual.count < fileLimit else { throw invalid("Unexpected package files.") }
            actual.insert(path)
        }
        guard actual == Set(paths) else { throw invalid("The complete package file set changed.") }
    }

    private static func invalid(_ message: String) -> CatalogContract.ValidationError { .invalid(message) }
    private static func read(directory: URL, path: String) throws -> Data {
        try withAsset(directory: directory, path: path) { fd, size in
            guard size <= CatalogContract.extendedFileBytes else { throw invalid("Invalid package asset size.") }
            let bytes = try read(fd: fd, count: size, offset: 0)
            var extra: UInt8 = 0
            guard systemRead(fd, &extra, 1) == 0 else { throw invalid("The immutable asset size changed.") }
            return bytes
        }
    }

    private static func withAsset<T>(directory: URL, path: String, body: (Int32, Int) throws -> T) throws -> T {
        guard CatalogContract.safePath(path) else { throw invalid("Invalid asset path.") }
        var descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw invalid("The immutable package is missing or unsafe.") }
        defer { _ = close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw invalid("Unsafe package directory.") }
            _ = close(descriptor); descriptor = child
        }
        let fd = openat(descriptor, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw invalid("Missing or unsafe package asset.") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, let size = Int(exactly: info.st_size), size >= 0 else {
            throw invalid("Invalid package asset size/type.")
        }
        return try body(fd, size)
    }

    private static func read(fd: Int32, count: Int, offset: Int) throws -> Data {
        guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { throw invalid("Could not seek to the catalog asset offset.") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var consumed = 0
            while consumed < buffer.count {
                let amount = systemRead(fd, buffer.baseAddress!.advanced(by: consumed), buffer.count - consumed)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw invalid("Incomplete immutable asset read.") }
                consumed += amount
            }
        }
        return data
    }

    private static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }

    /// Collect from the authoritative installation parser, including quoted >,
    /// object data, SVG presentation attributes, nested paths and CSS imports.
    static func dependencies(files: [AuthoringScreenFile]) throws -> (local: [String], external: [String]) {
        try AuthoringPackageDependencies.catalogDependencies(files: files)
    }
}
