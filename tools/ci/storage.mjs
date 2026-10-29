import { mkdirSync, readFileSync, writeFileSync, rmSync, statfsSync, lstatSync, existsSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';

// Only the run-specific scratch root is disposable; no shared caches or Simulators.
const root = resolve(process.env.CI_SCRATCH_ROOT ?? '');
const runner = resolve(process.env.RUNNER_TEMP ?? '');
if (!process.env.CI_SCRATCH_ROOT || !process.env.RUNNER_TEMP || !root.startsWith(`${runner}/screenpunk-public-`)) throw Error('Use a run-owned root under RUNNER_TEMP/screenpunk-public-*.');
if (existsSync(root) && lstatSync(root).isSymbolicLink()) throw Error('Scratch root must not be a symlink.');
const owner = `${process.env.GITHUB_REPOSITORY}/${process.env.GITHUB_RUN_ID}/${process.env.GITHUB_RUN_ATTEMPT}/${process.env.GITHUB_JOB}`;
const manifestPath = join(root, 'ownership.json');
const free = () => { const s = statfsSync(runner); return s.bavail * s.bsize; };
const directoryBytes = path => {
  if (!existsSync(path)) return 0;
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) return stat.size;
  return readdirSync(path).reduce((total, name) => total + directoryBytes(join(path, name)), 0);
};
const save = value => writeFileSync(manifestPath, `${JSON.stringify(value, null, 2)}\n`);
if (process.argv[2] === 'init') {
  const portable = process.argv[3] === '--portable';
  if (process.argv.length > (portable ? 4 : 3)) throw Error('Expected init or init --portable.');
  if (portable && process.platform !== 'linux') throw Error('The portable profile is only for lightweight Linux contract checks.');
  const profile = portable ? 'portable-contract-checks' : 'apple-build';
  const minimumFreeBytes = (portable ? 1 : 50) * 1024 ** 3;
  const budgetBytes = portable ? 512 * 1024 ** 2 : 20 * 1024 ** 3;
  if (existsSync(manifestPath)) throw Error('Run root already initialized; inspect its owner before reuse.');
  mkdirSync(join(root, 'evidence'), { recursive: true });
  const availableBytes = free();
  save({ owner, project: 'screenpunk-app', purpose: portable ? 'lightweight contract/setup generation, tests and artifact packing; no builds' : 'public unsigned Apple CI', profile, minimumFreeBytes, dependencyInstall: portable ? join(resolve(process.env.GITHUB_WORKSPACE ?? process.cwd()), 'node_modules') : null, created: new Date().toISOString(), lifecycle: 'active', budgetBytes, availableBytesBefore: availableBytes, resources: ['build'], keep: ['evidence', 'ownership.json'], simulators: [] });
  console.log(`Available bytes before CI: ${availableBytes}`);
  if (availableBytes < minimumFreeBytes) throw Error(portable ? 'Below 1 GiB: insufficient space for bounded portable checks.' : 'Below 50 GiB: inspect completed owned outputs before a build/install. No shared cleanup is permitted.');
} else if (process.argv[2] === 'budget') {
  const manifest = JSON.parse(readFileSync(manifestPath));
  if (manifest.owner !== owner || manifest.project !== 'screenpunk-app' || manifest.profile !== 'portable-contract-checks') throw Error('Expected owned portable contract-check manifest.');
  const measuredBytes = directoryBytes(root) + directoryBytes(manifest.dependencyInstall);
  save({ ...manifest, measuredBytes, budgetCheckedAt: new Date().toISOString() });
  console.log(`Portable scratch plus dependency install: ${measuredBytes} bytes / ${manifest.budgetBytes} budget`);
  if (measuredBytes > manifest.budgetBytes) throw Error('Portable check exceeded its 512 MiB budget; review scope before allocating more.');
} else if (process.argv[2] === 'cleanup') {
  if (!existsSync(manifestPath)) process.exit(0);
  const manifest = JSON.parse(readFileSync(manifestPath));
  if (manifest.owner !== owner || manifest.project !== 'screenpunk-app') throw Error('Scratch ownership mismatch.');
  const availableBytesBeforeCleanup = free();
  rmSync(join(root, 'build'), { recursive: true, force: true });
  const availableBytesAfter = free();
  save({ ...manifest, lifecycle: 'completed', resources: [], removed: [join(root, 'build')], availableBytesBeforeCleanup, availableBytesAfter, recoveredBytes: availableBytesAfter - availableBytesBeforeCleanup });
  console.log(`Available bytes after cleanup: ${availableBytesAfter}; observed recovery: ${availableBytesAfter - availableBytesBeforeCleanup}`);
} else throw Error('Expected init, budget or cleanup.');
