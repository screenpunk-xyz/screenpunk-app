# Canonical authoring contract v1

`definitions/authoring-v1.json` is the shared source of truth for device-agent authoring. It bundles versioned layout/design instructions, the exact exposed browser runtime features and package limits, implemented provider operation input/output schemas and setup requirements, and strict JSON Schemas for requests, results, preferences and application receipts. The prior authoring guidance is exported from this definition rather than maintained in account.ts.

TypeScript consumers import `authoring.ts`. `validateAuthoringRequest`, `validateAuthoringResult`, `validatePreferenceRecord`, `validateApplicationReceipt` and `validateAuthoringScreen` throw `AuthoringContractError` and return typed data. `authoringSnapshotDigest`, `sealAuthoringRequest` and `verifyAuthoringRequestDigest` use SHA-256 through Web Crypto. The synchronous request/result validators enforce structure and request binding; callers must also await `verifyAuthoringRequestDigest` before accepting a request or result. The `AUTHORING_*_SCHEMA` exports are fully inline for embedding in MCP tool schemas; definition.schemas.Request/Result/Preference/Receipt are standalone JSON Schemas with local `$defs` (lowercase aliases are available in TypeScript).

Swift consumers import `ScreenpunkCore`. Public Codable models use identical names and keys. `AuthoringContract` loads the byte-identical bundled definition and exposes `definition`, `designGuidance`, `runtime`, `serviceCatalog`, `makeServices(observedAt:)`, `seal`, `snapshotDigest`, and Data-based validators. Swift `validateRequest` verifies SHA-256, and `validateResult(request:)` validates the bound request as well. `encodedCanonical`, `canonicalJSON` and `contentDigest` support stable operation fingerprints.

A request snapshot is immutable once sealed. Its digest covers the full request, including guidance, runtime, independent capability observations, preference revisions, context, and delivery route; only `delivery.snapshotDigest` is omitted. Canonical JSON recursively sorts object keys by UTF-16 code units, uses standard JSON string escaping and ECMAScript number formatting, preserves Unicode without normalization, and is UTF-8 encoded for SHA-256. Undefined/nonfinite values are rejected. Request metadata excluding currentScreen is at most 128 KiB; a full request/result is at most 384 KiB. Answers preserve the legacy maximum of 16000 UTF-16 code units (schema byte ceiling 64000); both title and answer must contain non-whitespace text. Shared BMP and surrogate-pair vectors enforce these exact compatibility bounds. Result metadata excluding screen also has a separate 128 KiB serialized canonical UTF-8 bound, including JSON escaping in proposed preference values. `AUTHORING_RESULT_LIMITS` exports these limits; standalone result schema annotations document them as `x-screenpunk-*` byte limits. Swift exposes `resultMetadataBytes` and `resultBytes`. Screens retain the existing UTF-8 package envelope: 1–20 files, `index.html`, safe ASCII file paths <=160 bytes, title <=100 UTF-16 code units (the legacy JavaScript string length, with schema byte ceiling 400) and <=200 KiB serialized JSON including escaping and metadata. Native package/manifest/hash validation still runs at installation; the contract does not replace it.

Capability supported/configured/authorized/entitled/reachable facts are independent yes/no/unknown states with observation timestamps. Unknown does not authorize use. Google Calendar configuration is reported by the device; validators accept all three states without granting account authorization or per-screen calendar access. The legacy canonical guidance retains its original build-limitation wording for compatibility with existing request snapshots; it is not a validator restriction. Public HTTP uses the actual `connections.read(alias, operation, parameters)` API; the operation argument is manifest-defined, and its full declaration grammar and native restrictions are bundled in that operation descriptor. No arbitrary sockets or generic credentialed HTTP are advertised. Browser `state.*` is local screen state, distinct from durable authoring preferences.

Preferences have stable IDs, explicit profile/device/screen target scope, scalar value, revision, origin request and tombstone. Results only propose upsert/delete mutations with compare-and-swap revisions; mutation application remains native and atomic with installation. Any mutation requires a same-request authorization quoting exact request text containing explicit remember/always intent; ordinary screen edits never imply durable persistence. An external authoring agent must clarify ambiguous scope/value. Validation binds the quote to the request; it does not infer intent from repeated behavior. Receipts preserve request/operation/digest and report applied, conflict or rejected independently from delivery completion.

Run after editing the canonical definition:

```sh
node packages/contracts/scripts/generate-fixtures.mjs
node packages/contracts/scripts/sync-authoring.mjs
npm run contracts:check
npx vitest run packages/contracts/authoring.test.ts
```

`sync-authoring.mjs --check` detects drift in generated TypeScript, standalone schemas, and Swift bundled definition/fixture resources. `fixtures/conformance-v1.json` is shared by TypeScript and Swift tests: synthetic screen/request/result/preference/receipt examples, SHA-256 and Unicode/number canonicalization vectors, strict-version/field/scope/CAS rejection cases, and exact escaped/multibyte screen boundary vectors. Fixtures contain no credentials or private context. Swift conformance runs in the ordinary ScreenpunkCore test suite.

## Durable request lifecycle for v1 and v2

`deadlineAt` remains required compatibility metadata in the sealed snapshot. Keep its existing validation and original value when verifying the digest, reconciling a delivery, or validating its result. This runtime policy supersedes any legacy guidance that treats the timestamp as request expiry. An elapsed timestamp or a network attempt timeout leaves a pending request recoverable on the original route with the same request ID, snapshot and digest.

Reconcile against the current delivery before resuming work or retrying completion. An explicit cancellation, stored result or receipt, or another authoritative terminal state stops further authoring work. A stored result may still need native application and receipt reconciliation. Native revision, binding and permission checks continue to govern application.

## Negotiated asset retention v2

`authoring-v2.ts` and Swift `AuthoringV2Contract` are parallel APIs. V1 snapshots, generated bytes, whole-replacement behavior and receipts are unchanged. A route supports v2 only when its capabilities advertise both `contractVersions: ["2"]` and `features: ["asset-references-v2"]` (additional versions/features are allowed). Automatic routing must retain this requirement before sealing a request.

V2 uses the same runtime and limits. `context.libraryID` is the actual saved-library owner, not necessarily the Cloud profile ID. `currentScreen.files` is an immutable source manifest with safe path, MIME, raw UTF8 byte length, SHA256 digest and opaque request-bound reference. `content` is optional: image-dominated SVG/base64 content is omitted from repeated model context by the conversion helper, while editable text remains available. References hash canonical JSON of `{version:2,requestID,profileID,libraryID,screenID,baseRevision,path,mediaType,byteLength,digest}`. The snapshot digest excludes only `delivery.snapshotDigest` and includes all references. Swift validates cryptographic bindings synchronously; TypeScript callers must await `verifyAuthoringRequestDigestV2` (which also verifies references and included content hashes) before admitting a request/result.

A result screen has `files` and `deletedPaths`. File mutations are exactly `{kind:"write",path,content}` or `{kind:"retain",path,sourcePath,reference,digest}`. Every base path must have a same-path output or an explicit deletion. Copies have a new destination and leave the source requiring accounting; renames combine a new destination retain with deletion of the original source. Duplicate/case-colliding paths, overlaps, unknown deletion paths, foreign/stale references, omitted base files and writes/retains with mixed fields fail validation. New screens have no base manifest and cannot retain or delete. Optional `requiredAssets` are exact output paths and are validated before native static HTML/CSS dependency checks.

`materializeAuthoringResultV2` / Swift `materialize(_:request:resolve:)` resolve only validated manifest members. They verify raw source byte count and digest, require valid UTF8, preserve source bytes including BOMs, and enforce materialized package bounds. The native library additionally handles dependency rejection, revision compare-and-swap, durable pins, cancellation tombstones, journaling and atomic receipts. A model's completed response never releases source pins or proves native installation.

`fixtures/conformance-v2.json` is a shared TS/Swift hash vector with a synthetic 73,000-character embedded image recipe; the request itself contains no image base64. Regenerate with `node packages/contracts/scripts/generate-v2-fixtures.mjs`, then run `sync-authoring.mjs`. The existing sync drift check covers both versions, generated TS, standalone schemas and byte-identical Swift resources. V2 tests exercise scope/hash/path/partition/size failures, copy/rename, fresh screens, capabilities and exact retained content.

## Public release boundary

This package and its generated Swift resources are authoritative in `screenpunk-app`. Public software and shared contracts use Apache License 2.0; see `LICENSE`. The package version identifies the combined contracts/setup release artifact; request protocols remain independently versioned 1 and 2. The private cloud consumes a verified immutable bundle instead of importing a private editable copy. See `../../tools/public-artifacts/README.md` for packaging, commit/digest pins and the explicit local provisional bootstrap. Existing versions stay available during coordinated app/server rollout.

## Catalog backup capability v1

Catalog is additive and independent of authoring versions `1` and `2`. Source is
`catalog.ts`; `definitions/catalog-v1.json` is the wire schema definition,
`generated/catalog-definition.ts` and `definitions/catalog-*-v1.schema.json` are
checked generated outputs. Run `npm run contracts:generate` after schema edits.
`fixtures/conformance-catalog-v1.json` seals canonical package bytes and SHA256;
TypeScript and Swift conformance tests consume this same fixture.

Device-authenticated API routes (account/enrollment/copy come from server auth):

| Method | Route | Body/result |
| --- | --- | --- |
| GET | `/api/catalog/capabilities` | `CatalogCapability` |
| POST | `/api/catalog/backups/begin` | `CatalogBeginBackup` / `CatalogBackupStatus` |
| PUT | `/api/catalog/backups/{uploadID}/package` | Exact canonical package bytes / `CatalogBackupStatus` |
| PUT | `/api/catalog/backups/{uploadID}/preview` | Legacy route rejected; use the exact-version attachment protocol below |
| POST | `/api/catalog/backups/{uploadID}/complete` | `CatalogCompleteBackup` / `CatalogBackupStatus` |
| GET | `/api/catalog/backups/operations/{operationID}` | `CatalogBackupStatus` |

Browser-authenticated app routes: `GET /api/catalog` returns `CatalogList`
(`cursor` optional bounded opaque pagination token; at most 20 cards per page),
`GET /api/catalog/screens/{screenID}/versions/{versionID}/preview` serves only
private/no-store validated raster bytes, and
`DELETE /api/catalog/screens/{screenID}/versions/{versionID}` returns
`CatalogDeleteResult`. Browser deletes require existing CSRF/origin checks and an
`If-Match` header equal to the quoted decimal `catalogRevision` returned by list;
a stale revision returns `conflict` (HTTP 409), and the browser refetches. Device
credentials do not grant catalog listing or deletion. Errors are
`{error: CatalogError}`; safe bounded messages never contain source or secrets.
Suggested HTTP mapping: unauthorized=401, not_found=404, not_entitled=403,
conflict/deleted=409, quota_exceeded=413, invalid_package=400, retry_later=429,
offline=503. Known terminal operation retries precede entitlement rejection.
Capability absence disables new backup transport without changing authoring.

`previewMediaTypes: []` explicitly means raster capture/upload is unavailable.
Do not accept or advertise preview support without a real bounded decoder;
header signatures and caller dimensions are insufficient. Package publication
still succeeds with `{status:"unavailable",reason:"not_provided"}`. No HTML/SVG
preview execution or synthetic replacement images.

Packages are canonical JSON (existing `canonicalJSON`, UTF8, no BOM/newline),
containing a manifest and base64 **final materialized** file bytes. Hash and length
in begin refer to the exact whole uploaded envelope, not decoded file bytes or an
authoring delta. Each file also has its own raw digest/length. Sort files by exact
ASCII path; reject duplicate/case-colliding paths, traversal, links before export,
noncanonical base64 and unsupported media. Existing stricter authoring bounds
remain: <=20 UTF8 html/css/js/json/svg/txt files and <=204800-byte canonical
AuthoringScreen projection. The 10MiB outer transport ceiling does not add binary
package support. Raster previews are separate. Every discovered static local
reference must exist and appear in `requiredAssets`; discovered HTTP(S) references
must appear in `externalDependencies`. Bounded static markup/CSS validation does
not snapshot or exhaustively discover dynamic JavaScript dependencies. External
live data remains external; credential markers, private keys and secret-bearing
files are rejected, never silently stripped. Consumers retain existing stricter
package dependency/manifest validation.

Wire timestamps use exact UTC `YYYY-MM-DDTHH:mm:ss.SSSZ`; Swift uses
`CatalogContract.timestamp`. IDs are opaque bounded ASCII identifiers. Device
account identity, credential-bearing library owner and enrollment IDs are not
upload fields. Persist a separate stable wire library/local-screen ID when local
identifiers do not meet this grammar. Server maps authenticated enrollment plus
library/local-screen ID to its catalog/copy IDs. Source revision is immutable;
commitCounter is per copy, not a timestamp or display version. Parent IDs describe
lineage and predecessor identifies the previous captured copy revision. Display
versions are assigned only at publication, never reused. Idempotency uses stable
operationID plus `catalogBeginDigest`; changed request is conflict. Exact same
source revision dedupes; stale ancestors return superseded and never become latest.

Overflow pauses capture visibly while preserving bounded queued pins and permits
editing. Explicit Resume/current-screen acknowledgement may submit origin `seed`
with `gap` matching the server's **exact** prior copy counter/head. Skipped counters
start at checkpoint+1 and end immediately before the seed counter; reason is
`user_acknowledged_backup_pause`. Checkpoint must be >=1: drain the first queued
intent before reconciling a gap. This is not a reset-to-root escape, and server
still checks tombstones, monotonic counters, immutable source identity and copy
fences. No silent queue coalescing. A root seed has no gap and no predecessor.

Effective entitlement is configured server-side, with no pricing or billing policy.
Defaults: 3 versions/screen, 20 screens/account, 10MiB envelope, 512KiB preview,
2048px maximum dimensions, 1GiB account live/reserved usage and separately bounded
20MiB publication overlap, and 100 revisions/100MiB device queue. Count cleanup
backlog until physical deletion. Recheck entitlement/quota at publication; failed
uploads never evict completed backups. Downgrade pauses new captures while keeping
list/read/delete and completed history. `sizeBytes` is actual stored package bytes,
excluding preview/metadata. List uses real completed versions only, latest excluded
from descending history; stable display numbers may have gaps after deletion.

Release gate: merge all public source/generated fixtures and Swift parity tests in
an immutable public commit, assign an unused public artifact version, then run
`tools/public-artifacts/pack.mjs --source-revision FULL_SHA --output OUTSIDE_CHECKOUT`.
Publish those immutable bundle/hash/lock bytes through the owning GitHub plugin
release workflow. Private consumers must update their verifier allowlist support,
lock and vendor snapshot through the established artifact tooling using that
published SHA/hash. Provisional bundles are local integration evidence only and
cannot qualify deployment. Do not release against a working-tree import or edit
only the private vendored copy. Authoring contract version list stays `["1","2"]`.

Known missing R2 objects may mark a visible version `integrity:"missing"`; retain
its metadata and deletion path and display “Backup unavailable” instead of hiding
healthy rows or claiming the package exists. Expired upload leases return state
`failed`, error `retry_later`, and `restartOperation:true`. Only that terminal
combination permits rotating the transport operation ID while preserving the
source revision/counter/lineage, exact pinned package bytes and queue intent.
Ordinary pending/backoff responses never carry this flag.

Empty individual files are valid and preserved with byteLength zero, canonical empty
base64 and SHA256 of empty bytes; the whole package envelope remains nonempty.

### Exact-version PNG attachments (additive preview protocol v1)

Artifact beta.4 adds `previewBackfillVersion:"1"` on `CatalogCapability`.
Clients use this protocol only when that field is present **and**
`previewMediaTypes` includes `image/png`. PNG support applies to the following
post-publication flow. The legacy `/api/catalog/backups/{backupUploadID}/preview`
route remains rejected; advertising PNG does not authorize that route. Existing
package backup success and source-pin acknowledgement remain independent of
preview capture/upload failures. JPEG is not accepted by this attachment protocol.

| Method | Device-authenticated route | Typed body/result |
| --- | --- | --- |
| GET | `/api/catalog/preview-candidates?cursor=...` | `CatalogPreviewCandidates` (<=20 records/page) |
| GET | `/api/catalog/screens/{screenID}/versions/{versionID}/package?sourceRevisionID=...&packageDigest=...` | Exact immutable canonical package bytes |
| POST | `/api/catalog/previews/begin` | `CatalogPreviewBegin` / `CatalogPreviewStatus` |
| PUT | `/api/catalog/previews/{uploadID}/image` | Exact declared PNG bytes / `CatalogPreviewStatus` |
| POST | `/api/catalog/previews/{uploadID}/complete` | `CatalogCompleteBackup` / `CatalogPreviewStatus` |
| GET | `/api/catalog/previews/operations/{operationID}` | `CatalogPreviewStatus` |

Candidates and package retrieval are limited to the authenticated **original
producing enrollment and copy**, not an account-wide device catalog/list grant.
Server compares the selected version's mapped library/local-screen IDs,
sourceRevisionID, packageDigest, account ownership and current tombstone/integrity
state. The package query includes exact immutable source binding; it is not a
selector for arbitrary device/source data. Source downloads are private/no-store,
served as attachment/octet-stream without execution in the browser account origin.
Native recovery verifies the whole-envelope digest and existing package validators
before capture. Missing or unrecoverable source produces unavailable preview;
never capture the current screen for a different saved version.

`CatalogPreviewBegin` requires operationID, catalogScreenID, versionID, libraryID,
localScreenID, sourceRevisionID, packageDigest, source:`"exact_package"`, exact UTC
`capturedAt`, and PNG digest/actual byte length/dimensions. `catalogPreviewBeginDigest`
seals the canonical immutable intent. Same operation and request dedupe; changed
request conflicts. Intent/upload IDs are server-scoped, leased and bounded. Begin
and publication recheck version ownership, original copy/enrollment, revocation,
quota, entitlement and tombstones. An available preview is immutable: only the same
bytes can dedupe; a different image cannot silently replace it. Logical deletion
wins an in-flight attachment race and enqueues exact private-object cleanup.

A device may capture the active view only after checking its exact immutable
revision/package asset digests and generation before and after capture. Persist
those bounded PNG bytes and declaration before HTTP; attach only after the matching
package version is acknowledged. If the active view no longer matches, render the
exact recovered package in an isolated native view with network/device bridges,
runtime preferences and credentials disabled. Do not execute saved HTML in the
Cloud/browser account origin. Dynamic source that cannot produce an honest image
under those restrictions remains explicitly unavailable. This is a device capture
claim bound to authenticated provenance, not server-side proof of pixel semantics.

The server verifies PNG signature, complete chunk structure/CRC, supported raster
format, bounded decompression/scanlines and actual dimensions before publication;
filename, headers, or caller-supplied dimensions alone are insufficient. Enforce
<=512KiB and <=2048 pixels per dimension (plus stricter effective entitlement).
Do not advertise support until this validator and private storage are ready.
Capture/upload/validation failure never turns a completed package into a failed
screen application or fabricates an image.

Available `CatalogPreview` may include source:`"exact_package"` and `capturedAt`;
new attachments supply both, optional fields preserve compatibility with existing
wire readers. The browser's existing authorized per-version `/preview` GET serves
only active version metadata and safe PNG bytes with private/no-store headers.
Show the matching latest or earlier version's capture time. A backfilled image is
a **current rendering of that exact saved source**, not a historical snapshot of
external runtime data at sourceAppliedAt or backedUpAt. Never label missing or
failed captures as a screenshot. The synthetic one-pixel conformance raster is
protocol test evidence only and must never be served as a production preview.
