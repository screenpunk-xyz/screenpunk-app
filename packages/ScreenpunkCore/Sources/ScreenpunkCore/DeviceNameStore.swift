import Foundation

/// App-owned names use a caller-scoped opaque identity key. Callers can include
/// installation, origin, and account identity to keep names within their binding.
public struct DeviceNameStore {
    public static let maximumLength = 80
    private let defaults: UserDefaults
    private let key = "screenpunk.device.names.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func name(for deviceID: String, fallback: String = "Screenpunk") -> String {
        guard let saved = defaults.dictionary(forKey: key)?[deviceID] as? String,
              let normalized = try? Self.normalized(saved) else { return fallback }
        return normalized
    }

    @discardableResult
    public func save(_ name: String, for deviceID: String) throws -> String {
        guard !deviceID.isEmpty else { throw ValidationError.missingIdentity }
        let normalized = try Self.normalized(name)
        var names = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        names[deviceID] = normalized
        defaults.set(names, forKey: key)
        return normalized
    }

    public static func normalized(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= maximumLength,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.invalidName
        }
        return value
    }

    public enum ValidationError: LocalizedError {
        case invalidName, missingIdentity
        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a device name with 1–80 characters."
            case .missingIdentity: return "Device identity is not ready. Try again shortly."
            }
        }
    }
}

public struct CloudDeviceNameSnapshot: Codable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let nameRevision: Int
    public let enrollmentRevision: Int
    public init(deviceId: String, name: String, nameRevision: Int, enrollmentRevision: Int) {
        self.deviceId = deviceId; self.name = name; self.nameRevision = nameRevision; self.enrollmentRevision = enrollmentRevision
    }
    public var valid: Bool {
        !deviceId.isEmpty && deviceId.utf8.count <= 128 && nameRevision >= 0 && enrollmentRevision >= 0 &&
            (try? DeviceNameStore.normalized(name)) == name
    }
}

/// Canonical names and explicit offline edits are scoped to one Cloud enrollment.
/// Registration supplies only a seed; reconnecting never sends a rename write.
@MainActor public final class CloudDeviceNameRepository {
    public struct Edit: Codable, Equatable, Sendable {
        public let name: String
        public var expectedNameRevision: Int
        public let operationID: String
    }
    public struct Record: Codable, Equatable, Sendable {
        public var canonical: CloudDeviceNameSnapshot?
        public var pending: Edit?
        public var conflict: Bool
    }
    private let file: LocalDurableFile<[String: Record]>
    public init(rootDirectory: URL? = nil) throws { file = try .init(kind: "cloud-device-names", rootDirectory: rootDirectory) }
    public static func key(origin: String, accountID: String, deviceID: String) -> String {
        AuthoringContract.contentDigest(Data((origin + "\n" + accountID + "\n" + deviceID).utf8))
    }
    public func record(key: String) throws -> Record { try file.load()?[key] ?? .init(canonical: nil, pending: nil, conflict: false) }
    @discardableResult public func queue(name: String, key: String) throws -> Edit {
        var all = try file.load() ?? [:], record = all[key] ?? .init(canonical: nil, pending: nil, conflict: false)
        let edit = Edit(name: try DeviceNameStore.normalized(name), expectedNameRevision: record.canonical?.nameRevision ?? 0, operationID: UUID().uuidString)
        record.pending = edit; record.conflict = false; all[key] = record; try file.save(all); return edit
    }
    public func observe(_ snapshot: CloudDeviceNameSnapshot, key: String) throws {
        guard snapshot.valid else { throw DeviceNameStore.ValidationError.invalidName }
        var all = try file.load() ?? [:], record = all[key] ?? .init(canonical: nil, pending: nil, conflict: false)
        guard accept(snapshot, replacing: record.canonical) else { return }
        if let previous = record.canonical, snapshot.enrollmentRevision > previous.enrollmentRevision {
            record.pending = nil; record.conflict = false
        }
        record.canonical = snapshot; all[key] = record; try file.save(all)
    }
    public func complete(_ edit: Edit, snapshot: CloudDeviceNameSnapshot, conflict: Bool, key: String) throws {
        guard snapshot.valid else { throw DeviceNameStore.ValidationError.invalidName }
        var all = try file.load() ?? [:], record = all[key] ?? .init(canonical: nil, pending: nil, conflict: false)
        if accept(snapshot, replacing: record.canonical) { record.canonical = snapshot }
        if record.pending?.operationID == edit.operationID {
            record.pending = nil; record.conflict = conflict
        } else if !conflict, snapshot.name == edit.name, snapshot.nameRevision == edit.expectedNameRevision + 1,
                  record.pending?.expectedNameRevision == edit.expectedNameRevision {
            // The newer explicit edit has not passed the ordered write flight yet.
            // Rebase only over our own successful write, never over a Cloud edit.
            record.pending?.expectedNameRevision = snapshot.nameRevision
        }
        all[key] = record; try file.save(all)
    }
    private func accept(_ next: CloudDeviceNameSnapshot, replacing old: CloudDeviceNameSnapshot?) -> Bool {
        guard let old else { return true }
        return next.deviceId == old.deviceId && next.enrollmentRevision >= old.enrollmentRevision &&
            (next.nameRevision > old.nameRevision || (next.nameRevision == old.nameRevision && next.name == old.name))
    }
}
