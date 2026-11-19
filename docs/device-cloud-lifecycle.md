# Cloud device removal and names

These additive service fields do not change the screen authoring contract.

## Removal

For a previously valid credential whose enrollment was revoked, authenticated
device endpoints return HTTP 401 with:

```json
{"error":"device_revoked","deviceId":"captured-device-id"}
```

The existing device socket sends this notice before closing:

```json
{"type":"device_revoked","deviceId":"captured-device-id"}
```

The app accepts either signal only for the current captured credential and
device ID. Generic HTTP 401/403, socket closure, timeout, and server failures
do not sign the user out. Offline devices discover removal on their next
authenticated contact; there is no added polling loop.

The app records an origin-scoped hash of the revoked credential in its durable
local journal and clears the scoped Keychain session. The journal prevents
restoring that credential if Keychain clearing was temporarily unavailable.
If both stores fail, runtime sign-out still occurs and the app reports the
storage problem. A rotated credential or another origin is not revoked.

The current account library is detached, not deleted. The standalone local
profile is opened; account onboarding applies unless an actual local agent is
configured. Cloud backups, other account libraries, local connection credentials,
and account-deletion recovery transactions are preserved. Removal does not send
an account-delete request or sign-out DELETE back to the server.

## Canonical names

Registration and status retain existing fields and add:

```json
{"deviceId":"device-id","name":"Pappy's iPad","nameRevision":3,"enrollmentRevision":2}
```

Registration must retain its legacy `id` and `profileID` for older clients.
The new app accepts `deviceId` as an alias for `id`, rejects conflicting IDs,
and accepts legacy responses without revision metadata. The registration
request's existing `name` is only a seed: the server must not overwrite an
established name on reconnect, including when the caller is an older app.

An explicit native edit is persisted before sending:

```text
POST /api/device/name
```

```json
{"name":"Pappy's iPad","expectedNameRevision":3,"operationID":"stable-operation-uuid"}
```

The server derives enrollment identity/revision from the credential. Success
returns canonical name fields. A stale edit returns HTTP 409 with those fields
and `error: "device_name_conflict"`. Retries reuse the persisted operation ID
and original name revision; the app never rebases an edit over a Cloud rename.
The newer canonical name wins, and the app reports the conflict. A subsequent
explicit edit may replace it. A newer queued edit can be rebased over the app's
own immediately preceding successful write, preserving edits made in flight.

The socket emits:

```json
{"type":"device_name_updated","deviceId":"device-id","name":"Pappy's iPad","nameRevision":4,"enrollmentRevision":2}
```

The app applies matching-enrollment notices monotonically. When no matching
canonical baseline exists, the notice triggers one authenticated status read.
Late responses cannot downgrade names or affect a different signed-in session.
A new enrollment revision discards pending edits from the previous enrollment.

## Validation limits

Durable state, conflict/retry races, credential/origin isolation and wire parsing
are covered by the Core and device-library tests. The UIKit integration is
compiled unsigned. Real-account removal, device sign-out, installation and
production deployment require coordinated integration validation; source tests
and compilation do not establish that those actions occurred.
