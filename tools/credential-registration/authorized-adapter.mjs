// Fixture-only example. The operator supplies this source configuration independently of agent inputs.
import { checkServerIdentity } from 'node:tls';
import { request } from 'node:https';

const fingerprintPattern = /^[a-f0-9]{64}$/u;
const validFingerprint = (value) => typeof value === 'string' && fingerprintPattern.test(value);
const registrationIDPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/u;
const scopeFields = ['accountRoute', 'relayOrigin', 'deviceID', 'screenID', 'alias', 'serviceID', 'declarationDigest', 'operationID', 'origin', 'expiresAt'];

function checkedRegistration(config, scope) {
  const base = new URL(config.origin);
  const relay = new URL(config.relayOrigin);
  if (relay.protocol !== 'https:' || relay.origin !== config.relayOrigin || !validFingerprint(config.accountRoute) ||
      typeof config.deviceID !== 'string' || !config.deviceID || config.relayOrigin !== scope?.relayOrigin ||
      config.accountRoute !== scope.accountRoute || config.deviceID !== scope.deviceID ||
      base.protocol !== 'https:' || base.origin !== config.origin || config.origin !== scope?.origin ||
      scope.version !== 1 || !registrationIDPattern.test(scope.registrationID ?? '') ||
      !validFingerprint(config.leafCertificateSHA256) || !config.serviceID || !config.declarationDigest ||
      scope.serviceID !== config.serviceID || scope.declarationDigest !== config.declarationDigest || scope.readPath !== config.readPath ||
      config.readPath !== '/api/screenpunk/status') {
    throw new Error('No authorized source matches this registration.');
  }
  const binding = Object.fromEntries(scopeFields.map((field) => [field, scope[field]]));
  return {
    binding: { ...binding, readPath: config.readPath },
    endpoint: new URL('/api/credential-registrations/' + scope.registrationID, base),
  };
}

function verifiedRequest(config, endpoint, method, body) {
  const payload = body === undefined ? null : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = request(endpoint, {
      method, ca: config.ca, agent: false, rejectUnauthorized: true,
      checkServerIdentity(host, tls) {
        return checkServerIdentity(host, tls) ??
          (tls.fingerprint256?.replaceAll(':', '').toLowerCase() === config.leafCertificateSHA256 ? undefined
            : new Error('Source certificate differs from the independently verified leaf.'));
      },
      headers: {
        authorization: 'Bearer ' + config.adminToken,
        accept: 'application/json',
        ...(payload && { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }),
      },
      signal: AbortSignal.timeout(8000),
    }, (res) => {
      const chunks = [];
      let length = 0;
      res.on('data', (chunk) => {
        length += chunk.length;
        if (length > 4096) res.destroy(new Error('Oversized source response.'));
        else chunks.push(chunk);
      });
      res.once('end', () => {
        try { resolve({ status: res.statusCode, value: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
        catch (error) { reject(error); }
      });
      res.once('error', reject);
    });
    req.once('error', reject);
    req.end(payload);
  });
}

function matchesBinding(config, registrationID, binding, receipt) {
  return receipt?.registrationID === registrationID && receipt.leafCertificateSHA256 === config.leafCertificateSHA256 &&
    Object.entries(binding).every(([key, value]) => receipt[key] === value);
}

export async function registerSourceCredential(config, scope, verifier, now = Date.now()) {
  const { binding, endpoint } = checkedRegistration(config, scope);
  if (!validFingerprint(verifier) || !Number.isSafeInteger(scope.expiresAt) || scope.expiresAt <= now) {
    throw new Error('Invalid or expired credential registration.');
  }
  const installed = await verifiedRequest(config, endpoint, 'PUT', { ...binding, verifier });
  if (installed.status !== 200 && installed.status !== 201) throw new Error('Source rejected registration.');
  const readback = await verifiedRequest(config, endpoint, 'GET');
  if (readback.status !== 200 || readback.value.status !== 'installed' ||
      readback.value.verifier !== verifier || !matchesBinding(config, scope.registrationID, binding, readback.value)) {
    throw new Error('Source registration could not be verified.');
  }
  return {
    status: 'registered', origin: binding.origin, fingerprint: readback.value.leafCertificateSHA256,
    verifier_readback: readback.value.verifier,
  };
}

export async function revokeSourceCredential(config, scope) {
  const { binding, endpoint } = checkedRegistration(config, scope);
  const matches = (value) => matchesBinding(config, scope.registrationID, binding, value);
  const selected = await verifiedRequest(config, endpoint, 'GET');
  if (selected.status !== 404 && (selected.status !== 200 || !matches(selected.value))) {
    throw new Error('Source removal scope differs.');
  }
  const removed = await verifiedRequest(config, endpoint, 'DELETE', binding);
  if (removed.status !== 200 || removed.value.status !== 'revoked' || !matches(removed.value)) {
    throw new Error('Source revocation failed.');
  }
  const readback = await verifiedRequest(config, endpoint, 'GET');
  if (readback.status === 200 && readback.value.status === 'revoked' &&
      matches(readback.value) && !Object.hasOwn(readback.value, 'verifier')) {
    return { status: 'removed', origin: binding.origin, tombstone_verified: true };
  }
  throw new Error('Source revocation could not be verified.');
}
