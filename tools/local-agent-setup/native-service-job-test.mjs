// Real JXA regression for the production service-job action. No service mutations.
// Optional explicit local probes:
// SCREENPUNK_SETUP_SERVICE_JOB_CAPTURE=/path/to/captured-list.log
// SCREENPUNK_SETUP_SERVICE_JOB_READONLY=1  (only `launchctl list <fixed label>`)
import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,realpathSync,existsSync,statfsSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const evidence=resolve(process.env.SCREENPUNK_SETUP_TEST_ROOT||'.task/phase1/phase2/next-round/evidence/setup-v5');
mkdirSync(evidence,{recursive:true,mode:0o700});const fixtures=join(evidence,'fixtures');mkdirSync(fixtures,{recursive:true,mode:0o700});
const root=realpathSync(mkdtempSync(join(fixtures,'native-service-job-'))),home=root+'/home',fields=root+'/fields';for(const dir of [home,fields,root+'/tmp'])mkdirSync(dir,{mode:0o700});
const production=readFileSync('tools/local-agent-setup/macos/native.js','utf8')+'\n'+readFileSync('tools/local-agent-setup/macos/service-native.js','utf8');
const source=root+'/native.js';writeFileSync(source,production,{mode:0o600});
const free=()=>{const s=statfsSync(evidence);return s.bavail*s.bsize;};
const ownership={owner:process.env.SCREENPUNK_SETUP_TEST_OWNER||'screenpunk-one/native-service-job-tests',purpose:'Production service-job parser through actual JXA, synthetic files plus explicitly authorized read-only job capture',createdAt:new Date().toISOString(),lifecycle:'active',path:root,budgetMiB:100,productionHelperSHA256:createHash('sha256').update(production).digest('hex'),diskFreeBeforeBytes:free(),hostOperations:[]};
const receipt=join(evidence,'native-service-job-ownership.json');writeFileSync(receipt,JSON.stringify(ownership,null,2));
after(()=>{rmSync(root,{recursive:true});ownership.lifecycle='completed';ownership.removedAt=new Date().toISOString();ownership.diskFreeAfterBytes=free();ownership.pathRemoved=!existsSync(root);writeFileSync(receipt,JSON.stringify(ownership,null,2));});
function manifest(macHome='/Users/fixture') {const dir=macHome+'/.codex/screenpunk-local/setup-service',uid=process.getuid();return{schemaVersion:1,kind:'screenpunk.launchagent.v1',version:'4',label:'xyz.screenpunk.local-agent',uid,home:macHome,domain:'gui/'+uid,serviceDirectory:dir,plistPath:macHome+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist',controlPath:dir+'/manage-v4.sh',nativePath:dir+'/native-v4.js',cachedPlistPath:dir+'/agent-v4.plist',tokenIdentity:uid+':600:1',tokenSHA256:'0'.repeat(64),binarySHA256:'a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e',controlSHA256:'1'.repeat(64),nativeSHA256:'2'.repeat(64),plistSHA256:'3'.repeat(64),lifecycle:'prepared',consent:true};}
// Same diagnostic structure/spacing/delimiters as the actual captured Mac output.
function raw(macHome='/Users/fixture') {return `{
\t"StandardOutPath" = "/dev/null";
\t"LimitLoadToSessionType" = "Aqua";
\t"StandardErrorPath" = "/dev/null";
\t"Label" = "xyz.screenpunk.local-agent";
\t"OnDemand" = false;
\t"LastExitStatus" = 0;
\t"PID" = 63870;
\t"Program" = "/bin/sh";
\t"ProgramArguments" = (
\t\t"/bin/sh";
\t\t${JSON.stringify(macHome+'/.codex/screenpunk-local/setup-service/manage-v4.sh')};
\t\t"run";
\t);
};
`;}
function invoke(text,macHome='/Users/fixture') {
 writeFileSync(root+'/manifest.json',JSON.stringify(manifest(macHome)),{mode:0o600});writeFileSync(root+'/job.log',text,{mode:0o600});rmSync(fields+'/service-job-pid',{force:true});
 const result=spawnSync('/usr/bin/osascript',['-l','JavaScript',source,'service-job',root+'/manifest.json',root+'/job.log',fields],{env:{HOME:home,PATH:'/usr/bin:/bin',TMPDIR:root+'/tmp'},encoding:'utf8',timeout:10000,maxBuffer:16384});
 return{...result,pid:existsSync(fields+'/service-job-pid')?readFileSync(fields+'/service-job-pid','utf8'):undefined};
}
function accept(text,pid,macHome){const r=invoke(text,macHome);assert.equal(r.status,0,r.stderr);assert.equal(r.pid,String(pid));}
function reject(text){const r=invoke(text);assert.notEqual(r.status,0);assert.equal(r.pid,undefined);assert.match(r.stderr,/Cannot verify LaunchAgent job information|unknown job|Cannot read local setup file/);assert.doesNotMatch(r.stderr,/TypeError|ReferenceError/);}
test('actual diagnostic array separators and outer semicolon parse through production JXA',()=>{accept(raw(),63870);});
test('stopped job and optional outer semicolon remain bounded supported shapes',()=>{accept(raw().replace('\t"PID" = 63870;\n',''),0);accept(raw().replace('63870','0'),0);accept(raw().replace('};\n','}\n'),63870);});
test('quoted paths and escaped equivalent single keys preserve exact identity',()=>{accept(raw('/Users/Fixture "Mac"'),63870,'/Users/Fixture "Mac"');accept(raw().replace('"Label"','"\\u004cabel"'),63870);});
test('malformed, duplicate, type-confused and unsupported diagnostic output rejects clearly',()=>{
 const good=raw();for(const candidate of [
  '', 'not a dictionary', '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
  good.replace('"run";','"run",'),good.replace('"run";','run;'),good.replace('};\n','};\nextra'),good+'{}',good+';',
  good.replace('"Label" =','"Label" = "other"; "Label" ='),good.replace('"Label" =','"\\u004cabel" = "other"; "Label" ='),
  good.replace('"PID" = 63870;','"PID" = 63870; "PID" = 7;'),
  good.replace('"PID" = 63870;','"PID" = true;'),good.replace('"PID" = 63870;','"PID" = "63870";'),good.replace('63870','-1'),good.replace('63870','2147483648'),good.replace('63870','1.5'),good.replace('63870','063870'),
  good.replace('"ProgramArguments" = (','"ProgramArguments" = {'),good.replace('"run";','false;'),good.replace('"run";','"run"; "extra";'),
  good.replace('"Label" = "xyz.screenpunk.local-agent";','"Label" = false;'),good.replace('"Program" = "/bin/sh";','"Program" = ();'),
  good.replace('"OnDemand" = false;','"OnDemand" = "false";'),good.replace('"LastExitStatus" = 0;','"LastExitStatus" = true;'),
  good.replace('"StandardOutPath" = "/dev/null";','"StandardOutPath" = ();'),
  good.replace('"run";','"bad\\nvalue";'),good.replace('};\n','"Extra" = {"Key" = true; "Key" = false;}; };\n'),
  good.replace('};\n','"Extra" = '+ '('.repeat(6)+'"x";'+');'.repeat(6)+' };\n'),
  good.replace('"run";','"'+'x'.repeat(4097)+'";'),good+' '.repeat(65536),
 ])reject(candidate);
});
test('unknown label, executable and exact controller arguments are never accepted',()=>{for(const candidate of [raw().replace('xyz.screenpunk.local-agent','unknown.job'),raw().replace('"Program" = "/bin/sh"','"Program" = "/bin/zsh"'),raw().replace('manage-v4.sh','other.sh'),raw().replace('"run";','"restart";')])reject(candidate);});
test('exact captured host bytes parse without changing service or authentication state',{skip:!process.env.SCREENPUNK_SETUP_SERVICE_JOB_CAPTURE},()=>{accept(readFileSync(process.env.SCREENPUNK_SETUP_SERVICE_JOB_CAPTURE),63870,process.env.HOME);});
test('explicit real launchctl list read-only input goes through the production helper',{skip:process.env.SCREENPUNK_SETUP_SERVICE_JOB_READONLY!=='1'},()=>{
 const result=spawnSync('/bin/launchctl',['list','xyz.screenpunk.local-agent'],{encoding:'utf8',timeout:10000,maxBuffer:65536});assert.equal(result.status,0,'Read-only job lookup unavailable; no service operation was attempted');writeFileSync(join(evidence,'launchctl-list-readonly-current.log'),result.stdout,{mode:0o600});ownership.hostOperations.push('read-only /bin/launchctl list xyz.screenpunk.local-agent');writeFileSync(receipt,JSON.stringify(ownership,null,2));const r=invoke(result.stdout,process.env.HOME);assert.equal(r.status,0,r.stderr);assert.ok(Number(r.pid)>0);
});
