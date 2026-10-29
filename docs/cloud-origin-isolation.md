# Public app Cloud origin isolation

`ScreenpunkAPIOrigin` must be an HTTPS origin. Scheme/host case, a trailing slash,
and the default HTTPS port canonicalize to one origin. Different hosts or nondefault
ports use separate public-app Keychain services for both the session and installation
secret. A production build cannot load the staging token or installation secret.

Only `https://staging.screenpunk.xyz` can migrate the earlier fixed
`xyz.screenpunk.one.cloud` service. Migration persists the scoped value before
removing the original. Sign-out persists an empty scoped session marker before
legacy cleanup, so an interrupted deletion cannot restore an old login. The scoped
installation identity survives sign-out and remains stable on the next sign-in.
Other native/local-agent credential services are unaffected.
If secure storage cannot persist the sign-out marker, the app detaches the in-memory
session and explicitly reports that the saved sign-in could return after restart.
An offline server-revocation failure is reported separately after local clearing succeeds.

Rolling back to an older build can require signing in again: older builds only know
the fixed legacy service, which staging migration removes after its scoped copy is
durable. Existing saved staging screens retain their legacy local ownership.

Staging keeps its existing local account/library/permission owner IDs. Every other
origin namespaces those local IDs with the canonical origin and server user ID.
This prevents the same Google identity in staging and production from opening or
binding the other environment's library. Server user objects, profile IDs and device
IDs remain unchanged in authentication and authoring requests. An already selected
staging library may remain available locally when starting production signed out;
its Cloud ownership checks do not match a production session.
When a saved session is restored, a selected Cloud library from another origin or
account is replaced by that session's own account library. Switching between staging
and production builds therefore restores each environment's library without another
sign-in. An intentionally selected, unlinked local library stays selected.

`CloudOriginScopeTests` exercises canonicalization, migration interruption, scoped
credential reads/writes, sign-out markers and local profile separation with synthetic
values, without reading a real Keychain or changing an installed device session.
