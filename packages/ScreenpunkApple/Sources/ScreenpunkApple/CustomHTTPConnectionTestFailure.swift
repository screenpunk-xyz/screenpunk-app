import Foundation

/// Native Settings diagnostics contain no request or response content.
public enum CustomHTTPConnectionTestFailure: Error, Sendable, Equatable {
    case screenAccessRequired
    case invalidConfiguration
    case addressResolutionFailed
    case destinationBlocked
    case unreachable
    case timedOut
    case certificateRejected
    case pinMismatch
    case secureConnectionFailed
    case redirectBlocked
    case authenticationRequired
    case unauthorized
    case forbidden
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge

    public var message: String {
        switch self {
        case .screenAccessRequired: return "Screen access is required. Review this screen’s permission and try again."
        case .invalidConfiguration: return "The connection settings couldn’t be used for this test. Review the saved address and read operation."
        case .addressResolutionFailed: return "The server name couldn’t be resolved. Check the address and network."
        case .destinationBlocked: return "The server address is blocked by Screenpunk’s connection policy."
        case .unreachable: return "Screenpunk couldn’t reach the server. Check the address and network. For a server on your local network, also check Screenpunk’s Local Network permission in iPad Settings."
        case .timedOut: return "The server didn’t respond in time. Check that it’s running and reachable."
        case .certificateRejected: return "The server certificate couldn’t be verified. Check its identity, validity dates, and trust."
        case .pinMismatch: return "The server certificate differs from the saved fingerprint. Verify the server’s current fingerprint independently before replacing the pin."
        case .secureConnectionFailed: return "The HTTPS handshake failed. Check the server’s TLS settings."
        case .redirectBlocked: return "The server redirected the request. Screenpunk only uses the saved destination."
        case .authenticationRequired: return "The server requires authentication. Check the credential and connection setup."
        case .unauthorized: return "The server returned HTTP 401. Check that the connection has a valid credential."
        case .forbidden: return "The server returned HTTP 403. Check that the credential can read this operation."
        case .httpStatus(let code): return "The server returned HTTP \(code). Check the server and the declared read operation."
        case .invalidResponse: return "The server didn’t return a usable JSON response for this operation."
        case .responseTooLarge: return "The server response exceeds the size limit for this connection."
        }
    }
}
