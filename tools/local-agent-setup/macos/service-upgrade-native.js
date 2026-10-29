/* Setup-only, consent-gated repair of the known V4 parser. No service/network APIs. */
var screenpunkV4NativeSHA256='e3090e5962e34250a0cdaa011fbe39802a7ef20dd987b95bde9039836442842c';
var screenpunkV4ControlSHA256='5aae5398e4563d8d8fa96ebadbc8641339079587d1b0bd2ac95d91fba30f4e24';
ObjC.bindFunction('getuid',['unsigned int',[]]);
function upgradeServiceV4(args) {
    var operation=args[1], manifestPath=args[2], home=args[3], uid=Number(args[4]), source=args[5], controlSource=args[6];
    var fm=$.NSFileManager.defaultManager;
    function reject(){fail('Background helper repair ownership does not match the reviewed V4 installation. Nothing was stopped, restarted or rotated.');}
    if(['inspect','prepare','apply'].indexOf(operation)<0 || !Number.isSafeInteger(uid) || uid!==Number($.getuid()) || !bounded(home,1024) || home[0]!=='/' || /\/\//.test(home) || home.split('/').some(function(p){return p==='.'||p==='..';}) || ObjC.unwrap($(home).stringByResolvingSymlinksInPath)!==home) reject();
    var dir=home+'/.codex/screenpunk-local/setup-service', backup=dir+'/native-upgrade-v5';
    var journalPath=backup+'/journal.json', originalNative=backup+'/original-native-v4.js', originalManifest=backup+'/original-install-v4.json', nextNative=backup+'/replacement-native-v4.js', nextManifest=backup+'/replacement-install-v4.json';
    if(manifestPath!==dir+'/install.json') reject();
    function attrs(path){return ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(path),Ref()));}
    function directory(path,strict){var a=attrs(path);if(!a||a.NSFileType!=='NSFileTypeDirectory'||Number(a.NSFileOwnerAccountID)!==uid||(strict?Number(a.NSFilePosixPermissions)!==448:(Number(a.NSFilePosixPermissions)&18)!==0))reject();}
    function file(path,mode,max){var a=attrs(path);if(!a||a.NSFileType!=='NSFileTypeRegular'||Number(a.NSFileOwnerAccountID)!==uid||Number(a.NSFilePosixPermissions)!==mode||Number(a.NSFileReferenceCount)!==1||Number(a.NSFileSize)>max)reject();return String(a.NSFileSystemNumber)+':'+String(a.NSFileSystemFileNumber)+':'+String(a.NSFileSize);}
    function hash(path,mode,max){var identity=file(path,mode,max), task=$.NSTask.alloc.init, pipe=$.NSPipe.pipe, errors=$.NSPipe.pipe;task.launchPath='/usr/bin/shasum';task.arguments=$(['-a','256',path]);task.standardOutput=pipe;task.standardError=errors;task.launch;var data=pipe.fileHandleForReading.readDataToEndOfFile;task.waitUntilExit;if(Number(task.terminationStatus)!==0||file(path,mode,max)!==identity)reject();var text=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data,$.NSUTF8StringEncoding));if(typeof text!=='string'||!/^[a-f0-9]{64} /.test(text))reject();return text.slice(0,64);}
    function exclusive(path,text){
        if(attrs(path))reject();
        // Stage in the already verified private setup session, not the strict
        // backup inventory. A crash before rename preserves this exact orphan
        // for review without blocking journal-driven recovery of the targets.
        var temporary=source.slice(0,source.lastIndexOf('/'))+'/service-upgrade-stage-'+path.slice(path.lastIndexOf('/')+1)+'-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        write(temporary,text);
        if($.renamex_np(temporary,path,4)!==0)reject();
        syncDirectory(source.slice(0,source.lastIndexOf('/')));syncPath(path);
    }
    function backupFile(path,text,expected){if(attrs(path)){if(hash(path,384,1048576)!==expected)reject();return;}exclusive(path,text);if(hash(path,384,1048576)!==expected)reject();}
    directory(home,false);directory(home+'/.codex',false);directory(home+'/.codex/screenpunk-local',true);directory(dir,true);
    if(typeof source!=='string'||typeof controlSource!=='string'||source[0]!=='/'||controlSource[0]!=='/'||source.slice(0,source.lastIndexOf('/'))!==controlSource.slice(0,controlSource.lastIndexOf('/')))reject();
    directory(source.slice(0,source.lastIndexOf('/')),true);
    file(source,384,1048576);file(controlSource,384,1048576);
    var newSHA=hash(source,384,1048576);if(newSHA===screenpunkV4NativeSHA256||hash(controlSource,384,1048576)!==screenpunkV4ControlSHA256)reject();
    function snapshot(){
        file(manifestPath,384,16384);var m=serviceManifest(manifestPath);
        if(m.home!==home||m.uid!==uid||m.controlSHA256!==screenpunkV4ControlSHA256)reject();
        directory(home+'/Library',false);directory(home+'/Library/LaunchAgents',false);
        if(hash(m.controlPath,448,1048576)!==screenpunkV4ControlSHA256||hash(m.cachedPlistPath,384,16384)!==m.plistSHA256)reject();
        if(attrs(m.plistPath)&&hash(m.plistPath,384,16384)!==m.plistSHA256)reject();
        var tokenPath=home+'/.codex/screenpunk-local/transport-token';file(tokenPath,384,65);
        var a=attrs(tokenPath);if(Number(a.NSFileSize)!==65||m.tokenIdentity!==uid+':600:'+String(a.NSFileSystemFileNumber)||hash(tokenPath,384,65)!==m.tokenSHA256)reject();
        var nativeSHA=hash(m.nativePath,384,1048576), manifestSHA=hash(manifestPath,384,16384);
        if([screenpunkV4NativeSHA256,newSHA].indexOf(nativeSHA)<0||[screenpunkV4NativeSHA256,newSHA].indexOf(m.nativeSHA256)<0)reject();
        return {m:m,nativeSHA:nativeSHA,manifestSHA:manifestSHA,tokenIdentity:file(tokenPath,384,65)};
    }
    var initial=snapshot(), journal=null;
    function loadJournal(){
        if(!attrs(backup))return null;directory(backup,true);
        var names=ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError($(backup),null)), allowed=['journal.json','original-native-v4.js','original-install-v4.json','replacement-native-v4.js','replacement-install-v4.json'];
        if(!names||names.some(function(n){return allowed.indexOf(n)<0;}))reject();
        if(!attrs(journalPath)){if(names.length)reject();return null;}
        file(journalPath,384,16384);var j=JSON.parse(read(journalPath));
        if(j.schemaVersion!==1||j.kind!=='screenpunk.native-helper-upgrade.v1'||j.consent!==true||j.home!==home||j.uid!==uid||j.manifestPath!==manifestPath||j.fromNativeSHA256!==screenpunkV4NativeSHA256||j.toNativeSHA256!==newSHA||j.controlSHA256!==screenpunkV4ControlSHA256||j.tokenIdentity!==initial.m.tokenIdentity||j.tokenSHA256!==initial.m.tokenSHA256||j.plistSHA256!==initial.m.plistSHA256||!Number.isSafeInteger(j.createdAt)||['preparing','prepared','completed'].indexOf(j.lifecycle)<0||!/^[a-f0-9]{64}$/.test(j.originalManifestSHA256))reject();
        if(j.lifecycle!=='preparing'&&!/^[a-f0-9]{64}$/.test(j.replacementManifestSHA256))reject();
        return j;
    }
    journal=loadJournal();
    function state(){
        var s=snapshot();
        if(s.m.tokenIdentity!==initial.m.tokenIdentity||s.tokenIdentity!==initial.tokenIdentity||s.m.tokenSHA256!==initial.m.tokenSHA256||s.m.plistSHA256!==initial.m.plistSHA256)reject();
        var oldOld=s.nativeSHA===screenpunkV4NativeSHA256&&s.m.nativeSHA256===screenpunkV4NativeSHA256;
        var newOld=s.nativeSHA===newSHA&&s.m.nativeSHA256===screenpunkV4NativeSHA256;
        var newNew=s.nativeSHA===newSHA&&s.m.nativeSHA256===newSHA;
        if(!oldOld&&!newOld&&!newNew)reject();
        if(!journal){if(newOld)reject();return {name:oldOld?'required':'current',snapshot:s};}
        if(oldOld&&s.manifestSHA!==journal.originalManifestSHA256)reject();
        if(newOld&&(journal.lifecycle==='preparing'||s.manifestSHA!==journal.originalManifestSHA256))reject();
        if(newNew&&(journal.lifecycle==='preparing'||journal.lifecycle!=='completed'&&s.manifestSHA!==journal.replacementManifestSHA256))reject();
        if(journal.lifecycle==='completed'&&!newNew)reject();
        if(journal.lifecycle!=='preparing'){
            if(hash(originalNative,384,1048576)!==screenpunkV4NativeSHA256||hash(originalManifest,384,16384)!==journal.originalManifestSHA256||hash(nextNative,384,1048576)!==newSHA||hash(nextManifest,384,16384)!==journal.replacementManifestSHA256)reject();
            var before=JSON.parse(read(originalManifest)), after=JSON.parse(read(nextManifest));before.nativeSHA256=newSHA;
            if(JSON.stringify(before)!==JSON.stringify(after))reject();
            if(newNew&&journal.lifecycle==='completed'){
                // Normal controller lifecycle writes may follow a completed repair.
                // All other fields must still equal the archived replacement.
                var active=JSON.parse(read(manifestPath)), expected=JSON.parse(read(nextManifest));
                if(active.updatedAt!==undefined&&(!Number.isSafeInteger(active.updatedAt)||active.updatedAt<=0))reject();
                delete active.lifecycle;delete active.updatedAt;delete expected.lifecycle;delete expected.updatedAt;
                if(JSON.stringify(active)!==JSON.stringify(expected))reject();
            }
        }
        return {name:newNew?'current':'resume',snapshot:s};
    }
    var current=state();
    if(operation==='inspect')return current.name;
    if(!journal){
        if(current.name==='current')return 'current';
        if(operation!=='prepare')reject();
        if(!attrs(backup)){if(!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(backup),false,$({NSFilePosixPermissions:448}),null))reject();syncDirectory(dir);}directory(backup,true);
        // Consent is supplied by the trusted setup dispatcher only after its dialog.
        journal={schemaVersion:1,kind:'screenpunk.native-helper-upgrade.v1',consent:true,home:home,uid:uid,manifestPath:manifestPath,fromNativeSHA256:screenpunkV4NativeSHA256,toNativeSHA256:newSHA,controlSHA256:screenpunkV4ControlSHA256,tokenIdentity:initial.m.tokenIdentity,tokenSHA256:initial.m.tokenSHA256,plistSHA256:initial.m.plistSHA256,originalManifestSHA256:initial.manifestSHA,lifecycle:'preparing',createdAt:Date.now()};
        exclusive(journalPath,JSON.stringify(journal));
    }
    if(journal.lifecycle==='preparing'){
        current=state();if(current.snapshot.nativeSHA!==screenpunkV4NativeSHA256||current.snapshot.manifestSHA!==journal.originalManifestSHA256)reject();
        backupFile(originalNative,read(initial.m.nativePath),screenpunkV4NativeSHA256);
        backupFile(originalManifest,read(manifestPath),journal.originalManifestSHA256);
        backupFile(nextNative,read(source),newSHA);
        var replacement=JSON.parse(read(originalManifest));replacement.nativeSHA256=newSHA;
        var nextText=JSON.stringify(replacement);
        if(attrs(nextManifest)){file(nextManifest,384,16384);if(read(nextManifest)!==nextText)reject();}else exclusive(nextManifest,nextText);
        journal.replacementManifestSHA256=hash(nextManifest,384,16384);journal.lifecycle='prepared';
        state();write(journalPath,JSON.stringify(journal));
    }
    if(operation==='prepare')return 'prepared';
    current=state();
    if(current.snapshot.nativeSHA===screenpunkV4NativeSHA256){write(initial.m.nativePath,read(nextNative));syncPath(initial.m.nativePath);}
    current=state();
    // The helper is durable before its receipt changes. A crash here is new-old,
    // recoverable only through the durable consent journal and original backups.
    if(current.snapshot.m.nativeSHA256===screenpunkV4NativeSHA256){write(manifestPath,read(nextManifest));syncPath(manifestPath);}
    current=state();if(current.name!=='current')reject();
    if(journal.lifecycle!=='completed'){journal.lifecycle='completed';journal.completedAt=Date.now();write(journalPath,JSON.stringify(journal));}
    return 'current';
}
