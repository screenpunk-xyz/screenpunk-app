import CryptoKit
import Foundation
import ScreenpunkCore

struct PublicDataApprovalStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(owner: String, dashboardID: String, connections: [ManifestConnection]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(connections.filter { $0.publicHTTP != nil }) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return prefix(owner: owner, dashboardID: dashboardID) + digest
    }

    func isAllowed(key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func setAllowed(_ allowed: Bool, key: String) {
        defaults.set(allowed, forKey: key)
    }

    func forget(owner: String, dashboardIDs: Set<String>) {
        guard !dashboardIDs.isEmpty else { return }
        let prefixes = Set(dashboardIDs.map { Self.prefix(owner: owner, dashboardID: $0) })
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("screenpunk.publicReads.") {
            let digest = key.utf8.suffix(64)
            guard digest.count == 64,
                  digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  prefixes.contains(String(decoding: key.utf8.dropLast(64), as: UTF8.self)) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    private static func prefix(owner: String, dashboardID: String) -> String {
        "screenpunk.publicReads.\(owner).\(dashboardID)."
    }
}
