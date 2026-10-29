// SPDX-License-Identifier: Apache-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { sha256, lockFor, verifyBundle, validateLock } from './format.mjs';
import * as setup from '../local-agent-setup/generated/local-agent-setup.ts';
const root=fileURLToPath(new URL('../../',import.meta.url));
const scratch=resolve(process.env.SCREENPUNK_ARTIFACT_TEST_ROOT ?? join(tmpdir(),'screenpunk-public-artifact-tests-public'));
mkdirSync(scratch,{recursive:true});
const directory=mkdtempSync(join(scratch,'case-'));
writeFileSync(join(scratch,'ownership.json'),JSON.stringify({owner:'Screenpunk migration contracts_artifacts',project:'screenpunk-app',purpose:'Synthetic public artifact packaging checks',lifecycle:'active',budgetMiB:50,keep:['ownership.json']})+'\n');
const output=join(directory,'bundle.json');
const result=spawnSync(process.execPath,['tools/public-artifacts/pack.mjs','--provisional','--output',output],{cwd:root,encoding:'utf8'});
assert.equal(result.status,0,result.stderr);
const bytes=readFileSync(output),bundle=JSON.parse(bytes),lock=JSON.parse(readFileSync(output+'.lock.json'));
test('portable artifact includes the contract validators, schemas, fixtures, license and setup',()=>{
  const verified=verifyBundle(bytes,lock);
  for(const path of ['packages/contracts/authoring.ts','packages/contracts/authoring-v2.ts','packages/contracts/definitions/request-v1.schema.json','packages/contracts/definitions/request-v2.schema.json','packages/contracts/fixtures/conformance-v1.json','packages/contracts/fixtures/conformance-v2.json','LICENSE','tools/local-agent-setup/generated/local-agent-setup.ts']) assert.ok(verified.files.has(path),path);
  assert.equal(lock.sourceRevision,null);assert.equal(lock.provenance,'local-provisional');
  assert.throws(()=>validateLock(lock,{requirePublished:true}),/cannot deploy/);
});
test('preserves every published setup version, checksum, URL and CSP',()=>{
  const expected=['2d208f5fc45737dc2aa89c00db96c784fa3142ff13508c7ada7f7a53dd5f8957','5f46adbf5a0582e0734fdc8d7ea7aab0e200edd103351248c344162783fe2e6d','0945173fe87e98d2e3a168dd3f461b59acdfa10eef6e0897f2931205779d1ed5','311a4d48ccd6c84637521e9c6291c38813202f3fa869dadf5db7eb05f7557e5e','a54dc9fc1daedd4f95b8e2be126629c0dc83bdd63eb8bbc6076fb88734102fe3','061de76d6ddb9d7a97dab21657da934404b152b97fa9e5583e24e11bd26f6134'];
  assert.deepEqual(Object.keys(setup.localAgentSetupScripts),['1','2','3','4','5','6']);
  for(const [i,expectedSHA] of expected.entries()){const version=String(i+1),entry=setup.localAgentSetupScripts[version];assert.equal(entry.sha256,expectedSHA);assert.equal(sha256(entry.script),expectedSHA);if(i<5)assert.equal(entry.script,readFileSync(join(root,`tools/local-agent-setup/releases/v${version}/macos.sh`),'utf8'));}
  assert.match(setup.localAgentSetupHTML,/\/local\/setup\/v6\/macos\.sh/);
  assert.match(setup.localAgentSetupHTML,/061de76d6ddb9d7a97dab21657da934404b152b97fa9e5583e24e11bd26f6134/);
  const inline=setup.localAgentSetupHTML.match(/<script>([\s\S]*)<\/script>/)[1];
  const hash=Buffer.from(sha256(inline),'hex').toString('base64');
  assert.ok(setup.localAgentSetupCSP.includes(`'sha256-${hash}'`));
});
test('rejects whole-bundle, per-file, snapshot and lock identity tampering',()=>{
  assert.throws(()=>verifyBundle(Buffer.concat([bytes,Buffer.from(' ')]),lock),/SHA256/);
  for(const kind of ['content','snapshot','duplicate','license','base64','path','size']){
    const changed=structuredClone(bundle);
    if(kind==='content')changed.files[0].contentBase64=Buffer.from('changed').toString('base64');
    if(kind==='snapshot')changed.sourceSnapshotSHA256='a'.repeat(64);
    if(kind==='duplicate')changed.files.splice(1,0,structuredClone(changed.files[0]));
    if(kind==='license')changed.files=changed.files.filter(f=>f.path!=='LICENSE');
    if(kind==='base64')changed.files[0].contentBase64+='=';
    if(kind==='path')changed.files[0].path='packages/contracts/../../outside';
    if(kind==='size')changed.files[0].size=1024*1024*5;
    const encoded=Buffer.from(JSON.stringify(changed)+'\n');
    assert.throws(()=>verifyBundle(encoded,lockFor(changed,encoded)),undefined,kind);
  }
  assert.throws(()=>verifyBundle(bytes,{...lock,version:'0.1.1'}),/does not match lock/);
  // Synthetic identities exercise the exact source binding without creating a release pin.
  const published={...bundle,provenance:'published',sourceRevision:'a'.repeat(40)};
  const publishedBytes=Buffer.from(JSON.stringify(published)+'\n'), publishedLock=lockFor(published,publishedBytes);
  assert.throws(()=>verifyBundle(publishedBytes,{...publishedLock,sourceRevision:'b'.repeat(40)},{requirePublished:true}),/sourceRevision does not match lock/);
  assert.throws(()=>validateLock({...lock,sourceRevision:'main'}),/provenance/);
  assert.throws(()=>validateLock({...lock,url:'https://github.com/screenpunk-xyz/screenpunk-app/releases/latest/download/bundle.json'}),/exact versioned/);
});
test('packing is deterministic, immutable and never invents a public revision',()=>{
  const second=join(directory,'second.json');
  assert.equal(spawnSync(process.execPath,['tools/public-artifacts/pack.mjs','--provisional','--output',second],{cwd:root,encoding:'utf8'}).status,0);
  assert.deepEqual(readFileSync(second),bytes);
  assert.notEqual(spawnSync(process.execPath,['tools/public-artifacts/pack.mjs','--provisional','--output',output],{cwd:root,encoding:'utf8'}).status,0);
  assert.deepEqual(readFileSync(output),bytes);
  assert.notEqual(spawnSync(process.execPath,['tools/public-artifacts/pack.mjs','--source-revision','0'.repeat(40),'--output',join(directory,'invalid.json')],{cwd:root,encoding:'utf8'}).status,0);
});
test.after(()=>{
  rmSync(directory,{recursive:true});
  writeFileSync(join(scratch,'ownership.json'),JSON.stringify({owner:'Screenpunk migration contracts_artifacts',project:'screenpunk-app',purpose:'Synthetic public artifact packaging checks',lifecycle:'completed',budgetMiB:50,keep:['ownership.json'],removed:directory,activeFixtures:[]})+'\n');
});
