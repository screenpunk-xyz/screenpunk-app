# Screenpunk One device

Universal iOS 16+ app, using the existing Screenpunk bundle identity (`xyz.screenpunk.ios`) and Screenpunk development team. Installing replaces the previous app on the selected device; it does not update other devices. Open `ScreenpunkOne.xcodeproj`, select the ScreenpunkOne scheme, choose your development team and a connected iPad, and Run. Signing keys and provisioning profiles remain local; only the public team identifier is stored in source.

## First device slice

- System-browser Google sign-in through Screenpunk's native PKCE exchange; an opaque device token is stored in this app's Keychain namespace.
- A ready-agent gate backed by the Cloud event subscription, not merely an OAuth account grant.
- Three-finger hold while talking, release to send. The native overlay shows microphone state and transcription. Microphone and speech permissions are requested on use; releasing during a permission dialog cancels that recording attempt. Apple Speech uses on-device recognition when available and otherwise may use Apple's service. Backgrounding or audio interruption cancels capture.
- Complete UTF-8 screen packages are validated and committed locally with one atomic library write. The previous revision remains available in Settings. Existing screens continue running after Cloud disconnects. Source is retained for agent edits.
- Two-finger swipe between locally installed screens; two-finger hold opens device settings. An accessible Settings button is present during onboarding, and the inherited renderer exposes its native Device menu accessibility action.
- Device-owned temporary-screen restoration persists through relaunch, respects manual navigation, and reconciles deadlines while foregrounded. The Cloud status channel delivers account-scoped activation/end commands; the device acknowledges them after persistence. A small screen inventory is synced for agent selection.

## Runtime contract

Generated screens use `index.html` plus local CSS and JavaScript files, with at most 20 files and 200 KiB serialized UTF-8 content. Extensions are html, css, js, json, svg and txt. The inherited isolated renderer rejects inline JavaScript/CSS, external scripts, and unrestricted network access. Screens requiring new service permissions must not silently fetch them. Bundled integration providers remain in shared packages; a full declarative connection manifest and approval pipeline is separate work.

Home Assistant, Google TV and Google Calendar settings providers are retained. Home Assistant approval needs a valid manifest.json declaring its service requests. The native approval scope uses the immutable local revision; changed screens require fresh approval. Google Calendar requires a native OAuth client registered for the new bundle before it can connect. Keeping these providers does not imply that generated screens can already bind all of them.

## Known boundaries to validate on a physical iPad

Real Google sign-in, speech permissions, three-finger gesture behavior (including accessibility conflicts), Cloud request delivery, screen rendering, disconnect persistence, and signing need an end-to-end device run. Foreground device updates use an authenticated hibernating WebSocket for change notifications, followed by coalesced HTTP state reads. Routine three-second polling is removed. The client reconnects with bounded backoff and reauthenticates periodically. Account changes isolate local libraries. Expired sessions can be reauthorized from Settings; sign-out clears the Cloud session even if server revocation is unavailable; it keeps the active saved screens, native service credentials, and local authoring configuration available on this device.

Do not check in provisioning profiles, signing keys, bearer tokens, or generated build output.

## Shared authoring v1 (Phase 1)

Cloud submissions use the bundled contract in `packages/contracts`: immutable guidance/runtime/service facts, applicable scoped preferences, stable screen identity and base revision, and a SHA-256 snapshot digest. The transport-independent coordinator also supports a synthetic fixture adapter. Phase 2 adds the local Codex adapter described below.

Screen installation, preference mutations, synchronization intent and application receipts commit through one durable library journal. Duplicate operations replay their original receipt; stale revisions conflict. Settings > Preferences supports inspecting, editing and deleting saved values and resolving sync conflicts. A local commit remains usable during sync failure. Settings > Agents shows Cloud agent, Local agent, and Use for new requests (Automatic, Local, or Cloud). A prepared request keeps its original route.

When a matching Cloud account is connected, preference synchronization runs independently of that route. Local commits wake synchronization before agent acknowledgement, while a foreground one-minute cadence also pulls remote changes. Offline failures retain the outbox and retry with bounded backoff; Local authoring does not await Cloud. Account, profile, device and session changes fence stale responses. Local-only profiles perform no Cloud synchronization, and Local application receipts stay on the Local route.

Account-owned screen directories and native credential ownership remain unchanged. A separate Keychain installation secret enrolls an existing authenticated device and preserves its account-scoped device identity across subsequent sign-ins. It is sent only to authenticated registration or native token exchange, never to screen source or an authoring snapshot. Account switching opens the selected account's library; inaccessible old-device delivery records are retained and quarantined. An old request without a verifiable native screen revision receives an explicit resend outcome instead of installing into a guessed target.

Run the actual on-disk device-library tests without a Simulator:

```sh
swift test --package-path apps/device --scratch-path .task/device-authoring-tests
```

These tests cover combined crash recovery, durable preference/receipt replay, stale-screen conflicts, cancellation, old metadata decoding, account isolation, raw wire validation, reenrollment quarantine and lost submission responses. They do not replace a staging-to-iPad run. Release validation must still exercise real sign-in/reenrollment, Cloud create/edit, saved preferences after restart and another agent, receipt readback, account switching, and the existing Home Assistant edit-continuity/permission-expansion checks on a physical device.


## Computer pairing and asset-preserving authoring

Settings → Agents shows Cloud agent, Local agent, then **Use for new requests**. Existing profiles keep their explicit Local or Cloud choice; new profiles start with Automatic. Automatic checks the configured computer first, then a matching ready Cloud agent before preparing the request. Identity or configuration problems require repair. After preparation, accepted or uncertain delivery always reconciles on the original route. No Cloud account is needed to pair a computer or use Local.

This personal prototype supports Apple Silicon Macs with macOS 13 or later and the tested ChatGPT Mac application's bundled Codex **0.164.0-alpha.11.1**, SHA-256 `a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e`. Windows support is planned separately. It requests **GPT-6.1 Sol**, **high** reasoning, and **priority** service; the served tier is not independently measured. App Server remains experimental. Keep the Mac awake and reachable. Background startup requires the Mac account to remain signed in; a foreground connection also requires its Terminal session to stay open.

The setup flow has three stages:

1. **Prepare computer.** Save or share the iPad's public setup file. Open the public `/local/setup` page on the Mac, review its versioned script and checksum, then run its displayed checksum-verified command. Choose that public file in the native picker. The script checks the pinned binary and dedicated `~/.codex/screenpunk-local` home, prompts for Mac-only Codex sign-in when needed, and presents the SSH authorization changes for review. Enable Remote Login yourself for the selected Mac account. Setup v4 offers explicit consent to install the per-user `xyz.screenpunk.local-agent` LaunchAgent, or a Terminal-only alternative. Migrating a verified foreground server requires a separate brief-disconnect approval. Background startup runs now and after sign-in, restarts on exit, and stops at logout; it does not change power settings.
2. **Connect.** Scan the private reply QR shown on the Mac, or import its private connection file. Review the computer and host fingerprint, then run Test Connection. The test uses a small structured Codex response and reconnect check; it installs no screen. Discovery under Advanced only suggests addresses and never establishes identity. Keep the reply private: it contains the transport bearer, expires after five minutes, and is never uploaded to the setup page.
3. **Connected.** The app commits the tested candidate and lets you name the computer and choose the route for new requests. A failed import or test preserves the existing endpoint. Re-pairing stages a new Keychain reference; pending public state, exact reply identity and consumed nonce receipts recover interrupted imports without silently approving a different reply.

The iPad connects to authenticated loopback App Server through pinned SSH. The private SSH key and bearer stay in iPad Keychain; Mac Codex login stays on the Mac. Existing paired configurations and saved libraries survive migration. Advanced provides manual recovery commands and address-only repair using the existing pin and credentials.

The private connection reply includes `serverLifecycle: "background"` only after the background job, process identity and exclusive loopback listener are verified. Missing lifecycle metadata defaults to foreground, preserving older connections. The app waits for both local transport versions to disconnect before reconnecting. V2 readiness keeps new empty threads in memory; submission persists the thread before sending a turn. The exact pinned-server missing-rollout error can replace only an unused thread with no bound delivery record. Accepted or uncertain requests always reconcile their original history and are never replayed by this recovery.

Both agents use authoring V2 for screen edits. Snapshots include editable source plus revision-bound asset references. Results explicitly write, retain or delete each base file. Native code copies retained bytes from the pinned original package, validates hashes, size limits and static dependencies, then commits the package, preferences and receipt through the durable journal. Omitted images are never reconstructed by the model. Missing assets, stale revisions, cancelled requests and invalid references are rejected. Older Cloud servers can still handle compatible new-screen V1 requests; an asset edit requires V2 support.

**Forget local agent** blocks outstanding local deliveries and removes the exact active iPad credential reference and configuration. Revoke access separately on the Mac by removing this iPad's public key from `~/.ssh/authorized_keys`, then stop App Server or rotate its bearer if needed. Dismissing or expiring the QR does not revoke an installed public key or stop an already running server.

Portable tests cover pairing fault cuts, route choice, raw-byte retention, dependency validation, journal recovery and Cloud wire compatibility. A signed build and fixture passes do not replace physical QR scanning, pairing review, Local/Cloud create and repeated edits, cancellation/reconnect, account isolation, and Home Assistant permission-continuity checks on the iPad.
