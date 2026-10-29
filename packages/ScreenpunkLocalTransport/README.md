# ScreenpunkLocalTransport

An iOS16+/macOS13+ Swift transport for a local Codex App Server. The client authenticates an SSH connection with an Ed25519 key, checks a previously confirmed `SHA256:` host fingerprint, then opens a `directTCPIP` channel to the SSH server's `127.0.0.1:appServerPort`. HTTP upgrade and text WebSocket frames run inside that channel. Only the winning IPv6/IPv4 TCP candidate gets the SSH pipeline; socket reads remain disabled until that pipeline is installed. Losing candidates cannot close the winning session. No local forwarding listener or helper process is created.

Supply an `SSHCredentialStore` backed by Keychain. Its synchronous `load(reference:)` returns a 32-byte Ed25519 raw private key and App Server bearer token. The transport calls the store from its actor. Persist `SSHCredentialReference` and `SSHTransportEndpoint` only; `SSHTransportCredentials` intentionally cannot be encoded, and its descriptions redact both secrets. The token enters only the HTTP Authorization header inside SSH.

```swift
let transport = SSHWebSocketTransport(credentialStore: keychainStore)
let connection = try await transport.connect(
    endpoint: endpoint,
    credentialReference: reference
)
try await connection.send(requestJSON)
for try await message in connection.messages {
    // Decode App Server protocol messages in the caller.
}
await connection.close()
```

Use a single consumer for `messages`. Close the connection when leaving the session; `close()` waits for the owned event loop to stop and is idempotent. Cancelling establishment or an in-flight send closes the connection. A normal peer close finishes the stream; unexpected disconnects finish it with a typed error. Errors contain no token, private key, raw HTTP response body or network diagnostic text. Host-key mismatch supplies only the expected/observed public fingerprints; the caller must require explicit review before changing its saved pin.

Limits: 15-second TCP/authentication/upgrade phases, 2MiB inbound frames/assembled text messages, 1MiB outbound text messages and 128 buffered inbound messages. Exceeding inbound limits closes the SSH connection. Oversized outbound sends fail before writing. Text fragmentation, UTF-8 validation, masked client frames, ping/pong and close frames are supported. Unnegotiated extensions and binary data are rejected.

Dependencies are exact pinned Apple releases (NIOSSH0.15.1, SwiftNIO2.104.0, SwiftCrypto5.0.3) with transitive revisions recorded in `Package.resolved`. Package tests use generated synthetic keys and ephemeral loopback-only SSH/WebSocket servers, never system Remote Login or user credentials. On sandboxed agent hosts, fixture execution requires socket-bind permission.
