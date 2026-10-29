// SPDX-License-Identifier: Apache-2.0
import { readFileSync, writeFileSync, readdirSync, lstatSync, existsSync } from 'node:fs';
import { resolve, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { FORMAT, SOURCE_REPOSITORY, safePath, sha256, sourceSnapshot, lockFor, verifyBundle } from './format.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
function option(name) { const i = args.indexOf(name); if (i < 0) return undefined; if (!args[i + 1] || args[i + 1].startsWith('--')) throw Error(`Missing ${name}`); return args[i + 1]; }
for (let i = 0; i < args.length; i++) { if (['--output','--source-revision'].includes(args[i])) i++; else if (args[i] !== '--provisional') throw Error(`Unknown option: ${args[i]}`); }
const output = option('--output');
if (!output) throw Error('Usage: node tools/public-artifacts/pack.mjs --output /path/bundle.json (--source-revision FULL_COMMIT | --provisional)');
const provisional = args.includes('--provisional'), revision = option('--source-revision');
if (provisional === !!revision) throw Error('Choose an exact committed source revision or explicit --provisional');
const paths = ['LICENSE','packages/contracts/LICENSE','packages/contracts/package.json','packages/contracts/README.md','packages/contracts/authoring.ts','packages/contracts/authoring-v2.ts','tools/local-agent-setup/generated/local-agent-setup.ts'];
for (const directory of ['definitions','fixtures','generated']) for (const file of readdirSync(resolve(root,'packages/contracts',directory))) paths.push(`packages/contracts/${directory}/${file}`);
paths.sort();
const files = paths.map(path => {
  safePath(path);
  const absolute = resolve(root,path);
  let directory = dirname(absolute);
  while (directory !== root) { if (lstatSync(directory).isSymbolicLink() || !lstatSync(directory).isDirectory()) throw Error(`Linked artifact source directory: ${directory}`); directory = dirname(directory); }
  if (!lstatSync(absolute).isFile() || lstatSync(absolute).isSymbolicLink()) throw Error(`Artifact source must be a regular file: ${path}`);
  const content = readFileSync(absolute);
  return {path, size: content.length, sha256: sha256(content), contentBase64: content.toString('base64')};
});
if (!provisional) {
  if (!/^[0-9a-f]{40}$/.test(revision)) throw Error('Use a full lowercase Git source commit');
  const git = (...args) => execFileSync('git', ['-C',root,...args], {encoding:'utf8'}).trim();
  if (git('rev-parse','HEAD') !== revision || git('rev-parse','--show-toplevel') !== root) throw Error('Artifact source revision must equal this public checkout HEAD');
  // Read the committed bytes rather than trusting working-tree cleanliness alone (including untracked inputs).
  for (const file of files) {
    const committed = execFileSync('git',['-C',root,'show',`${revision}:${file.path}`]);
    if (sha256(committed) !== file.sha256) throw Error(`Artifact input differs from committed source: ${file.path}`);
  }
  for (const file of ['tools/public-artifacts/pack.mjs','tools/public-artifacts/format.mjs','tools/local-agent-setup/generate.mjs']) {
    if (sha256(execFileSync('git',['-C',root,'show',`${revision}:${file}`])) !== sha256(readFileSync(resolve(root,file)))) throw Error(`Artifact tool differs from committed source: ${file}`);
  }
}
const setup = readFileSync(resolve(root,'tools/local-agent-setup/generated/local-agent-setup.ts'),'utf8');
const constant = name => JSON.parse(setup.match(new RegExp(`^export const localAgentSetup${name} = ("[^"\\n]*");$`,'m'))?.[1] ?? 'null');
const {version} = JSON.parse(readFileSync(resolve(root,'packages/contracts/package.json')));
const bundle = {format:FORMAT,version,sourceRepository:SOURCE_REPOSITORY,sourceRevision:revision ?? null,provenance:provisional ? 'local-provisional':'published',sourceSnapshotSHA256:sourceSnapshot(files),setupVersion:constant('Version'),setupSHA256:constant('SHA256'),contractVersions:['1','2'],files};
const bytes = Buffer.from(JSON.stringify(bundle)+'\n'), lock = lockFor(bundle,bytes);
verifyBundle(bytes,lock);
const out = resolve(output);
if (out === root || relative(root,out).split('/')[0] !== '..') throw Error('Write release artifacts outside the source checkout');
for (const path of [out,out+'.sha256',out+'.lock.json']) if (existsSync(path)) throw Error(`Immutable artifact output already exists: ${path}`);
// Immutable outputs: never overwrite a versioned asset or its receipts.
writeFileSync(out,bytes,{flag:'wx'});
writeFileSync(out+'.sha256',`${lock.sha256}  ${out.split('/').pop()}\n`,{flag:'wx'});
writeFileSync(out+'.lock.json',JSON.stringify(lock,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({output:out,...lock},null,2));
