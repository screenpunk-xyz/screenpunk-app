import Foundation
import ScreenpunkCore
import ScreenpunkLocalTransport

/// Ordinary unavailability permits Automatic to choose matching configured Cloud.
public enum LocalAgentUnavailability: String, Equatable, Sendable {
    case notConfigured, unreachable, timedOut, disconnected, signInRequired, modelUnavailable, credentialsUnavailable
}
/// Identity, binding and unsafe protocol failures always require repair, never fallback.
public enum LocalAgentRepairReason: String, Equatable, Sendable {
    case hostIdentityChanged, wrongBinding, unsupportedVersion, unsafeConfiguration, invalidCredentials, unsupportedProtocol, missingConversationHistory
}
public enum LocalAgentReadiness: Equatable, Sendable {
    case ready
    case unavailable(LocalAgentUnavailability)
    case repairRequired(LocalAgentRepairReason)

    static func classify(_ error: Error) -> Self {
        if let error = error as? LocalAuthoringError {
            switch error {
            case .notConfigured: return .unavailable(.notConfigured)
            case .timeout: return .unavailable(.timedOut)
            case .disconnected: return .unavailable(.disconnected)
            case .signInOnMac: return .unavailable(.signInRequired)
            case .modelUnavailable: return .unavailable(.modelUnavailable)
            case .unsupportedVersion: return .repairRequired(.unsupportedVersion)
            case .unsafeMacConfiguration: return .repairRequired(.unsafeConfiguration)
            case .unmaterializedThread: return .repairRequired(.missingConversationHistory)
            case .wrongBinding: return .repairRequired(.wrongBinding)
            default: return .repairRequired(.unsupportedProtocol)
            }
        }
        if let error = error as? SSHTransportError {
            switch error {
            case .hostKeyMismatch: return .repairRequired(.hostIdentityChanged)
            case .invalidFingerprint, .invalidEndpoint: return .repairRequired(.unsafeConfiguration)
            case .credentialsUnavailable: return .unavailable(.credentialsUnavailable)
            case .invalidCredentials, .authenticationFailed, .webSocketRejected: return .repairRequired(.invalidCredentials)
            case .timeout: return .unavailable(.timedOut)
            case .unreachable: return .unavailable(.unreachable)
            case .disconnected: return .unavailable(.disconnected)
            default: return .repairRequired(.unsupportedProtocol)
            }
        }
        if error is CancellationError { return .unavailable(.timedOut) }
        if error is LocalPersistenceError { return .repairRequired(.wrongBinding) }
        return .repairRequired(.unsupportedProtocol)
    }
}

@MainActor final class LocalReadinessRace {
    var continuation: CheckedContinuation<LocalAgentReadiness, Never>?
    var probe: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ value: LocalAgentReadiness) {
        guard let continuation else { return }
        self.continuation = nil
        probe?.cancel(); timer?.cancel()
        self.probe = nil; self.timer = nil
        continuation.resume(returning: value)
    }
}
