// Explicit graphical smoke test. Opens two synthetic dialogs, each expiring after two seconds.
// No pairing request, bearer, SSH/system command, Codex, credential or real HOME is accessed.
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,mkdirSync,realpathSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {spawnSync} from 'node:child_process';
const evidenceRoot=resolve(process.env.SCREENPUNK_SETUP_TEST_ROOT || '.task/phase1/phase2/next-round/evidence/mac-setup');
const testOwner=process.env.SCREENPUNK_SETUP_TEST_OWNER || 'screenpunk-one/mac-setup-tests';
const scratch=join(evidenceRoot,'fixtures');
mkdirSync(scratch,{recursive:true,mode:0o700});
const owned=[];
for(const qr of [false,true]){
 const root=realpathSync(mkdtempSync(join(scratch,'native-display-')));
 const resource={path:root,owner:testOwner,purpose:'synthetic native display expiry only',lifecycle:'active'};owned.push(resource);
 try{
  mkdirSync(root+'/home',{mode:0o700});mkdirSync(root+'/tmp',{mode:0o700});
  const source=readFileSync('tools/local-agent-setup/macos/native.js','utf8').replace("    alert.addButtonWithTitle('Done');","    var copy=ObjC.unwrap(alert.informativeText); if(reply.serverLifecycle==='background'){if(copy.indexOf('Terminal can close')<0||copy.indexOf('Keep Terminal open')>=0)fail('Background lifecycle copy is incorrect');}else if(copy.indexOf('Keep Terminal open')<0)fail('Foreground lifecycle copy is incorrect'); alert.addButtonWithTitle('Done');");
  writeFileSync(root+'/native.js',source+`
function run(args){${qr?'renderQR("SYNTHETIC SCREENPUNK DISPLAY TEST ONLY",args[0]+"/connection.png");':''}write(args[0]+"/private-reply.json",JSON.stringify({computerName:"SYNTHETIC EXPIRY TEST",serverLifecycle:"${qr?'background':'foreground'}",expiresAt:Date.now()+2000}));showReply(args[0]);}
`);
  const started=Date.now(),result=spawnSync('/usr/bin/osascript',['-l','JavaScript',root+'/native.js',root],{env:{HOME:root+'/home',PATH:'/usr/bin:/bin',TMPDIR:root+'/tmp'},encoding:'utf8',timeout:6000}),elapsed=Date.now()-started;
  assert.equal(result.status,0,result.stderr);assert.ok(elapsed>=1800 && elapsed<6000,'Native dialog must actually wait, then expire');
  console.log(`Synthetic native ${qr?'background QR':'foreground private-file fallback'} display expired: status=0 durationMs=${elapsed}`);
 }finally{rmSync(root,{recursive:true});resource.lifecycle='removed';writeFileSync(join(evidenceRoot,'display-fixture-ownership.json'),JSON.stringify(owned,null,2));}
}
