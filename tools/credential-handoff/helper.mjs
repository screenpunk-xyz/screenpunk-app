import { createCipheriv, createHash, createHmac, hkdfSync, randomBytes, timingSafeEqual } from 'node:crypto';
import { constants } from 'node:fs';
import { open, writeFile } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

const protocol = 'screenpunk-credential-handoff-v1';
const scopeKeys = [
  'accountRoute', 'relayOrigin', 'deliveryID', 'pairID', 'requestID', 'inputDigest', 'deviceID',
  'screenID', 'operationID', 'alias', 'name', 'origin', 'serviceID', 'declarationDigest',
];
const maximumLifetime = 15 * 60_000;
const maxOffers = 16;
const maxResponse = 32 * 1024;
const ascii = (value) => typeof value === 'string' && /^[ -!#-\[\]-~]{1,512}$/.test(value);
const namePattern = /^[a-z][a-z0-9-]{1,47}$/u;
const hex = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const uuid = (value) => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(value);

function raw(value, length) {
  if (typeof value !== 'string' || value.length !== Math.ceil(4 * length / 3)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.length === length && bytes.toString('base64url') === value ? bytes : null;
}

function httpsOrigin(value) {
  try {
    const url = new URL(value);
    return ascii(value) && url.protocol === 'https:' && url.origin === value;
  } catch { return false; }
}

function fail() { throw new Error('Invalid helper configuration or relay response.'); }

export function validateConfig(config) {
  if (config?.version !== 1 || !httpsOrigin(config.relayOrigin) ||
      !raw(config.pairID, 16) || !raw(config.pairKey, 32) || !raw(config.capability, 32) ||
      config.pairKey === config.capability || !hex(config.accountRoute) || !ascii(config.deviceID) ||
      !Array.isArray(config.credentials) || config.credentials.length < 1 || config.credentials.length > 32) fail();
  for (const entry of config.credentials) {
    if (typeof entry?.name !== 'string' || !namePattern.test(entry.name) || !httpsOrigin(entry.origin) || !ascii(entry.serviceID) ||
        !hex(entry.declarationDigest) || typeof entry.file !== 'string' || !isAbsolute(entry.file)) fail();
  }
  if (new Set(config.credentials.map((entry) => entry.name)).size !== config.credentials.length) fail();
  return config;
}

function message(scope) {
  return Buffer.from(JSON.stringify([protocol, scope.version, ...scopeKeys.map((key) => scope[key]), scope.expiresAt]));
}

function derivedKey(key, deliveryID, purpose) {
  return hkdfSync('sha256', key, Buffer.from(deliveryID), Buffer.from(protocol + ':' + purpose), 32);
}

function matchesScope(scope, config, now) {
  return scope?.version === 1 && scopeKeys.every((key) => ascii(scope[key])) &&
    scope.pairID === config.pairID && scope.deviceID === config.deviceID &&
    scope.accountRoute === config.accountRoute && scope.relayOrigin === config.relayOrigin &&
    uuid(scope.deliveryID) && hex(scope.inputDigest) && hex(scope.declarationDigest) &&
    Number.isSafeInteger(scope.expiresAt) && scope.expiresAt > now && scope.expiresAt <= now + maximumLifetime;
}

function authenticOffer(offer, now, config) {
  if (!offer || !matchesScope(offer.scope, config, now)) return false;
  const challenge = raw(offer.challenge, 32);
  if (!challenge) return false;
  const key = raw(config.pairKey, 32);
  const expected = createHmac('sha256', derivedKey(key, offer.scope.deliveryID, 'challenge'))
    .update(message(offer.scope)).digest();
  return timingSafeEqual(challenge, expected);
}

function encrypt(scope, key, plaintext) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', derivedKey(key, scope.deliveryID, 'envelope'), iv);
  cipher.setAAD(message(scope));
  return Buffer.concat([iv, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]).toString('base64url');
}

async function readPrivate(file, limit) {
  // A nonblocking open prevents a local FIFO from stalling the helper before fstat.
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) ||
        stat.size < 1 || stat.size > limit) fail();
    const bytes = Buffer.alloc(limit + 1);
    const { bytesRead } = await handle.read(bytes);
    if (!bytesRead || bytesRead > limit || bytesRead !== stat.size) fail();
    return bytes.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

async function readToken(file) {
  const bytes = await readPrivate(file, 4098);
  let length = bytes.length;
  if (bytes[length - 1] === 10) {
    length--;
    if (bytes[length - 1] === 13) length--;
  }
  const punctuation = Buffer.from('._~+/=-', 'ascii');
  if (length < 1 || length > 4096 || !bytes.subarray(0, length).every((byte) =>
    (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || punctuation.includes(byte))) {
    bytes.fill(0);
    fail();
  }
  return bytes.subarray(0, length);
}

async function boundedJSON(response) {
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    fail();
  }
  const parts = [];
  let count = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > maxResponse) { await reader.cancel(); fail(); }
      parts.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return JSON.parse(Buffer.concat(parts).toString('utf8'));
}

export async function processOffers(config, fetchImpl = fetch, now = Date.now) {
  validateConfig(config);
  const path = config.relayOrigin + '/api/credential-handoff/' + config.accountRoute + '/' + config.pairID;
  const headers = { authorization: 'Bearer ' + config.capability, accept: 'application/json' };
  const request = { headers, redirect: 'error', cache: 'no-store', credentials: 'omit' };
  const response = await fetchImpl(path, { ...request, signal: AbortSignal.timeout(8000) });
  const payload = await boundedJSON(response);
  if (!Array.isArray(payload?.offers) || payload.offers.length > maxOffers) fail();
  let delivered = 0;
  let failed = 0;
  const seen = new Set();
  for (const offer of payload.offers) {
    if (!authenticOffer(offer, now(), config)) continue;
    const { scope } = offer;
    if (seen.has(scope.deliveryID)) continue;
    const entry = config.credentials.find(({ name, origin, serviceID, declarationDigest }) =>
      name === scope.name && origin === scope.origin && serviceID === scope.serviceID &&
      declarationDigest === scope.declarationDigest);
    if (!entry) continue;
    seen.add(scope.deliveryID);
    try {
      const token = await readToken(entry.file);
      let envelope;
      try {
        if (scope.expiresAt <= now()) continue;
        envelope = encrypt(scope, raw(config.pairKey, 32), token);
      } finally {
        token.fill(0);
      }
      const sent = await fetchImpl(path + '/' + scope.deliveryID, {
        ...request,
        headers: { ...headers, 'content-type': 'application/json' },
        method: 'POST',
        body: JSON.stringify({ envelope }),
        signal: AbortSignal.timeout(8000),
      });
      await sent.body?.cancel();
      if (sent.ok) delivered += 1;
      else if (sent.status !== 409 && sent.status !== 410) failed += 1;
    } catch { failed += 1; }
  }
  return { delivered, failed };
}

async function setup(relayOrigin, configFile, pairingFile, qr) {
  if (!httpsOrigin(relayOrigin) || !configFile || !pairingFile?.endsWith('.screenpunk-pair')) fail();
  const config = {
    version: 1, relayOrigin, pairID: randomBytes(16).toString('base64url'), pairKey: randomBytes(32).toString('base64url'),
    capability: randomBytes(32).toString('base64url'), accountRoute: '', deviceID: '', credentials: [],
  };
  const { version, pairID, pairKey, capability } = config;
  const capabilityHash = createHash('sha256').update(Buffer.from(capability, 'base64url')).digest('hex');
  const pairing = JSON.stringify({ version, relayOrigin, pairID, pairKey, capabilityHash });
  await writeFile(configFile, JSON.stringify(config, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  await writeFile(pairingFile, pairing + '\n', { flag: 'wx', mode: 0o600 });
  console.log('Private config and pairing file created.');
  if (qr && process.stdout.isTTY) {
    const result = spawnSync('qrencode', ['-t', 'ANSIUTF8', '-m', '2'], { input: pairing, stdio: ['pipe', 'inherit', 'ignore'] });
    if (result.status !== 0) console.error('QR unavailable. Import the pairing file instead.');
  } else if (qr) {
    console.error('The QR is only displayed in an interactive terminal. Import the pairing file instead.');
  }
}

async function run(file, once) {
  const config = validateConfig(JSON.parse((await readPrivate(file, 32 * 1024)).toString('utf8')));
  if (once) {
    const { delivered, failed } = await processOffers(config);
    console.log('Delivered ' + delivered + ' credential handoff(s).');
    if (failed) throw new Error('Delivery failed.');
    return;
  }
  let failures = 0;
  while (true) {
    try {
      const result = await processOffers(config);
      failures = result.failed ? Math.min(failures + 1, 5) : 0;
    } catch { failures = Math.min(failures + 1, 5); }
    if (failures === 1) console.error('Credential handoff polling failed. Retrying.');
    await delay(Math.min(60_000, 4_000 * 2 ** failures) + Math.floor(Math.random() * 500));
  }
}

async function main(args) {
  const [command, first, second, third, flag] = args;
  if (command === 'init' && (args.length === 4 || args.length === 5 && flag === '--qr')) {
    await setup(first, second, third, flag === '--qr');
  } else if (command === 'run' && (args.length === 2 || args.length === 3 && second === '--once')) {
    await run(first, second === '--once');
  } else {
    console.error('Usage: helper.mjs init HTTPS_ORIGIN CONFIG PAIR.screenpunk-pair [--qr] | run CONFIG [--once]');
    process.exitCode = 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(() => {
    console.error('Credential handoff failed. Check the private file permissions, helper configuration, and relay availability.');
    process.exitCode = 1;
  });
}
