import Foundation

public enum LocalPersistenceError: LocalizedError, Equatable {
    case unsupportedVersion(Int), invalid(String), conflict(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported local storage version \(version)."
        case .invalid(let reason), .conflict(let reason): return reason
        }
    }
}

/// Each repository owns a separate redo journal directory; no credential bytes enter this store.
final class LocalDurableFile<Value: Codable> {
    private struct Envelope: Codable { var schemaVersion: Int; var value: Value }
    private let journal: AuthoringJournal
    init(kind: String, rootDirectory: URL?) throws {
        let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ScreenpunkLocal", isDirectory: true).appendingPathComponent(kind, isDirectory: true)
        journal = try AuthoringJournal(root: root, stateName: "state.json")
    }
    func load() throws -> Value? {
        guard let data = try journal.recover() else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw LocalPersistenceError.unsupportedVersion(envelope.schemaVersion) }
        return envelope.value
    }
    func save(_ value: Value) throws {
        do { try journal.commit(JSONEncoder().encode(Envelope(schemaVersion: 1, value: value))) }
        catch { _ = try? journal.recover(); throw error }
    }
}

extension NSRecursiveLock {
    func locallyLocked<T>(_ operation: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try operation()
    }
}
