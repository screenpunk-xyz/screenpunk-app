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
  const hosted = process.argv[3] === '--hosted-apple';
  if (process.argv.length !== (portable || hosted ? 4 : 3)) throw Error('Unknown storage profile.');
  if (hosted && (process.platform !== 'darwin' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted')) throw Error('Disposable GitHub-hosted Mac required.');
  if (portable && process.platform !== 'linux') throw Error('The portable profile is only for lightweight Linux contract checks.');
  const profile = portable ? 'portable-contract-checks' : hosted ? 'hosted-apple' : 'apple-build';
  const minimumFreeBytes = (portable ? 1 : hosted ? 28 : 50) * 1024 ** 3;
  const budgetBytes = portable ? 512 * 1024 ** 2 : (hosted ? 8 : 20) * 1024 ** 3;
  if (existsSync(manifestPath)) throw Error('Run root already initialized; inspect its owner before reuse.');
  mkdirSync(join(root, 'evidence'), { recursive: true });
  const availableBytes = free();
  save({ owner, project: 'screenpunk-app', purpose: portable ? 'lightweight contract/setup generation, tests and artifact packing; no builds' : 'public unsigned Apple CI', profile, minimumFreeBytes, dependencyInstall: portable ? join(resolve(process.env.GITHUB_WORKSPACE ?? process.cwd()), 'node_modules') : null, created: new Date().toISOString(), lifecycle: 'active', budgetBytes, availableBytesBefore: availableBytes, resources: ['build'], keep: ['evidence', 'ownership.json'], simulators: [] });
  console.log(`Available bytes before CI: ${availableBytes}`);
  if (availableBytes < minimumFreeBytes) throw Error(portable ? 'Below 1 GiB: insufficient space for bounded portable checks.' : hosted ? 'Need 28 GiB for an 8 GiB hosted job and 20 GiB reserve.' : 'Below 50 GiB: inspect completed owned outputs before a build/install. No shared cleanup is permitted.');
} else if (process.argv[2] === 'run') {
  const manifest = JSON.parse(readFileSync(manifestPath));
  if (manifest.owner !== owner || manifest.profile !== 'hosted-apple') throw Error('Expected owned hosted Apple job.');
  const floor = Math.max(20 * 1024 ** 3, manifest.availableBytesBefore - manifest.budgetBytes);
  const checkSpace = () => {
    const available = free();
    if (available > floor + 256 * 1024 ** 2) return true;
    console.error(`Stopping hosted job before the disk limit: ${available} bytes available, floor ${floor}.`);
    return false;
  };
  if (!checkSpace()) process.exit(1);
  const { spawn } = await import('node:child_process');
  const child = spawn(process.argv[3], process.argv.slice(4), { stdio: 'inherit', detached: true });
  let exceeded = false;
  const monitor = setInterval(() => {
    if (checkSpace()) return;
    exceeded = true;
    process.kill(-child.pid, 'SIGKILL');
    clearInterval(monitor);
  }, 500);
  child.on('exit', code => {
    clearInterval(monitor);
    process.exitCode = exceeded || !checkSpace() ? 1 : (code ?? 1);
  });
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
