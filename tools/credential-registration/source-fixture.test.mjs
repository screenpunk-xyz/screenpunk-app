import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID, X509Certificate } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { request } from 'node:https';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { checkServerIdentity } from 'node:tls';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { registerSourceCredential, revokeSourceCredential } from './authorized-adapter.mjs';
import { createRegistrationFixture } from './source-fixture.mjs';

const readPath = '/api/screenpunk/status';
const adminToken = randomBytes(32).toString('base64url');
const bearer = () => randomBytes(32).toString('base64url');
const verifierFor = (token) => createHash('sha256').update(token, 'utf8').digest('hex');
let ca, key, cert, origin, fixture, config, directory;

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'screenpunk-source-test-'));
  const reserve = createServer().listen(0, '127.0.0.1');
  await once(reserve, 'listening');
  const { port } = reserve.address();
  await new Promise((resolve, reject) => reserve.close((error) => error ? reject(error) : resolve()));
  origin = 'https://127.0.0.1:' + port;
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=Screenpunk synthetic root', '-keyout', join(directory, 'ca.key'), '-out', join(directory, 'ca.pem')], { stdio: 'ignore' });
  execFileSync('openssl', ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1',
    '-keyout', join(directory, 'leaf.key'), '-out', join(directory, 'leaf.csr')], { stdio: 'ignore' });
  execFileSync('openssl', ['x509', '-req', '-days', '1', '-in', join(directory, 'leaf.csr'),
    '-CA', join(directory, 'ca.pem'), '-CAkey', join(directory, 'ca.key'), '-set_serial', '1',
    '-extfile', '/dev/stdin', '-out', join(directory, 'leaf.pem')], {
    input: 'subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n',
    stdio: ['pipe', 'ignore', 'ignore'],
  });
  [ca, key, cert] = await Promise.all(['ca.pem', 'leaf.key', 'leaf.pem'].map((path) => readFile(join(directory, path))));
  fixture = createRegistrationFixture({ key, cert, adminToken, origin });
  fixture.server.listen(port, '127.0.0.1');
  await once(fixture.server, 'listening');
  config = { origin, ca, adminToken, relayOrigin: 'https://relay.example', accountRoute: 'a'.repeat(64), deviceID: 'ipad-1', serviceID: 'synthetic-source', declarationDigest: 'e'.repeat(64), readPath,
    leafCertificateSHA256: createHash('sha256').update(new X509Certificate(cert).raw).digest('hex') };
});

after(async () => {
  if (fixture) await new Promise((resolve) => fixture.server.close(resolve));
  if (directory) await rm(directory, { recursive: true, force: true });
});

function scope(id = randomUUID()) {
  return { version: 1, registrationID: id, accountRoute: config.accountRoute, relayOrigin: config.relayOrigin, deviceID: config.deviceID, screenID: 'screen-2', alias: 'source',
    serviceID: config.serviceID, declarationDigest: config.declarationDigest, operationID: 'operation-3',
    origin, readPath, expiresAt: Date.now() + 10_000 };
}

function scopeBinding({ accountRoute, relayOrigin, deviceID, screenID, alias, serviceID, declarationDigest, operationID, origin, readPath, expiresAt }) {
  return { accountRoute, relayOrigin, deviceID, screenID, alias, serviceID, declarationDigest, operationID, origin, readPath, expiresAt };
}

function call(path, { token, method = 'GET', body, host, certificateAuthority = ca } = {}) {
  const bytes = body === undefined ? null : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = request(origin + path, {
      ca: certificateAuthority, agent: false, method,
      ...(host && { checkServerIdentity: (_peer, cert) => checkServerIdentity('127.0.0.1', cert) }),
      headers: {
        ...(token && { Authorization: 'Bearer ' + token }),
        ...(host && { Host: host }),
        ...(bytes && { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bytes) }),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.once('end', () => resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString()) }));
      res.once('error', reject);
    });
    req.once('error', reject);
    req.end(bytes);
  });
}

test('reads nothing during install and requires actual distinct bearer on the fixed read-only route', async () => {
  const selected = scope();
  const token = bearer();
  const verifier = verifierFor(token);
  const adminPath = '/api/credential-registrations/' + selected.registrationID;
  const count = fixture.counts.authenticatedReads;
  assert.equal((await call(adminPath, { method: 'PUT', token, body: { ...scopeBinding(selected), verifier } })).status, 401);
  assert.deepEqual(await registerSourceCredential(config, selected, verifier), {
    status: 'registered', origin, fingerprint: config.leafCertificateSHA256, verifier_readback: verifier,
  });
  assert.equal(fixture.counts.authenticatedReads, count);
  for (const credential of [undefined, verifier, adminToken, bearer()]) {
    assert.equal((await call(readPath, { token: credential })).status, 401);
  }
  assert.equal((await call(readPath, { method: 'POST', token })).status, 405);
  assert.equal((await call(readPath + '?action=change', { token })).status, 404);
  assert.equal((await call(readPath, { token, host: 'unrelated.example' })).status, 421);
  assert.deepEqual(await call(readPath, { token }), { status: 200, body: { ok: true, value: 'synthetic' } });
});

test('uses authenticated HTTPS with independently verified exact certificate pin before any management request', async () => {
  const selected = scope();
  const verifier = verifierFor(bearer());
  const count = fixture.counts.installed;
  await assert.rejects(registerSourceCredential({ ...config, ca: undefined }, selected, verifier));
  await assert.rejects(registerSourceCredential({ ...config, leafCertificateSHA256: '1'.repeat(64) }, selected, verifier));
  await assert.rejects(registerSourceCredential(config, { ...selected, origin: 'https://other.example' }, verifier));
  await assert.rejects(registerSourceCredential(config, { ...selected, readPath: '/api/other' }, verifier));
  for (const substitute of [
    { relayOrigin: 'https://other-relay.example' },
    { accountRoute: 'd'.repeat(64) },
    { deviceID: 'unpaired-device' },
  ]) {
    await assert.rejects(registerSourceCredential(config, { ...selected, ...substitute }, verifier));
    await assert.rejects(revokeSourceCredential(config, { ...selected, ...substitute }));
  }
  assert.equal(fixture.counts.installed, count);
});

test('idempotent registration and source readback reject changed binding and duplicate verifier', async () => {
  const selected = scope();
  const token = bearer();
  const verifier = verifierFor(token);
  const count = fixture.counts.installed;
  assert.deepEqual(await registerSourceCredential(config, selected, verifier), await registerSourceCredential(config, selected, verifier));
  assert.equal(fixture.counts.installed, count + 1);
  await assert.rejects(registerSourceCredential(config, { ...selected, deviceID: 'other-device' }, verifier));
  await assert.rejects(registerSourceCredential(config, scope(), verifier));
  await assert.rejects(revokeSourceCredential(config, { ...selected, deviceID: 'other-device' }));
  assert.equal((await call(readPath, { token })).status, 200);
  assert.deepEqual(await revokeSourceCredential(config, selected), { status: 'removed', origin, tombstone_verified: true });
  assert.deepEqual(await revokeSourceCredential(config, selected), { status: 'removed', origin, tombstone_verified: true });
  assert.equal((await call(readPath, { token })).status, 401);
});

test('source tombstones prevent delayed installs even when removal comes first', async () => {
  const selected = scope();
  const token = bearer();
  const verifier = verifierFor(token);
  const count = fixture.counts.installed;
  assert.deepEqual(await revokeSourceCredential(config, selected), { status: 'removed', origin, tombstone_verified: true });
  await assert.rejects(registerSourceCredential(config, selected, verifier));
  assert.equal(fixture.counts.installed, count);
  assert.equal((await call(readPath, { token })).status, 401);
  const expired = { ...scope(), expiresAt: Date.now() - 1 };
  assert.equal((await call('/api/credential-registrations/' + expired.registrationID,
    { method: 'PUT', token: adminToken, body: { ...scopeBinding(expired), verifier } })).status, 410);
});
