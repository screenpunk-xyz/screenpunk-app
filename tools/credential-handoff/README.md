# Screenpunk credential handoff helper

Run the helper on a trusted Mac or Linux host where its service user can read the dedicated bearer token. The helper accepts work for one paired iPad and only for credential mappings the operator installs locally. Screenpunk Cloud and the authoring agent receive requests, public scope, delivery state, and an encrypted envelope. The bearer remains in the helper and the accepting iPad.

## Set up one iPad

1. On the helper host, create an owner-only directory outside source control. With Node.js 24 or later, run:

   ```sh
   umask 077
   mkdir -p "$HOME/.config/screenpunk-handoff"
   chmod 700 "$HOME/.config/screenpunk-handoff"
   node tools/credential-handoff/helper.mjs init https://api.screenpunk.xyz \
     "$HOME/.config/screenpunk-handoff/helper.json" \
     "$HOME/.config/screenpunk-handoff/device.screenpunk-pair"
   ```

   For Staging, use its configured HTTPS API origin. For an interactive QR instead of file transfer, append `--qr` and install `qrencode` on the helper host. Use a private terminal without session capture for the QR. The command also creates the file in this mode.

2. On the iPad, sign into the intended Screenpunk environment. In **Settings → Credential Helper**, scan the helper QR or import the pairing file over a private, user-controlled transfer. Review the relay and pair identity. The file and QR carry the shared pairing key, so keep them private and remove the imported copy and the original pairing file after pairing. Keep the helper configuration private. It holds both the pairing key and the independent relay capability.

3. In the helper configuration, fill in `accountRoute` and `deviceID` from the device pairing receipt. Add a `credentials` entry for each permitted mapping:

   ```json
   {
     "name": "backup-controller-read-only",
     "origin": "https://192.168.1.23",
     "serviceID": "backup-controller",
     "declarationDigest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
     "file": "/path/to/operator-owned/read-only.token"
   }
   ```

   In the iPad’s custom connection editor, enter the exact HTTPS server and expand **Details for helper setup**. Copy **Connection ID**, **Declaration SHA-256**, and **Server** into `serviceID`, `declarationDigest`, and `origin`. The iPad derives the digest from the installed declaration. The operator chooses a name for the source, and uses that exact name when asking the agent to request the handoff. The server value is a canonical origin, without an endpoint path or trailing slash. Each name is unique within the pair, starts with a lowercase letter, and is 2 to 48 characters using lowercase letters, digits and hyphens. A changed server or declaration requires an explicit mapping update. The local path must be absolute and point to a regular non-symlink file owned by the helper user, with no group or other access. The file contains only the bearer, optionally followed by one line ending. Maintain configuration permissions when editing.

4. Start the helper:

   ```sh
   node tools/credential-handoff/helper.mjs run "$HOME/.config/screenpunk-handoff/helper.json"
   ```

   Keep it running under the host's normal service supervisor as the credential file owner. Restart it after local configuration changes. For a single polling cycle use `run CONFIG --once`. It contacts only the configured HTTPS Cloud relay and rejects redirects. Errors in the daemon are rate-limited and omit request bodies, credentials, and local paths.

## Author and accept a handoff

In an agent request, identify the configured credential by its name and ask the agent to deliver it for the named connection. After an authorized screen request has established an exact connection setup proposal, the assigned agent can call `request_credential_handoff` with that request ID, the declared alias and the configured credential name. The iPad authorizes a challenge for that scope, the helper encrypts the matching token, and the user can accept it in native Settings. Certificate trust and screen approval remain separate. Disconnect a helper from the iPad's native Settings to revoke its relay capability.

## Protocol v1

A pairing file contains UTF-8 JSON `{version:1,relayOrigin,pairID,pairKey,capabilityHash}`. The pair ID is canonical unpadded base64url encoding of 16 random bytes. The pair key and separate helper relay capability each use 32 random bytes. `capabilityHash` is lower-case hex SHA-256 of the raw capability bytes. The device registers the capability hash, and the relay compares it against a helper Authorization bearer containing the canonical base64url capability. The relay never receives the pair key.

The authenticated bytes are UTF-8 JSON serialization of the following array with compact separators and unescaped forward slashes. Scope strings are printable ASCII excluding double quotes and backslash. `expiresAt` is an integer Unix timestamp in milliseconds.

```
["screenpunk-credential-handoff-v1",1,accountRoute,relayOrigin,deliveryID,
 pairID,requestID,inputDigest,deviceID,screenID,operationID,alias,name,
 origin,serviceID,declarationDigest,expiresAt]
```

Derive two 32-byte keys with HKDF-SHA256, using the raw pair key as IKM, UTF-8 delivery ID as salt, and UTF-8 `screenpunk-credential-handoff-v1:challenge` or `screenpunk-credential-handoff-v1:envelope` as info. The challenge is HMAC-SHA256 of the authenticated bytes with the challenge key. The envelope uses AES-256-GCM with a fresh 12-byte random nonce, the authenticated bytes as AAD, and the bearer bytes as plaintext. Encode `nonce || ciphertext || 16-byte tag` as canonical unpadded base64url. A different account route, relay, device, proposal, field scope, or delivery expiration invalidates the corresponding message authentication.

The helper polls `GET /api/credential-handoff/{accountRoute}/{pairID}` for `{offers:[{scope,challenge}]}` and posts `{envelope}` to the same path with `/{deliveryID}` appended. It checks the challenge, fixed configuration scope and expiration before opening a local token file. An offer is usable for at most 15 minutes, subject to the original request deadline. The relay accepts one immutable envelope for a delivery. The app handles one-time acceptance and stores the accepted bearer in device-local Keychain.

Run the offline, synthetic helper tests with `node --test tools/credential-handoff/helper.test.mjs`.
