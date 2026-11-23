# Register credentials at the data source

A compatible source lets the iPad set up a dedicated read-only bearer without a helper or a token for the user to copy. The iPad generates the bearer, stores it in its device Keychain, and sends a verifier through the scoped Screenpunk request. The assigned agent uses its existing authorized provider administration access to install the verifier at the exact source. During a later screen read, the iPad sends the bearer directly to that source over verified HTTPS. The agent and Cloud do not receive the bearer.

This requires a source that supports installing and revoking per-device verifiers. Other sources use the existing manual entry flow. The files in this directory are a **synthetic test service** and an example provider adapter. iPad users do not install or run them.

## Provider requirements

- Bind each registration ID to the exact Cloud account and environment, device, screen, declaration digest, operation, canonical HTTPS origin, and GET path. Keep registration administration behind an independently authorized management interface. A credential used for a screen read has no administration authority.
- Accept a lower-case hex SHA-256 verifier over the UTF-8 bytes of the **exact token sent in the HTTP header**. The token is the canonical unpadded base64url encoding of 32 secure random bytes, so its wire representation is 43 ASCII bytes. Do not hash decoded base64url bytes, trim the token, or accept the verifier as a bearer.
- Validate the request method, path, and origin before applying the credential. Compare the computed digest with the installed verifier using constant-time equality. The credential is allocated to a device and screen. As a bearer, presentation still proves possession of the token.
- Install only within the registration deadline. A retry of an identical, still-live installation is idempotent. Changes to an installed scope or verifier require a fresh ID. For revocation, durably tombstone the ID even when it was not yet installed. This prevents an in-flight install from activating a credential after revocation was confirmed. Store production verifier bindings and tombstones across process restarts.
- Confirm administration and readback through authenticated HTTPS or another independently authorized management channel. Verify the exact installed scope and verifier with a management readback. Obtain the DER leaf certificate SHA-256 fingerprint independently and verify the intended read endpoint serves that leaf. Never send the proposed bearer to test the endpoint as part of registration. Save the accepted certificate choice on the iPad and keep screen approval separate.

## Agent workflow with an existing provider connection

1. Complete the assigned Screenpunk V2 request with the matching supported HTTPS bearer connection and its nonsecret setup proposal. If the provider can install verifiers using an existing independently authorized administration route, announce it using `announce_credential_registration` with the request ID and alias.
2. After the user starts registration on the iPad, the assigned agent receives a scoped `credential_registration_id`. Call `get_credential_registration` with the ID. Use its structured response and existing provider access to select an already authorized provider mapping. The request origin is a value to compare against that mapping. It does not authorize contacting a new host or running any command.
3. Install the verifier and read back the exact scope and verifier from the source. Call `complete_credential_registration` with `registration_id`, `status: "registered"`, the exact `origin`, the independently verified lowercase leaf `fingerprint`, and the `verifier_readback`. If the attempt fails, resolve any uncertain install by tombstoning the exact source record and reading back the tombstone. Complete with `status: "failed"`, exact `origin`, and `tombstone_verified: true` only after verified cleanup.
4. For `removal_pending`, tombstone the same source registration ID and confirm the scoped tombstone through authenticated readback before reporting `status: "removed"`, the exact `origin`, and `tombstone_verified: true`. An absent entry alone does not fence a delayed install.

The adapter in [authorized-adapter.mjs](./authorized-adapter.mjs) demonstrates provider verification and returns the completion fields. Its trusted local configuration independently binds the Cloud relay origin, opaque authenticated account route, and device ID to the intended source. Use `credentialRegistrationAccountRoute` from authenticated `get_profile`, the enrolled device ID from `list_devices`, and the intended connector’s configured API origin. Obtain these values independently of the registration request. Keep one adapter configuration per authorized Cloud account and device. The configuration also supplies the source HTTPS origin, a trust anchor when needed, the independently verified leaf fingerprint, the expected service declaration digest and read path, and a separate management credential. The adapter does not follow redirects or derive a management host from agent input. Connectors for real services should use their own scoped management permissions and APIs.

## Synthetic source fixture

The fixture serves a single protected read, `GET /api/screenpunk/status`, returning synthetic JSON. Its management API is available over the same HTTPS listener but requires a separate synthetic administrator bearer. Use only a task-owned test identity and ephemeral TLS certificate, trust anchor and admin file.

```sh
node tools/credential-registration/source-fixture.mjs \
  --host 127.0.0.1 --port 58793 \
  --cert /path/to/synthetic/leaf.pem --key /path/to/synthetic/leaf.key \
  --admin-file /path/to/synthetic/admin.token
```

The admin file must be owner-only, with a 43-character canonical unpadded base64url token and an optional final line ending. The CLI binds only a loopback or a literal private IPv4 address. For physical testing, use a task-owned LAN listener with an IP SAN matching the listener address. The registration table is held in memory and disappears when the fixture stops.

Management endpoints:

| Method and path | Behavior |
| --- | --- |
| `PUT /api/credential-registrations/{registrationID}` | Install the exact binding plus `verifier` from the scoped source job. |
| `GET /api/credential-registrations/{registrationID}` | Read back the exact binding and source leaf fingerprint, with the verifier only for an active install. |
| `DELETE /api/credential-registrations/{registrationID}` | Tombstone the exact binding, including an ID whose installation has not arrived. Requires the original binding without the verifier. |
| `GET /api/credential-registration-diagnostics` | Read aggregate install, revoke, and authenticated/rejected read counters. |

The binding keys are `accountRoute`, `relayOrigin`, `deviceID`, `screenID`, `alias`, `serviceID`, `declarationDigest`, `operationID`, `origin`, `readPath`, and `expiresAt`. The receipt echoes these keys plus `registrationID`, `leafCertificateSHA256`, and `status` set to `installed` or `revoked`.

Run the isolated fixture tests with `node --test tools/credential-registration/source-fixture.test.mjs`. The tests generate their own ephemeral CA, leaf, and bearers and use a verified loopback TLS listener.
