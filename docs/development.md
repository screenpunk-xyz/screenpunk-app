# Developer configuration

The official identity remains `xyz.screenpunk.ios`, Apple team `77KASWDGM6`, and callback scheme `screenpunk-one`. Migration does not change storage locations, Keychain identifiers, preferences, screen library layout, permission prompts, or local/cloud routing. Existing installations must be upgraded under the same official identity.

The checked-in default API origin is `https://staging.screenpunk.xyz`. Build with `SCREENPUNK_API_ORIGIN=https://your-server.example` to select a compatible HTTPS origin. This is nonsecret configuration embedded in the app's Info.plist. Native Google OAuth client IDs are public configuration; each fork must register its own client and redirect scheme for its chosen bundle identifier. Backend OAuth client secrets belong on the server.

For a signed fork build, copy `config/Fork.xcconfig.example` to ignored `config/Local.xcconfig`, fill in your team and bundle ID, then pass `-xcconfig config/Local.xcconfig` to xcodebuild. Configure matching OAuth callbacks with your provider. Use your own artwork for redistributed forks; the supplied official icon is separately reserved. Local-only use requires no Screenpunk account or server secret.

App Store Connect keys, distribution private keys, provisioning passwords, user session tokens and local agent bearers must never be embedded in source, packages or test fixtures. Official signing belongs to the trusted private release pipeline.

Before substantial builds, check disk space. Reuse a task-owned `.task` build root and remove only owned disposable outputs after saving concise test evidence. Do not delete personal Simulators or user state. Public CI uses GitHub-hosted machines; self-hosted release runners stay private.
