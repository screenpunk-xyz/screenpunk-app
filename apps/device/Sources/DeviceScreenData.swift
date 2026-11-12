import Foundation
import ScreenpunkApple
import ScreenpunkCore

struct DeviceScreenDataTarget: Codable, Hashable {
    let screenId: String
    let revision: String
    let generation: String
    let exportName: String
}

struct DeviceScreenDataReader: Codable, Equatable {
    enum Kind: String, Codable { case screen, mcp }
    let kind: Kind
    let deviceId: String?
    let screenId: String?
    let revision: String?
    let generation: String?
    let grantId: String?
    let title: String
    let deviceTitle: String?

    struct Identity: Codable, Hashable {
        let kind: Kind
        let deviceId: String?
        let screenId: String?
        let revision: String?
        let generation: String?
        let grantId: String?
    }

    var identity: Identity {
        .init(kind: kind, deviceId: deviceId, screenId: screenId, revision: revision, generation: generation, grantId: grantId)
    }

    var label: String {
        let safeTitle = Self.displayText(title)
        switch kind {
        case .screen:
            let device = deviceTitle.map(Self.displayText) ?? "device \(deviceId?.suffix(8) ?? "")"
            return "\(safeTitle) on \(device)"
        case .mcp:
            return "\(safeTitle) (connection \(grantId?.suffix(8) ?? ""))"
        }
    }

    private static func displayText(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    var valid: Bool {
        guard !Self.displayText(title).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              deviceTitle.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { return false }
        switch kind {
        case .screen:
            return grantId == nil && [deviceId, screenId, revision, generation].allSatisfy { $0.map(ScreenDataContract.isInstalledID) == true }
        case .mcp:
            return deviceId == nil && screenId == nil && revision == nil && generation == nil &&
                grantId.map(ScreenDataContract.isInstalledID) == true
        }
    }
}

struct DeviceScreenDataNotice: Decodable, Equatable {
    let queryId: String
    let deadlineAt: Int64
    let target: DeviceScreenDataTarget
    let reader: DeviceScreenDataReader

    var valid: Bool {
        UUID(uuidString: queryId) != nil && deadlineAt > 0 && reader.valid &&
            [target.screenId, target.revision, target.generation].allSatisfy(ScreenDataContract.isInstalledID) &&
            ScreenDataContract.isName(target.exportName)
    }
}

enum DeviceScreenDataWire {
    static let replyLimit = 24 * 1024
    struct Reply: Codable {
        let status: String
        let result: ScreenDataSnapshot?

        init(_ snapshot: ScreenDataSnapshot) { status = "ok"; result = snapshot }
        init(_ error: ScreenDataError) { status = error.rawValue; result = nil }

        func snapshot() throws -> ScreenDataSnapshot {
            if status == "ok", let result {
                try ScreenDataContract.validateValue(result.value)
                guard (1...ScreenDataContract.maxVersion).contains(result.version),
                      DeviceScreenDataArchive.date(from: result.updatedAt) != nil,
                      DeviceScreenDataArchive.date(from: result.readAt) != nil else { throw ScreenDataError.unavailable }
                return result
            }
            guard result == nil, let failure = ScreenDataError(rawValue: status) else { throw ScreenDataError.unavailable }
            throw failure
        }
    }
}

struct DeviceScreenDataPermission: Codable, Identifiable {
    struct Key: Codable, Hashable {
        let owner: String
        let target: DeviceScreenDataTarget
        let reader: DeviceScreenDataReader.Identity
    }
    enum Decision: String, Codable { case allowed, denied, revoked }
    var id: Key { key }
    let key: Key
    let targetTitle: String
    let exportDescription: String
    let readerLabel: String
    var decision: Decision
}

struct DeviceScreenDataPrompt: Identifiable {
    let id = UUID()
    let permission: DeviceScreenDataPermission
    let expiresAt: Date
    let remote: Bool
}

@MainActor
final class DeviceScreenDataArchive {
    private static let byteLimit = 4 * 1024 * 1024
    // Leave room for native consent records even when publication storage is full.
    private static let publicationLimit = 3 * 1024 * 1024
    private let folder: URL
    private var file: URL { folder.appendingPathComponent("archive-v1.json") }

    private struct Published: Codable {
        let owner: String
        let generation: String
        let version: Int
        let updatedAt: String
        let value: AuthoringJSONValue
    }
    private struct PublishedScreen: Codable {
        var counter = 0
        var exports: [String: Published] = [:]
    }
    private struct Archive: Codable {
        var version = 1
        var screens: [String: PublishedScreen] = [:]
        var permissions: [DeviceScreenDataPermission] = []
    }

    init(root: URL) { folder = root.appendingPathComponent("screen-data", isDirectory: true) }

    func publish(owner: String, target: DeviceScreenDataTarget, value: AuthoringJSONValue?, now: Date = Date()) throws {
        if let value { try ScreenDataContract.validateValue(value) }
        var archive = try read()
        var screen = archive.screens[target.screenId] ?? PublishedScreen()
        let previous = screen.exports[target.exportName]
        guard value != nil || (previous?.generation == target.generation && previous?.owner == owner) else { return }
        guard screen.counter < ScreenDataContract.maxVersion else { throw ScreenDataError.unavailable }
        screen.counter += 1
        if let value {
            screen.exports[target.exportName] = .init(owner: owner, generation: target.generation,
                version: screen.counter, updatedAt: Self.format(now), value: value)
        } else {
            screen.exports.removeValue(forKey: target.exportName)
        }
        archive.screens[target.screenId] = screen
        try write(archive, publishing: value != nil)
    }

    func query(_ key: DeviceScreenDataPermission.Key, now: Date = Date()) throws -> ScreenDataSnapshot {
        let archive = try read()
        guard archive.permissions.first(where: { $0.key == key })?.decision == .allowed else {
            throw ScreenDataError.permissionRequired
        }
        guard let record = archive.screens[key.target.screenId]?.exports[key.target.exportName],
              record.owner == key.owner, record.generation == key.target.generation else {
            throw ScreenDataError.notFound
        }
        return .init(value: record.value, version: record.version, updatedAt: record.updatedAt, readAt: Self.format(now))
    }

    func decision(for key: DeviceScreenDataPermission.Key) throws -> DeviceScreenDataPermission.Decision? {
        try read().permissions.first { $0.key == key }?.decision
    }

    func permissions(owner: String) throws -> [DeviceScreenDataPermission] {
        try read().permissions.filter { $0.key.owner == owner }
    }

    func set(_ permission: DeviceScreenDataPermission) throws {
        var archive = try read()
        if let index = archive.permissions.firstIndex(where: { $0.key == permission.key }) {
            archive.permissions[index] = permission
        } else {
            guard archive.permissions.count < 256 else { throw ScreenDataError.rateLimited }
            archive.permissions.append(permission)
        }
        try write(archive)
    }

    func forget(_ key: DeviceScreenDataPermission.Key) throws {
        var archive = try read()
        archive.permissions.removeAll { $0.key == key && $0.decision != .allowed }
        try write(archive)
    }

    func reconcile(generations: [String: String], localDeviceIds: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var archive = try read()
        let previousScreens = archive.screens.count
        let previousPermissions = archive.permissions.count
        archive.screens = archive.screens.filter { generations[$0.key] != nil }
        var retiredValues = false
        for (id, var screen) in archive.screens {
            let active = screen.exports.filter { $0.value.generation == generations[id] }
            guard active.count != screen.exports.count else { continue }
            // Retire unreachable bytes while retaining a single counter for the
            // installation, including when a later revision redeclares a name.
            screen.exports = active
            archive.screens[id] = screen
            retiredValues = true
        }
        archive.permissions.removeAll { permission in
            let key = permission.key
            guard generations[key.target.screenId] == key.target.generation else { return true }
            if let device = key.reader.deviceId, localDeviceIds.contains(device), let screen = key.reader.screenId {
                return generations[screen] != key.reader.generation
            }
            return false
        }
        guard retiredValues || previousScreens != archive.screens.count || previousPermissions != archive.permissions.count else { return }
        try write(archive)
    }

    private func read() throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else { return Archive() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= Self.byteLimit else { throw ScreenDataError.unavailable }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
        guard archive.version == 1 else { throw ScreenDataError.unavailable }
        return archive
    }

    private func write(_ archive: Archive, publishing: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(archive)
        guard bytes.count <= (publishing ? Self.publicationLimit : Self.byteLimit) else { throw ScreenDataError.rateLimited }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = folder
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        #if os(iOS)
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: file, options: .atomic)
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated static func date(from string: String) -> Date? {
        guard string.hasSuffix("Z"), string.utf8.count <= 35 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

@MainActor
final class DeviceScreenDataProvider: ScreenDataProvider {
    let publishValue: (String, AuthoringJSONValue?) throws -> Void
    let readValue: (String) async throws -> ScreenDataSnapshot

    init(publishValue: @escaping (String, AuthoringJSONValue?) throws -> Void,
         readValue: @escaping (String) async throws -> ScreenDataSnapshot) {
        self.publishValue = publishValue
        self.readValue = readValue
    }

    func publish(name: String, value: AuthoringJSONValue) throws { try publishValue(name, value) }
    func remove(name: String) throws { try publishValue(name, nil) }
    func query(alias: String) async throws -> ScreenDataSnapshot { try await readValue(alias) }
}
