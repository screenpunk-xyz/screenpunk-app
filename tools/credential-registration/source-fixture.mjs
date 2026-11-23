import { createHash, timingSafeEqual, X509Certificate } from 'node:crypto';
import { createServer } from 'node:https';
import { isIP } from 'node:net';
import { constants } from 'node:fs';
import { open, readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const readPath = '/api/screenpunk/status';
const registrationsPath = '/api/credential-registrations/';
const diagnosticsPath = '/api/credential-registration-diagnostics';
const registrationIDPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/u;
const digestPattern = /^[a-f0-9]{64}$/u;
const bindingFields = ['accountRoute', 'relayOrigin', 'deviceID', 'screenID', 'alias', 'serviceID', 'declarationDigest', 'operationID', 'origin', 'readPath', 'expiresAt'];
const installFields = [...bindingFields, 'verifier'];
const maximumRegistrations = 256;

function validToken(value) {
  return typeof value === 'string' && value.length === 43 &&
    Buffer.from(value, 'base64url').toString('base64url') === value;
}

function scopeString(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/u.test(value);
}

function digest(token) {
  return createHash('sha256').update(token, 'utf8').digest();
}

function authorizedDigest(req) {
  const authorization = req.headers.authorization;
  if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) return null;
  const token = authorization.slice(7);
  return validToken(token) ? digest(token) : null;
}

function safeEqual(left, right) {
  return timingSafeEqual(left, right);
}

function json(res, code, value) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(value));
}

function methodNotAllowed(res, allow) {
  res.setHeader('Allow', allow);
  json(res, 405, { error: 'method_not_allowed' });
}

async function readJSON(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') return null;
  const chunks = [];
  let size = 0;
  for await (const chunk of req.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > 4096) {
      req.resume();
      return null;
    }
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { return null; }
}

function canonicalHTTPS(origin) {
  try {
    const url = new URL(origin);
    return url.protocol === 'https:' && url.origin === origin;
  } catch { return false; }
}

function validBinding(body, origin, fields) {
  return body && Object.keys(body).length === fields.length && fields.every((field) => Object.hasOwn(body, field)) &&
    typeof body.accountRoute === 'string' && digestPattern.test(body.accountRoute) && canonicalHTTPS(body.relayOrigin) &&
    ['deviceID', 'screenID', 'alias', 'serviceID', 'operationID'].every((field) => scopeString(body[field])) &&
    typeof body.declarationDigest === 'string' && digestPattern.test(body.declarationDigest) &&
    Number.isSafeInteger(body.expiresAt) && body.expiresAt > 0 && body.origin === origin && body.readPath === readPath;
}

export function createRegistrationFixture({ key, cert, origin, adminToken, now = Date.now }) {
  const url = new URL(origin);
  if (url.protocol !== 'https:' || url.origin !== origin || !validToken(adminToken)) {
    throw new Error('Invalid synthetic fixture settings.');
  }
  const administratorVerifier = digest(adminToken);
  const leafCertificateSHA256 = createHash('sha256').update(new X509Certificate(cert).raw).digest('hex');
  const registrations = new Map();
  const counts = { installed: 0, revoked: 0, authenticatedReads: 0, rejectedReads: 0 };
  const dummyVerifier = Buffer.alloc(32);

  function receipt(registrationID, row) {
    const { verifier, ...binding } = row.binding;
    return {
      ...binding, registrationID, leafCertificateSHA256,
      ...(row.active ? { status: 'installed', verifier } : { status: 'revoked' }),
    };
  }

  async function route(req, res) {
    if (req.headers.host !== url.host) return json(res, 421, { error: 'wrong_origin' });
    if (req.url === readPath) {
      if (req.method !== 'GET') return methodNotAllowed(res, 'GET');
      const candidate = authorizedDigest(req);
      let accepted = false;
      for (const row of registrations.values()) {
        const equal = safeEqual(candidate ?? dummyVerifier, row.verifierBytes ?? dummyVerifier);
        if (candidate && equal && row.active) accepted = true;
      }
      if (!accepted) {
        counts.rejectedReads++;
        return json(res, 401, { error: 'authorization_required' });
      }
      counts.authenticatedReads++;
      return json(res, 200, { ok: true, value: 'synthetic' });
    }

    if (req.url !== diagnosticsPath && !req.url?.startsWith(registrationsPath)) {
      return json(res, 404, { error: 'not_found' });
    }
    const adminDigest = authorizedDigest(req);
    const isAdmin = safeEqual(adminDigest ?? dummyVerifier, administratorVerifier);
    if (!adminDigest || !isAdmin) return json(res, 401, { error: 'authorization_required' });
    if (req.url === diagnosticsPath) {
      return req.method === 'GET' ? json(res, 200, counts) : methodNotAllowed(res, 'GET');
    }

    const registrationID = req.url.slice(registrationsPath.length);
    if (!registrationIDPattern.test(registrationID)) return json(res, 404, { error: 'not_found' });
    const existing = registrations.get(registrationID);
    if (req.method === 'GET') {
      if (!existing) return json(res, 404, { error: 'not_found' });
      return json(res, 200, receipt(registrationID, existing));
    }
    if (req.method === 'DELETE') {
      const binding = await readJSON(req);
      if (!validBinding(binding, origin, bindingFields)) {
        return json(res, 400, { error: 'invalid_binding' });
      }
      const current = registrations.get(registrationID);
      if (current && bindingFields.some((field) => binding[field] !== current.binding[field])) {
        return json(res, 409, { error: 'registration_conflict' });
      }
      if (!current && registrations.size >= maximumRegistrations) {
        return json(res, 409, { error: 'registration_conflict' });
      }
      // Tombstone even an absent ID, so an in-flight install cannot follow a confirmed removal.
      const row = current ?? { active: false, binding };
      if (!current || current.active) {
        row.active = false;
        registrations.set(registrationID, row);
        counts.revoked++;
      }
      return json(res, 200, receipt(registrationID, row));
    }
    if (req.method !== 'PUT') return methodNotAllowed(res, 'PUT, GET, DELETE');

    const body = await readJSON(req);
    if (!validBinding(body, origin, installFields) || typeof body.verifier !== 'string' ||
        !digestPattern.test(body.verifier) || body.verifier === administratorVerifier.toString('hex')) {
      return json(res, 400, { error: 'invalid_registration' });
    }
    const current = registrations.get(registrationID);
    if (body.expiresAt <= now()) return json(res, 410, { error: 'registration_expired' });
    if (current) {
      if (!current.active || installFields.some((field) => body[field] !== current.binding[field])) {
        return json(res, 409, { error: 'registration_conflict' });
      }
      return json(res, 200, receipt(registrationID, current));
    }
    if (registrations.size >= maximumRegistrations ||
        [...registrations.values()].some(({ binding }) => binding.verifier === body.verifier)) {
      return json(res, 409, { error: 'registration_conflict' });
    }

    const row = { active: true, binding: body, verifierBytes: Buffer.from(body.verifier, 'hex') };
    registrations.set(registrationID, row);
    counts.installed++;
    return json(res, 201, receipt(registrationID, row));
  }

  const server = createServer({ key, cert, minVersion: 'TLSv1.2', requestTimeout: 5000, headersTimeout: 5000 }, (req, res) => {
    route(req, res).catch(() => {
      if (!res.headersSent) json(res, 500, { error: 'fixture_failure' });
      else res.end();
    });
  });
  return { server, counts };
}

async function readAdminToken(path) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o077) || info.size > 45) {
      throw new Error('Invalid synthetic admin file.');
    }
    const bytes = Buffer.alloc(46);
    const { bytesRead } = await file.read(bytes);
    try { return bytes.subarray(0, bytesRead).toString('utf8').replace(/\r?\n$/u, ''); }
    finally { bytes.fill(0); }
  } finally {
    await file.close();
  }
}

async function main() {
  const { values } = parseArgs({ options: {
    host: { type: 'string', default: '127.0.0.1' }, port: { type: 'string' },
    key: { type: 'string' }, cert: { type: 'string' }, 'admin-file': { type: 'string' },
  } });
  const { host, key, cert, 'admin-file': adminFile } = values;
  const port = Number(values.port);
  const privateIPv4 = /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/u;
  if (isIP(host) !== 4 || !privateIPv4.test(host) || !Number.isInteger(port) || port < 1024 || port > 65535 ||
      !key || !cert || !adminFile) {
    throw new Error('Invalid synthetic fixture settings.');
  }
  const origin = 'https://' + host + ':' + port;
  const [keyBytes, certBytes, adminToken] = await Promise.all([readFile(key), readFile(cert), readAdminToken(adminFile)]);
  const { server } = createRegistrationFixture({ key: keyBytes, cert: certBytes, origin, adminToken });
  keyBytes.fill(0);
  server.on('error', () => {
    console.error('Synthetic credential registration fixture could not listen.');
    process.exitCode = 1;
  });
  server.listen(port, host, () => console.log('Synthetic credential registration fixture listening at ' + origin));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    console.error('Synthetic credential registration fixture could not start. Check its bind address, files and TLS setup.');
    process.exitCode = 1;
  });
}
