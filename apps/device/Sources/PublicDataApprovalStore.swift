import CryptoKit
import Foundation
import ScreenpunkCore

struct PublicDataApprovalStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(owner: String, dashboardID: String, connections: [ManifestConnection], revision: String? = nil) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let declarations = connections.filter { $0.publicHTTP != nil }
        guard var data = try? encoder.encode(declarations) else { return nil }
        if declarations.contains(where: { $0.publicHTTP?.operations.contains(where: { $0.response == "text" }) == true }) {
            guard let revision, !revision.isEmpty else { return nil }
            data.append(0)
            data.append(contentsOf: revision.utf8)
        }
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
