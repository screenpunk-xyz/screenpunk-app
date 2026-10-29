import { mkdirSync, readFileSync, writeFileSync, rmSync, statfsSync, lstatSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';

// Only the run-specific scratch root is disposable; no shared caches or Simulators.
const root = resolve(process.env.CI_SCRATCH_ROOT ?? '');
const runner = resolve(process.env.RUNNER_TEMP ?? '');
if (!process.env.CI_SCRATCH_ROOT || !process.env.RUNNER_TEMP || !root.startsWith(`${runner}/screenpunk-public-`)) throw Error('Use a run-owned root under RUNNER_TEMP/screenpunk-public-*.');
if (existsSync(root) && lstatSync(root).isSymbolicLink()) throw Error('Scratch root must not be a symlink.');
const owner = `${process.env.GITHUB_REPOSITORY}/${process.env.GITHUB_RUN_ID}/${process.env.GITHUB_RUN_ATTEMPT}/${process.env.GITHUB_JOB}`;
const manifestPath = join(root, 'ownership.json');
const free = () => { const s = statfsSync(runner); return s.bavail * s.bsize; };
const save = value => writeFileSync(manifestPath, `${JSON.stringify(value, null, 2)}\n`);
if (process.argv[2] === 'init') {
  if (existsSync(manifestPath)) throw Error('Run root already initialized; inspect its owner before reuse.');
  mkdirSync(join(root, 'evidence'), { recursive: true });
  const availableBytes = free();
  save({ owner, project: 'screenpunk-app', purpose: 'public unsigned CI', created: new Date().toISOString(), lifecycle: 'active', budgetBytes: 20 * 1024 ** 3, availableBytesBefore: availableBytes, resources: ['build'], keep: ['evidence', 'ownership.json'], simulators: [] });
  console.log(`Available bytes before CI: ${availableBytes}`);
  if (availableBytes < 50 * 1024 ** 3) throw Error('Below 50 GiB: inspect completed owned outputs before a build/install. No shared cleanup is permitted.');
} else if (process.argv[2] === 'cleanup') {
  if (!existsSync(manifestPath)) process.exit(0);
  const manifest = JSON.parse(readFileSync(manifestPath));
  if (manifest.owner !== owner || manifest.project !== 'screenpunk-app') throw Error('Scratch ownership mismatch.');
  const availableBytesBeforeCleanup = free();
  rmSync(join(root, 'build'), { recursive: true, force: true });
  const availableBytesAfter = free();
  save({ ...manifest, lifecycle: 'completed', resources: [], removed: [join(root, 'build')], availableBytesBeforeCleanup, availableBytesAfter, recoveredBytes: availableBytesAfter - availableBytesBeforeCleanup });
  console.log(`Available bytes after cleanup: ${availableBytesAfter}; observed recovery: ${availableBytesAfter - availableBytesBeforeCleanup}`);
} else throw Error('Expected init or cleanup.');
