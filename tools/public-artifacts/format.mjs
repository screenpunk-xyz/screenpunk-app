// SPDX-License-Identifier: Apache-2.0
// This verifier is also copied into the private build tools; it has no runtime/network dependencies.
import { createHash } from 'node:crypto';

export const FORMAT = 'screenpunk-public-artifacts-v1';
export const LOCK_FORMAT = 'screenpunk-public-artifacts-lock-v1';
export const SOURCE_REPOSITORY = 'screenpunk-xyz/screenpunk-app';
export const MAX_BUNDLE_BYTES = 16 * 1024 * 1024;
export const MAX_FILE_BYTES = 4 * 1024 * 1024;
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw Error(message); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function exactKeys(value, keys, name) {
  if (!object(value) || Object.keys(value).sort().join('\0') !== [...keys].sort().join('\0')) fail(`Invalid ${name} fields`);
}
function digest(value, name) { if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) fail(`Invalid ${name}`); }
export function safePath(value) {
  if (typeof value !== 'string' || value.length > 180 || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value) || value.split('/').some(part => !part || part === '.' || part === '..')) fail('Unsafe artifact path');
  const allowed = value === 'LICENSE' || value === 'packages/contracts/README.md' || value === 'packages/contracts/LICENSE' || value === 'packages/contracts/package.json' || /^packages\/contracts\/(authoring|authoring-v2)\.ts$/.test(value) || /^packages\/contracts\/(definitions|fixtures|generated)\/[A-Za-z0-9][A-Za-z0-9._-]*\.(json|ts)$/.test(value) || value === 'tools/local-agent-setup/generated/local-agent-setup.ts';
  if (!allowed) fail(`Unexpected artifact path: ${value}`);
  return value;
}
export function sourceSnapshot(files) {
  return sha256(JSON.stringify(files.map(({path, sha256, size}) => ({path, sha256, size}))));
}
export function validateIdentity(value, lock = false) {
  const common = ['format','version','sourceRepository','sourceRevision','provenance','sourceSnapshotSHA256','setupVersion','setupSHA256'];
  exactKeys(value, lock ? [...common,'sha256','url'] : [...common,'contractVersions','files'], lock ? 'lock' : 'bundle');
  if (value.format !== (lock ? LOCK_FORMAT : FORMAT)) fail('Unsupported artifact format');
  if (typeof value.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(value.version)) fail('Invalid artifact version');
  if (value.sourceRepository !== SOURCE_REPOSITORY) fail('Unexpected source repository');
  if (value.provenance === 'published') {
    if (typeof value.sourceRevision !== 'string' || !/^[0-9a-f]{40}$/.test(value.sourceRevision) || /^0+$/.test(value.sourceRevision)) fail('Published artifacts require an exact source commit');
  } else if (value.provenance !== 'local-provisional' || value.sourceRevision !== null) fail('Invalid artifact provenance');
  digest(value.sourceSnapshotSHA256, 'source snapshot SHA256');
  digest(value.setupSHA256, 'setup SHA256');
  if (value.setupVersion !== '6') fail('Unsupported setup version');
  if (lock) {
    digest(value.sha256, 'bundle SHA256');
    const url = `https://github.com/${SOURCE_REPOSITORY}/releases/download/v${value.version}/screenpunk-public-artifacts-${value.version}.json`;
    if (value.url !== (value.provenance === 'published' ? url : null)) fail('Artifact URL must name the exact versioned GitHub release asset');
  } else if (JSON.stringify(value.contractVersions) !== '["1","2"]') fail('Unsupported contract version set');
  return value;
}
export function validateLock(value, { requirePublished = false } = {}) {
  validateIdentity(value, true);
  if (requirePublished && value.provenance !== 'published') fail('Deployment requires a published artifact pinned to a real public source commit; local provisional artifacts cannot deploy');
  return value;
}
export function lockFor(bundle, bytes) {
  const {version, sourceRepository, sourceRevision, provenance, sourceSnapshotSHA256, setupVersion, setupSHA256} = bundle;
  return validateLock({format: LOCK_FORMAT, version, sourceRepository, sourceRevision, provenance, sourceSnapshotSHA256, setupVersion, setupSHA256, sha256: sha256(bytes), url: provenance === 'published' ? `https://github.com/${sourceRepository}/releases/download/v${version}/screenpunk-public-artifacts-${version}.json` : null});
}
export function verifyBundle(bytes, lock, options = {}) {
  validateLock(lock, options);
  if (bytes.length > MAX_BUNDLE_BYTES || bytes.length === 0) fail('Artifact bundle size exceeds limit');
  if (sha256(bytes) !== lock.sha256) fail('Artifact bundle SHA256 mismatch');
  const bundle = JSON.parse(bytes.toString('utf8'));
  validateIdentity(bundle);
  for (const key of ['version','sourceRepository','sourceRevision','provenance','sourceSnapshotSHA256','setupVersion','setupSHA256']) if (bundle[key] !== lock[key]) fail(`Artifact ${key} does not match lock`);
  if (!Array.isArray(bundle.files) || bundle.files.length < 10 || bundle.files.length > 100) fail('Invalid artifact file count');
  let previous = ''; let total = 0;
  const files = new Map(), foldedPaths = new Set();
  for (const file of bundle.files) {
    exactKeys(file, ['path','size','sha256','contentBase64'], 'file');
    safePath(file.path);
    if (foldedPaths.has(file.path.toLowerCase())) fail('Artifact paths collide on case-insensitive filesystems');
    foldedPaths.add(file.path.toLowerCase());
    if (file.path <= previous) fail('Artifact files must be unique and sorted');
    previous = file.path;
    digest(file.sha256, 'file SHA256');
    if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > MAX_FILE_BYTES) fail('Invalid artifact file size');
    if (typeof file.contentBase64 !== 'string' || file.contentBase64.length > Math.ceil(MAX_FILE_BYTES / 3) * 4) fail('Invalid artifact encoding');
    const content = Buffer.from(file.contentBase64, 'base64');
    if (content.toString('base64') !== file.contentBase64 || content.length !== file.size || sha256(content) !== file.sha256) fail(`Artifact file integrity mismatch: ${file.path}`);
    total += content.length; if (total > MAX_BUNDLE_BYTES) fail('Expanded artifact exceeds limit');
    files.set(file.path, content);
  }
  for (const path of ['LICENSE','packages/contracts/LICENSE','packages/contracts/package.json','packages/contracts/README.md','packages/contracts/authoring.ts','packages/contracts/authoring-v2.ts','packages/contracts/generated/authoring-definition.ts','packages/contracts/generated/authoring-v2-definition.ts','packages/contracts/definitions/authoring-v1.json','packages/contracts/definitions/authoring-v2.json','packages/contracts/fixtures/conformance-v1.json','packages/contracts/fixtures/conformance-v2.json','tools/local-agent-setup/generated/local-agent-setup.ts']) if (!files.has(path)) fail(`Required artifact file missing: ${path}`);
  if (sourceSnapshot(bundle.files) !== bundle.sourceSnapshotSHA256) fail('Artifact source snapshot mismatch');
  const setup = files.get('tools/local-agent-setup/generated/local-agent-setup.ts').toString('utf8');
  for (const [name, expected] of [['Version',bundle.setupVersion],['SHA256',bundle.setupSHA256]]) {
    const match = setup.match(new RegExp(`^export const localAgentSetup${name} = ("[^"\\n]*");$`, 'm'));
    if (!match || JSON.parse(match[1]) !== expected) fail('Setup identity mismatch');
  }
  const script = setup.match(/^export const localAgentSetupScript = (".*");$/m);
  if (!script || sha256(JSON.parse(script[1])) !== bundle.setupSHA256) fail('Setup script SHA256 mismatch');
  const pkg = JSON.parse(files.get('packages/contracts/package.json'));
  if (pkg.version !== bundle.version || pkg.license !== 'Apache-2.0') fail('Contract package identity mismatch');
  return {bundle, files};
}
