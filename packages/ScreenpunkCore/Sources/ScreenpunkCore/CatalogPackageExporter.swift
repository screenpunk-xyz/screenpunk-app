// SPDX-License-Identifier: Apache-2.0
import Foundation
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
    public static func export(directory: URL, title: String, entry: String, paths: [String]) throws -> Export {
        guard entry == "index.html", !paths.isEmpty, paths.count <= 20,
              Set(paths.map { $0.lowercased() }).count == paths.count,
              paths.allSatisfy(CatalogContract.safePath) else { throw invalid("Invalid package paths or entrypoint.") }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("The immutable package directory is unsafe.") }
        var actual = Set<String>()
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { throw invalid("The immutable package is missing.") }
        var members = 0
        for case let path as String in enumerator {
            members += 1
            guard members <= 64 else { throw invalid("Too many package directory entries.") }
            let url = directory.appendingPathComponent(path)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true else { throw invalid("Symbolic links cannot be backed up.") }
            if info.isDirectory == true { continue }
            guard info.isRegularFile == true, CatalogContract.safePath(path), actual.count < 20 else { throw invalid("Unexpected package files.") }
            actual.insert(path)
        }
        guard actual == Set(paths) else { throw invalid("The complete package file set changed.") }
        var files: [CatalogPackageFile] = []
        var source: [AuthoringScreenFile] = []
        for path in paths.sorted() {
            let raw = try read(directory: directory, path: path)
            guard let text = String(data: raw, encoding: .utf8), !CatalogContract.containsCredentials(path: path, content: text) else { throw invalid("This package contains unsupported bytes or credential markers. Remove credentials from source before backing up.") }
            files.append(.init(path: path, mediaType: try AuthoringV2Contract.mediaType(path: path), byteLength: raw.count, digest: CatalogContract.digest(raw), contentBase64: raw.base64EncodedString()))
            source.append(.init(path: path, content: text))
        }
        try AuthoringPackageDependencies.validate(files: source)
        try AuthoringPackageDependencies.validateManifest(files: source)
        let dependencies = try dependencies(files: source)
        let package = CatalogPackage(screen: .init(title: title, entry: entry, requiredAssets: dependencies.local, externalDependencies: dependencies.external), files: files)
        let bytes = try CatalogContract.encodePackage(package)
        return Export(package: package, bytes: bytes, declaration: .init(byteLength: bytes.count, digest: CatalogContract.digest(bytes)))
    }
    private static func invalid(_ message: String) -> CatalogContract.ValidationError { .invalid(message) }
    private static func read(directory: URL, path: String) throws -> Data {
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
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= 204_800 else { throw invalid("Invalid package asset size/type.") }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = systemRead(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw invalid("Incomplete immutable asset read.") }
                offset += amount
            }
        }
        var extra: UInt8 = 0
        guard systemRead(fd, &extra, 1) == 0 else { throw invalid("The immutable asset size changed.") }
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
