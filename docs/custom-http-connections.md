# Custom HTTP connections

A screen can declare a connection when the authoring request advertises
`custom-http-v1`. The device asks the user to configure the connection and
approve the screen's declared access. Use this for an API the user asked the
screen to read. Use the API's documented route and response.

```json
{
  "alias": "generator",
  "required": true,
  "customHTTP": {
    "id": "generator-telemetry",
    "version": 1,
    "label": "Generator",
    "fields": [
      { "id": "origin", "label": "Server address", "type": "url" },
      { "id": "credential", "label": "Bearer token", "type": "secret" }
    ],
    "originField": "origin",
    "auth": { "mode": "bearer", "field": "credential" },
    "operations": [
      { "name": "telemetry", "method": "GET", "path": "/telemetry", "response": "json", "parameters": {} }
    ]
  }
}
```

Place the declaration in `manifest.json` under `connections`. Call
`await screenpunk.connections.request("generator", "telemetry", {})` to read
the decoded JSON at `result.value`. Handle setup, permission, and network
failures in the screen UI.

- Keep the connection ID and version stable across unrelated screen edits.
- Supply one `url` field for the origin. Native configuration accepts a scheme, host, and optional port. Local network and insecure HTTP access require user approval. Prefer HTTPS.
- Declare `auth` only if the API uses bearer authentication. The device asks for the associated secret field and attaches its value natively. Keep entered configuration and credentials out of the manifest, package files, and SDK calls.
- Other field types are `text`, `number`, `toggle`, and `choice`. Only `choice` fields include an `options` array of distinct strings. All declared configuration fields need values.
- Name the exact read operations the screen needs. This version supports fixed GET paths returning JSON. Put query inputs in `parameters`. Use `text`, `number`, `toggle`, or `choice` descriptors with `type`, plus `options` for choices. An optional `field` binds the parameter to a configuration field of the same type and options. Supply only unbound parameters as strings in the SDK call. Use decimal notation for numbers and `"true"` or `"false"` for toggles.

## Request-bound setup proposals

New native clients negotiate `custom-http-prefill-v1` with Cloud. Only a V2
request advertising that feature accepts `connectionSetupProposals` in its
completion result. V1, browser and legacy clients retain manual entry. The
initial native rollout does not advertise prefill to local authoring hosts.

Each proposal is `{version:1, alias, declaration, fields}`. `declaration` must
exactly match the alias's `customHTTP` object in a **written** `manifest.json`
in the same result. `fields` maps declared nonsecret field IDs to validated
strings (decimal numbers, `true`/`false` toggles and exact choices). Include the
origin. No credential, secret field, credential reference or network approval
is accepted. Suggestions live outside the portable screen package.

The result's request ID, immutable input digest, revision and operation identity
bind proposals to the authenticated request and its device/profile/library/screen.
Cloud and native validate the same payload; native applies a draft only with a
successfully installed screen before the request deadline. The draft is valid only for that local revision
and declaration, is not backed up with the package, and is removed when that
revision is replaced. Cancellation, stale results and replay with changed bytes
use the existing delivery rejection gates.

Native Settings prefills an unconfigured form without another permission
prompt. Saved settings remain authoritative; the proposed and current server
are displayed separately. Editing an existing connection starts with its saved
values. Saving remains explicit, and changing settings invalidates prior grants.
The existing vault may retain a compatible saved bearer credential only during
an explicit save at the same canonical origin. A change of origin requires a credential explicitly provided for the new server.

## Paired credential delivery

On a Cloud V2 request advertising `credential-handoff-v1`, the authoring agent
can request a delivery from the iPad’s paired helper. Complete the screen
request with a matching HTTPS setup proposal first. Then call
`request_credential_handoff` with the same request ID, the connection alias,
and the public name of the credential configured on the helper. Keep that name
out of screen files. The device and helper check the destination and exact
declaration independently before the user can accept the token.

The initial pairing uses a trusted channel between the helper operator and
native Settings. Open **Settings → Shared Connections → Credential Helper** on
the iPad to scan the helper’s pairing code or import its pairing file. Treat
that pairing material as a secret. See the [helper setup instructions](../tools/credential-handoff/README.md).

The token travels in an authenticated encrypted envelope. Native Settings shows
the destination for review and saves an accepted token in the device Keychain.
Certificate trust and per-screen approval still apply. Unpaired devices and
older clients can use manual token entry.

The first attempted unapproved declared operation opens trusted native review
over the active screen. It identifies the screen, destination and exact GET
operations. Setup, local HTTP consent, Save connection and Allow this screen
remain separate decisions. The failed request is not automatically replayed;
the screen may retry after approval. No DNS resolution, HTTP request or bearer
header construction occurs before approval. Dismissing without approval records
a denial, scoped to the owner, screen, alias, exact declaration and saved service
generation. Revocation also suppresses repeat prompts; Settings can explicitly
allow access later. Screen HTML cannot render or accept this native decision.

Qualification uses synthetic origins and credentials. An unsigned build and
unit/integration tests do not establish physical-device presentation or TestFlight
acceptance; those remain explicit rollout checks.
