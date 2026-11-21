import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded raw reads from one app-owned immutable revision. No model supplied absolute paths.
public enum AuthoringPinnedPackage {
    public struct InspectedAsset {
        public let byteLength: Int
        public let digest: String
        /// Present only when the caller's bounded inline allowance fits this asset.
        public let content: Data?
    }

    public static func inspectNative(directory: URL, path: String, inlineLimit: Int = -1) throws -> InspectedAsset {
        try streamNative(directory: directory, path: path, inlineLimit: inlineLimit)
    }

    public static func verifyNative(directory: URL, path: String, byteLength: Int, digest: String, content: String? = nil, destination: URL? = nil) throws {
        let asset = try streamNative(directory: directory, path: path, inlineLimit: content == nil ? -1 : byteLength,
                                     expectedLength: byteLength, destination: destination)
        guard asset.digest == digest, content.map({ Data($0.utf8) == asset.content }) ?? true else {
            throw AuthoringStoreError.invalid("The pinned asset raw bytes changed.")
        }
    }

    private static func streamNative(directory: URL, path: String, inlineLimit: Int, expectedLength: Int? = nil, destination: URL? = nil) throws -> InspectedAsset {
        guard CatalogContract.safePath(path) else { throw AuthoringStoreError.invalid("Unsafe pinned asset path.") }
        return try withFile(directory: directory, path: path) { file, length in
            guard expectedLength.map({ $0 == length }) ?? true else { throw AuthoringStoreError.invalid("The pinned asset size changed.") }
            let keepContent = length <= inlineLimit
            var content = Data()
            var hash = SHA256()
            var remaining = length
            let output = try destination.map { url in
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw AuthoringStoreError.invalid("Could not stage the retained asset.")
                }
                return try FileHandle(forWritingTo: url)
            }
            defer { try? output?.close() }
            while remaining > 0 {
                let chunk = try readChunk(file, count: min(remaining, CatalogContract.assetChunkBytes))
                hash.update(data: chunk)
                try output?.write(contentsOf: chunk)
                if keepContent { content.append(chunk) }
                remaining -= chunk.count
            }
            try verifyEnd(file)
            try output?.synchronize()
            return .init(byteLength: length, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                         content: keepContent ? content : nil)
        }
    }

    public static func read(directory: URL, path: String, byteLength: Int, digest: String) throws -> Data {
        guard (0...204_800).contains(byteLength),
              path.range(of: #"^[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*\.(?:html|css|js|json|svg|txt)$"#, options: .regularExpression) != nil else {
            throw AuthoringStoreError.invalid("Unsafe pinned asset path or size.")
        }
        return try withFile(directory: directory, path: path) { file, length in
            guard length == byteLength else { throw AuthoringStoreError.invalid("The pinned asset size changed.") }
            var data = Data()
            while data.count < length {
                data.append(try readChunk(file, count: length - data.count))
            }
            try verifyEnd(file)
            guard AuthoringContract.contentDigest(data) == digest else {
                throw AuthoringStoreError.invalid("The pinned asset raw-byte digest changed.")
            }
            return data
        }
    }

    private static func withFile<T>(directory: URL, path: String, body: (Int32, Int) throws -> T) throws -> T {
        var descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AuthoringStoreError.invalid("The pinned base package is missing or unsafe.") }
        defer { _ = close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw AuthoringStoreError.invalid("The pinned asset directory is missing or unsafe.") }
            _ = close(descriptor)
            descriptor = child
        }
        let file = openat(descriptor, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AuthoringStoreError.invalid("The pinned asset is missing or unsafe.") }
        defer { _ = close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (0...9_007_199_254_740_991).contains(info.st_size) else {
            throw AuthoringStoreError.invalid("The pinned asset size is invalid or the asset is not a regular file.")
        }
        return try body(file, Int(info.st_size))
    }

    private static func readChunk(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let length = data.withUnsafeMutableBytes { buffer in
            var length: Int
            repeat { length = readBytes(descriptor, buffer.baseAddress!, count) } while length < 0 && errno == EINTR
            return length
        }
        guard length > 0 else { throw AuthoringStoreError.invalid("The pinned asset could not be read completely.") }
        data.count = length
        return data
    }

    private static func verifyEnd(_ descriptor: Int32) throws {
        var extra: UInt8 = 0
        var length: Int
        repeat { length = readBytes(descriptor, &extra, 1) } while length < 0 && errno == EINTR
        guard length == 0 else { throw AuthoringStoreError.invalid("The pinned asset size changed.") }
    }
    private static func readBytes(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, length)
        #else
        return Glibc.read(descriptor, buffer, length)
        #endif
    }
}
