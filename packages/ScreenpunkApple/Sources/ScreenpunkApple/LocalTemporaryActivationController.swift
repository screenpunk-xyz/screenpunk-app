import Foundation
import ScreenpunkCore

/// Device-owned restoration, independent of the renderer, network connection, and Mac pairing.
/// Call `reconcile` on foreground entry and at the stored deadline. Persist screen selection
/// after each proposal, then acknowledge it; a crash between those writes is recoverable.
@MainActor
public final class LocalTemporaryActivationController {
    private struct Checkpoint: Codable {
        var owner: String
        var navigation: TemporaryActivationNavigation
        var pendingSelection: String?
    }
    private let url: URL
    private var checkpoint: Checkpoint
    public var expiresAt: Date? { checkpoint.navigation.dismissed ? nil : checkpoint.navigation.expiresAt }

    public init(root: URL, owner: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("local-temporary-activation.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data), saved.owner == owner {
            checkpoint = saved
        } else {
            checkpoint = Checkpoint(owner: owner, navigation: .init(), pendingSelection: nil)
        }
    }

    public func activate(id: String, target: String, expiresAt: Date, selected: String,
                         startedAt: Date = Date(), now: Date = Date()) throws -> String? {
        try apply { $0.activate(id: id, target: target, selected: selected, startedAt: startedAt, expiresAt: expiresAt, now: now) }
    }
    public func end(id: String, selected: String) throws -> String? {
        guard checkpoint.navigation.alertId == id else { return nil }
        if checkpoint.navigation.dismissed { return checkpoint.pendingSelection }
        var next = checkpoint
        next.pendingSelection = next.navigation.end(id: id, selected: selected)
        try save(next)
        return next.pendingSelection
    }
    public func reconcile(selected: String, now: Date = Date()) throws -> String? {
        // Expiration wins over a not-yet-applied activation after an offline relaunch.
        if !checkpoint.navigation.dismissed, let deadline = checkpoint.navigation.expiresAt, now >= deadline {
            var next = checkpoint
            next.pendingSelection = nil
            let proposal = next.navigation.expire(selected: selected, now: now)
            next.pendingSelection = proposal
            try save(next)
            return proposal
        }
        return checkpoint.pendingSelection
    }
    public func manualSelection() throws {
        var next = checkpoint
        next.navigation.manualSelection(); next.pendingSelection = nil
        try save(next)
    }
    public func acknowledgeSelection() throws {
        var next = checkpoint; next.pendingSelection = nil; try save(next)
    }
    private func apply(_ change: (inout TemporaryActivationNavigation) -> String?) throws -> String? {
        var next = checkpoint
        if let proposal = change(&next.navigation) { next.pendingSelection = proposal }
        try save(next)
        return next.pendingSelection
    }
    private func save(_ next: Checkpoint) throws {
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        checkpoint = next
    }
}
