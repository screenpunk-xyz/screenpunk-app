# Public contract and setup release bundle

The public repository owns the authoring contract definitions, TypeScript validators, Swift conformance resources and local setup generator. This tool packages the TypeScript validators, generated definitions, standalone schemas, shared fixtures, Apache licenses, and portable setup module into one deterministic JSON asset. Each member has a safe allowlisted path, byte length and SHA256. The complete asset has a separate SHA256. JSON with base64 members avoids archive extraction, links and traversal semantics.

Run the ordinary contract/setup drift checks and tests before packing. Select a reviewed committed public source revision and an unused version in `packages/contracts/package.json`:

```sh
node tools/public-artifacts/pack.mjs \
  --source-revision FULL_40_CHARACTER_PUBLIC_COMMIT \
  --output /owned/release/screenpunk-public-artifacts-0.1.0-migration.1.json
```

The tool requires that commit to equal the public checkout HEAD and verifies every bundled file and the packaging tools against committed bytes. It writes the asset, `.sha256` receipt and `.lock.json` consumer pin with exclusive creation. The versioned GitHub release asset URL contains that exact version; upload these exact bytes. Never replace an asset for a released version. The source snapshot digest describes the sorted bundled paths, sizes and digests; the source commit identifies the complete public checkout.

Before a real public commit exists, local migration qualification can use `--provisional` instead of `--source-revision`. The resulting metadata explicitly records `sourceRevision: null`, `provenance: "local-provisional"`, a source snapshot digest and `url: null`. It is local evidence and cannot pass the private deployment gate. No source revision or published receipt is fabricated.

The private repository copies the reviewed `.lock.json` to `public-artifacts.lock.json`, prepares dependencies using its own verifier, and compiles only its verified `vendor/screenpunk-public` content. It never fetches a moving branch, resolves `latest`, generates a cloud-specific contract variant or downloads contracts at Worker runtime. A coordinated release uses the same public source commit for Apple builds and this bundle. Contract versions 1 and 2 remain supported; breaking changes require a separate compatibility and rollout plan.

`node --test tools/public-artifacts/tests.mjs` verifies determinism, immutable output, content/source identity checks and unchanged setup v1–v6 checksums. These packaging checks supplement the TypeScript/Swift conformance tests.
