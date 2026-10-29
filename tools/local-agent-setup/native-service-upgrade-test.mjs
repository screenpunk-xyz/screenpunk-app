// Real JXA/fs durability against isolated fake HOME only. Never executes controller.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,realpathSync,rmSync,statSync,chmodSync,symlinkSync,linkSync,existsSync,statfsSync,readdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const root=resolve(process.env.SCREENPUNK_SETUP_TEST_ROOT || '.task/phase1/phase2/next-round/evidence/setup-v5');
const scratch=join(root,'upgrade-fixtures');mkdirSync(scratch,{recursive:true,mode:0o700});
const manifestPath=join(root,'native-service-upgrade-ownership.json'),owned=[];
const owner=process.env.SCREENPUNK_SETUP_TEST_OWNER || '01a17dd6-fa05-7981-a99f-90adbf05a937/next_local';
const sha=s=>createHash('sha256').update(s).digest('hex'),free=()=>{const s=statfsSync(scratch);return s.bavail*s.bsize;};
const save=()=>writeFileSync(manifestPath,JSON.stringify({owner,project:'screenpunk-one',purpose:'V5 helper-only repair synthetic durability fixtures',budgetMiB:100,resources:owned,keep:['native-service-upgrade-test.log','native-service-upgrade-ownership.json']},null,2));
const frozen=readFileSync('tools/local-agent-setup/releases/v4/macos.sh','utf8');
assert.equal(sha(frozen),'311a4d48ccd6c84637521e9c6291c38813202f3fa869dadf5db7eb05f7557e5e');
function embedded(marker){return frozen.split("<<'"+marker+"'\n")[1].split('\n'+marker)[0]+'\n';}
const oldNative=embedded('SCREENPUNK_NATIVE_JS'),control=embedded('SCREENPUNK_SERVICE_CONTROL');
assert.equal(sha(oldNative),'e3090e5962e34250a0cdaa011fbe39802a7ef20dd987b95bde9039836442842c');
assert.equal(sha(control),'5aae5398e4563d8d8fa96ebadbc8641339079587d1b0bd2ac95d91fba30f4e24');
const candidate=readFileSync('tools/local-agent-setup/macos/native.js','utf8').trimEnd()+'\n'+readFileSync('tools/local-agent-setup/macos/service-native.js','utf8').trimEnd()+'\n'+readFileSync('tools/local-agent-setup/macos/service-upgrade-native.js','utf8').trimEnd()+'\n';
const token='5'.repeat(64)+'\n';
function fixture(){
 const directory=realpathSync(mkdtempSync(join(scratch,'fixture-'))),home=directory+'/home',code=home+'/.codex/screenpunk-local',service=code+'/setup-service',session=code+'/setup-session.fixture';
 const record={path:directory,owner,purpose:'synthetic helper repair only',lifecycle:'active',createdAt:new Date().toISOString(),diskFreeBeforeBytes:free()};owned.push(record);save();
 for(const p of [home,home+'/.codex',code,code+'/workspace',service,session,home+'/Library',home+'/Library/LaunchAgents',directory+'/tmp'])mkdirSync(p,{mode:0o700});
 writeFileSync(code+'/transport-token',token,{mode:0o600});writeFileSync(service+'/native-v4.js',oldNative,{mode:0o600});writeFileSync(service+'/manage-v4.sh',control,{mode:0o700});
 const plist='<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>xyz.screenpunk.local-agent</string></dict></plist>\n';
 writeFileSync(service+'/agent-v4.plist',plist,{mode:0o600});writeFileSync(home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist',plist,{mode:0o600});
 const m={schemaVersion:1,kind:'screenpunk.launchagent.v1',version:'4',label:'xyz.screenpunk.local-agent',uid:process.getuid(),home,domain:'gui/'+process.getuid(),serviceDirectory:service,plistPath:home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist',controlPath:service+'/manage-v4.sh',nativePath:service+'/native-v4.js',cachedPlistPath:service+'/agent-v4.plist',tokenIdentity:process.getuid()+':600:'+statSync(code+'/transport-token').ino,tokenSHA256:sha(token),binarySHA256:'a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e',controlSHA256:sha(control),nativeSHA256:sha(oldNative),plistSHA256:sha(plist),lifecycle:'prepared',consent:true,createdAt:123456789};
 const originalManifest=JSON.stringify(m);writeFileSync(service+'/install.json',originalManifest,{mode:0o600});
 writeFileSync(session+'/native.js',candidate,{mode:0o600});writeFileSync(session+'/service-control.sh',control,{mode:0o600});
 const driver=candidate+`\nfunction run(args){if(args[1]==='production-service-state'){return serviceAction(['service-state',args[2],'enabled']);}var actualSync=syncPath,actualWrite=write,cut=args[7];write=function(path,text){actualWrite(path,text);if(cut==='staged-original'&&path.indexOf('/service-upgrade-stage-original-native-v4.js-')>=0)throw Error('synthetic durable pre-rename cut');if(cut==='staged-journal'&&path.indexOf('/service-upgrade-stage-journal.json-')>=0)throw Error('synthetic durable pre-rename cut');};syncPath=function(path){actualSync(path);var base=args[3]+'/.codex/screenpunk-local/setup-service',journal=base+'/native-upgrade-v5/journal.json';if(cut==='native'&&path===base+'/native-v4.js')throw Error('synthetic durable cut');if(cut==='manifest'&&path===base+'/install.json')throw Error('synthetic durable cut');if(cut==='original'&&path===base+'/native-upgrade-v5/original-native-v4.js')throw Error('synthetic durable cut');if(path===journal&&cut&&cut!=='none'&&JSON.parse(read(journal)).lifecycle===cut)throw Error('synthetic durable cut');};return upgradeServiceV4(args);}\n`;
 writeFileSync(directory+'/driver.js',driver,{mode:0o600});
 const files=[code+'/transport-token',service+'/manage-v4.sh',service+'/agent-v4.plist',m.plistPath];
 const before=files.map(path=>({path,bytes:readFileSync(path),inode:statSync(path).ino,mode:statSync(path).mode}));
 return {directory,home,code,service,session,m,originalManifest,before,
  run(operation,cut='none'){const r=spawnSync('/usr/bin/osascript',['-l','JavaScript',directory+'/driver.js','upgrade-service-v4',operation,service+'/install.json',home,String(process.getuid()),session+'/native.js',session+'/service-control.sh',cut],{encoding:'utf8',env:{HOME:home,TMPDIR:directory+'/tmp',PATH:'/usr/bin:/bin:/usr/sbin:/sbin'},timeout:15000});assert.ok(!r.stdout.includes(token.trim())&&!r.stderr.includes(token.trim()),'Never print even the synthetic bearer');return r;},
  unchanged(){for(const f of before){assert.deepEqual(readFileSync(f.path),f.bytes);assert.equal(statSync(f.path).ino,f.inode);assert.equal(statSync(f.path).mode,f.mode);}assert.equal(JSON.parse(readFileSync(service+'/install.json')).version,'4');},
  clean(){rmSync(directory,{recursive:true});record.lifecycle='removed';record.removedAt=new Date().toISOString();record.diskFreeAfterBytes=free();save();}
 };
}
function ok(result,expected){assert.equal(result.status,0,result.stdout+result.stderr);if(expected)assert.equal(result.stdout.trim(),expected);}
const native=process.platform==='darwin';
test('verified V4 repair changes only helper and native hash and retains exact originals',{skip:!native},()=>{
 const f=fixture();try{ok(f.run('inspect'),'required');assert.ok(!existsSync(f.service+'/native-upgrade-v5'));assert.notEqual(f.run('apply').status,0,'No mutation without durable consent journal');
 ok(f.run('prepare'),'prepared');assert.equal(readFileSync(f.service+'/native-v4.js','utf8'),oldNative);assert.equal(readFileSync(f.service+'/install.json','utf8'),f.originalManifest);
 ok(f.run('apply'),'current');ok(f.run('inspect'),'current');ok(f.run('apply'),'current');f.unchanged();
 assert.equal(readFileSync(f.service+'/native-v4.js','utf8'),candidate);const next=JSON.parse(readFileSync(f.service+'/install.json'));assert.deepEqual(next,{...f.m,nativeSHA256:sha(candidate)});
 const backup=f.service+'/native-upgrade-v5';assert.equal(readFileSync(backup+'/original-native-v4.js','utf8'),oldNative);assert.equal(readFileSync(backup+'/original-install-v4.json','utf8'),f.originalManifest);assert.equal(JSON.parse(readFileSync(backup+'/journal.json')).lifecycle,'completed');
 }finally{f.clean();}
});
for(const cut of ['preparing','original','prepared','native','manifest','completed'])test('resume journal-proven durable repair cut: '+cut,{skip:!native},()=>{
 const f=fixture();try{if(['native','manifest','completed'].includes(cut))ok(f.run('prepare'),'prepared');const operation=['native','manifest','completed'].includes(cut)?'apply':'prepare';const r=f.run(operation,cut);assert.notEqual(r.status,0,'Fault must interrupt real durable operation');
 ok(f.run('apply'),'current');ok(f.run('inspect'),'current');f.unchanged();assert.equal(readFileSync(f.service+'/native-v4.js','utf8'),candidate);assert.equal(JSON.parse(readFileSync(f.service+'/install.json')).nativeSHA256,sha(candidate));
 }finally{f.clean();}
});
test('fresh current V5 install is a verified no-op without an upgrade journal',{skip:!native},()=>{
 const f=fixture();try{writeFileSync(f.service+'/native-v4.js',candidate);writeFileSync(f.service+'/install.json',JSON.stringify({...f.m,nativeSHA256:sha(candidate)}));const inode=statSync(f.service+'/native-v4.js').ino;ok(f.run('inspect'),'current');assert.ok(!existsSync(f.service+'/native-upgrade-v5'));assert.equal(statSync(f.service+'/native-v4.js').ino,inode);f.unchanged();}finally{f.clean();}
});
for(const kind of ['unknown-native','unknown-controller','unknown-manifest-hash','changed-token','helper-symlink','helper-hardlink','wrong-mode','new-old-without-journal','old-new','conflicting-journal','conflicting-backup'])test('reject conflicting repair ownership: '+kind,{skip:!native},()=>{
 const f=fixture();try{
  if(kind==='unknown-native')writeFileSync(f.service+'/native-v4.js','unknown helper\n');
  if(kind==='unknown-controller')writeFileSync(f.service+'/manage-v4.sh','unknown controller\n');
  if(kind==='unknown-manifest-hash')writeFileSync(f.service+'/install.json',JSON.stringify({...f.m,nativeSHA256:'0'.repeat(64)}));
  if(kind==='changed-token')writeFileSync(f.code+'/transport-token','6'.repeat(64)+'\n');
  if(kind==='helper-symlink'){rmSync(f.service+'/native-v4.js');symlinkSync(f.session+'/native.js',f.service+'/native-v4.js');}
  if(kind==='helper-hardlink')linkSync(f.service+'/native-v4.js',f.directory+'/hardlink');
  if(kind==='wrong-mode')chmodSync(f.service+'/native-v4.js',0o644);
  if(kind==='new-old-without-journal')writeFileSync(f.service+'/native-v4.js',candidate);
  if(kind==='old-new')writeFileSync(f.service+'/install.json',JSON.stringify({...f.m,nativeSHA256:sha(candidate)}));
  if(kind==='conflicting-journal'||kind==='conflicting-backup'){ok(f.run('prepare'),'prepared');const path=f.service+'/native-upgrade-v5/'+(kind==='conflicting-journal'?'journal.json':'original-native-v4.js');writeFileSync(path,'conflicting\n');}
  const helperBefore=readFileSync(f.service+'/native-v4.js'),manifestBefore=readFileSync(f.service+'/install.json');assert.notEqual(f.run('inspect').status,0);assert.notEqual(f.run('apply').status,0);assert.deepEqual(readFileSync(f.service+'/native-v4.js'),helperBefore);assert.deepEqual(readFileSync(f.service+'/install.json'),manifestBefore);
 }finally{f.clean();}
});
test('setup-only shell asks consent before preparing and never invokes lifecycle operations',()=>{
 const shell=readFileSync('tools/local-agent-setup/macos/service-upgrade.sh','utf8');assert.ok(shell.indexOf('native consent')<shell.indexOf('native upgrade-service-v4 prepare'));assert.doesNotMatch(shell,/\b(?:launchctl|kill|bootout|bootstrap|kickstart)\s/);
});

test('completed repair permits only production lifecycle metadata evolution',{skip:!native},()=>{
 const f=fixture();try{ok(f.run('prepare'),'prepared');ok(f.run('apply'),'current');const backup=f.service+'/native-upgrade-v5',journal=readFileSync(backup+'/journal.json'),original=readFileSync(backup+'/original-install-v4.json');ok(f.run('production-service-state'));const enabled=readFileSync(f.service+'/install.json');assert.equal(JSON.parse(enabled).lifecycle,'enabled');ok(f.run('inspect'),'current');ok(f.run('apply'),'current');assert.deepEqual(readFileSync(f.service+'/install.json'),enabled);assert.deepEqual(readFileSync(backup+'/journal.json'),journal);assert.deepEqual(readFileSync(backup+'/original-install-v4.json'),original);f.unchanged();
 const changed={...JSON.parse(enabled),createdAt:999};writeFileSync(f.service+'/install.json',JSON.stringify(changed));assert.notEqual(f.run('inspect').status,0,'Unrelated receipt metadata cannot silently evolve');
 }finally{f.clean();}
});

for(const cut of ['staged-original','staged-journal'])test('pre-rename session stage survives without poisoning repair recovery: '+cut,{skip:!native},()=>{
 const f=fixture();try{assert.notEqual(f.run('prepare',cut).status,0);const stages=readdirSync(f.session).filter(n=>n.startsWith('service-upgrade-stage-'));assert.equal(stages.length,1);const stage=f.session+'/'+stages[0],bytes=readFileSync(stage);assert.equal(readFileSync(f.service+'/native-v4.js','utf8'),oldNative);assert.equal(readFileSync(f.service+'/install.json','utf8'),f.originalManifest);
 if(cut==='staged-journal'){ok(f.run('inspect'),'required');ok(f.run('prepare'),'prepared');}else ok(f.run('inspect'),'resume');
 ok(f.run('apply'),'current');assert.deepEqual(readFileSync(stage),bytes,'Preserve the exact orphan as private review evidence');f.unchanged();
 }finally{f.clean();}
});

test('repair cancellation cannot fall through when errexit is disabled by caller',()=>{
 const f=fixture();try{const shell=readFileSync('tools/local-agent-setup/macos/service-upgrade.sh','utf8');const script=shell+`
private_dir(){ :; }
private_file(){ :; }
service_paths(){ sp_service_dir="$TESTROOT/home/.codex/screenpunk-local/setup-service"; sp_service_manifest="$sp_service_dir/install.json"; }
fail(){ exit 1; }
native(){ printf '%s\\n' "$*" >> "$TESTROOT/actions"; if [ "$1" = consent ]; then return 1; fi; if [ "$2" = inspect ]; then echo required; fi; return 0; }
sp_uid=501
sp_session="$TESTROOT/home/.codex/screenpunk-local/setup-session.fixture"
if service_upgrade_v4_if_needed; then exit 99; else exit 0; fi
`;const r=spawnSync('/bin/sh',['-c',script],{encoding:'utf8',env:{HOME:f.home,TESTROOT:f.directory,PATH:'/usr/bin:/bin'}});assert.equal(r.status,0,r.stderr);const actions=readFileSync(f.directory+'/actions','utf8');assert.match(actions,/^consent /m);assert.doesNotMatch(actions,/upgrade-service-v4 (prepare|apply)/);assert.equal(readFileSync(f.service+'/native-v4.js','utf8'),oldNative);assert.equal(readFileSync(f.service+'/install.json','utf8'),f.originalManifest);
 }finally{f.clean();}
});
