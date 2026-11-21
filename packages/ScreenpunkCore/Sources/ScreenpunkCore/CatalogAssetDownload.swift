// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

/// Streams a manifest asset into its version-scoped staging directory. A complete
/// SHA-256 verification covers both saved bytes and bytes fetched on this attempt.
public enum CatalogAssetDownload {
    @MainActor public static func restore(
        file: CatalogAssetFile,
        destination: URL,
        current: () throws -> Void,
        fetch: (Int, Int) async throws -> Data
    ) async throws {
        try current()
        guard file.byteLength >= 0 else { throw invalid("Invalid catalog asset size.") }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid("A partial catalog asset is unsafe.") }
        } else if !manager.createFile(atPath: destination.path, contents: nil) {
            throw invalid("Could not create a restored catalog asset.")
        }
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        let onDisk = try handle.seekToEnd()
        let existing = min(UInt64(file.byteLength), onDisk)
        let chunkSize = UInt64(CatalogContract.assetChunkBytes)
        let resumeAt = existing == UInt64(file.byteLength) ? existing : existing - existing % chunkSize
        if onDisk != resumeAt { try handle.truncate(atOffset: resumeAt) }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        var offset = 0
        while offset < Int(resumeAt) {
            await Task.yield()
            try current()
            let count = min(CatalogContract.assetChunkBytes, Int(resumeAt) - offset)
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                throw invalid("A partial catalog asset could not be read.")
            }
            hash.update(data: bytes)
            offset += count
        }
        while offset < file.byteLength {
            try current()
            let count = min(CatalogContract.assetChunkBytes, file.byteLength - offset)
            let chunk = try await fetch(offset, count)
            try current()
            guard chunk.count == count else { throw invalid("A catalog asset was incomplete.") }
            try handle.write(contentsOf: chunk)
            hash.update(data: chunk)
            offset += count
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.digest else {
            // The next attempt refetches this file and can still use all other verified files.
            try handle.close()
            try manager.removeItem(at: destination)
            throw invalid("A restored catalog asset failed verification. Retry to download the file again.")
        }
        try handle.synchronize()
    }

    private static func invalid(_ message: String) -> CatalogContract.ValidationError { .invalid(message) }
}
