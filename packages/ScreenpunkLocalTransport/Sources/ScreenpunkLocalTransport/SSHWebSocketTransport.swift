import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import NIOHTTP1
import NIOWebSocket

/// A text WebSocket carried directly by an authenticated SSH directTCPIP channel.
/// There is no local forwarding listener and no transport helper process.
public actor SSHWebSocketTransport {
    private let credentialStore: any SSHCredentialStore
    private let timeout: TimeAmount
    private let resolver: (any Resolver & Sendable)?

    public init(credentialStore: any SSHCredentialStore) {
        self.credentialStore = credentialStore
        self.timeout = .seconds(15)
        self.resolver = nil
    }
    init(credentialStore: any SSHCredentialStore, timeout: TimeAmount, resolver: (any Resolver & Sendable)? = nil) {
        self.credentialStore = credentialStore
        self.timeout = timeout
        self.resolver = resolver
    }

    public func connect(endpoint: SSHTransportEndpoint, credentialReference: SSHCredentialReference) async throws -> SSHWebSocketConnection {
        try endpoint.validate()
        try Task.checkCancellation()
        let credentials: SSHTransportCredentials
        do { credentials = try credentialStore.load(reference: credentialReference) }
        catch { throw SSHTransportError.credentialsUnavailable }
        try credentials.validate()
        let key: NIOSSHPrivateKey
        do { key = NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: credentials.privateKey)) }
        catch { throw SSHTransportError.invalidCredentials }

        let (messages, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let resources = SessionResources(continuation: continuation)
        continuation.onTermination = { [weak resources] _ in resources?.close() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let ready = resources.phase()
                let parent = try await ClientBootstrap(group: resources.group)
                    // Keep the server identification bytes in the socket until
                    // the winning TCP channel has its SSH pipeline installed.
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .connectTimeout(timeout)
                    .resolver(resolver)
                    .channelInitializer { channel in
                        resources.registerCandidate(channel)
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                    .connect(host: endpoint.host, port: endpoint.port).get()
                resources.attach(parent)
                try Task.checkCancellation()
                guard parent.isActive else { throw resources.error(or: .disconnected) }
                try await parent.eventLoop.submit {
                    try parent.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: PublicKeyDelegate(username: endpoint.username, key: key, resources: resources),
                                serverAuthDelegate: PinnedHostDelegate(expected: endpoint.hostKeySHA256, resources: resources)
                            )),
                            allocator: parent.allocator,
                            inboundChildChannelInitializer: { child, _ in child.eventLoop.makeFailedFuture(SSHTransportError.protocolViolation) }
                        ),
                        AuthObserver(ready: ready, resources: resources)
                    )
                }.get()
                try await parent.setOption(ChannelOptions.autoRead, value: true).get()
                let authenticationTimeout = parent.eventLoop.scheduleTask(in: timeout) {
                    resources.record(.timeout); resources.close(error: SSHTransportError.timeout)
                }
                ready.futureResult.whenComplete { _ in authenticationTimeout.cancel() }
                try await ready.futureResult.get()
                try Task.checkCancellation()

                let upgraded = resources.phase()
                let upgradeTimeout = parent.eventLoop.scheduleTask(in: timeout) {
                    resources.record(.timeout); resources.close(error: SSHTransportError.timeout)
                }
                upgraded.futureResult.whenComplete { _ in upgradeTimeout.cancel() }
                let child = try await parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let promise = parent.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(promise, channelType: .directTCPIP(.init(
                        targetHost: "127.0.0.1", targetPort: endpoint.appServerPort,
                        originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    ))) { child, kind in
                        guard case .directTCPIP = kind else { return child.eventLoop.makeFailedFuture(SSHTransportError.protocolViolation) }
                        let request = UpgradeRequestHandler(token: credentials.appServerToken, port: endpoint.appServerPort, upgraded: upgraded, resources: resources)
                        let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: inboundMessageLimit, automaticErrorHandling: false) { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(MessageHandler(resources: resources))
                                upgraded.succeed()
                            }
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(SSHByteCodec())
                        }.flatMap {
                            child.pipeline.addHTTPClientHandlers(withClientUpgrade: ([upgrader], { context in
                                // HTTP response validation and WebSocket codecs are now installed.
                                request.willUpgrade()
                                context.pipeline.removeHandler(request, promise: nil)
                            }))
                        }.flatMap { child.pipeline.addHandler(request) }
                    }
                    return promise.futureResult
                }.get()
                try await upgraded.futureResult.get()
                try Task.checkCancellation()
                resources.finishConnectionAttempt()
                return SSHWebSocketConnection(messages: messages, channel: child, resources: resources)
            } catch {
                let safe: Error
                if Task.isCancelled { safe = CancellationError() }
                else if let typed = error as? SSHTransportError { safe = typed }
                else if case ChannelError.connectTimeout = error { safe = SSHTransportError.timeout }
                else { safe = resources.error(or: .unreachable) }
                resources.close(error: safe)
                resources.finishConnectionAttempt()
                await resources.waitForShutdown()
                throw safe
            }
        } onCancel: {
            resources.close(error: CancellationError())
        }
    }
}

public final class SSHWebSocketConnection: @unchecked Sendable {
    public let messages: AsyncThrowingStream<String, Error>
    private let channel: Channel
    private let resources: SessionResources
    init(messages: AsyncThrowingStream<String, Error>, channel: Channel, resources: SessionResources) {
        self.messages = messages; self.channel = channel; self.resources = resources
    }
    deinit { resources.close() }

    public func send(_ text: String) async throws {
        try Task.checkCancellation()
        guard text.utf8.count <= outboundMessageLimit else { throw SSHTransportError.messageTooLarge }
        guard channel.isActive else { throw resources.error(or: .disconnected) }
        try await withTaskCancellationHandler {
            do {
                try await channel.writeAndFlush(maskedFrame(opcode: .text, data: ByteBuffer(string: text))).get()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw resources.error(or: .disconnected)
            }
        } onCancel: { [resources] in resources.close(error: CancellationError()) }
    }

    /// Finishes the stream and waits until the SSH socket and its owned event loop stop.
    public func close() async {
        resources.close()
        await resources.waitForShutdown()
    }
}
