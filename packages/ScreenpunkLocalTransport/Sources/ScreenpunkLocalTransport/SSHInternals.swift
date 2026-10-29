import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// Hash the SSH wire key, rather than only its algorithm-specific bytes.
func hostFingerprint(_ key: NIOSSHPublicKey) -> String {
    let encoded = String(openSSHPublicKey: key).split(separator: " ")[1]
    let blob = Data(base64Encoded: String(encoded))!
    return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
}

final class PhaseCompletion: @unchecked Sendable {
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var finished = false
    var futureResult: EventLoopFuture<Void> { promise.futureResult }
    init(on loop: EventLoop) { promise = loop.makePromise(of: Void.self) }
    func succeed() { complete(nil) }
    func fail(_ error: Error) { complete(error) }
    private func complete(_ error: Error?) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; lock.unlock()
        if let error { promise.fail(error) } else { promise.succeed(()) }
    }
}

final class SessionResources: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var parent: Channel?
    private var candidates: [Channel] = []
    private var establishing = true
    private var parentClosed = false
    private var closing = false
    private var shutdownStarted = false
    private var shutdownFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var firstError: SSHTransportError?
    private var phases: [PhaseCompletion] = []

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) { self.continuation = continuation }

    func phase() -> PhaseCompletion {
        let phase = PhaseCompletion(on: group.next())
        lock.lock(); phases.append(phase); let closed = closing; lock.unlock()
        if closed { phase.fail(error(or: .disconnected)) }
        return phase
    }
    func record(_ error: SSHTransportError) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }
    func error(or fallback: SSHTransportError) -> SSHTransportError {
        lock.lock(); defer { lock.unlock() }; return firstError ?? fallback
    }
    /// Bootstrap may initialize several IPv6/IPv4 candidates. They have no SSH
    /// pipeline and never own the shared stream or event loop.
    func registerCandidate(_ channel: Channel) {
        lock.lock(); candidates.append(channel); let shouldClose = closing; lock.unlock()
        if shouldClose { channel.close(promise: nil) }
    }
    /// Called exactly once, with the successful Happy Eyeballs result.
    func attach(_ channel: Channel) {
        lock.lock()
        precondition(parent == nil)
        parent = channel
        let losing = candidates.filter { $0 !== channel }
        candidates = []
        let shouldClose = closing
        lock.unlock()
        channel.closeFuture.whenComplete { [self] _ in
            lock.lock(); parentClosed = true; let mayShutdown = !establishing; lock.unlock()
            close(error: error(or: .disconnected))
            if mayShutdown { shutdown() }
        }
        for candidate in losing { candidate.close(promise: nil) }
        if shouldClose { channel.close(promise: nil) }
    }
    func close(error: Error? = nil) {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        closing = true
        let channels = candidates + (parent.map { [$0] } ?? [])
        let pending = phases
        lock.unlock()
        for phase in pending { phase.fail(error ?? SSHTransportError.disconnected) }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        for channel in channels { channel.close(promise: nil) }
    }
    // No shutdown until establishment has returned or thrown: bootstrap and
    // pipeline installation may still be scheduling work during cancellation.
    func finishConnectionAttempt() {
        lock.lock()
        establishing = false
        let hasParent = parent != nil
        let closedParent = parentClosed
        let remaining = candidates
        candidates = []
        lock.unlock()
        if !hasParent {
            for channel in remaining { channel.close(promise: nil) }
            EventLoopFuture.andAllComplete(remaining.map(\.closeFuture), on: group.next()).whenComplete { [self] _ in shutdown() }
        } else if closedParent { shutdown() }
    }
    private func shutdown() {
        lock.lock()
        guard !shutdownStarted else { lock.unlock(); return }
        shutdownStarted = true
        lock.unlock()
        group.shutdownGracefully { [self] _ in
            lock.lock(); shutdownFinished = true; let pending = waiters; waiters = []; lock.unlock()
            for waiter in pending { waiter.resume() }
        }
    }
    func waitForShutdown() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if shutdownFinished { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}

final class PinnedHostDelegate: NIOSSHClientServerAuthenticationDelegate {
    let expected: String
    let resources: SessionResources
    init(expected: String, resources: SessionResources) { self.expected = expected; self.resources = resources }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let observed = hostFingerprint(hostKey)
        guard observed == expected else {
            let error = SSHTransportError.hostKeyMismatch(expected: expected, observed: observed)
            resources.record(error); validationCompletePromise.fail(error); return
        }
        validationCompletePromise.succeed(())
    }
}

final class PublicKeyDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: NIOSSHPrivateKey
    let resources: SessionResources
    var attempted = false
    init(username: String, key: NIOSSHPrivateKey, resources: SessionResources) { self.username = username; self.key = key; self.resources = resources }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !attempted, availableMethods.contains(.publicKey) else {
            resources.record(.authenticationFailed); nextChallengePromise.fail(SSHTransportError.authenticationFailed); return
        }
        attempted = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Every callback runs on this connection's single event loop.
final class AuthObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    let ready: PhaseCompletion
    let resources: SessionResources
    private var finished = false
    init(ready: PhaseCompletion, resources: SessionResources) { self.ready = ready; self.resources = resources }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !finished { finished = true; ready.succeed() }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let safe = resources.error(or: .protocolViolation)
        if !finished { finished = true; ready.fail(safe) }
        resources.close(error: safe)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finished = true; ready.fail(resources.error(or: .disconnected)) }
        context.fireChannelInactive()
    }
}

final class SSHByteCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else { context.fireErrorCaught(SSHTransportError.protocolViolation); return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}
