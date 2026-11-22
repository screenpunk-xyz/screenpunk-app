import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createDecipheriv, createHash, createHmac, hkdfSync } from 'node:crypto';
import { chmod, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { processOffers, validateConfig } from './helper.mjs';

const expiresAt = 1900000000000;
const scope = {
  version: 1,
  accountRoute: 'a'.repeat(64),
  relayOrigin: 'https://relay.example',
  deliveryID: 'adc3e749-26fc-456d-96fa-8947d1f84330',
  pairID: Buffer.alloc(16, 0x04).toString('base64url'),
  requestID: 'request-1',
  inputDigest: 'b'.repeat(64),
  deviceID: 'ipad-1',
  screenID: 'screen-1',
  operationID: 'operation-1',
  alias: 'backup',
  name: 'backup-controller-read-only',
  origin: 'https://192.168.1.23:8443',
  serviceID: 'backup-controller',
  declarationDigest: 'c'.repeat(64),
  expiresAt,
};
const token = 'synthetic-bearer-only';
const pairKey = Buffer.alloc(32, 0x12);
const capability = Buffer.alloc(32, 0x23).toString('base64url');

function authenticate(s) {
  const plaintext = JSON.stringify(['screenpunk-credential-handoff-v1', 1, s.accountRoute, s.relayOrigin,
    s.deliveryID, s.pairID, s.requestID, s.inputDigest, s.deviceID, s.screenID, s.operationID, s.alias, s.name,
    s.origin, s.serviceID, s.declarationDigest, s.expiresAt]);
  const derive = (purpose) => hkdfSync('sha256', pairKey, Buffer.from(s.deliveryID),
    Buffer.from('screenpunk-credential-handoff-v1:' + purpose), 32);
  const challenge = createHmac('sha256', derive('challenge')).update(plaintext).digest('base64url');
  return {
    challenge,
    decrypt(envelope) {
      const body = Buffer.from(envelope, 'base64url');
      const decipher = createDecipheriv('aes-256-gcm', derive('envelope'), body.subarray(0, 12));
      decipher.setAAD(Buffer.from(plaintext));
      decipher.setAuthTag(body.subarray(-16));
      return Buffer.concat([decipher.update(body.subarray(12, -16)), decipher.final()]).toString();
    },
  };
}

async function fixture(t) {
  const dir = await mkdtemp(join(tmpdir(), 'screenpunk-helper-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'bearer');
  await writeFile(file, token + '\n', { mode: 0o600 });
  const { version, relayOrigin, accountRoute, deviceID, pairID, name, origin, serviceID, declarationDigest } = scope;
  return { dir, file, config: {
    version, relayOrigin, accountRoute, deviceID, pairID, pairKey: pairKey.toString('base64url'), capability,
    credentials: [{ name, origin, serviceID, declarationDigest, file }],
  } };
}

function relay(offers, postStatus = 204) {
  const calls = [];
  return { calls, fetch: async (url, request) => {
    calls.push([url, request]);
    return request.method === 'POST' ? new Response(null, { status: postStatus }) : Response.json({ offers });
  } };
}

test('accepts only the authenticated and allowlisted scope, sends an authenticated encrypted bearer', async (t) => {
  const { config } = await fixture(t);
  const authentication = authenticate(scope);
  const changedOrigin = { ...scope, origin: 'https://elsewhere.example' };
  const changedService = { ...scope, serviceID: 'other-controller' };
  const changedRevision = { ...scope, declarationDigest: 'd'.repeat(64) };
  const expired = { ...scope, expiresAt: expiresAt - 1000 };
  const anotherAccount = { ...scope, accountRoute: 'f'.repeat(64) };
  const anotherDevice = { ...scope, deviceID: 'ipad-2' };
  const relaySubstitution = { ...scope, relayOrigin: 'https://impostor.example' };
  const changedRequest = { ...scope, requestID: 'forged' };
  const r = relay([
    ...[changedOrigin, changedService, changedRevision, expired, anotherAccount, anotherDevice, relaySubstitution]
      .map((altered) => ({ scope: altered, challenge: authenticate(altered).challenge })),
    { scope: changedRequest, challenge: authentication.challenge },
    { scope, challenge: authentication.challenge + '=' },
    { scope, challenge: authentication.challenge },
    { scope, challenge: authentication.challenge },
  ]);
  assert.deepEqual(await processOffers(config, r.fetch, () => expiresAt - 1000), { delivered: 1, failed: 0 });
  const [poll, deliver] = r.calls;
  assert.equal(r.calls.length, 2);
  const path = `${scope.relayOrigin}/api/credential-handoff/${scope.accountRoute}/${scope.pairID}`;
  assert.equal(poll[0], path);
  assert.equal(deliver[0], path + '/' + scope.deliveryID);
  assert.equal(deliver[1].headers.authorization, 'Bearer ' + capability);
  assert.equal(poll[1].redirect, 'error');
  assert.equal(deliver[1].redirect, 'error');
  assert.equal(deliver[1].body.includes(token), false);
  const { envelope } = JSON.parse(deliver[1].body);
  assert.equal(authentication.decrypt(envelope), token);
  assert.throws(() => authenticate(changedOrigin).decrypt(envelope));
});

test('fails closed for insecure files and leaves plaintext inside the allowlisted helper', async (t) => {
  const { config, dir, file } = await fixture(t);
  const offer = { scope, challenge: authenticate(scope).challenge };
  const linked = join(dir, 'linked');
  await symlink(file, linked);
  config.credentials[0].file = linked;
  const r = relay([offer]);
  assert.deepEqual(await processOffers(config, r.fetch, () => expiresAt - 1), { delivered: 0, failed: 1 });
  await chmod(file, 0o644);
  config.credentials[0].file = file;
  assert.deepEqual(await processOffers(config, r.fetch, () => expiresAt - 1), { delivered: 0, failed: 1 });
  assert.equal(r.calls.every(([, request]) => !request.body), true);
  await chmod(file, 0o600);
  await writeFile(file, token + '\n\n');
  assert.deepEqual(await processOffers(config, r.fetch, () => expiresAt - 1), { delivered: 0, failed: 1 });
  assert.equal(r.calls.every(([, request]) => !request.body), true);
});

test('rejects duplicate names and ignores a finished relay offer', async (t) => {
  const { config } = await fixture(t);
  assert.throws(() => validateConfig({ ...config, credentials: [...config.credentials, ...config.credentials] }));
  assert.throws(() => validateConfig({ ...config, relayOrigin: 'http://relay.example' }));
  assert.throws(() => validateConfig({ ...config, capability: config.pairKey }));
  const r = relay([{ scope, challenge: authenticate(scope).challenge }], 409);
  assert.deepEqual(await processOffers(config, r.fetch, () => expiresAt - 1), { delivered: 0, failed: 0 });
});

test('authenticated scope reference vector', () => {
  assert.equal(authenticate(scope).challenge, 'C8VyS1cyvPjeqItWxM1xD98kQXqAMWAL4c4o78WsHI8');
});

test('generates a private import file and a separate helper capability', async (t) => {
  const { dir } = await fixture(t);
  const tool = fileURLToPath(new URL('./helper.mjs', import.meta.url));
  const configFile = join(dir, 'helper.json');
  const pairingFile = join(dir, 'device.screenpunk-pair');
  const output = execFileSync(process.execPath, [tool, 'init', scope.relayOrigin, configFile, pairingFile],
    { encoding: 'utf8' });
  const config = JSON.parse(await readFile(configFile, 'utf8'));
  const pair = JSON.parse(await readFile(pairingFile, 'utf8'));
  assert.equal((await stat(configFile)).mode & 0o777, 0o600);
  assert.equal((await stat(pairingFile)).mode & 0o777, 0o600);
  assert.equal(pair.pairID, config.pairID);
  assert.equal(pair.pairKey, config.pairKey);
  assert.equal(pair.capabilityHash, createHash('sha256').update(Buffer.from(config.capability, 'base64url')).digest('hex'));
  assert.equal(pair.capability, undefined);
  assert.notEqual(config.capability, config.pairKey);
  assert.equal(output.includes(config.capability) || output.includes(config.pairKey), false);
});
