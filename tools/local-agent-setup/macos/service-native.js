/* Native support for the optional user-consented LaunchAgent. No network APIs. */
var screenpunkServiceLabel = 'xyz.screenpunk.local-agent';
function serviceXML(value) { return String(value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;'); }
function serviceManifest(path) {
    var m=JSON.parse(read(path));
    if(m.schemaVersion!==1 || m.kind!=='screenpunk.launchagent.v1' || m.label!==screenpunkServiceLabel || m.version!=='4' || !Number.isSafeInteger(m.uid) || m.uid<0 || !bounded(m.home,1024) || m.home[0]!=='/' || m.serviceDirectory!==m.home+'/.codex/screenpunk-local/setup-service' || m.plistPath!==m.home+'/Library/LaunchAgents/'+m.label+'.plist' || m.controlPath!==m.serviceDirectory+'/manage-v4.sh' || m.nativePath!==m.serviceDirectory+'/native-v4.js' || m.cachedPlistPath!==m.serviceDirectory+'/agent-v4.plist' || m.domain!=='gui/'+m.uid || m.binarySHA256!=='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e' || !/^[0-9]+:600:[0-9]+$/.test(m.tokenIdentity) || !/^[a-f0-9]{64}$/.test(m.tokenSHA256)) fail('Unknown background-service ownership receipt; no service was changed');
    ['controlSHA256','nativeSHA256','plistSHA256'].forEach(function(k){if(!/^[a-f0-9]{64}$/.test(m[k])) fail('Invalid background-service file receipt');});
    if(['prepared','enabled','failed','uninstalled'].indexOf(m.lifecycle)<0 || m.consent!==true) fail('Background startup was not authorized');
    return m;
}
// `launchctl list label` emits a diagnostic dictionary, not an OpenStep/XML
// plist: array elements are semicolon-delimited and the outer brace may end in
// a semicolon. Parse only this observed format; never eval or guess a format.
function parseLaunchctlJobInformation(text) {
    function bad(reason) { fail('Cannot verify LaunchAgent job information: '+reason+'; no job was stopped'); }
    if(typeof text!=='string' || !text.length || utf8Bytes(text)>65536) bad('output exceeds the supported bound');
    var index=0, nodes=0;
    function whitespace() { while(index<text.length && /[ \t\r\n]/.test(text[index])) index++; }
    function expect(character) { whitespace();if(text[index]!==character) bad('malformed diagnostic dictionary');index++; }
    function quoted() {
        whitespace();if(text[index]!== '"') bad('quoted string required');
        var start=index++;
        while(index<text.length) {
            if(text[index]==='\\') {index+=2;continue;}
            if(text[index]==='"') {index++;var value;try{value=JSON.parse(text.slice(start,index));if(utf8Bytes(value)>4096 || /[\x00-\x1f\x7f]/.test(value))bad('unsupported string');}catch(_){bad('invalid quoted string');}return value;}
            index++;
        }
        bad('unterminated quoted string');
    }
    function value(depth) {
        if(depth>4 || ++nodes>256) bad('output is too complex');
        whitespace();var character=text[index];
        if(character==='"') return quoted();
        if(character==='{') {
            index++;var object=Object.create(null), count=0;whitespace();
            while(text[index]!=='}') {
                if(index>=text.length || ++count>64) bad('dictionary is too large or incomplete');
                var key=quoted();if(!key || Object.prototype.hasOwnProperty.call(object,key))bad('duplicate or empty field');
                expect('=');object[key]=value(depth+1);expect(';');whitespace();
            }
            index++;return object;
        }
        if(character==='(') {
            index++;var array=[];whitespace();
            while(text[index]!==')') {if(index>=text.length || array.length>=64)bad('array is too large or incomplete');array.push(value(depth+1));expect(';');whitespace();}
            index++;return array;
        }
        var token=/^(?:true|false|-?(?:0|[1-9][0-9]*))/.exec(text.slice(index));
        if(!token)bad('unsupported diagnostic value');index+=token[0].length;
        if(token[0]==='true')return true;if(token[0]==='false')return false;
        var number=Number(token[0]);if(!Number.isSafeInteger(number))bad('integer is out of range');return number;
    }
    whitespace();if(text[index]!=='{')bad('unsupported output format');var job=value(0);whitespace();if(text[index]===';'){index++;whitespace();}if(index!==text.length)bad('trailing output');
    if(!job || Array.isArray(job) || typeof job!=='object' || typeof job.Label!=='string' || !Array.isArray(job.ProgramArguments) || job.ProgramArguments.length!==3 || !job.ProgramArguments.every(function(v){return typeof v==='string';}) || (job.Program!==undefined && typeof job.Program!=='string'))bad('invalid identity field shape');
    if(job.PID!==undefined && (typeof job.PID!=='number' || !Number.isSafeInteger(job.PID) || job.PID<0 || job.PID>2147483647))bad('invalid process identity');
    if(job.LastExitStatus!==undefined && (typeof job.LastExitStatus!=='number'||!Number.isSafeInteger(job.LastExitStatus)||job.LastExitStatus< -2147483648||job.LastExitStatus>2147483647))bad('invalid exit status');
    if(job.OnDemand!==undefined && typeof job.OnDemand!=='boolean')bad('invalid demand state');
    ['StandardOutPath','StandardErrorPath','LimitLoadToSessionType'].forEach(function(k){if(job[k]!==undefined && typeof job[k]!=='string')bad('invalid advisory field shape');});
    return job;
}
function serviceAction(args) {
    var action=args[0];
    if(action==='service-choice') {
        var result=nativeApp().displayDialog('Keep Screenpunk available after closing Terminal? Enable background startup installs a LaunchAgent for your Mac account and starts the same private local server now and whenever you sign in. It restarts if the server exits. Your Mac must stay awake and you must be logged in; logout stops it, and reboot requires login. Existing SSH keys and the saved credential are unchanged. Choose Terminal only for the foreground alternative.',{withTitle:'Screenpunk background startup',buttons:['Cancel','Terminal only','Enable background startup'],defaultButton:'Enable background startup',cancelButton:'Cancel'});
        return result.buttonReturned==='Enable background startup'?'background':'foreground';
    }
    if(action==='service-plist') {
        var home=args[2], uid=Number(args[3]), dir=home+'/.codex/screenpunk-local/setup-service';
        if(!bounded(home,1024) || home[0]!=='/' || !Number.isSafeInteger(uid) || uid<0) fail('Invalid background-service account');
        var xml='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'
        +'<key>Label</key><string>'+screenpunkServiceLabel+'</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>'+serviceXML(dir+'/manage-v4.sh')+'</string><string>run</string></array>'
        +'<key>EnvironmentVariables</key><dict><key>HOME</key><string>'+serviceXML(home)+'</string><key>CODEX_HOME</key><string>'+serviceXML(home+'/.codex/screenpunk-local')+'</string><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>'
        +'<key>WorkingDirectory</key><string>'+serviceXML(home+'/.codex/screenpunk-local/workspace')+'</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer><key>ProcessType</key><string>Background</string><key>LimitLoadToSessionType</key><string>Aqua</string><key>Umask</key><integer>63</integer><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>\n';
        write(args[1],xml);return;
    }
    if(action==='service-prepare') {
        var home=args[3], dir=home+'/.codex/screenpunk-local/setup-service', manifest={schemaVersion:1,kind:'screenpunk.launchagent.v1',version:'4',label:screenpunkServiceLabel,uid:Number(args[4]),home:home,domain:'gui/'+args[4],serviceDirectory:dir,plistPath:home+'/Library/LaunchAgents/'+screenpunkServiceLabel+'.plist',controlPath:dir+'/manage-v4.sh',nativePath:dir+'/native-v4.js',cachedPlistPath:dir+'/agent-v4.plist',tokenIdentity:args[5],tokenSHA256:args[6],binarySHA256:args[7],controlSHA256:args[8],nativeSHA256:args[9],plistSHA256:args[10],lifecycle:'prepared',consent:true,createdAt:Date.now()};
        if($.NSFileManager.defaultManager.fileExistsAtPath($(args[1]))) {
            var old=serviceManifest(args[1]);Object.keys(manifest).forEach(function(k){if(['lifecycle','createdAt'].indexOf(k)<0 && old[k]!==manifest[k]) fail('Existing background-service ownership conflicts; no files were overwritten');});return;
        }
        var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(dir),null));
        if(!names || names.length) fail('Unknown files exist in the background-service directory; review them before installing');
        if($.NSFileManager.defaultManager.fileExistsAtPath($(manifest.plistPath))) fail('An unknown LaunchAgent plist already exists; it was not replaced');
        write(args[1],JSON.stringify(manifest));return;
    }
    if(action==='service-files') {
        var m=serviceManifest(args[1]), source=args[2];
        [[source+'/service-control.sh',m.controlPath,448],[source+'/native.js',m.nativePath,384],[source+'/service.plist',m.cachedPlistPath,384]].forEach(function(v){if(!$.NSFileManager.defaultManager.fileExistsAtPath($(v[1]))) {write(v[1],read(v[0]));if(!$.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({NSFilePosixPermissions:v[2]}),$(v[1]),null)) fail('Cannot set private service file permissions');syncPath(v[1]);}});return;
    }
    if(action==='service-validate') {
        var m=serviceManifest(args[1]);
        if(m.home!==args[2] || String(m.uid)!==args[3] || m.tokenIdentity!==args[4] || m.tokenSHA256!==args[5] || m.controlSHA256!==args[6] || m.nativeSHA256!==args[7] || m.plistSHA256!==args[8]) fail('Background-service files or saved credential changed; nothing was stopped');
        if(args[9]) {field(args[9],'service-domain',m.domain);field(args[9],'service-lifecycle',m.lifecycle);} return;
    }
    if(action==='service-job') {
        var m=serviceManifest(args[1]);
        var attributes=ObjC.deepUnwrap($.NSFileManager.defaultManager.attributesOfItemAtPathError($(args[2]),Ref()));
        if(!attributes || attributes.NSFileType!=='NSFileTypeRegular' || typeof attributes.NSFileSize!=='number' || attributes.NSFileSize<1 || attributes.NSFileSize>65536) fail('Cannot verify LaunchAgent job information: unsupported output file; no job was stopped');
        var job=parseLaunchctlJobInformation(read(args[2])), expected=['/bin/sh',m.controlPath,'run'];
        if(job.Label!==m.label || JSON.stringify(job.ProgramArguments)!==JSON.stringify(expected) || (job.Program!==undefined && job.Program!=='/bin/sh')) fail('The LaunchAgent label belongs to an unknown job; nothing was stopped');
        field(args[3],'service-job-pid',job.PID===undefined?0:job.PID);return;
    }
    if(action==='service-state') {var m=serviceManifest(args[1]);if(['enabled','failed','uninstalled'].indexOf(args[2])<0) fail('Invalid service state');m.lifecycle=args[2];m.updatedAt=Date.now();write(args[1],JSON.stringify(m));return;}
    if(action==='service-server-write') {
        var m=serviceManifest(args[1]);write(args[2],JSON.stringify({schemaVersion:1,pid:Number(args[3]),start:args[4],tokenIdentity:m.tokenIdentity,tokenSHA256:m.tokenSHA256,binarySHA256:m.binarySHA256,serverLifecycle:'background',serviceLabel:m.label,serviceDirectory:m.serviceDirectory}));return;
    }
    if(action==='service-ready') {
        var m=serviceManifest(args[1]), s=JSON.parse(read(args[2]));
        if(s.serverLifecycle!=='background'||s.serviceLabel!==m.label||s.serviceDirectory!==m.serviceDirectory||String(s.pid)!==args[3]||s.start!==args[4]||s.tokenIdentity!==m.tokenIdentity||s.tokenSHA256!==m.tokenSHA256||s.binarySHA256!==m.binarySHA256)fail('Background listener ownership is not verified');return;
    }
    if(action==='service-status') {var m=serviceManifest(args[1]);write(m.serviceDirectory+'/status.json',JSON.stringify({schemaVersion:1,lifecycle:m.lifecycle,stage:args[2],updatedAt:Date.now(),note:'No server request, reply, bearer or account payload is logged. Client connection diagnostics provide protocol errors.'}));return;}
    if(action==='service-copy-plist') {
        var m=serviceManifest(args[1]), text=read(m.cachedPlistPath), fm=$.NSFileManager.defaultManager;
        [m.home+'/Library',m.home+'/Library/LaunchAgents'].forEach(function(path){var a=ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(path),Ref()));if(!a||a.NSFileType!=='NSFileTypeDirectory'||[0,m.uid].indexOf(Number(a.NSFileOwnerAccountID))<0||(Number(a.NSFilePosixPermissions)&18)!==0)fail('LaunchAgent parent ownership changed during review');});
        var a=ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(m.plistPath),Ref()));
        if(a){if(a.NSFileType!=='NSFileTypeRegular'||Number(a.NSFileOwnerAccountID)!==m.uid||Number(a.NSFilePosixPermissions)!==384||Number(a.NSFileReferenceCount)!==1||read(m.plistPath)!==text)fail('An unknown LaunchAgent plist appeared during review; it was not overwritten');return 'existing';}
        var temporary=m.plistPath+'.prepare-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        try{write(temporary,text);if($.renamex_np(temporary,m.plistPath,4)!==0)fail('LaunchAgent publication lost ownership; no plist was overwritten');}finally{$.unlink(temporary);}
        syncPath(m.plistPath);return 'created';
    }
    fail('Unknown background-service action');
}
