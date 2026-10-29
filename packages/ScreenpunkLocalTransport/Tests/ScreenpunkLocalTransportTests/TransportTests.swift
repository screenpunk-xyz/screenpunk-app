import XCTest
import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import NIOHTTP1
import NIOWebSocket
@testable import ScreenpunkLocalTransport

private let fixtureToken = "synthetic-fixture-token"
private struct MemoryStore: SSHCredentialStore {
    let key: Data
    var token = fixtureToken
    func load(reference: SSHCredentialReference) throws -> SSHTransportCredentials { .init(privateKey: key, appServerToken: token) }
}
private final class AuthorizedKey: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    init(_ key: NIOSSHPublicKey) { self.key = key }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == "fixture", case .publicKey(let offer) = request.request, offer.publicKey == key else { responsePromise.succeed(.failure); return }
        responsePromise.succeed(.success)
    }
}
private final class Relay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var peer: Channel?
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { peer?.writeAndFlush(unwrapInboundIn(data), promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { peer?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private final class UnauthorizedResponse: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .unauthorized, headers: ["Content-Length":"0"]))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
private final class FixtureFrames: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else {
            if frame.opcode == .pong { context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.text,data:ByteBuffer(string:"pong-received"))),promise:nil) }
            return
        }
        // Every client frame must be masked, including ping replies.
        guard frame.maskKey != nil else { context.close(promise:nil); return }
        let command = String(buffer: frame.unmaskedData)
        switch command {
        case "fragment":
            context.write(wrapOutboundOut(.init(fin:false,opcode:.text,data:ByteBuffer(string:"hel"))),promise:nil)
            context.write(wrapOutboundOut(.init(fin:true,opcode:.ping,data:ByteBuffer(string:"heartbeat"))),promise:nil)
            context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.continuation,data:ByteBuffer(string:"lo"))),promise:nil)
        case "oversized-fragments":
            context.write(wrapOutboundOut(.init(fin:false,opcode:.text,data:ByteBuffer(repeating:65,count:inboundMessageLimit))),promise:nil)
            context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.continuation,data:ByteBuffer(string:"x"))),promise:nil)
        case "oversized-frame":
            context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.text,data:ByteBuffer(repeating:65,count:inboundMessageLimit+1))),promise:nil)
        case "disconnect": context.close(promise:nil)
        case "close":
            var bytes=ByteBuffer(); bytes.writeInteger(UInt16(1000))
            context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.connectionClose,data:bytes)),promise:nil)
        default: context.writeAndFlush(wrapOutboundOut(.init(fin:true,opcode:.text,data:frame.unmaskedData)),promise:nil)
        }
    }
}

/// Always offers an IPv6 candidate first. The fixture intentionally listens on
/// IPv4 only, so a successful connection must survive the failed IPv6 socket.
private final class IPv6FirstResolver: Resolver, @unchecked Sendable {
    let loop: EventLoop
    let ipv4Gate: EventLoopFuture<Void>?
    let ipv4LookupStarted: XCTestExpectation?
    init(loop: EventLoop, ipv4Gate: EventLoopFuture<Void>? = nil, ipv4LookupStarted: XCTestExpectation? = nil) {
        self.loop = loop; self.ipv4Gate = ipv4Gate; self.ipv4LookupStarted = ipv4LookupStarted
    }
    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        loop.makeSucceededFuture([try! SocketAddress(ipAddress: "::1", port: port)])
    }
    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        if let ipv4Gate {
            ipv4LookupStarted?.fulfill()
            return ipv4Gate.map { [try! SocketAddress(ipAddress: "127.0.0.1", port: port)] }
        }
        return loop.scheduleTask(in: .milliseconds(75)) { [try! SocketAddress(ipAddress: "127.0.0.1", port: port)] }.futureResult
    }
    func cancelQueries() {}
}

private final class Fixture: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let ssh: Channel
    let websocket: Channel
    let privateKey: Data
    let endpoint: SSHTransportEndpoint
    private init(group:MultiThreadedEventLoopGroup,ssh:Channel,websocket:Channel,privateKey:Data,endpoint:SSHTransportEndpoint) {
        self.group=group;self.ssh=ssh;self.websocket=websocket;self.privateKey=privateKey;self.endpoint=endpoint
    }
    static func start(stallSSH: Bool = false) async throws -> Fixture {
        let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
        let host=NIOSSHPrivateKey(ed25519Key:.init())
        let client=Curve25519.Signing.PrivateKey()
        let key=NIOSSHPrivateKey(ed25519Key:client)
        let websocket=try await ServerBootstrap(group:group).childChannelInitializer { channel in
            let upgrader=NIOWebSocketServerUpgrader(shouldUpgrade:{ channel,head in
                // The only accepted request is the expected in-tunnel host/path and bearer header.
                let authorized = head.uri == "/" && head.headers.first(name:"Authorization") == "Bearer \(fixtureToken)" && head.headers.first(name:"Host")?.hasPrefix("127.0.0.1:") == true
                return channel.eventLoop.makeSucceededFuture(authorized ? HTTPHeaders() : nil)
            },upgradePipelineHandler:{ channel,_ in channel.pipeline.removeHandler(name:"unauthorized").flatMap { channel.pipeline.addHandler(FixtureFrames()) } })
            return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade:([upgrader],{ _ in })).flatMap { channel.pipeline.addHandler(UnauthorizedResponse(),name:"unauthorized") }
        }.bind(host:"127.0.0.1",port:0).get()
        let target=websocket.localAddress!.port!
        let ssh=try await ServerBootstrap(group:group).childChannelInitializer { channel in
            if stallSSH { return channel.eventLoop.makeSucceededFuture(()) }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role:.server(.init(hostKeys:[host],userAuthDelegate:AuthorizedKey(key.publicKey))),allocator:channel.allocator,inboundChildChannelInitializer:{ child,type in
                    guard case .directTCPIP(let address)=type, address.targetHost == "127.0.0.1", address.targetPort == target else { return child.eventLoop.makeFailedFuture(SSHTransportError.protocolViolation) }
                    let inbound=Relay(); let outbound=Relay()
                    return child.pipeline.addHandlers(SSHByteCodec(),inbound).flatMap {
                        ClientBootstrap(group:child.eventLoop).channelInitializer { remote in
                            outbound.peer=child;inbound.peer=remote;return remote.pipeline.addHandler(outbound)
                        }.connect(host:address.targetHost,port:address.targetPort).map { _ in }
                    }
                }))
            }
        }.bind(host:"127.0.0.1",port:0).get()
        return Fixture(group:group,ssh:ssh,websocket:websocket,privateKey:client.rawRepresentation,endpoint:.init(host:"127.0.0.1",port:ssh.localAddress!.port!,username:"fixture",hostKeySHA256:hostFingerprint(host.publicKey),appServerPort:target))
    }
    func stop() async {
        try? await ssh.close().get();try? await websocket.close().get()
        await withCheckedContinuation { (done:CheckedContinuation<Void,Never>) in group.shutdownGracefully { _ in done.resume() } }
    }
    func transport(token:String=fixtureToken,key:Data?=nil) -> SSHWebSocketTransport {
        SSHWebSocketTransport(credentialStore:MemoryStore(key:key ?? privateKey,token:token),timeout:.seconds(2))
    }
    func connect() async throws -> SSHWebSocketConnection { try await transport().connect(endpoint:endpoint,credentialReference:.init(rawValue:"fixture")) }
}

final class TransportTests: XCTestCase {
    func testPinnedPublicKeyBearerWebSocketFragmentationPingAndClose() async throws {
        let fixture=try await Fixture.start()
        do {
            let connection=try await fixture.connect()
            var iterator=connection.messages.makeAsyncIterator()
            try await connection.send("echo")
            let echo=try await iterator.next();XCTAssertEqual(echo,"echo")
            try await connection.send("fragment")
            let first=try await iterator.next();let second=try await iterator.next()
            XCTAssertEqual(Set([first,second].compactMap{$0}),Set(["hello","pong-received"]))
            try await connection.send("close")
            let end=try await iterator.next();XCTAssertNil(end)
            await connection.close()
            await connection.close()
            do { try await connection.send("after-close");XCTFail("Send after close succeeded") } catch { XCTAssertEqual(error as? SSHTransportError,.disconnected) }
        } catch { await fixture.stop();throw error }
        await fixture.stop()
    }

    func testLocalhostAndFailingIPv6CandidateLeaveWinningIPv4SessionUsable() async throws {
        let fixture = try await Fixture.start()
        do {
            var endpoint = fixture.endpoint
            endpoint.host = "localhost"
            let custom = SSHWebSocketTransport(credentialStore: MemoryStore(key: fixture.privateKey), timeout: .seconds(2), resolver: IPv6FirstResolver(loop: fixture.group.next()))
            // Also exercise the real system localhost resolver, rather than
            // relying solely on synthetic address ordering.
            for transport in [custom, fixture.transport()] {
                let connection = try await transport.connect(endpoint: endpoint, credentialReference: .init(rawValue: "fixture"))
                var iterator = connection.messages.makeAsyncIterator()
                try await connection.send("after-ipv6-failure")
                let echoed = try await iterator.next()
                XCTAssertEqual(echoed, "after-ipv6-failure")
                await connection.close()
            }
            // Hold IPv4 until cancellation is requested. A timed sleep cannot
            // guarantee ordering when a hosted runner delays the test task.
            let loop = fixture.group.next()
            let ipv4Gate = loop.makePromise(of: Void.self)
            let lookupStarted = expectation(description: "IPv4 lookup is pending")
            let cancellationTransport = SSHWebSocketTransport(credentialStore: MemoryStore(key: fixture.privateKey), timeout: .seconds(2), resolver: IPv6FirstResolver(loop: loop, ipv4Gate: ipv4Gate.futureResult, ipv4LookupStarted: lookupStarted))
            let cancelled = Task { try await cancellationTransport.connect(endpoint: endpoint, credentialReference: .init(rawValue: "fixture")) }
            await fulfillment(of: [lookupStarted], timeout: 2)
            cancelled.cancel()
            // Let the connector settle its outstanding lookup and reap channels.
            ipv4Gate.succeed(())
            do { let connection = try await cancelled.value; await connection.close(); XCTFail("Cancelled dual-stack dial succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        } catch { await fixture.stop(); throw error }
        await fixture.stop()
    }

    func testWrongHostAndClientKeyFailClosed() async throws {
        let fixture=try await Fixture.start()
        do {
            var wrong=fixture.endpoint
            wrong.hostKeySHA256=hostFingerprint(NIOSSHPrivateKey(ed25519Key:.init()).publicKey)
            do { _=try await fixture.transport().connect(endpoint:wrong,credentialReference:.init(rawValue:"fixture"));XCTFail("Wrong host accepted") }
            catch { XCTAssertEqual(error as? SSHTransportError,.hostKeyMismatch(expected:wrong.hostKeySHA256,observed:fixture.endpoint.hostKeySHA256)) }
            do { _=try await fixture.transport(key:Curve25519.Signing.PrivateKey().rawRepresentation).connect(endpoint:fixture.endpoint,credentialReference:.init(rawValue:"fixture"));XCTFail("Wrong key accepted") }
            catch { XCTAssertEqual(error as? SSHTransportError,.authenticationFailed) }
        }
        await fixture.stop()
    }

    func testBearerRejectionIsTypedAndRedacted() async throws {
        let fixture=try await Fixture.start()
        do { _=try await fixture.transport(token:"wrong-secret-token").connect(endpoint:fixture.endpoint,credentialReference:.init(rawValue:"fixture"));XCTFail("Wrong token accepted") }
        catch { XCTAssertEqual(error as? SSHTransportError,.webSocketRejected(status:401));XCTAssertFalse(String(describing:error).contains("wrong-secret-token")) }
        await fixture.stop()
    }

    func testOutboundLimitAndInboundFragmentLimit() async throws {
        let fixture=try await Fixture.start()
        do {
            let connection=try await fixture.connect()
            do { try await connection.send(String(repeating:"x",count:outboundMessageLimit+1));XCTFail("Oversized send accepted") }
            catch { XCTAssertEqual(error as? SSHTransportError,.messageTooLarge) }
            var iterator=connection.messages.makeAsyncIterator()
            try await connection.send("oversized-fragments")
            do { _=try await iterator.next();XCTFail("Oversized fragments accepted") }
            catch { XCTAssertEqual(error as? SSHTransportError,.messageTooLarge) }
            await connection.close()
        } catch { await fixture.stop();throw error }
        await fixture.stop()
    }

    func testOversizedFrameAndDisconnectFinishStream() async throws {
        let fixture=try await Fixture.start()
        do {
            for command in ["oversized-frame","disconnect"] {
                let connection=try await fixture.connect()
                var iterator=connection.messages.makeAsyncIterator()
                try await connection.send(command)
                do { _=try await iterator.next();XCTFail("Expected stream error") }
                catch { XCTAssertEqual(error as? SSHTransportError,command == "oversized-frame" ? .messageTooLarge : .disconnected) }
                await connection.close()
            }
        } catch { await fixture.stop();throw error }
        await fixture.stop()
    }

    func testAuthenticationTimeoutAndCancellationCleanUp() async throws {
        let fixture=try await Fixture.start(stallSSH:true)
        let transport=SSHWebSocketTransport(credentialStore:MemoryStore(key:fixture.privateKey),timeout:.milliseconds(100))
        do { _=try await transport.connect(endpoint:fixture.endpoint,credentialReference:.init(rawValue:"fixture"));XCTFail("Stalled handshake accepted") }
        catch { XCTAssertEqual(error as? SSHTransportError,.timeout) }
        let task=Task { try await fixture.transport().connect(endpoint:fixture.endpoint,credentialReference:.init(rawValue:"fixture")) }
        try await Task.sleep(nanoseconds:20_000_000)
        task.cancel()
        do { _=try await task.value;XCTFail("Cancelled handshake succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        // Cancellation before dialing also releases the newly allocated event loop.
        let preCancelled=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.transport().connect(endpoint:fixture.endpoint,credentialReference:.init(rawValue:"fixture"))
        }
        do { _=try await preCancelled.value;XCTFail("Pre-cancelled connection succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        await fixture.stop()
    }

    func testValidationAndCredentialDescriptionsNeverExposeSecrets() throws {
        let credentials=SSHTransportCredentials(privateKey:Data(repeating:7,count:32),appServerToken:"secret-example")
        XCTAssertFalse(String(describing:credentials).contains("secret-example"))
        XCTAssertFalse(String(reflecting:credentials).contains("secret-example"))
        for token in ["bad\r\nX-Injected: yes","bad token","", "bad=token"] {
            XCTAssertThrowsError(try SSHTransportCredentials(privateKey:credentials.privateKey,appServerToken:token).validate())
        }
        var endpoint=SSHTransportEndpoint(host:"host\n",username:"user",hostKeySHA256:"SHA256:invalid",appServerPort:1234)
        XCTAssertThrowsError(try endpoint.validate())
        endpoint.host="localhost";endpoint.username="user\n";XCTAssertThrowsError(try endpoint.validate())
        endpoint.username="user";XCTAssertThrowsError(try endpoint.validate())
    }
}
