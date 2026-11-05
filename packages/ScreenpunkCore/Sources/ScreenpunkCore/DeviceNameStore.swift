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
