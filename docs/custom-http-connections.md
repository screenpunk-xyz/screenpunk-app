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
