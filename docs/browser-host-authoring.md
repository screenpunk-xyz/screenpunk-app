# Opt-in browser host authoring

`browser-host-v1` is a separate canonical runtime/guidance pair for a host that
implements the subset in `packages/contracts/definitions/browser-host-v1.json`.
It does not activate adapters, select itself by default, or grant permission.
This follow-up does not publish an artifact, change private pins or rebuild the
current iOS app. The existing Viewer playback release can ship independently.

The original v1 definition, v1/v2 request/result schemas, native/offline browser
pairs and existing conformance fixtures retain their bytes. The wire request
remains schema version 1 (or existing v2 asset-reference delivery); the exact
`browser-host-v1` feature marker and canonical pair identify this opt-in profile.
Existing sealed snapshots keep their original pair and digest.

## Consumer selection

Use `browserHostAuthoringRuntime()` and `browserHostAuthoringDesignGuidance()`
together only after qualifying the adapter. Swift exposes
`AuthoringContract.browserHostRuntime` and `browserHostDesignGuidance`.
Existing `browserAuthoringRuntime()` / `browserAuthoringDesignGuidance()` still
return the offline profile.

`makeBrowserHostAuthoringServices(observedAt, observations)` supplies only the
browser-specific publicHTTP descriptor; Swift has
`makeBrowserHostServices(observedAt:observations:)`. Each supplied fact keeps its
own timestamp. Configured, authorized, entitled and reachable independently
default to unknown. A declaration, backup, runtime status flag or native-device
approval is not evidence of browser authorization. Observe facts for the bound
account, screen and current package revision. An unknown/negative authorization
is never a read grant; a current-package grant does not authorize an edit.

## Advertised subset

| Area | Contract |
| --- | --- |
| Public reads | `connections.read` / `release`; five reviewed weather/NASA origins, declared string parameters, revision-bound user approval, credential-free reads and browser CORS |
| Responses | Fresh/stale JSON or opaque PNG/JPEG image URLs; JSON 1 MiB, raster 4 MiB with dimension/pixel bounds; failures reject; release managed images |
| SDK state | Async get/set/remove; missing is null; 16 KiB/value, 128 KiB and 128 keys/screen, host-enforced nesting limit; await writes |
| DOM storage | Hydrated scoped localStorage method facade, separate 512 KiB budget and asynchronous persistence; frame-local sessionStorage with 512 KiB budget; no cross-tab storage event promise |
| Pages | navigation.get/open within declared bundled HTML pages; no device activation, external navigation or event-rule engine |
| Lifecycle | ready/status, cancellation, release and dispose; browser background timers may be throttled |

Use the host-provided SDK instead of a native transport. Raster URLs are opaque
browser resources; do not assume native custom-scheme URLs. Bounds are exported
as immutable `BROWSER_HOST_AUTHORING_PROFILE.policy`.

Home Assistant, Calendar, Google TV, native Maps/cameras/location, brightness,
screen data and authoring preferences are absent. Requests cannot supply
authoring preferences; results cannot mutate them, declare screenData or use
non-publicHTTP connections. Native and browser provider descriptors cannot be
substituted. Existing unsupported screens may be inputs for repair; authored
output must meet the target profile.

V2 written manifests are checked during result validation. Opaque retained
manifests are checked after pinned bytes are resolved by
`materializeAuthoringResultV2` / Swift `materialize`; materialize before install.
Authoring validation is not runtime admission: the host still enforces message
ownership, operation parameters, destination policy, approval and revocation.

## Basis and rollout

The subset follows Cloud's viewer-frame-runtime, viewer-broker,
viewer-public-data, viewer-raster and viewer-pages adapters. It promises no
provider credentials, native grants, unrestricted networking or device storage.
The shared `conformance-browser-host-v1.json` covers sealing and manifest
acceptance in TypeScript and Swift, alongside observation/profile/preference and
v2 retained-reference rejection tests.

Publish a new immutable public artifact version and qualify/update the consumer
in a later coordinated change before using this profile in Cloud authoring.
Do not republish beta.14, change its pins or alter legacy sealed requests.
