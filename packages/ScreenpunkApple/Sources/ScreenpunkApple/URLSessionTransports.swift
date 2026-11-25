import Foundation
import ScreenpunkCore

final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let certificatePin: ReviewedCertificatePin?
    private let lock = NSLock()
    private var rejection: CustomHTTPConnectionTestFailure?
    var challengeRejection: CustomHTTPConnectionTestFailure? { lock.withLock { rejection } }

    func reject(_ failure: CustomHTTPConnectionTestFailure) {
        lock.withLock { rejection = failure }
    }

    init(certificatePin: ReviewedCertificatePin? = nil) { self.certificatePin = certificatePin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let certificatePin else { return completionHandler(.performDefaultHandling, nil) }
        let space = challenge.protectionSpace
        guard !space.isProxy(), certificatePin.matches(scheme: space.protocol, host: space.host, port: space.port) else {
            reject(.certificateRejected)
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            switch space.authenticationMethod {
            case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                 NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate:
                reject(.authenticationRequired)
            case NSURLAuthenticationMethodClientCertificate:
                reject(.secureConnectionFailed)
            default:
                reject(.certificateRejected)
            }
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        if let failure = certificatePin.rejection(trust, host: space.host) {
            reject(failure)
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Native HTTP adapter. TLS stays on. Redirects are not followed.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let bounds: HTTPAdapterBounds
    private let session: URLSession
    private let delegate: RedirectDenyingDelegate

    public init(bounds: HTTPAdapterBounds = .production, privateRequests: Bool = false, certificatePin: ReviewedCertificatePin? = nil) {
        self.bounds = bounds
        let delegate = RedirectDenyingDelegate(certificatePin: certificatePin)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = bounds.timeoutSeconds
        configuration.timeoutIntervalForResource = bounds.timeoutSeconds
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 2
        if privateRequests {
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        try await send(request, diagnose: false)
    }

    func send(_ request: AuthorizedHTTPRequest, diagnose: Bool) async throws -> HTTPTransportResponse {
        if let pin = delegate.certificatePin,
           !pin.matches(scheme: request.url.scheme, host: request.url.host, port: request.url.port) {
            if diagnose { throw CustomHTTPConnectionTestFailure.certificateRejected }
            throw ConnectionFailure.certificateRejected
        }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        var data = Data()
        let http: HTTPURLResponse
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate.certificatePin == nil ? nil : delegate)
            guard let response = response as? HTTPURLResponse else { throw ConnectionFailure.deviceOffline }
            http = response
            if diagnose && !(200...299).contains(http.statusCode) {
                return HTTPTransportResponse(status: http.statusCode, body: Data())
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < request.maxBytes else { throw ConnectionFailure.sizeLimit }
                data.append(byte)
            }
        } catch {
            if diagnose {
                try Task.checkCancellation()
                if let failure = error as? ConnectionFailure {
                    throw failure == .sizeLimit ? CustomHTTPConnectionTestFailure.responseTooLarge : .invalidResponse
                }
                throw Self.diagnosis(for: (error as? URLError)?.code, challengeRejection: delegate.challengeRejection)
            }
            if let failure = error as? ConnectionFailure { throw failure }
            if (error as? URLError)?.code == .timedOut { throw ConnectionFailure.timeout }
            if delegate.certificatePin != nil, let failure = error as? URLError,
               [.cancelled, .userCancelledAuthentication, .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot].contains(failure.code) {
                throw ConnectionFailure.certificateRejected
            }
            throw ConnectionFailure.deviceOffline
        }

        return HTTPTransportResponse(status: http.statusCode, body: data)
    }

    static func diagnosis(for code: URLError.Code?, challengeRejection: CustomHTTPConnectionTestFailure?) -> CustomHTTPConnectionTestFailure {
        if let challengeRejection { return challengeRejection }
        switch code {
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .addressResolutionFailed
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .certificateRejected
        case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
             .clientCertificateRejected, .clientCertificateRequired: return .secureConnectionFailed
        case .userAuthenticationRequired: return .authenticationRequired
        case .cannotParseResponse, .badServerResponse, .zeroByteResource: return .invalidResponse
        default: return .unreachable
        }
    }
}

final class URLSessionWebSocketSession: WebSocketSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let maxBytes: Int

    init(task: URLSessionWebSocketTask, maxBytes: Int) {
        self.task = task
        self.maxBytes = maxBytes
    }

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw ConnectionFailure.deviceOffline
        }
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw ConnectionFailure.validationFailed
        }
        if data.count > maxBytes {
            throw ConnectionFailure.sizeLimit
        }
        return data
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func sendText(_ text: String) async throws { try await task.send(.string(text)) }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Native WebSocket adapter. Auth is applied on the handshake, never by page JS.
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: RedirectDenyingDelegate

    public init() {
        let delegate = RedirectDenyingDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = request.maxMessageBytes
        task.resume()
        return URLSessionWebSocketSession(task: task, maxBytes: request.maxMessageBytes)
    }
}
