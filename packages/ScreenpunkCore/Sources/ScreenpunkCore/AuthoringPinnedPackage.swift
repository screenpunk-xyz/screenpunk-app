import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded raw reads from one app-owned immutable revision. No model supplied absolute paths.
public enum AuthoringPinnedPackage {
    public static func read(directory: URL, path: String, byteLength: Int, digest: String) throws -> Data {
        guard byteLength >= 0, byteLength <= 204_800,
              path.range(of: #"^[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*\.(?:html|css|js|json|svg|txt)$"#, options: .regularExpression) != nil else { throw AuthoringStoreError.invalid("Unsafe pinned asset path or size.") }
        var descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AuthoringStoreError.invalid("The pinned base package is missing or unsafe.") }
        defer { _ = close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw AuthoringStoreError.invalid("The pinned asset directory is missing or unsafe.") }
            _ = close(descriptor); descriptor = child
        }
        let file = openat(descriptor, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AuthoringStoreError.invalid("The pinned asset is missing or unsafe.") }
        defer { _ = close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == byteLength else { throw AuthoringStoreError.invalid("The pinned asset size changed or is not a regular file.") }
        var data = Data(count: byteLength)
        var count = 0
        try data.withUnsafeMutableBytes { buffer in
            while count < byteLength {
                let amount = readBytes(file, buffer.baseAddress!.advanced(by: count), byteLength - count)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw AuthoringStoreError.invalid("The pinned asset could not be read completely.") }
                count += amount
            }
        }
        var extra: UInt8 = 0
        guard readBytes(file, &extra, 1) == 0, AuthoringContract.contentDigest(data) == digest else { throw AuthoringStoreError.invalid("The pinned asset raw-byte digest changed.") }
        return data
    }
    private static func readBytes(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, length)
        #else
        return Glibc.read(descriptor, buffer, length)
        #endif
    }
}
