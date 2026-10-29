/* Embedded in macos.sh by generate.mjs. Native Apple frameworks only; no network APIs. */
ObjC.import('Foundation');
// macOS fsync + F_FULLFSYNC (fcntl command 51) order file/rename metadata before grants/exec.
ObjC.bindFunction('open',['int',['char *','int']]);
ObjC.bindFunction('fsync',['int',['int']]);
ObjC.bindFunction('fcntl',['int',['int','int','int']]);
ObjC.bindFunction('close',['int',['int']]);
ObjC.bindFunction('renamex_np',['int',['char *','char *','int']]);
ObjC.bindFunction('unlink',['int',['char *']]);
function syncDirectory(path) { var fd=$.open(path,0); if(fd<0) fail('Cannot open setup directory for durability'); try { if($.fsync(fd)!==0) fail('Cannot synchronize setup directory'); } finally { $.close(fd); } }
function syncPath(path) { var fd=$.open(path,0); if(fd<0) fail('Cannot open setup file for durability'); try { if($.fsync(fd)!==0) fail('Cannot synchronize setup file'); syncDirectory(path.slice(0,path.lastIndexOf('/')) || '/'); if($.fcntl(fd,51,0)!==0) fail('Cannot establish durable setup ordering on this filesystem'); } finally { $.close(fd); } }

function utf8Bytes(s) { return unescape(encodeURIComponent(s)).length; }
function fail(message) { throw new Error(message); }
function bounded(s, max) { return typeof s === 'string' && utf8Bytes(s) > 0 && utf8Bytes(s) <= max && !/[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/.test(s); }
function b64decode(s) {
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', bits = 0, value = 0, bytes = [];
    for (var i = 0; i < s.length; i++) { var n = alphabet.indexOf(s[i]); if (n < 0) fail('Invalid base64'); value = (value << 6) | n; bits += 6; if (bits >= 8) { bits -= 8; bytes.push((value >> bits) & 255); } }
    if (bits && (value & ((1 << bits) - 1))) fail('Noncanonical base64');
    return bytes;
}
function validDigest(s) { return typeof s === 'string' && /^SHA256:[A-Za-z0-9+/]{43}$/.test(s) && b64decode(s.slice(7)).length === 32; }
function exactObject(text, keys, limit) {
    if (utf8Bytes(text) > limit) fail('Setup request is too large');
    var value = JSON.parse(text);
    if (!value || Array.isArray(value) || Object.keys(value).sort().join('|') !== keys.slice().sort().join('|')) fail('Unexpected setup request fields');
    // The schema is flat. Count decoded keys before JSON.parse can discard duplicates.
    var matches = text.match(/"(?:[^"\\]|\\.)*"\s*:/g) || [], seen = {};
    matches.forEach(function (m) { var k = JSON.parse(m.replace(/\s*:$/, '')); if (seen[k]) fail('Duplicate setup request field'); seen[k] = true; });
    if (matches.length !== keys.length) fail('Duplicate or nested setup request field');
    return value;
}
function validateRequest(text, now) {
    var keys = ['type','schemaVersion','pairingID','nonce','issuedAt','expiresAt','publicKeyOpenSSH','publicKeySHA256','deviceName','codexVersion','protocolProfile'];
    var r = exactObject(text, keys, 8192);
    if (r.type !== 'screenpunk.pairing-request.v1' || r.schemaVersion !== 1 || r.codexVersion !== '0.164.0-alpha.11.1' || r.protocolProfile !== 'macos-codex-0.164.0-alpha.11.1') fail('Unsupported setup request or Codex profile');
    if (typeof r.pairingID !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(r.pairingID) || typeof r.nonce !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(r.nonce) || b64decode(r.nonce.replace(/-/g,'+').replace(/_/g,'/')).length !== 32 || !validDigest(r.publicKeySHA256)) fail('Invalid setup request identity');
    if (!Number.isSafeInteger(r.issuedAt) || !Number.isSafeInteger(r.expiresAt) || r.issuedAt <= 0 || r.expiresAt <= r.issuedAt || r.expiresAt - r.issuedAt > 1800000) fail('Invalid setup request lifetime');
    if (r.issuedAt > now + 120000) fail('Mac and iPad clocks differ; correct the clock and share a new request');
    if (r.expiresAt < now - 120000) fail('Setup request expired; share a new request from iPad');
    if (!bounded(r.deviceName, 128) || !bounded(r.publicKeyOpenSSH, 512)) fail('Invalid device label or public key');
    var parts = r.publicKeyOpenSSH.split(/ +/), blob;
    if (parts.length < 2 || parts[0] !== 'ssh-ed25519' || !/^[A-Za-z0-9+/]{68}$/.test(parts[1])) fail('Expected an Ed25519 iPad public key');
    blob = b64decode(parts[1]);
    if (blob.length !== 51 || blob.slice(0,19).join(',') !== [0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32].join(',')) fail('Invalid Ed25519 key encoding');
    r.publicKeyOpenSSH = 'ssh-ed25519 ' + parts[1]; // Never retain supplied key options/comments.
    return r;
}
function read(path) { var error = Ref(), value = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, error); if (!value) fail('Cannot read local setup file'); return ObjC.unwrap(value); }
function write(path, text) { if (!$(text).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null)) fail('Cannot write private setup material'); $.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({NSFilePosixPermissions: 384}), $(path), null); syncPath(path); }
function field(dir, name, value) { write(dir + '/' + name, String(value)); }
function nativeApp() { var app = Application.currentApplication(); app.includeStandardAdditions = true; return app; }
function makeReply(r, fields, now) {
    var host = fields.host, username = fields.username, workspace = fields.macWorkspace;
    if (!bounded(fields.computerName,128) || typeof host !== 'string' || !/^[A-Za-z0-9.:%_-]{1,253}$/.test(host) || host[0] === '-' || !/^[A-Za-z0-9._-]{1,64}$/.test(username) || username[0] === '-' || !bounded(workspace,1024) || workspace[0] !== '/' || workspace === '/' || /\/\//.test(workspace) || workspace.split('/').some(function(p){return p === '.' || p === '..';}) || !validDigest(fields.hostKeySHA256) || !/^[a-f0-9]{64}$/.test(fields.appServerToken)) fail('Computer metadata cannot be safely paired');
    var result = {type:'screenpunk.pairing-reply.v1',schemaVersion:1,pairingID:r.pairingID,nonce:r.nonce,publicKeySHA256:r.publicKeySHA256,issuedAt:now,expiresAt:now+300000,computerName:fields.computerName,host:host,sshPort:22,username:username,hostKeySHA256:fields.hostKeySHA256,appServerPort:4500,macWorkspace:workspace,codexVersion:r.codexVersion,protocolProfile:r.protocolProfile,appServerToken:fields.appServerToken};
    if (fields.serverLifecycle === 'background') result.serverLifecycle='background';
    else if (fields.serverLifecycle !== undefined && fields.serverLifecycle !== 'foreground') fail('Invalid local server lifecycle');
    return result;
}
function renderQR(reply, path) {
    ObjC.import('Cocoa'); ObjC.import('CoreImage');
    var data = $(reply).dataUsingEncoding($.NSUTF8StringEncoding), filter = $.CIFilter.filterWithName('CIQRCodeGenerator');
    filter.setValueForKey(data,'inputMessage'); filter.setValueForKey($('M'),'inputCorrectionLevel');
    var qr = filter.outputImage, extent = qr.extent;
    var white = $.CIImage.imageWithColor($.CIColor.colorWithRedGreenBlue(1,1,1)).imageByCroppingToRect($.NSMakeRect(-4,-4,extent.size.width+8,extent.size.height+8));
    qr = qr.imageByCompositingOverImage(white);
    var scale = $.NSAffineTransform.transform; scale.scaleBy(8);
    filter = qr.imageByApplyingFilterWithInputParameters('CIAffineTransform', $({inputTransform:scale}));
    var ci = filter, context = $.CIContext.contextWithOptions($({})), cg = context.createCGImageFromRect(ci,ci.extent), bitmap = $.NSBitmapImageRep.alloc.initWithCGImage(cg);
    if (!bitmap.representationUsingTypeProperties($.NSPNGFileType,$({})).writeToFileAtomically($(path),true)) fail('Cannot render connection code');
}
function showReply(dir) {
    ObjC.import('Cocoa');
    var reply = JSON.parse(read(dir + '/private-reply.json')), qr = $.NSFileManager.defaultManager.fileExistsAtPath($(dir + '/connection.png'));
    var alert = $.NSAlert.alloc.init;
    alert.messageText = $('Scan with Screenpunk on your iPad');
    var startupText=reply.serverLifecycle==='background'?'Background startup is verified. After scanning, Terminal can close. Keep this Mac signed in, awake and reachable.':'Keep Terminal open.';
    alert.informativeText = $('Private connection code for ' + reply.computerName + '. Expires in five minutes. '+startupText+' The private file contains a bearer: transfer locally only, never upload or email it.');
    alert.addButtonWithTitle('Done'); alert.addButtonWithTitle('Show private file');
    if (qr) {
        var image = $.NSImage.alloc.initWithContentsOfFile($(dir + '/connection.png'));
        var iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0,0,540,540));
        iv.image = image; iv.imageScaling = $.NSImageScaleProportionallyUpOrDown; alert.accessoryView = iv;
    } else { alert.informativeText = $('This connection needs the private file fallback. Use “Show private file” and transfer it locally to Screenpunk. It contains a bearer; never upload or email it. It expires in five minutes. '+startupText); }
    $.NSApplication.sharedApplication.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
    $.NSApplication.sharedApplication.activateIgnoringOtherApps(true);
    ObjC.registerSubclass({name:'ScreenpunkPairingExpiry',superclass:'NSObject',methods:{'expire:':{types:['void',['id']],implementation:function(){ $.NSApplication.sharedApplication.abortModal; }}}});
    var expiryTarget=$.ScreenpunkPairingExpiry.alloc.init;
    while (Date.now() < reply.expiresAt) {
        var timer=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(Math.max(0.001,(reply.expiresAt-Date.now())/1000),expiryTarget,'expire:',null,false);
        $.NSRunLoop.currentRunLoop.addTimerForMode(timer,$.NSModalPanelRunLoopMode);
        var result=Number(alert.runModal); timer.invalidate; alert.window.orderOut(null);
        if (result === Number($.NSAlertSecondButtonReturn) && Date.now() < reply.expiresAt) { $.NSWorkspace.sharedWorkspace.selectFileInFileViewerRootedAtPath($(dir+'/private-reply.json'),$(dir)); continue; }
        break;
    }
}
function auditSSHText(text, username, includeDirectory, main, sourcePath, cryptoPath, cryptoOnly) {
    var includesCrypto = false;
    text.split(/\r?\n/).forEach(function(line, index) {
        line = line.replace(/#.*$/, '').trim(); if (!line) return;
        var parts = line.split(/\s+/), directive = parts.shift();
        var location = sourcePath + ':' + (index + 1);
        if (!/^[A-Za-z]+$/.test(directive)) fail('Unsupported SSH configuration syntax at '+location+'; review it before pairing');
        directive = directive.toLowerCase();
        if (cryptoOnly) {
            if (['ciphers','kexalgorithms','macs'].indexOf(directive) < 0 || parts.length === 0) fail('Unsupported directive '+directive+' at '+location+'; the macOS crypto Include may contain only Ciphers, KexAlgorithms and MACs');
            return;
        }
        if (directive === 'include') {
            var standardDirectory = main && parts.length === 1 && (parts[0] === includeDirectory+'/*' || parts[0] === includeDirectory+'/*.conf');
            var standardCrypto = !main && sourcePath === includeDirectory+'/100-macos.conf' && parts.length === 1 && parts[0] === cryptoPath;
            if (!standardDirectory && !standardCrypto) fail('Nonstandard or nested SSH Include at '+location+': '+line+'; manual review is required before pairing');
            if (standardCrypto) includesCrypto = true;
        }
        if (directive === 'match' && !(parts.length === 1 && parts[0].toLowerCase() === 'all') && !(parts.length === 2 && parts[0].toLowerCase() === 'user' && parts[1] === username)) fail('Conditional SSH Match rules at '+location+' could override forwarding for the iPad. Review host/address/group policies before pairing');
    });
    return includesCrypto;
}
function run(args) {
    var action = args[0], dir = args[2], app;
    if (action === 'upgrade-service-v4') return upgradeServiceV4(args);
    if (action.indexOf('service-')===0) return serviceAction(args);
    if (action === 'token-adopt') {
        var destination=args[1], temporary=destination+'.adopt-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        try {
            write(temporary,JSON.stringify({schemaVersion:1,origin:'adopted-legacy-token',pid:Number(args[2]),start:args[3],tokenIdentity:args[4],tokenSHA256:args[5],binarySHA256:args[6]}));
            // RENAME_EXCL (Darwin sys/stdio.h): one atomic move, no overwrite or two-link crash window.
            if($.renamex_np(temporary,destination,4)!==0) fail('Existing connection ownership changed; no receipt was overwritten');
        } finally { $.unlink(temporary); }
        syncPath(destination); return;
    }
    if (action === 'restore-server') { write(args[2],read(args[1])); return; }
    if (action === 'sync') { syncPath(args[1]); return; }
    if (action === 'sync-rename') { syncDirectory(args[2]); syncPath(args[1]); return; }
    if (action === 'session-start') { write(args[1]+'/.screenpunk-session.json',JSON.stringify({owner:'screenpunk.mac-setup.v1',directory:args[1],pid:Number(args[2]),createdAt:Date.now()})); return; }
    if (action === 'session-clean') { var marker=JSON.parse(read(args[1]+'/.screenpunk-session.json')); if(marker.owner!=='screenpunk.mac-setup.v1' || marker.directory!==args[1] || !Number.isSafeInteger(marker.pid) || marker.pid<1) fail('Unknown prior setup session; inspect it before continuing'); ['private-reply.json','connection.png','new-token'].forEach(function(n){var path=args[1]+'/'+n; if($.NSFileManager.defaultManager.fileExistsAtPath($(path))) $.NSFileManager.defaultManager.removeItemAtPathError($(path),null);}); return; }
    if (action === 'choose') { app = nativeApp(); var chosen = app.chooseFile({withPrompt:'Select the PUBLIC Screenpunk setup-request JSON received from your iPad'}); write(args[1], String(chosen)); return; }
    if (action === 'consent') { app = nativeApp(); app.displayDialog(args[1],{withTitle:'Screenpunk Mac setup',buttons:['Cancel','Continue'],defaultButton:'Cancel',cancelButton:'Cancel'}); return; }
    if (action === 'request') { var request = validateRequest(read(args[1]),Date.now()); write(dir+'/request.json',JSON.stringify(request)); field(dir,'key.pub',request.publicKeyOpenSSH+'\n'); field(dir,'key-digest',request.publicKeySHA256); return; }
    if (action === 'reply') { var r = validateRequest(read(args[1]+'/request.json'),Date.now()), metadata = JSON.parse(read(args[1]+'/metadata.json')); metadata.appServerToken=read(args[2]).trim(); var text=JSON.stringify(makeReply(r,metadata,Date.now())); if(utf8Bytes(text)>8192) fail('Private reply too large'); write(args[1]+'/private-reply.json',text); if(utf8Bytes(text)<=1536) { try { renderQR(text,args[1]+'/connection.png'); } catch (_) { /* Private-file fallback stays available if CoreImage is unavailable. */ } } return; }
    if (action === 'audit-ssh') { var crypto=args[4], includedCrypto=false; auditSSHText(read(args[1]),args[3],args[2],true,args[1],crypto,false); var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(args[2]),null)); if(!names) fail('Cannot inspect SSH include directory'); names.forEach(function(n){if(auditSSHText(read(args[2]+'/'+n),args[3],args[2],false,args[2]+'/'+n,crypto,false)) includedCrypto=true;}); if(includedCrypto) { var leaf=args[5]; if(typeof leaf!=='string' || !leaf) fail('Verified SSH crypto policy path is missing'); auditSSHText(read(leaf),args[3],args[2],false,leaf,crypto,true); } return; }
    if (action === 'display') { showReply(args[1]); return; }
    if (action === 'metadata') { write(args[1]+'/metadata.json',JSON.stringify({computerName:args[2],host:args[3],username:args[4],hostKeySHA256:args[5],macWorkspace:args[6],serverLifecycle:args[7] || 'foreground'})); return; }
    if (action === 'server-write') { write(args[1],JSON.stringify({schemaVersion:1,pid:Number(args[2]),start:args[3],tokenIdentity:args[4],tokenSHA256:args[5],binarySHA256:args[6]})); return; }
    if (action === 'server-read') { var s=JSON.parse(read(args[1])); if(s.schemaVersion!==1 || !Number.isSafeInteger(s.pid) || s.pid<0 || !bounded(s.start,128) || (s.pid===0 && s.start!=='not-started') || !/^[0-9]+:600:[0-9]+$/.test(s.tokenIdentity) || !/^[a-f0-9]{64}$/.test(s.tokenSHA256) || s.binarySHA256!=='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e') fail('Unknown App Server receipt'); ['pid','start','tokenIdentity','tokenSHA256'].forEach(function(k){field(dir,'server-'+k,s[k]);}); if(s.serverLifecycle==='background')field(dir,'server-serverLifecycle','background'); return; }
    if (action === 'prepared-receipts') { var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(args[1]),null)); if(!names) fail('Cannot inspect setup receipts'); names.forEach(function(n){if(JSON.parse(read(args[1]+'/'+n)).lifecycle!=='prepared') fail('A paired-client receipt exists without its bearer. Review it; setup did not rotate the token');}); return; }
    if (action === 'receipt-complete') { var record=JSON.parse(read(args[1])); if(record.lifecycle==='handoff-ready') return; if(record.lifecycle!=='prepared') fail('Unknown install journal stage'); record.lifecycle='handoff-ready'; record.handoffReadyAt=Date.now(); write(args[1],JSON.stringify(record)); return; }
    if (action === 'receipt') { if ($.NSFileManager.defaultManager.fileExistsAtPath($(args[1]))) { var old=JSON.parse(read(args[1])); if(old.schemaVersion!==1 || old.addedPublicKeyLine!==read(args[2]+'/authorized-line') || old.policyPath!==args[4] || old.policySHA256!==args[5] || old.serverReceipt!==args[7] || old.tokenFile!==args[8]) fail('Existing install receipt conflicts; review ownership'); return; } write(args[1],JSON.stringify({schemaVersion:1,setupVersion:'5',lifecycle:'prepared',pairingID:JSON.parse(read(args[2]+'/request.json')).pairingID,addedPublicKeyLine:read(args[2]+'/authorized-line'),keyWasAdded:args[3]==='1',policyPath:args[4],policySHA256:args[5],policyWasAdded:args[6]==='1',serverReceipt:args[7],tokenFile:args[8],tokenWasCreated:args[9]==='1',createdAt:Date.now(),revoke:'Remove only addedPublicKeyLine from ~/.ssh/authorized_keys. Keep the shared account policy/token/server until every paired client is revoked. Stop only the PID with matching start identity in serverReceipt. Never rotate the token without reviewing all paired clients.'})); return; }
    fail('Unknown native setup action');
}
