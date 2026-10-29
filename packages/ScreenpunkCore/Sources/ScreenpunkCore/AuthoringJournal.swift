import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A redo journal for one complete library index. The referenced package must be validated
/// before commit; it becomes visible only when this index is installed. Recovery rolls a
/// durable intent forward, so screen metadata, preferences and receipts never split.
public final class AuthoringJournal {
    public enum Cut: String, CaseIterable { case assetsDurable, journalDurable, stateDurable, journalRemoved }
    public typealias Fault = (Cut) throws -> Void
    private struct Intent: Codable { var state: Data; var stagedDirectory: String? }
    private let root: URL
    private let stateName: String
    private let fault: Fault?
    private var requiresRecovery = false
    public init(root: URL, stateName: String = "library.json", fault: Fault? = nil) throws {
        self.root = root; self.stateName = stateName; self.fault = fault
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func recover() throws -> Data? {
        let journal = root.appendingPathComponent("authoring-journal.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: journal))
            if let staged = intent.stagedDirectory {
                guard Self.safeComponent(staged), FileManager.default.fileExists(atPath: root.appendingPathComponent(staged).path) else {
                    throw AuthoringStoreError.invalid("The durable screen package is missing.")
                }
            }
            try writeDurably(intent.state, to: root.appendingPathComponent(stateName))
            try FileManager.default.removeItem(at: journal); try syncDirectory(root)
        }
        let state = root.appendingPathComponent(stateName)
        let data = FileManager.default.fileExists(atPath: state.path) ? try Data(contentsOf: state) : nil
        requiresRecovery = false
        return data
    }
    public func commit(_ state: Data, stagedDirectory: String? = nil) throws {
        guard !requiresRecovery, !FileManager.default.fileExists(atPath: root.appendingPathComponent("authoring-journal.json").path) else { throw AuthoringStoreError.invalid("Recover the previous durable transaction before writing again.") }
        requiresRecovery = true
        try performCommit(state, stagedDirectory: stagedDirectory)
        requiresRecovery = false
    }
    private func performCommit(_ state: Data, stagedDirectory: String?) throws {
        if let stagedDirectory {
            guard Self.safeComponent(stagedDirectory) else { throw AuthoringStoreError.invalid("Unsafe staged screen directory.") }
            let directory = root.appendingPathComponent(stagedDirectory)
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { throw AuthoringStoreError.invalid("The staged screen directory is missing.") }
            for case let file as URL in files {
                if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                    let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
                }
            }
            // Directory entries must reach storage before the journal references them.
            let directories = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for child in directories.reversed() { try syncDirectory(child) }
            try syncDirectory(directory); try syncDirectory(root)
        }
        try fault?(.assetsDurable)
        let journal = root.appendingPathComponent("authoring-journal.json")
        try writeDurably(JSONEncoder().encode(Intent(state: state, stagedDirectory: stagedDirectory)), to: journal)
        try fault?(.journalDurable)
        try writeDurably(state, to: root.appendingPathComponent(stateName))
        try fault?(.stateDurable)
        try FileManager.default.removeItem(at: journal); try syncDirectory(root)
        try fault?(.journalRemoved)
    }
    private static func safeComponent(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") }
    private func writeDurably(_ data: Data, to destination: URL) throws {
        let temporary = root.appendingPathComponent(".authoring-write-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try syncDirectory(root)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
