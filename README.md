# Screenpunk app

Universal iPhone and iPad app with local rendering, device services, local agent authoring, and the public Screenpunk authoring contracts. The app supports account-free local use. Cloud service implementation and official signing/release orchestration are maintained separately.

Requires macOS 26+, Xcode 26.6, Swift 6.3, and Node.js 24 for contract checks. Minimum app deployment target remains iOS/iPadOS 16.

```sh
npm ci
npm run check
npm test
swift test --package-path packages/ScreenpunkCore
swift test --package-path packages/ScreenpunkApple
swift test --package-path apps/device
swift test --package-path packages/ScreenpunkLocalTransport
swift test --package-path packages/ScreenpunkLocalAuthoring
xcodebuild -project apps/device/ScreenpunkOne.xcodeproj -scheme ScreenpunkOne \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .task/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

No private repository, cloud account, signing key, or Google developer password is required for an unsigned build or local use. See [developer configuration](docs/development.md), [CI](docs/ci.md), and [local Mac setup](tools/local-agent-setup/README.md). Setup tests use synthetic data; never execute the setup installer as a test.

Canonical contracts live in `packages/contracts`. Generated Swift resources must pass `npm run contracts:check`. Contract/setup bundles are versioned and checksummed for private cloud consumption; see `tools/public-artifacts`.

Software and public contracts are Apache License 2.0. Preserve [LICENSE](LICENSE), [NOTICE](NOTICE), third-party notices, and [brand terms](docs/brand-policy.md). Screenpunk trademarks and artwork have separate reserved rights. Forks should use their own app identity, OAuth registration, signing, and branding.
