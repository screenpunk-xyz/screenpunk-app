import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,existsSync,chmodSync,readdirSync,statSync,realpathSync,statfsSync,symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
const evidenceRoot=resolve(process.env.SCREENPUNK_SETUP_TEST_ROOT || '.task/phase1/phase2/next-round/evidence/mac-setup');
const testOwner=process.env.SCREENPUNK_SETUP_TEST_OWNER || 'screenpunk-one/mac-setup-tests';
const scratch=join(evidenceRoot,'fixtures');mkdirSync(scratch,{recursive:true,mode:0o700});
const owned=[];const ownershipPath=join(evidenceRoot,'fixture-ownership.json');
function saveOwnership(){writeFileSync(ownershipPath,JSON.stringify({owner:testOwner,project:'screenpunk-one',purpose:'Synthetic setup regression fixtures only',budgetMiB:50,fixtures:owned},null,2));}
function diskFree(){const fs=statfsSync(scratch);return fs.bavail*fs.bsize;}
const sha='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e';
const binary=Buffer.concat([Buffer.from([0,0,0,11]),Buffer.from('ssh-ed25519'),Buffer.from([0,0,0,32]),Buffer.alloc(32,7)]);
const digest='SHA256:'+createHash('sha256').update(binary).digest('base64').replace(/=/g,'');
function request(now=Date.now()){return {type:'screenpunk.pairing-request.v1',schemaVersion:1,pairingID:'11111111-2222-4333-8444-555555555555',nonce:Buffer.alloc(32,7).toString('base64url'),issuedAt:now,expiresAt:now+1800000,publicKeyOpenSSH:'ssh-ed25519 '+binary.toString('base64'),publicKeySHA256:digest,deviceName:'Synthetic iPad',codexVersion:'0.164.0-alpha.11.1',protocolProfile:'macos-codex-0.164.0-alpha.11.1'};}
const context=vm.createContext({ObjC:{import(){},bindFunction(){}},Date,JSON,Number,Error,encodeURIComponent,unescape});
vm.runInContext(readFileSync('tools/local-agent-setup/macos/native.js','utf8'),context);
test('strict public parser rejects malformed, expired, swapped protocol and duplicate fields',()=>{
 const now=Date.now(), good=request(now); assert.equal(context.validateRequest(JSON.stringify(good),now).publicKeyOpenSSH,good.publicKeyOpenSSH);
 for(const overrides of [{schemaVersion:true},{type:'wrong'},{protocolProfile:'wrong'},{expiresAt:now+1800001},{issuedAt:now+120001,expiresAt:now+1800000},{issuedAt:now-2000000,expiresAt:now-120001},{nonce:'z'.repeat(43)},{publicKeyOpenSSH:'command=bad '+good.publicKeyOpenSSH},{publicKeyOpenSSH:good.publicKeyOpenSSH+'\n'},{publicKeyOpenSSH:'ssh-ed25519 '+Buffer.alloc(51).toString('base64')},{deviceName:'bad\u202evalue'},{extra:'field'}]) assert.throws(()=>context.validateRequest(JSON.stringify({...good,...overrides}),now),JSON.stringify(overrides));
 assert.throws(()=>context.validateRequest(JSON.stringify(good).replace('"schemaVersion":1','"schemaVersion":1,"schemaVersion":1'),now));
 assert.throws(()=>context.validateRequest(JSON.stringify(good).replace('"schemaVersion":1','"schemaVersion":1,"schema\\u0056ersion":1'),now));
});
test('private reply is request bound, short lived, bounded and path/host safe',()=>{
 const r=request(), fields={computerName:'Fixture Mac',host:'fixture.local',username:'fixture',hostKeySHA256:digest,macWorkspace:'/Users/fixture/.codex/screenpunk-local/workspace',appServerToken:'1'.repeat(64)};
 const reply=context.makeReply(r,fields,Date.now());assert.equal(reply.nonce,r.nonce);assert.equal(reply.expiresAt-reply.issuedAt,300000);assert.ok(Buffer.byteLength(JSON.stringify(reply))<1024);
 for(const override of [{host:'-evil'},{host:'host\nname'},{username:'-root'},{macWorkspace:'/Users/../secret'},{macWorkspace:'/Users//secret'},{appServerToken:'bad'},{computerName:'x'.repeat(129)}])assert.throws(()=>context.makeReply(r,{...fields,...override},Date.now()));
});
// Assemble unpublished source only in memory. Published v1-v5 files are never rewritten by fixtures.
function candidateSetupScript(){
 const base='tools/local-agent-setup/macos/',native=['native.js','service-native.js','service-upgrade-native.js'].map(n=>readFileSync(base+n,'utf8').trimEnd()).join('\n');
 const service=readFileSync(base+'service.sh','utf8'),control=readFileSync(base+'service-control.sh.in','utf8').replace('@@SERVICE_SHELL@@',()=>service.trimEnd());
 let text=readFileSync(base+'macos.sh.in','utf8');
 for(const [marker,value] of [['@@NATIVE_JS@@',native],['@@SSH_AUDIT@@',readFileSync(base+'ssh-audit.sh','utf8')],['@@SERVICE_SHELL@@',service],['@@SERVICE_CONTROL@@',control],['@@SERVICE_UPGRADE@@',readFileSync(base+'service-upgrade.sh','utf8')]])text=text.replace(marker,()=>value.trimEnd());
 return text;
}
function fixture(){
 const root=realpathSync(mkdtempSync(join(scratch,'fixture-'))), home=root+'/home',bin=root+'/bin';for(const path of [home,bin,root+'/tmp',root+'/sshd_config.d',root+'/crypto'])mkdirSync(path,{mode:0o700});
 const resource={path:root,createdAt:new Date().toISOString(),lifecycle:'active',diskFreeBeforeBytes:diskFree()};owned.push(resource);saveOwnership();
 const executable=(name,text)=>{writeFileSync(bin+'/'+name,'#!/bin/sh\nset -eu\n'+text);chmodSync(bin+'/'+name,0o700);};
 writeFileSync(root+'/sshd_config',`Include ${root}/sshd_config.d/*\n`);
 writeFileSync(root+'/sshd_config.d/100-macos.conf',`# Options set by macOS\nUsePAM yes\nAcceptEnv LANG LC_*\nInclude ${root}/crypto.conf\n`);
 symlinkSync('crypto/apple.conf',root+'/crypto.conf');
 writeFileSync(root+'/crypto/apple.conf','Ciphers ^aes128-gcm@openssh.com,aes256-gcm@openssh.com\nKexAlgorithms ^ecdh-sha2-nistp256\nMACs ^hmac-sha2-256-etm@openssh.com,hmac-sha2-256\n',{mode:0o644});
 writeFileSync(root+'/public.json',JSON.stringify(request()));writeFileSync(root+'/host.pub','ssh-ed25519 '+binary.toString('base64')+' fixture-host\n');
 executable('uname','case "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n');executable('sw_vers','echo 14.0\n');
 executable('id','if [ "$1" = -un ]; then echo fixture; else /usr/bin/id "$@"; fi\n');
 executable('shasum','if [ "$3" = "$TESTROOT/bin/codex" ]; then echo "'+sha+'  codex"; else exec /usr/bin/shasum "$@"; fi\n');
 executable('stat','if [ "$2" = %u ] && [ "$3" = "$TESTROOT/${TEST_BAD_OWNER:-not-a-policy}" ]; then echo 501; exit; fi; if [ "$2" = %u ] && { [ "$3" = "$TESTROOT/host.pub" ] || [ "$3" = "$TESTROOT/sshd_config" ] || [ "$3" = "$TESTROOT/policy.conf" ] || [ "$3" = "$TESTROOT/crypto.conf" ] || [ "$3" = "$TESTROOT/crypto/apple.conf" ] || [ "$3" = "$TESTROOT/crypto" ] || [ "$3" = "$TESTROOT" ] || [ "$3" = "$TESTROOT/sshd_config.d" ] || [ "${3%/*}" = "$TESTROOT/sshd_config.d" ]; }; then echo 0; else exec /usr/bin/stat "$@"; fi\n');
 executable('ssh-keygen','if [ "$1" = -A ]; then echo generated >> "$TESTROOT/hostkey-actions"; printf "fixture-host\\n" > "$TESTROOT/host.pub"; else echo "256 '+digest+' fixture (ED25519)"; fi\n');
 executable('nc','case " $* " in *" 4500 "*) exit "${TEST_PORT_ACTIVE:-1}";; *) exit "${TEST_REMOTE_STATUS:-0}";; esac\n');executable('dscl','exit 1\n');
 executable('scutil','if [ "$2" = ComputerName ]; then echo "Synthetic Mac"; else echo fixture-mac; fi\n');
 executable('sshd','echo sshd >> "$TESTROOT/actions"; if [ "$1" = -t ]; then exit "${TEST_SSHD_STATUS:-0}"; fi; printf "%s\\n" "${TEST_EFFECTIVE:-allowtcpforwarding local\npermitlisten none\nallowstreamlocalforwarding no\ndisableforwarding no\npubkeyauthentication yes}"\n');
 executable('sudo','echo sudo >> "$TESTROOT/actions"; case "$1" in "$TESTROOT/bin/sshd"|install|rm|ssh-keygen) exec "$@";; *) exit 99;; esac\n');
 executable('codex','case "$1" in --version) echo "codex 0.164.0-alpha.11.1"; exit;; login) if [ "${2:-}" = status ]; then exit "${TEST_LOGIN_STATUS:-0}"; fi; touch "$TESTROOT/login"; exit;; esac\necho $$ > "$TESTROOT/server-pid"\ntrap "exit 0" TERM INT\nwhile [ ! -f "$TESTROOT/stop-server" ]; do /bin/sleep 0.05; done\n');
 executable('ps','/bin/kill -0 "$2" 2>/dev/null || exit 1; echo "Wed Oct 28 00:00:00 2026"\n');
 executable('lsof','if [ "${TEST_UNKNOWN_PORT:-0}" = 1 ]; then echo 999999; exit; fi\n[ -f "$TESTROOT/server-pid" ] || exit 1\npid=$(cat "$TESTROOT/server-pid"); if [ "${TEST_RESTORE_NO_LISTENER:-0}" = 1 ] && [ "$pid" != "${TEST_ORIGINAL_PID:-0}" ]; then exit 1; fi; /bin/kill -0 "$pid" 2>/dev/null || exit 1\ncase " $* " in *" -Fn "*) echo "p$pid"; echo n127.0.0.1:4500;; *) echo "$pid";; esac\n');
 writeFileSync(root+'/fake-launchctl.mjs',`import{readFileSync,writeFileSync,existsSync,rmSync}from'node:fs';import{spawn}from'node:child_process';const root=process.env.TESTROOT,home=process.env.HOME,state=root+'/job.json',args=process.argv.slice(2),label='xyz.screenpunk.local-agent',control=home+'/.codex/screenpunk-local/setup-service/manage-v4.sh';const actions=existsSync(root+'/launch-actions.json')?JSON.parse(readFileSync(root+'/launch-actions.json')):[];actions.push(args);writeFileSync(root+'/launch-actions.json',JSON.stringify(actions));const alive=p=>{try{process.kill(p,0);return true;}catch{return false;}};const xml=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');const launch=()=>{const child=spawn('/bin/sh',[control,'run'],{env:process.env,stdio:'ignore'});writeFileSync(state,JSON.stringify({pid:child.pid,control}));child.unref();};if(args[0]==='list'){if(!existsSync(state))process.exit(113);const s=JSON.parse(readFileSync(state));const path=process.env.TEST_UNKNOWN_JOB==='1'?root+'/unrelated.sh':s.control;console.log('{'+JSON.stringify('Label')+' = '+JSON.stringify(label)+'; '+JSON.stringify('Program')+' = '+JSON.stringify('/bin/sh')+'; '+JSON.stringify('ProgramArguments')+' = ('+["/bin/sh",path,"run"].map(v=>JSON.stringify(v)+';').join(' ')+'); '+(alive(s.pid)?JSON.stringify('PID')+' = '+s.pid+'; ':'')+'};');}else if(args[0]==='bootstrap'){if(process.env.TEST_BOOTSTRAP_STATUS==='1')process.exit(71);if(existsSync(state))process.exit(72);launch();}else if(args[0]==='bootout'){if(!existsSync(state))process.exit(113);const s=JSON.parse(readFileSync(state));if(s.control!==control)process.exit(73);if(alive(s.pid))process.kill(s.pid,'SIGTERM');rmSync(state);}else if(args[0]==='kickstart'){if(!existsSync(state))process.exit(113);const s=JSON.parse(readFileSync(state));if(!alive(s.pid))launch();}else process.exit(99);`);
 executable('launchctl',`exec '${process.execPath}' "$TESTROOT/fake-launchctl.mjs" "$@"\n`);
 executable('mv','/bin/mv "$@"; if [ "${TEST_CUT:-}" = token ] && [ "$1" = -n ]; then /bin/kill -KILL "$PPID"; fi\n');
 executable('osascript','action=$4\nprintf "%s\\n" "$action" >> "$TESTROOT/native-actions"\ncase "$action" in service-choice) printf "%s\\n" "${TEST_SERVICE_MODE:-foreground}";; choose) printf "%s" "$TESTROOT/public.json" > "$5";; consent) printf "%s\\n" "$5" >> "$TESTROOT/consent-messages"; if [ "${TEST_CANCEL_RESUME:-0}" = 1 ]; then case "$5" in "Resume the verified interrupted"*) exit 1;; esac; fi; if [ "${TEST_CANCEL_REENABLE:-0}" = 1 ]; then case "$5" in "Re-enable the verified"*) exit 1;; esac; fi; if [ "${TEST_LATE_PLIST:-0}" = 1 ]; then case "$5" in "Move the verified"*) printf "Unrelated user plist\\n" > "$HOME/Library/LaunchAgents/xyz.screenpunk.local-agent.plist";; esac; fi; if [ "${TEST_CANCEL_MIGRATION:-0}" = 1 ]; then case "$5" in "Move the verified"*) exit 1;; esac; fi; if [ "${TEST_CANCEL_GRANT:-0}" = 1 ]; then case "$5" in "Authorize this iPad"*) exit 1;; esac; fi; exit "${TEST_CONSENT_STATUS:-0}";; display) cp "$5/private-reply.json" "$TESTROOT/reply.json"; if [ -f "$5/connection.png" ]; then cp "$5/connection.png" "$TESTROOT/qr.png"; fi; if [ "${TEST_KEEP_SERVER:-0}" != 1 ]; then touch "$TESTROOT/stop-server"; fi;; *) if [ "${TEST_FAIL_NATIVE:-}" = "$action" ]; then exit 77; fi; /usr/bin/osascript "$@"; result=$?; if [ "${TEST_CUT:-}" = "$action" ]; then /bin/kill -KILL "$PPID"; fi; exit "$result";; esac\n');
 function setSetupSource(source){
 let script=source.replaceAll('PATH=/usr/bin:/bin:/usr/sbin:/sbin',`PATH=${bin}:/usr/bin:/bin:/usr/sbin:/sbin`).replaceAll("SP_CODEX='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'",`SP_CODEX='${bin}/codex'`).replaceAll('SP_OSASCRIPT=/usr/bin/osascript',`SP_OSASCRIPT=${bin}/osascript`).replaceAll('SP_SUDO=/usr/bin/sudo',`SP_SUDO=${bin}/sudo`).replaceAll('SP_SSHD=/usr/sbin/sshd',`SP_SSHD=${bin}/sshd`).replaceAll('SP_POLICY=/etc/ssh/sshd_config.d/090-screenpunk-local.conf',`SP_POLICY=${root}/sshd_config.d/090-screenpunk-local.conf`).replace('SP_HOSTKEY=/etc/ssh/ssh_host_ed25519_key.pub',`SP_HOSTKEY=${root}/host.pub`).replace('SP_SSHCONFIG=/etc/ssh/sshd_config',`SP_SSHCONFIG=${root}/sshd_config`).replace('SP_SSHDIR=/etc/ssh/sshd_config.d',`SP_SSHDIR=${root}/sshd_config.d`).replace('SP_CRYPTO=/etc/ssh/crypto.conf',`SP_CRYPTO=${root}/crypto.conf`).replaceAll('SP_LAUNCHCTL=/bin/launchctl',`SP_LAUNCHCTL=${bin}/launchctl`).replaceAll('\"$sp_service_attempt\" -lt 20','\"$sp_service_attempt\" -lt 3').replaceAll('\"$sp_attempt\" -lt 20','\"$sp_attempt\" -lt 3');
 // Fixtures rewrite controller executable paths; bind only their reviewed controller hash.
 const fixtureControl=script.split("<<'SCREENPUNK_SERVICE_CONTROL'\n")[1].split('\nSCREENPUNK_SERVICE_CONTROL\n')[0]+'\n';
 script=script.replace("var screenpunkV4ControlSHA256='5aae5398e4563d8d8fa96ebadbc8641339079587d1b0bd2ac95d91fba30f4e24';","var screenpunkV4ControlSHA256='"+createHash('sha256').update(fixtureControl).digest('hex')+"';");
 writeFileSync(root+'/setup.sh',script);}
 setSetupSource(readFileSync('tools/local-agent-setup/macos/macos.sh','utf8'));const env={HOME:home,PATH:bin+':/usr/bin:/bin',TMPDIR:root+'/tmp',TESTROOT:root};
 return{root,home,bin,env,setSetupSource,run(extra={},keepServer=false){rmSync(root+'/stop-server',{force:true});if(!keepServer)rmSync(root+'/server-pid',{force:true});return spawnSync('/bin/sh',[root+'/setup.sh'],{encoding:'utf8',env:{...env,...extra},timeout:15000});},spawn(extra={}){rmSync(root+'/stop-server',{force:true});return spawn('/bin/sh',[root+'/setup.sh'],{env:{...env,...extra},stdio:['ignore','pipe','pipe']});},manage(action,extra={}){return spawnSync('/bin/sh',[home+'/.codex/screenpunk-local/setup-service/manage-v4.sh',action],{env:{...env,...extra},encoding:'utf8',timeout:15000});},clean(){writeFileSync(root+'/stop-server','stop owned fixture');spawnSync('/bin/sleep',['0.15']);rmSync(root,{recursive:true});resource.lifecycle='removed';resource.removedAt=new Date().toISOString();resource.diskFreeAfterBytes=diskFree();saveOwnership();}};
}
function success(f,r){assert.equal(r.status,0,r.stdout+r.stderr);assert.ok(!r.stdout.includes('1'.repeat(64)));assert.ok(existsSync(f.home+'/.codex/screenpunk-local/.setup.lock')); for(const name of readdirSync(f.home+'/.codex/screenpunk-local').filter(n=>n.startsWith('setup-session.')))for(const file of ['private-reply.json','connection.png','new-token'])assert.ok(!existsSync(f.home+'/.codex/screenpunk-local/'+name+'/'+file));}
test('synthetic native chooser → authorization → foreground server → private QR and idempotent rerun',()=>{
 const f=fixture();try{let r=f.run();success(f,r);const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),keys=readFileSync(f.home+'/.ssh/authorized_keys','utf8'),policy=readFileSync(f.root+'/sshd_config.d/090-screenpunk-local.conf','utf8'),receipts=readdirSync(base+'/setup-receipts'),receipt=readFileSync(base+'/setup-receipts/'+receipts[0],'utf8');
 assert.equal(statSync(base+'/transport-token').mode&0o777,0o600);assert.ok(existsSync(f.root+'/qr.png'),'CoreImage should render native QR');assert.ok(statSync(f.root+'/qr.png').size>0);writeFileSync(f.root+'/decode-qr.js',`ObjC.import('Cocoa');ObjC.import('CoreImage');function run(args){var image=$.CIImage.imageWithContentsOfURL($.NSURL.fileURLWithPath($(args[0])));var options=$.NSMutableDictionary.alloc.init;options.setObjectForKey($.CIDetectorAccuracyHigh,$.CIDetectorAccuracy);var detector=$.CIDetector.detectorOfTypeContextOptions($.CIDetectorTypeQRCode,$.CIContext.contextWithOptions($({})),options);var features=detector.featuresInImage(image);var expected=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(args[1]),$.NSUTF8StringEncoding,null));var actual=ObjC.unwrap(features.objectAtIndex(0).messageString);if(Number(features.count)!==1 || actual!==expected)throw Error('Synthetic QR did not round-trip; detector count='+features.count+' actualType='+typeof actual+' actualLength='+(actual||'').length+' expectedType='+typeof expected+' expectedLength='+(expected||'').length);return 'MATCH';}`);const decoded=spawnSync('/usr/bin/osascript',['-l','JavaScript',f.root+'/decode-qr.js',f.root+'/qr.png',f.root+'/reply.json'],{env:f.env,encoding:'utf8'});assert.equal(decoded.status,0,decoded.stderr);assert.equal(decoded.stdout.trim(),'MATCH');const reply=JSON.parse(readFileSync(f.root+'/reply.json','utf8'));assert.equal(reply.appServerToken,token.trim());assert.equal(reply.publicKeySHA256,digest);assert.equal(reply.hostKeySHA256,digest);assert.ok(!r.stdout.includes(token.trim()));assert.ok(!r.stderr.includes(token.trim()));assert.ok(!receipt.includes(token.trim()));assert.equal(reply.host,'fixture-mac.local');assert.ok(keys.includes('restrict,port-forwarding,permitopen="127.0.0.1:4500",command="/usr/bin/false"'));
 r=f.run();success(f,r);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(f.home+'/.ssh/authorized_keys','utf8'),keys);assert.equal(readFileSync(f.root+'/sshd_config.d/090-screenpunk-local.conf','utf8'),policy);assert.equal(readFileSync(base+'/setup-receipts/'+receipts[0],'utf8'),receipt);assert.ok(!existsSync(f.root+'/login'));
 }finally{f.clean();}
});
test('SSH failure rolls back only new policy, adds no key/token and clears private session',()=>{
 const f=fixture();try{const r=f.run({TEST_EFFECTIVE:'allowtcpforwarding yes\npermitlisten any\nallowstreamlocalforwarding yes\npubkeyauthentication yes'});assert.notEqual(r.status,0);assert.match(r.stderr,/Effective SSH policy/);assert.ok(!existsSync(f.root+'/sshd_config.d/090-screenpunk-local.conf'));assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'));assert.ok(!existsSync(f.home+'/.codex/screenpunk-local/transport-token'));}finally{f.clean();}
});
test('unknown port, unapproved saved token, conflicting policy and remote-login denial fail closed',()=>{
 for(const kind of ['port','token','policy','remote','consent']){const f=fixture();try{const extra={};if(kind==='port')extra.TEST_UNKNOWN_PORT='1';if(kind==='token'){extra.TEST_CONSENT_STATUS='1';mkdirSync(f.home+'/.codex',{mode:0o700});mkdirSync(f.home+'/.codex/screenpunk-local',{mode:0o700});writeFileSync(f.home+'/.codex/screenpunk-local/transport-token','2'.repeat(64)+'\n',{mode:0o600});}if(kind==='policy')writeFileSync(f.root+'/sshd_config.d/090-screenpunk-local.conf','Unrelated policy\n');if(kind==='remote')extra.TEST_REMOTE_STATUS='1';if(kind==='consent')extra.TEST_CONSENT_STATUS='1';const r=f.run(extra);assert.notEqual(r.status,0,kind);assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'),kind);if(kind==='policy')assert.equal(readFileSync(f.root+'/sshd_config.d/090-screenpunk-local.conf','utf8'),'Unrelated policy\n');if(kind==='token')assert.equal(readFileSync(f.home+'/.codex/screenpunk-local/transport-token','utf8'),'2'.repeat(64)+'\n');}finally{f.clean();}}
});
test('missing host keys require consent and use fake ssh-keygen -A only',()=>{const f=fixture();try{rmSync(f.root+'/host.pub');success(f,f.run());assert.equal(readFileSync(f.root+'/hostkey-actions','utf8'),'generated\n');}finally{f.clean();}});
test('oversized selection identifies the public iPad file before authorization',()=>{
 const f=fixture();try{writeFileSync(f.root+'/public.json','x'.repeat(8193));const result=f.run();assert.notEqual(result.status,0);assert.match(result.stderr,/Choose Screenpunk-setup-request.json sent from the iPad, not the downloaded Mac setup script/);assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'));assert.ok(!existsSync(f.home+'/.codex/screenpunk-local/transport-token'));}finally{f.clean();}
});
test('address-conditional SSH rules and nested includes cannot bypass account forwarding restriction',()=>{
 for(const text of ['Match Address 192.168.1.*\n AllowTcpForwarding yes\n','Include /another/location/*\n']){const f=fixture();try{writeFileSync(f.root+'/sshd_config.d/001-existing.conf',text);const r=f.run();assert.notEqual(r.status,0);assert.match(r.stderr,/Conditional SSH Match|Nonstandard or nested/);assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'));assert.equal(readFileSync(f.root+'/sshd_config.d/001-existing.conf','utf8'),text);}finally{f.clean();}}
});
test('standard macOS crypto Include is allowed only from 100-macos.conf and only for algorithms',()=>{
 const directory='/fixture/sshd_config.d',crypto='/fixture/crypto.conf';
 assert.equal(context.auditSSHText('UsePAM yes\nInclude '+crypto+'\n','fixture',directory,false,directory+'/100-macos.conf',crypto,false),true);
 assert.doesNotThrow(()=>context.auditSSHText('Ciphers ^aes128-gcm@openssh.com\nKexAlgorithms ^ecdh-sha2-nistp256\nMACs ^hmac-sha2-256\n','fixture',directory,false,crypto,crypto,true));
 for(const text of ['Include /another.conf','Match Address 192.168.1.*','AllowTcpForwarding yes','PermitListen any','Ciphers'])assert.throws(()=>context.auditSSHText(text,'fixture',directory,false,crypto,crypto,true),/crypto\.conf:1/);
 for(const path of [directory+'/001-custom.conf',directory+'/100-macos.conf.backup'])assert.throws(()=>context.auditSSHText('Include '+crypto,'fixture',directory,false,path,crypto,false),/Nonstandard or nested SSH Include/);
 assert.throws(()=>context.auditSSHText('Include '+crypto+' /another.conf','fixture',directory,false,directory+'/100-macos.conf',crypto,false),/Nonstandard or nested SSH Include/);
});
test('crypto policy rejects forwarding, escaped or chained links and writable policy paths',()=>{
 for(const kind of ['forwarding','include','mode','link','chain','dangling','directory-link','directory-mode','newline']){const f=fixture();try{
  if(kind==='forwarding')writeFileSync(f.root+'/crypto.conf','AllowTcpForwarding yes\n');
  if(kind==='include')writeFileSync(f.root+'/crypto.conf','Include /elsewhere/hidden.conf\n');
  if(kind==='mode')chmodSync(f.root+'/crypto.conf',0o666);
  if(kind==='chain'){rmSync(f.root+'/crypto/apple.conf');writeFileSync(f.root+'/crypto/other.conf','Ciphers aes128-gcm@openssh.com\n');symlinkSync('other.conf',f.root+'/crypto/apple.conf');}
  if(kind==='newline'){rmSync(f.root+'/crypto.conf');writeFileSync(f.root+'/crypto/apple.conf\n','Ciphers aes128-gcm@openssh.com\n');symlinkSync('crypto/apple.conf\n',f.root+'/crypto.conf');}
  if(kind==='dangling')rmSync(f.root+'/crypto/apple.conf');
  if(kind==='directory-link'){rmSync(f.root+'/crypto',{recursive:true});mkdirSync(f.root+'/elsewhere');writeFileSync(f.root+'/elsewhere/apple.conf','Ciphers aes128-gcm@openssh.com\n');symlinkSync('elsewhere',f.root+'/crypto');}
  if(kind==='directory-mode')chmodSync(f.root+'/crypto',0o777);
  if(kind==='link'){rmSync(f.root+'/crypto.conf');writeFileSync(f.root+'/target.conf','Ciphers aes128-gcm@openssh.com\n');symlinkSync(f.root+'/target.conf',f.root+'/crypto.conf');}
  const r=f.run();assert.notEqual(r.status,0,kind);assert.match(r.stderr,/crypto|Crypto/,kind);assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'),kind);assert.ok(!existsSync(f.home+'/.codex/screenpunk-local/transport-token'),kind);
 }finally{f.clean();}}
});
test('Apple crypto link, leaf and containing directories must be root-owned',()=>{
 for(const relative of ['crypto.conf','crypto/apple.conf','crypto','sshd_config.d']){const f=fixture();try{const result=f.run({TEST_BAD_OWNER:relative});assert.notEqual(result.status,0,relative);assert.match(result.stderr,/root-owned/);assert.ok(!existsSync(f.home+'/.ssh/authorized_keys'));assert.ok(!existsSync(f.home+'/.codex/screenpunk-local/transport-token'));}finally{f.clean();}}
});
test('stopped legacy setup reuses the same bearer without fabricating creation ownership',()=>{
 const f=fixture();try{success(f,f.run());const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),inode=statSync(base+'/transport-token').ino,keys=readFileSync(f.home+'/.ssh/authorized_keys','utf8');for(const name of ['setup-server.json','setup-token.json'])rmSync(base+'/'+name);
  assert.notEqual(f.run({TEST_CONSENT_STATUS:'1'}).status,0);assert.ok(!existsSync(base+'/setup-token.json'));assert.equal(readFileSync(base+'/transport-token','utf8'),token);
  success(f,f.run());assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(statSync(base+'/transport-token').ino,inode);assert.equal(readFileSync(f.home+'/.ssh/authorized_keys','utf8'),keys);const adoption=JSON.parse(readFileSync(base+'/setup-token.json','utf8'));assert.equal(adoption.origin,'adopted-legacy-token');assert.equal(adoption.pid,0);assert.equal(adoption.start,'not-started');
 }finally{f.clean();}
});
test('adoption receipt publication is single-linked and refuses an existing destination',()=>{
 const f=fixture();try{const destination=f.root+'/adoption.json';const args=['-l','JavaScript','tools/local-agent-setup/macos/native.js','token-adopt',destination,'0','not-started','501:600:123','a'.repeat(64),sha];const first=spawnSync('/usr/bin/osascript',args,{env:f.env,encoding:'utf8'});assert.equal(first.status,0,first.stderr);assert.equal(statSync(destination).nlink,1);const original=readFileSync(destination,'utf8');args[args.length-2]='b'.repeat(64);const again=spawnSync('/usr/bin/osascript',args,{env:f.env,encoding:'utf8'});assert.notEqual(again.status,0);assert.match(again.stderr,/no receipt was overwritten/);assert.equal(readFileSync(destination,'utf8'),original);assert.ok(!readdirSync(f.root).some(n=>n.startsWith('adoption.json.adopt-')));
 }finally{f.clean();}
});
test('running legacy server is preserved behind the manual ownership gate',()=>{
 const f=fixture();try{const cut=f.run({TEST_CUT:'metadata'});assert.equal(cut.signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',pid=Number(readFileSync(f.root+'/server-pid','utf8')),token=readFileSync(base+'/transport-token','utf8'),keys=readFileSync(f.home+'/.ssh/authorized_keys','utf8');for(const name of ['setup-server.json','setup-token.json'])rmSync(base+'/'+name);const result=f.run({},true);assert.notEqual(result.status,0);assert.match(result.stderr,/already running without ownership receipts/);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(f.home+'/.ssh/authorized_keys','utf8'),keys);assert.ok(!existsSync(base+'/setup-token.json'));assert.ok(!existsSync(base+'/setup-server.json'));process.kill(pid,0);
 }finally{f.clean();}
});
test('SIGKILL after token publication resumes from durable provenance without token rotation or stale lock',()=>{
 const f=fixture();try{const killed=f.run({TEST_CUT:'token'});assert.equal(killed.signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8');assert.ok(existsSync(base+'/setup-token.json'));assert.ok(!existsSync(base+'/setup-server.json'));success(f,f.run());assert.equal(readFileSync(base+'/transport-token','utf8'),token);}finally{f.clean();}
});
test('SIGKILL after durable server launch reuses exact owned listener and token',()=>{
 const f=fixture();try{const killed=f.run({TEST_CUT:'metadata'});assert.equal(killed.signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),server=readFileSync(base+'/setup-server.json','utf8');const r=f.run({},true);success(f,r);assert.match(r.stdout,/Reused the verified foreground App Server/);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(base+'/setup-server.json','utf8'),server);}finally{f.clean();}
});
test('failed owned-server restart restores prior receipt and remains retryable',()=>{
 const f=fixture();try{success(f,f.run());const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),server=readFileSync(base+'/setup-server.json','utf8');assert.notEqual(f.run({TEST_FAIL_NATIVE:'reply'}).status,0);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(base+'/setup-server.json','utf8'),server);success(f,f.run());assert.equal(readFileSync(base+'/transport-token','utf8'),token);}finally{f.clean();}
});
test('completed install receipts forbid fresh bearer creation even when all token/server provenance is absent',()=>{
 const f=fixture();try{success(f,f.run());const base=f.home+'/.codex/screenpunk-local';for(const n of ['transport-token','setup-token.json','setup-server.json'])rmSync(base+'/'+n);const r=f.run();assert.notEqual(r.status,0);assert.match(r.stderr,/paired-client receipt exists without its bearer/);assert.ok(!existsSync(base+'/transport-token'));}finally{f.clean();}
});
test('generated script/hash/page/CSP are reproducible and public page has no upload channels',()=>{
 const r=spawnSync(process.execPath,['tools/local-agent-setup/generate.mjs','--check'],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
 const source=readFileSync('services/cloud/src/generated/local-agent-setup.ts','utf8'),script=readFileSync('tools/local-agent-setup/macos/macos.sh','utf8'),generatedHash=createHash('sha256').update(script).digest('hex');assert.ok(source.includes(generatedHash));assert.ok(source.includes('localAgentSetupCSP'));assert.ok(source.includes("connect-src 'none'"));assert.ok(!script.includes('pbcopy'));assert.ok(!script.includes('curl '));assert.ok(!script.includes('python'));assert.ok(!script.includes('node '));assert.match(script,/sp_handoff=1/);
});

// All LaunchAgent calls below use the fixture's fake launchctl and synthetic processes.
test('background opt-in installs a private secret-free LaunchAgent and management preserves credentials',()=>{
 const f=fixture();try{const r=f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'});success(f,r);assert.match(r.stdout,/Terminal can close/);assert.ok(!r.stdout.includes('keep its original Terminal open'));const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service',token=readFileSync(base+'/transport-token','utf8'),keys=readFileSync(f.home+'/.ssh/authorized_keys','utf8'),plist=readFileSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist','utf8'),reply=JSON.parse(readFileSync(f.root+'/reply.json','utf8'));assert.equal(reply.serverLifecycle,'background');assert.match(plist,/<key>KeepAlive<\/key><true\/>/);assert.match(plist,/<key>RunAtLoad<\/key><true\/>/);assert.match(plist,/<integer>30<\/integer>/);assert.ok(!plist.includes(token.trim()));assert.equal(statSync(service+'/manage-v4.sh').mode&0o777,0o700);assert.equal(statSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist').mode&0o777,0o600);assert.equal(f.manage('status').status,0);const first=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));assert.equal(f.manage('restart').status,0);const second=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));assert.notEqual(second.pid,first.pid);assert.equal(second.tokenIdentity,first.tokenIdentity);assert.equal(second.tokenSHA256,first.tokenSHA256);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(f.manage('uninstall').status,0);assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));assert.ok(!existsSync(service+'/manage-v4.sh'));assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(f.home+'/.ssh/authorized_keys','utf8'),keys);assert.ok(existsSync(base+'/workspace'));}finally{f.clean();}
});
test('background startup failure preserves credential and falls back to owned foreground mode',()=>{
 const f=fixture();try{const r=f.run({TEST_SERVICE_MODE:'background',TEST_BOOTSTRAP_STATUS:'1'});success(f,r);assert.match(r.stderr,/Background startup failed/);assert.match(r.stdout,/Keep this Terminal open/);const base=f.home+'/.codex/screenpunk-local';assert.ok(existsSync(base+'/transport-token'));assert.equal(JSON.parse(readFileSync(f.root+'/reply.json','utf8')).serverLifecycle,undefined);assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));assert.equal(JSON.parse(readFileSync(base+'/setup-service/install.json','utf8')).lifecycle,'failed');}finally{f.clean();}
});
test('unknown service label and changed owned files stop without killing jobs or rotating credentials',()=>{
 for(const kind of ['unknown-label','changed-file']){const f=fixture();try{if(kind==='unknown-label'){writeFileSync(f.root+'/job.json',JSON.stringify({pid:999999,control:f.root+'/unrelated.sh'}));assert.notEqual(f.run({TEST_SERVICE_MODE:'background'}).status,0);}else{success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8');writeFileSync(base+'/setup-service/manage-v4.sh','changed source\n');assert.notEqual(f.manage('restart').status,0);assert.equal(readFileSync(base+'/transport-token','utf8'),token);}const actions=JSON.parse(readFileSync(f.root+'/launch-actions.json','utf8'));assert.ok(!actions.some(a=>a[0]==='bootout'),kind);}finally{f.clean();}}
});
test('approved migration stops only verified foreground instance and preserves its token',()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),old=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));const r=f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'},true);success(f,r);const current=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));assert.notEqual(current.pid,old.pid);assert.equal(current.serverLifecycle,'background');assert.equal(readFileSync(base+'/transport-token','utf8'),token);}finally{f.clean();}
});

test('declined foreground migration leaves original server and credential with no autoload plist',()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),old=readFileSync(base+'/setup-server.json','utf8');const r=f.run({TEST_SERVICE_MODE:'background',TEST_CANCEL_MIGRATION:'1',TEST_KEEP_SERVER:'1'},true);assert.notEqual(r.status,0);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(base+'/setup-server.json','utf8'),old);assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));assert.ok(!JSON.parse(readFileSync(f.root+'/launch-actions.json','utf8')).some(a=>a[0]==='bootstrap'||a[0]==='bootout'));}finally{f.clean();}
});
test('post-ready migrated reply failure preserves verified background availability for old pair',()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8');const r=f.run({TEST_SERVICE_MODE:'background',TEST_FAIL_NATIVE:'reply',TEST_KEEP_SERVER:'1'},true);assert.notEqual(r.status,0);assert.match(r.stderr,/verified background server remains enabled/);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(JSON.parse(readFileSync(base+'/setup-server.json','utf8')).serverLifecycle,'background');assert.ok(existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));assert.equal(f.manage('status').status,0);}finally{f.clean();}
});

test('late unknown plist is not overwritten and restored foreground child stops on setup TERM',async()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),child=f.spawn({TEST_SERVICE_MODE:'background',TEST_LATE_PLIST:'1',TEST_KEEP_SERVER:'1'});let stderr='';child.stderr.on('data',d=>stderr+=d);child.stdout.resume();const deadline=Date.now()+14000;while(!stderr.includes('existing connection was restored in this Terminal')&&Date.now()<deadline)await new Promise(r=>setTimeout(r,50));assert.match(stderr,/existing connection was restored in this Terminal/);const restored=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));const closed=new Promise(r=>child.once('close',(code,signal)=>r({code,signal})));child.kill('SIGTERM');await closed;assert.equal(readFileSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist','utf8'),'Unrelated user plist\n');assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.throws(()=>process.kill(restored.pid,0));assert.ok(!JSON.parse(readFileSync(f.root+'/launch-actions.json','utf8')).some(a=>a[0]==='bootstrap'||a[0]==='bootout'));}finally{f.clean();}
});
test('background runner lock survives exec and a new owned instance refreshes receipt without rotation',async()=>{
 const f=fixture();try{success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));const base=f.home+'/.codex/screenpunk-local',token=readFileSync(base+'/transport-token','utf8'),old=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));const locked=spawnSync('/usr/bin/lockf',['-k','-t','0',base+'/setup-service/instance.lock','/usr/bin/true'],{env:f.env,encoding:'utf8'});assert.equal(locked.status,75);process.kill(old.pid,'SIGTERM');await new Promise(r=>setTimeout(r,150));const restarted=spawnSync(f.bin+'/launchctl',['kickstart','gui/'+process.getuid()+'/xyz.screenpunk.local-agent'],{env:f.env,encoding:'utf8'});assert.equal(restarted.status,0,restarted.stderr);const deadline=Date.now()+6000;let current;while(Date.now()<deadline){current=JSON.parse(readFileSync(base+'/setup-server.json','utf8'));if(current.pid!==old.pid)break;await new Promise(r=>setTimeout(r,50));}assert.notEqual(current.pid,old.pid);assert.equal(current.tokenIdentity,old.tokenIdentity);assert.equal(current.tokenSHA256,old.tokenSHA256);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(statSync(base+'/setup-service/instance.lock').mode&0o777,0o600);}finally{f.clean();}
});

test('failed restored foreground startup reaps its exact child and retains original receipt backup',()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',old=JSON.parse(readFileSync(base+'/setup-server.json','utf8')),token=readFileSync(base+'/transport-token','utf8');const r=f.run({TEST_SERVICE_MODE:'background',TEST_LATE_PLIST:'1',TEST_RESTORE_NO_LISTENER:'1',TEST_ORIGINAL_PID:String(old.pid),TEST_KEEP_SERVER:'1'},true);assert.notEqual(r.status,0);assert.match(r.stderr,/foreground restoration needs review/);const restored=Number(readFileSync(f.root+'/server-pid','utf8'));assert.notEqual(restored,old.pid);assert.throws(()=>process.kill(restored,0));assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.ok(readdirSync(base).filter(n=>n.startsWith('setup-session.')).some(n=>existsSync(base+'/'+n+'/server-original.json')));assert.equal(readFileSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist','utf8'),'Unrelated user plist\n');}finally{f.clean();}
});

test('failed retry preserves a preexisting owned autoload plist and its saved credential',async()=>{
 const f=fixture();try{success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));const base=f.home+'/.codex/screenpunk-local',plistPath=f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist',plist=readFileSync(plistPath,'utf8'),token=readFileSync(base+'/transport-token','utf8');const stopped=spawnSync(f.bin+'/launchctl',['bootout','gui/'+process.getuid()+'/xyz.screenpunk.local-agent'],{env:f.env,encoding:'utf8'});assert.equal(stopped.status,0);await new Promise(r=>setTimeout(r,150));const r=f.run({TEST_SERVICE_MODE:'background',TEST_BOOTSTRAP_STATUS:'1'});success(f,r);assert.match(r.stderr,/Background startup failed/);assert.equal(readFileSync(plistPath,'utf8'),plist);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(JSON.parse(readFileSync(f.root+'/reply.json','utf8')).serverLifecycle,undefined);}finally{f.clean();}
});
test('TERM during foreground restoration startup does not orphan the new owned child',async()=>{
 const f=fixture();try{assert.equal(f.run({TEST_CUT:'metadata',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');const base=f.home+'/.codex/screenpunk-local',old=JSON.parse(readFileSync(base+'/setup-server.json','utf8')),child=f.spawn({TEST_SERVICE_MODE:'background',TEST_LATE_PLIST:'1',TEST_RESTORE_NO_LISTENER:'1',TEST_ORIGINAL_PID:String(old.pid),TEST_KEEP_SERVER:'1'});child.stdout.resume();child.stderr.resume();const deadline=Date.now()+12000;let restored=old.pid;while(Date.now()<deadline){if(existsSync(f.root+'/server-pid'))restored=Number(readFileSync(f.root+'/server-pid','utf8'));if(restored!==old.pid)break;await new Promise(r=>setTimeout(r,50));}assert.notEqual(restored,old.pid);const closed=new Promise(r=>child.once('close',r));child.kill('SIGTERM');await closed;assert.throws(()=>process.kill(restored,0));}finally{f.clean();}
});


test('V5 repairs verified V4 helper in place and reuses the same live background process',()=>{
 const f=fixture();try{
  success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
  const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service',oldServer=JSON.parse(readFileSync(base+'/setup-server.json','utf8')),token=readFileSync(base+'/transport-token','utf8'),keys=readFileSync(f.home+'/.ssh/authorized_keys','utf8');
  const frozen=readFileSync('tools/local-agent-setup/releases/v4/macos.sh','utf8'),oldNative=frozen.split("<<'SCREENPUNK_NATIVE_JS'\n")[1].split('\nSCREENPUNK_NATIVE_JS\n')[0]+'\n';
  assert.equal(createHash('sha256').update(oldNative).digest('hex'),'e3090e5962e34250a0cdaa011fbe39802a7ef20dd987b95bde9039836442842c');
  writeFileSync(service+'/native-v4.js',oldNative);const manifest=JSON.parse(readFileSync(service+'/install.json','utf8'));manifest.nativeSHA256='e3090e5962e34250a0cdaa011fbe39802a7ef20dd987b95bde9039836442842c';manifest.lifecycle='prepared';writeFileSync(service+'/install.json',JSON.stringify(manifest));
  const before=JSON.parse(readFileSync(f.root+'/launch-actions.json','utf8')).filter(a=>a[0]==='bootstrap'||a[0]==='bootout'||a[0]==='kickstart');
  success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'},true));
  assert.equal(JSON.parse(readFileSync(base+'/setup-server.json','utf8')).pid,oldServer.pid);assert.equal(readFileSync(base+'/transport-token','utf8'),token);assert.equal(readFileSync(f.home+'/.ssh/authorized_keys','utf8'),keys);
  assert.equal(readFileSync(service+'/native-upgrade-v5/original-native-v4.js','utf8'),oldNative);assert.equal(JSON.parse(readFileSync(service+'/native-upgrade-v5/journal.json','utf8')).lifecycle,'completed');
  // Normal readiness changes installation lifecycle metadata after repair.
  assert.equal(JSON.parse(readFileSync(service+'/install.json','utf8')).lifecycle,'enabled');success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'},true));
  assert.equal(JSON.parse(readFileSync(base+'/setup-server.json','utf8')).pid,oldServer.pid);assert.deepEqual(JSON.parse(readFileSync(f.root+'/launch-actions.json','utf8')).filter(a=>a[0]==='bootstrap'||a[0]==='bootout'||a[0]==='kickstart'),before);
 }finally{f.clean();}
});


test('uninstall then actual public setup flow re-enables background with the unchanged owned credential',async()=>{
 const f=fixture();try{
  f.setSetupSource(readFileSync('tools/local-agent-setup/releases/v5/macos.sh','utf8'));
  success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
  const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service',token=readFileSync(base+'/transport-token'),keys=readFileSync(f.home+'/.ssh/authorized_keys'),tokenInode=statSync(base+'/transport-token').ino;
  assert.equal(f.manage('uninstall').status,0);
  await new Promise(r=>setTimeout(r,150));
  assert.equal(JSON.parse(readFileSync(service+'/install.json')).lifecycle,'uninstalled');
  for(const name of ['manage-v4.sh','native-v4.js','agent-v4.plist'])assert.ok(!existsSync(service+'/'+name));
  f.setSetupSource(candidateSetupScript());
  success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
  assert.equal(JSON.parse(readFileSync(service+'/install.json')).lifecycle,'enabled');
  assert.equal(JSON.parse(readFileSync(f.root+'/reply.json')).serverLifecycle,'background');
  assert.deepEqual(readFileSync(base+'/transport-token'),token);assert.equal(statSync(base+'/transport-token').ino,tokenInode);assert.deepEqual(readFileSync(f.home+'/.ssh/authorized_keys'),keys);
 }finally{f.clean();}
});


async function uninstalledPublishedV5(f,repair=false){
 f.setSetupSource(readFileSync('tools/local-agent-setup/releases/v5/macos.sh','utf8'));
 success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
 const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service';
 if(repair){
  const frozen=readFileSync('tools/local-agent-setup/releases/v4/macos.sh','utf8'),old=frozen.split("<<'SCREENPUNK_NATIVE_JS'\n")[1].split('\nSCREENPUNK_NATIVE_JS\n')[0]+'\n';
  writeFileSync(service+'/native-v4.js',old);const manifest=JSON.parse(readFileSync(service+'/install.json'));manifest.nativeSHA256=createHash('sha256').update(old).digest('hex');manifest.lifecycle='prepared';writeFileSync(service+'/install.json',JSON.stringify(manifest));
  success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'},true));
 }
 const snapshot={base,service,token:readFileSync(base+'/transport-token'),tokenInode:statSync(base+'/transport-token').ino,keys:readFileSync(f.home+'/.ssh/authorized_keys')};
 assert.equal(f.manage('uninstall').status,0);await new Promise(r=>setTimeout(r,150));
 snapshot.manifest=readFileSync(service+'/install.json');snapshot.actions=JSON.parse(readFileSync(f.root+'/launch-actions.json')).filter(a=>['bootstrap','bootout','kickstart'].includes(a[0]));
 f.setSetupSource(candidateSetupScript());return snapshot;
}
test('repaired V4 uninstall then current setup preserves the original repair journal and re-enables',async()=>{
 const f=fixture();try{const s=await uninstalledPublishedV5(f,true),backup=s.service+'/native-upgrade-v5',journal=readFileSync(backup+'/journal.json'),original=readFileSync(backup+'/original-install-v4.json');
 success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
 assert.equal(JSON.parse(readFileSync(s.service+'/install.json')).lifecycle,'enabled');assert.equal(JSON.parse(readFileSync(f.root+'/reply.json')).serverLifecycle,'background');
 assert.deepEqual(readFileSync(backup+'/journal.json'),journal);assert.deepEqual(readFileSync(backup+'/original-install-v4.json'),original);assert.deepEqual(readFileSync(s.base+'/transport-token'),s.token);assert.equal(statSync(s.base+'/transport-token').ino,s.tokenInode);
 assert.match(readFileSync(f.root+'/consent-messages','utf8'),/Re-enable the verified Screenpunk/);
 }finally{f.clean();}
});
test('uninstalled startup can choose Terminal only without background re-enable consent or files',async()=>{
 const f=fixture();try{const s=await uninstalledPublishedV5(f);success(f,f.run({TEST_SERVICE_MODE:'foreground'}));
 assert.equal(JSON.parse(readFileSync(s.service+'/install.json')).lifecycle,'uninstalled');assert.equal(JSON.parse(readFileSync(f.root+'/reply.json')).serverLifecycle,undefined);
 assert.doesNotMatch(readFileSync(f.root+'/consent-messages','utf8'),/Re-enable the verified Screenpunk/);
 for(const name of ['manage-v4.sh','native-v4.js','agent-v4.plist'])assert.ok(!existsSync(s.service+'/'+name));assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));
 assert.deepEqual(readFileSync(s.base+'/transport-token'),s.token);assert.deepEqual(JSON.parse(readFileSync(f.root+'/launch-actions.json')).filter(a=>['bootstrap','bootout','kickstart'].includes(a[0])),s.actions);
 }finally{f.clean();}
});
test('declining background re-enable leaves the uninstall receipt, credential and missing files unchanged',async()=>{
 const f=fixture();try{const s=await uninstalledPublishedV5(f),r=f.run({TEST_SERVICE_MODE:'background',TEST_CANCEL_REENABLE:'1'});assert.notEqual(r.status,0);assert.match(readFileSync(f.root+'/consent-messages','utf8'),/Re-enable the verified Screenpunk/);
 assert.deepEqual(readFileSync(s.service+'/install.json'),s.manifest);assert.deepEqual(readFileSync(s.base+'/transport-token'),s.token);assert.equal(statSync(s.base+'/transport-token').ino,s.tokenInode);assert.deepEqual(readFileSync(f.home+'/.ssh/authorized_keys'),s.keys);
 for(const name of ['manage-v4.sh','native-v4.js','agent-v4.plist'])assert.ok(!existsSync(s.service+'/'+name));assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));
 assert.deepEqual(JSON.parse(readFileSync(f.root+'/launch-actions.json')).filter(a=>['bootstrap','bootout','kickstart'].includes(a[0])),s.actions);
 }finally{f.clean();}
});
for(const kind of ['manifest','token','helper','plist','loaded-label'])test('uninstalled recovery rejects unknown '+kind+' before re-enable consent or mutation',async()=>{
 const f=fixture();try{const s=await uninstalledPublishedV5(f);let target;
 if(kind==='manifest'){target=s.service+'/install.json';const m=JSON.parse(readFileSync(target));m.nativeSHA256='0'.repeat(64);writeFileSync(target,JSON.stringify(m));}
 if(kind==='token'){target=s.base+'/transport-token';writeFileSync(target,'f'.repeat(64)+'\n');}
 if(kind==='helper'){target=s.service+'/native-v4.js';writeFileSync(target,'unknown helper\n',{mode:0o600});}
 if(kind==='plist'){target=f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist';writeFileSync(target,'unknown plist\n',{mode:0o600});}
 if(kind==='loaded-label'){target=f.root+'/job.json';writeFileSync(target,JSON.stringify({pid:999999,control:f.root+'/unrelated.sh'}));}
 const bytes=readFileSync(target),before=JSON.parse(readFileSync(f.root+'/launch-actions.json')).filter(a=>['bootstrap','bootout','kickstart'].includes(a[0]));
 assert.notEqual(f.run({TEST_SERVICE_MODE:'background'}).status,0);assert.deepEqual(readFileSync(target),bytes);
 assert.doesNotMatch(readFileSync(f.root+'/consent-messages','utf8'),/Re-enable the verified Screenpunk/);
 assert.ok(!existsSync(s.service+'/manage-v4.sh'));assert.ok(!existsSync(s.service+'/agent-v4.plist'));if(kind!=='helper')assert.ok(!existsSync(s.service+'/native-v4.js'));
 assert.deepEqual(JSON.parse(readFileSync(f.root+'/launch-actions.json')).filter(a=>['bootstrap','bootout','kickstart'].includes(a[0])),before);
 }finally{f.clean();}
});

test('public V5 interrupted after prepared service receipt resumes missing owned files with current setup',()=>{
 const f=fixture();try{
  f.setSetupSource(readFileSync('tools/local-agent-setup/releases/v5/macos.sh','utf8'));
  assert.equal(f.run({TEST_SERVICE_MODE:'background',TEST_CUT:'service-prepare',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');
  const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service',token=readFileSync(base+'/transport-token'),inode=statSync(base+'/transport-token').ino,keys=readFileSync(f.home+'/.ssh/authorized_keys');
  assert.equal(JSON.parse(readFileSync(service+'/install.json')).lifecycle,'prepared');
  for(const name of ['manage-v4.sh','native-v4.js','agent-v4.plist'])assert.ok(!existsSync(service+'/'+name));
  f.setSetupSource(candidateSetupScript());success(f,f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1'}));
  assert.equal(JSON.parse(readFileSync(service+'/install.json')).lifecycle,'enabled');assert.equal(JSON.parse(readFileSync(f.root+'/reply.json')).serverLifecycle,'background');
  assert.deepEqual(readFileSync(base+'/transport-token'),token);assert.equal(statSync(base+'/transport-token').ino,inode);assert.deepEqual(readFileSync(f.home+'/.ssh/authorized_keys'),keys);
 }finally{f.clean();}
});


for(const kind of ['known-partial','cancel','unknown-partial'])test('prepared missing-files recovery: '+kind,()=>{
 const f=fixture();try{
  f.setSetupSource(readFileSync('tools/local-agent-setup/releases/v5/macos.sh','utf8'));
  assert.equal(f.run({TEST_SERVICE_MODE:'background',TEST_CUT:'service-prepare',TEST_KEEP_SERVER:'1'}).signal,'SIGKILL');
  const base=f.home+'/.codex/screenpunk-local',service=base+'/setup-service',manifest=readFileSync(service+'/install.json'),token=readFileSync(base+'/transport-token');let inode;
  if(kind==='known-partial'){
   const session=readdirSync(base).find(n=>n.startsWith('setup-session.'));
   writeFileSync(service+'/native-v4.js',readFileSync(base+'/'+session+'/native.js'),{mode:0o600});inode=statSync(service+'/native-v4.js').ino;
  }
  if(kind==='unknown-partial')writeFileSync(service+'/native-v4.js','unknown partial helper\n',{mode:0o600});
  f.setSetupSource(candidateSetupScript());const r=f.run({TEST_SERVICE_MODE:'background',TEST_KEEP_SERVER:'1',TEST_CANCEL_RESUME:kind==='cancel'?'1':'0'});
  if(kind==='known-partial'){success(f,r);assert.equal(statSync(service+'/native-v4.js').ino,inode);assert.equal(JSON.parse(readFileSync(service+'/install.json')).lifecycle,'enabled');assert.match(readFileSync(f.root+'/consent-messages','utf8'),/Resume the verified interrupted Screenpunk/);}
  else{assert.notEqual(r.status,0);assert.deepEqual(readFileSync(service+'/install.json'),manifest);assert.ok(!existsSync(service+'/manage-v4.sh'));assert.ok(!existsSync(service+'/agent-v4.plist'));assert.ok(!existsSync(f.home+'/Library/LaunchAgents/xyz.screenpunk.local-agent.plist'));if(kind==='unknown-partial'){assert.equal(readFileSync(service+'/native-v4.js','utf8'),'unknown partial helper\n');assert.doesNotMatch(readFileSync(f.root+'/consent-messages','utf8'),/Resume the verified interrupted Screenpunk/);}else assert.ok(!existsSync(service+'/native-v4.js'));}
  assert.deepEqual(readFileSync(base+'/transport-token'),token);
 }finally{f.clean();}
});
