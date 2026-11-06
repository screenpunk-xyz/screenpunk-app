import Foundation

/// Registration and rename writes share one ordered flight. Cancellation of a
/// caller does not let a later write overtake an earlier server-side mutation.
@MainActor public final class DeviceNameWriteQueue {
    private var tail: Task<Void, Never>?
    public init() { }
    public func perform<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }
}
