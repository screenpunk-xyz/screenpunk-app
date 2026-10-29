#!/bin/sh
# Screenpunk Mac setup v3. User reviewed, foreground only. No network upload or installer.
# Generated self-contained macos.sh; audit source tools/local-agent-setup/macos/.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SP_CODEX='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
SP_OSASCRIPT=/usr/bin/osascript
SP_SUDO=/usr/bin/sudo
SP_SSHD=/usr/sbin/sshd
SP_POLICY=/etc/ssh/sshd_config.d/090-screenpunk-local.conf
SP_HOSTKEY=/etc/ssh/ssh_host_ed25519_key.pub
SP_SSHCONFIG=/etc/ssh/sshd_config
SP_SSHDIR=/etc/ssh/sshd_config.d
SP_CRYPTO=/etc/ssh/crypto.conf
SP_SHA=a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e
SP_VERSION=0.164.0-alpha.11.1
fail() { printf '%s\n' "$1" >&2; exit 1; }
# BEGIN SCREENPUNK READ-ONLY SSH AUDIT
# Read-only SSH metadata audit. Sourcing this file defines functions only.
# Call audit_ssh_configuration after the access review and before sshd -t.
# Inputs: SP_SSHCONFIG, SP_SSHDIR, SP_CRYPTO, sp_user, fail(), native().
# Output: sp_crypto_leaf, passed to the native algorithm-only content audit.
screenpunk_ssh_require_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u' "$1")" = 0 ] || fail "SSH configuration directory must be an actual root-owned directory: $1"
  sp_audit_mode=$(stat -f '%Lp' "$1") || fail "Cannot inspect SSH configuration directory permissions: $1"
  case "$sp_audit_mode" in ''|*[!0-7]*) fail "Unexpected SSH configuration directory permissions: $1";; esac
  [ "$((0$sp_audit_mode & 022))" -eq 0 ] || fail "SSH configuration directory is writable by another account: $1"
}

screenpunk_ssh_require_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u' "$1")" = 0 ] || fail "SSH configuration must be a regular root-owned file: $1"
  sp_audit_mode=$(stat -f '%Lp' "$1") || fail "Cannot inspect SSH configuration file permissions: $1"
  case "$sp_audit_mode" in ''|*[!0-7]*) fail "Unexpected SSH configuration file permissions: $1";; esac
  [ "$((0$sp_audit_mode & 022))" -eq 0 ] || fail "SSH configuration file is writable by another account: $1"
}

audit_ssh_configuration() {
  case "$SP_SSHCONFIG" in /*) ;; *) fail 'The SSH main configuration path must be absolute.';; esac
  case "$SP_SSHDIR" in /*) ;; *) fail 'The SSH include directory path must be absolute.';; esac
  case "$SP_CRYPTO" in /*) ;; *) fail 'The SSH crypto policy path must be absolute.';; esac

  screenpunk_ssh_require_directory "${SP_SSHCONFIG%/*}"
  screenpunk_ssh_require_directory "$SP_SSHDIR"
  screenpunk_ssh_require_regular_file "$SP_SSHCONFIG"
  for sp_audit_config in "$SP_SSHDIR"/*; do
    if [ ! -e "$sp_audit_config" ] && [ ! -L "$sp_audit_config" ]; then continue; fi
    screenpunk_ssh_require_regular_file "$sp_audit_config"
  done

  sp_crypto_parent=${SP_CRYPTO%/*}
  screenpunk_ssh_require_directory "$sp_crypto_parent"
  sp_crypto_leaf=$SP_CRYPTO
  if [ -L "$SP_CRYPTO" ]; then
    # Link permissions are not access controls. Trust its owner and containing
    # directories, and accept only Apple's exact one-hop relative target.
    [ "$(stat -f '%u' "$SP_CRYPTO")" = 0 ] || fail 'The macOS SSH crypto policy link must be root-owned.'
    # Read raw target bytes without readlink's display newline, then retain them
    # with a sentinel so command substitution cannot strip a target's newlines.
    sp_crypto_target=$(readlink -n "$SP_CRYPTO" && printf '.') || fail 'Cannot read the macOS SSH crypto policy link.'
    sp_crypto_expected='crypto/apple.conf.'
    [ "$sp_crypto_target" = "$sp_crypto_expected" ] || fail 'The macOS SSH crypto policy link has a custom target; only crypto/apple.conf is supported without manual review.'
    screenpunk_ssh_require_directory "$sp_crypto_parent/crypto"
    sp_crypto_leaf="$sp_crypto_parent/crypto/apple.conf"
  fi
  screenpunk_ssh_require_regular_file "$sp_crypto_leaf"

  native audit-ssh "$SP_SSHCONFIG" "$SP_SSHDIR" "$sp_user" "$SP_CRYPTO" "$sp_crypto_leaf"
}
# END SCREENPUNK READ-ONLY SSH AUDIT
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'This reviewed setup supports Apple Silicon macOS only.'
sp_os=$(sw_vers -productVersion); [ "${sp_os%%.*}" -ge 13 ] || fail 'macOS 13 or later is required.'
[ -x "$SP_CODEX" ] || fail 'Install the supported ChatGPT Mac app; the bundled Codex was not found.'
[ "$(shasum -a 256 "$SP_CODEX" | awk '{print $1}')" = "$SP_SHA" ] || fail 'Codex binary changed. Use the reviewed supported build; no software was installed or downgraded.'
[ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ] || fail 'Codex version is unsupported.'
sp_uid=$(id -u); sp_user=$(id -un)
case "$sp_user" in ''|-*|*[!A-Za-z0-9._-]*) fail 'Unsupported account short name.';; esac
[ "${#sp_user}" -le 64 ] || fail 'Unsupported account short name.'
case "$HOME" in /*) ;; *) fail 'An absolute Mac home directory is required.';; esac
[ "$(cd "$HOME" && pwd -P)" = "$HOME" ] || fail 'The home directory must not contain symbolic links.'
private_dir() {
  [ ! -L "$1" ] || fail 'A Screenpunk directory is a symbolic link; review it before continuing.'
  if [ -e "$1" ]; then
    [ -d "$1" ] && [ "$(stat -f '%u:%Lp' "$1")" = "$sp_uid:700" ] || fail 'Existing Screenpunk directories must be owned by this account with mode 700. Review permissions; setup will not repair unknown files.'
  else mkdir "$1"; fi
}
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp:%l' "$1")" = "$sp_uid:600:1" ] || fail 'Expected a private, singly linked, account-owned Screenpunk file.'; }
if [ -e "$HOME/.codex" ] || [ -L "$HOME/.codex" ]; then
  [ -d "$HOME/.codex" ] && [ ! -L "$HOME/.codex" ] && [ "$(stat -f '%u' "$HOME/.codex")" = "$sp_uid" ] || fail 'Review the Codex home directory ownership/symlink.'
  sp_parentmode=$(stat -f '%Lp' "$HOME/.codex"); [ "$((0$sp_parentmode & 022))" -eq 0 ] || fail 'Codex home must not be writable by other accounts.'
else mkdir "$HOME/.codex"; fi
export CODEX_HOME="$HOME/.codex/screenpunk-local"
private_dir "$CODEX_HOME"; private_dir "$CODEX_HOME/workspace"; private_dir "$CODEX_HOME/setup-receipts"
for sp_sensitive in auth.json config.toml; do [ ! -L "$CODEX_HOME/$sp_sensitive" ] || fail 'Dedicated Codex authentication/configuration must not link to another home.'; done
# Kernel-held descriptor lease: no stale directory to delete after SIGKILL/power loss.
sp_lock="$CODEX_HOME/.setup.lock"
if [ -e "$sp_lock" ] || [ -L "$sp_lock" ]; then private_file "$sp_lock"; fi
exec 9<> "$sp_lock"
/usr/bin/lockf -t 0 9 || fail 'Another setup is running. Wait for its connection display to close, then retry.'
sp_lock_held=1
sp_session=$(mktemp -d "$CODEX_HOME/setup-session.XXXXXX")
sp_policy_added=0; sp_key_added=0; sp_token_created=0; sp_started=0; sp_handoff=0; sp_pid=''; sp_start=''
sp_token="$CODEX_HOME/transport-token"; sp_server_receipt="$CODEX_HOME/setup-server.json"; sp_token_receipt="$CODEX_HOME/setup-token.json"
sp_keys="$HOME/.ssh/authorized_keys"
sp_policyhash=''; sp_keyline=''; sp_newreceipt_hash=''; sp_tokenidentity=''; sp_tokenhash=''; sp_tokenreceipt_hash=''
process_start() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'; }
cleanup() {
  sp_status=$?
  set +e
  sp_restore_failed=0
  trap - EXIT HUP INT TERM
  # A failed pre-handoff attempt rolls back only exact resources created in this attempt.
  if [ "$sp_started" -eq 1 ] && [ "$(process_start "$sp_pid")" = "$sp_start" ]; then kill "$sp_pid" 2>/dev/null || :; wait "$sp_pid" 2>/dev/null || :; fi
  if [ "$sp_handoff" -eq 0 ]; then
    if [ "$sp_key_added" -eq 1 ] && [ -f "$sp_keys" ] && [ ! -L "$sp_keys" ]; then
      grep -Fvx -- "$sp_keyline" "$sp_keys" > "$sp_session/keys.rollback" || [ "$?" -eq 1 ]
      cat "$sp_session/keys.rollback" > "$sp_keys"
    fi
    if [ "$sp_policy_added" -eq 1 ] && [ ! -L "$SP_POLICY" ] && [ -f "$SP_POLICY" ] && [ "$(shasum -a 256 "$SP_POLICY" | awk '{print $1}')" = "$sp_policyhash" ]; then "$SP_SUDO" rm -f "$SP_POLICY" || :; fi
    if [ "$sp_token_created" -eq 1 ] && [ -f "$sp_token" ] && [ ! -L "$sp_token" ] && [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_tokenidentity" ] && [ "$(shasum -a 256 "$sp_token" | awk '{print $1}')" = "$sp_tokenhash" ]; then
      rm -f "$sp_token"
      if [ -n "$sp_tokenreceipt_hash" ] && [ -f "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ] && [ "$(shasum -a 256 "$sp_token_receipt" | awk '{print $1}')" = "$sp_tokenreceipt_hash" ]; then rm -f "$sp_token_receipt"; fi
    fi
    if [ "$sp_started" -eq 1 ] && [ -n "$sp_newreceipt_hash" ] && [ -f "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ "$(shasum -a 256 "$sp_server_receipt" | awk '{print $1}')" = "$sp_newreceipt_hash" ]; then
      if [ -f "$sp_session/server-original.json" ]; then native restore-server "$sp_session/server-original.json" "$sp_server_receipt" || sp_restore_failed=1; else rm -f "$sp_server_receipt"; fi
    fi
  fi
  rm -f "$sp_session/native.js" "$sp_session/request-path" "$sp_session/request.json" "$sp_session/key.pub" "$sp_session/key-digest" "$sp_session/policy" "$sp_session/authorized-line" "$sp_session/keys.rollback" "$sp_session/private-reply.json" "$sp_session/connection.png" "$sp_session/metadata.json" "$sp_session/server-pid" "$sp_session/server-start" "$sp_session/server-tokenIdentity" "$sp_session/server-tokenSHA256" "$sp_session/new-token" "$sp_session/start-server" "$sp_session/.screenpunk-session.json"
  if [ "$sp_restore_failed" -eq 0 ]; then rm -f "$sp_session/server-original.json"; fi
  rmdir "$sp_session" 2>/dev/null || :
  if [ "$sp_lock_held" -eq 1 ]; then exec 9>&-; fi
  exit "$sp_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
cat > "$sp_session/native.js" <<'SCREENPUNK_NATIVE_JS'
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
    return {type:'screenpunk.pairing-reply.v1',schemaVersion:1,pairingID:r.pairingID,nonce:r.nonce,publicKeySHA256:r.publicKeySHA256,issuedAt:now,expiresAt:now+300000,computerName:fields.computerName,host:host,sshPort:22,username:username,hostKeySHA256:fields.hostKeySHA256,appServerPort:4500,macWorkspace:workspace,codexVersion:r.codexVersion,protocolProfile:r.protocolProfile,appServerToken:fields.appServerToken};
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
    alert.informativeText = $('Private connection code for ' + reply.computerName + '. Expires in five minutes. Keep Terminal open. The private file contains a bearer: transfer locally only, never upload or email it.');
    alert.addButtonWithTitle('Done'); alert.addButtonWithTitle('Show private file');
    if (qr) {
        var image = $.NSImage.alloc.initWithContentsOfFile($(dir + '/connection.png'));
        var iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0,0,540,540));
        iv.image = image; iv.imageScaling = $.NSImageScaleProportionallyUpOrDown; alert.accessoryView = iv;
    } else { alert.informativeText = $('This connection needs the private file fallback. Use “Show private file” and transfer it locally to Screenpunk. It contains a bearer; never upload or email it. It expires in five minutes.'); }
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
    if (action === 'metadata') { write(args[1]+'/metadata.json',JSON.stringify({computerName:args[2],host:args[3],username:args[4],hostKeySHA256:args[5],macWorkspace:args[6]})); return; }
    if (action === 'server-write') { write(args[1],JSON.stringify({schemaVersion:1,pid:Number(args[2]),start:args[3],tokenIdentity:args[4],tokenSHA256:args[5],binarySHA256:args[6]})); return; }
    if (action === 'server-read') { var s=JSON.parse(read(args[1])); if(s.schemaVersion!==1 || !Number.isSafeInteger(s.pid) || s.pid<0 || !bounded(s.start,128) || (s.pid===0 && s.start!=='not-started') || !/^[0-9]+:600:[0-9]+$/.test(s.tokenIdentity) || !/^[a-f0-9]{64}$/.test(s.tokenSHA256) || s.binarySHA256!=='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e') fail('Unknown App Server receipt'); ['pid','start','tokenIdentity','tokenSHA256'].forEach(function(k){field(dir,'server-'+k,s[k]);}); return; }
    if (action === 'prepared-receipts') { var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(args[1]),null)); if(!names) fail('Cannot inspect setup receipts'); names.forEach(function(n){if(JSON.parse(read(args[1]+'/'+n)).lifecycle!=='prepared') fail('A paired-client receipt exists without its bearer. Review it; setup did not rotate the token');}); return; }
    if (action === 'receipt-complete') { var record=JSON.parse(read(args[1])); if(record.lifecycle==='handoff-ready') return; if(record.lifecycle!=='prepared') fail('Unknown install journal stage'); record.lifecycle='handoff-ready'; record.handoffReadyAt=Date.now(); write(args[1],JSON.stringify(record)); return; }
    if (action === 'receipt') { if ($.NSFileManager.defaultManager.fileExistsAtPath($(args[1]))) { var old=JSON.parse(read(args[1])); if(old.schemaVersion!==1 || old.addedPublicKeyLine!==read(args[2]+'/authorized-line') || old.policyPath!==args[4] || old.policySHA256!==args[5] || old.serverReceipt!==args[7] || old.tokenFile!==args[8]) fail('Existing install receipt conflicts; review ownership'); return; } write(args[1],JSON.stringify({schemaVersion:1,setupVersion:'3',lifecycle:'prepared',pairingID:JSON.parse(read(args[2]+'/request.json')).pairingID,addedPublicKeyLine:read(args[2]+'/authorized-line'),keyWasAdded:args[3]==='1',policyPath:args[4],policySHA256:args[5],policyWasAdded:args[6]==='1',serverReceipt:args[7],tokenFile:args[8],tokenWasCreated:args[9]==='1',createdAt:Date.now(),revoke:'Remove only addedPublicKeyLine from ~/.ssh/authorized_keys. Keep the shared account policy/token/server until every paired client is revoked. Stop only the PID with matching start identity in serverReceipt. Never rotate the token without reviewing all paired clients.'})); return; }
    fail('Unknown native setup action');
}
SCREENPUNK_NATIVE_JS
native() { "$SP_OSASCRIPT" -l JavaScript "$sp_session/native.js" "$@"; }
# An acquired kernel lease proves no other setup display still owns the lease.
# Clear only declared private display files from verified prior script-owned sessions.
for sp_prior in "$CODEX_HOME"/setup-session.*; do
  [ -d "$sp_prior" ] && [ ! -L "$sp_prior" ] && [ "$sp_prior" != "$sp_session" ] || continue
  private_dir "$sp_prior"
  if [ -e "$sp_prior/.screenpunk-session.json" ] || [ -L "$sp_prior/.screenpunk-session.json" ]; then
    private_file "$sp_prior/.screenpunk-session.json"
    for sp_private in private-reply.json connection.png new-token; do
      if [ -e "$sp_prior/$sp_private" ] || [ -L "$sp_prior/$sp_private" ]; then private_file "$sp_prior/$sp_private"; fi
    done
    native session-clean "$sp_prior"
  fi
done
native session-start "$sp_session" "$$"
printf '%s\n' 'Select the PUBLIC setup request received from iPad. Nothing is uploaded.'
native choose "$sp_session/request-path"
sp_request=$(cat "$sp_session/request-path")
[ -f "$sp_request" ] && [ ! -L "$sp_request" ] || fail 'Select a regular public setup-request JSON file.'
[ "$(stat -f '%z' "$sp_request")" -le 8192 ] || fail 'Selected file is too large for the public iPad request. Choose Screenpunk-setup-request.json sent from the iPad, not the downloaded Mac setup script.'
native request "$sp_request" "$sp_session"
[ "$(ssh-keygen -lf "$sp_session/key.pub" -E sha256 | awk '{print $2}')" = "$(cat "$sp_session/key-digest")" ] || fail 'The public key digest does not match the request.'
# Check an already active Remote Login listener without enabling or restarting the service.
nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 || fail 'Turn on Remote Login in System Settings > General > Sharing, allow this account, then run setup again. Screenpunk does not enable it.'
if dscl . -read /Groups/com.apple.access_ssh RecordName >/dev/null 2>&1; then
  dsmemberutil checkmembership -U "$sp_user" -G com.apple.access_ssh | grep -q 'is a member' || fail 'Allow this Mac account in Remote Login settings, then retry.'
fi
[ ! -L "$SP_HOSTKEY" ] || fail 'The public host key must not be a symbolic link.'
if [ ! -f "$SP_HOSTKEY" ]; then
  native consent 'The Mac has no public Ed25519 SSH host key. Continue authorizes sudo ssh-keygen -A to create missing system host keys only. Existing keys are never regenerated. Remote Login remains under your control.'
  "$SP_SUDO" ssh-keygen -A
fi
[ -f "$SP_HOSTKEY" ] && [ ! -L "$SP_HOSTKEY" ] && [ "$(stat -f '%u' "$SP_HOSTKEY")" = 0 ] || fail 'No public SSH host key is available. Review Remote Login and system host keys.'
sp_hostmode=$(stat -f '%Lp' "$SP_HOSTKEY"); [ "$((0$sp_hostmode & 022))" -eq 0 ] || fail 'The public host key is writable by another account.'
sp_hostpin=$(ssh-keygen -lf "$SP_HOSTKEY" -E sha256 | awk '{print $2}')
# Authentication is scoped to the dedicated home. Never copy global credentials.
if "$SP_CODEX" login status >/dev/null 2>&1; then printf '%s\n' 'Already signed in to the dedicated Screenpunk Codex home.'
else
  printf '%s\n' 'Sign in using the standard Codex browser flow for this dedicated Screenpunk home.'
  "$SP_CODEX" login
  "$SP_CODEX" login status >/dev/null 2>&1 || fail 'Codex sign-in was not confirmed. Retry after completing browser sign-in.'
fi
# Reuse a stopped earlier setup only after explicit review of its unchanged private bearer.
# Running unowned servers remain untouched; no creation history is inferred.
if { [ -e "$sp_token" ] || [ -L "$sp_token" ]; } && [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ ! -e "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ]; then
  private_file "$sp_token"
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'The earlier saved bearer has an unexpected format; it was not changed.'
  sp_legacy_pid=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
  if [ -z "$sp_legacy_pid" ]; then
    if nc -z -G 1 127.0.0.1 4500 >/dev/null 2>&1; then fail 'A live server cannot be identified for ownership review. Keep the working connection unchanged; setup did not stop anything.'; fi
    sp_legacy_identity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_legacy_hash=$(shasum -a 256 "$sp_token" | awk '{print $1}')
    native consent 'Reuse your saved Screenpunk connection credential? The earlier setup saved a private bearer but no ownership receipt, and no App Server is listening now. Continue records your approval to reuse this exact file unchanged and start a new foreground server. Existing iPad credentials are not reset. Cancel keeps all saved data. No model request is sent.'
    private_file "$sp_token"
    [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_legacy_identity" ] && [ "$(shasum -a 256 "$sp_token" | awk '{print $1}')" = "$sp_legacy_hash" ] || fail 'The saved credential changed during review; nothing was adopted.'
    [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || fail 'A listener appeared during review; no server was stopped.'
    if nc -z -G 1 127.0.0.1 4500 >/dev/null 2>&1; then fail 'A listener appeared during review; no server was stopped.'; fi
    [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ ! -e "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ] || fail 'Ownership changed during review; no receipt was overwritten.'
    native token-adopt "$sp_token_receipt" 0 not-started "$sp_legacy_identity" "$sp_legacy_hash" "$SP_SHA"
    printf '%s\n' 'Reusing the saved Screenpunk bearer unchanged; setup will start its foreground server.'
  else
    fail 'The earlier App Server is already running without ownership receipts. Keep it and your working connection unchanged. This upgrade needs manual ownership review; setup did not stop the server, rotate its bearer or add a key.'
  fi
fi
native consent "Authorize this iPad public key for this Mac account? Setup adds one restricted line to ~/.ssh/authorized_keys and, if absent, $SP_POLICY. The account-wide policy disables reverse TCP and Unix-socket forwarding for ALL SSH keys on $sp_user. The iPad key allows only local forwarding to 127.0.0.1:4500, with no shell, PTY or agent forwarding. Setup uses sudo for SSH policy validation, reuses an owned bearer/server, and keeps App Server in this Terminal. No daemon is installed."
printf 'Match User %s\n    AllowTcpForwarding local\n    PermitListen none\n    AllowStreamLocalForwarding no\nMatch all\n' "$sp_user" > "$sp_session/policy"
sp_policyhash=$(shasum -a 256 "$sp_session/policy" | awk '{print $1}')
private_dir "$HOME/.ssh"
if [ -e "$sp_keys" ] || [ -L "$sp_keys" ]; then private_file "$sp_keys"; fi
sp_keyline="restrict,port-forwarding,permitopen=\"127.0.0.1:4500\",command=\"/usr/bin/false\" $(cat "$sp_session/key.pub") Screenpunk-iPad"
printf '%s' "$sp_keyline" > "$sp_session/authorized-line"
sp_keyid=$(shasum -a 256 "$sp_session/key.pub" | awk '{print $1}')
sp_receipt="$CODEX_HOME/setup-receipts/$sp_keyid.json"
sp_keyplanned=0; sp_policyplanned=0; sp_tokenplanned=0
grep -Fqx -- "$sp_keyline" "$sp_keys" 2>/dev/null || sp_keyplanned=1
if [ ! -e "$SP_POLICY" ] && [ ! -L "$SP_POLICY" ]; then sp_policyplanned=1; fi
if [ ! -e "$sp_token" ] && [ ! -L "$sp_token" ]; then sp_tokenplanned=1; fi
if [ -e "$sp_receipt" ] || [ -L "$sp_receipt" ]; then private_file "$sp_receipt"; fi
# Durable nonsecret intent precedes privileged policy/key/token changes.
native receipt "$sp_receipt" "$sp_session" "$sp_keyplanned" "$SP_POLICY" "$sp_policyhash" "$sp_policyplanned" "$sp_server_receipt" "$sp_token" "$sp_tokenplanned"
if [ -e "$SP_POLICY" ] || [ -L "$SP_POLICY" ]; then
  [ ! -L "$SP_POLICY" ] && cmp -s "$sp_session/policy" "$SP_POLICY" || fail 'Existing Screenpunk SSH policy differs. No key was added; review that policy.'
else "$SP_SUDO" install -m 644 "$sp_session/policy" "$SP_POLICY"; sp_policy_added=1; native sync "$SP_POLICY"; fi
# A loopback-only -T check cannot prove restrictions across conditional LAN Match rules.
# Refuse unsupported conditionals/includes rather than granting a key under an unproved policy.
audit_ssh_configuration
"$SP_SUDO" "$SP_SSHD" -t || fail 'SSH configuration validation failed; check host keys and configuration.'
sp_effective=$("$SP_SUDO" "$SP_SSHD" -T -C "user=$sp_user,host=localhost,addr=127.0.0.1")
printf '%s\n' "$sp_effective" | awk '
$1 == "allowtcpforwarding" { tcp = ($2 == "local" && NF == 2) }
$1 == "permitlisten" { listen = ($2 == "none" && NF == 2) }
$1 == "allowstreamlocalforwarding" { stream = ($2 == "no" && NF == 2) }
$1 == "disableforwarding" { disabled = ($2 != "no") }
$1 == "pubkeyauthentication" { key = ($2 == "yes") }
END { exit !(tcp && listen && stream && !disabled && key) }' || fail 'Effective SSH policy is incompatible. No iPad key was added.'
# Never follow a symlink or replace an unknown token/receipt/listener.
if [ -e "$sp_token" ] || [ -L "$sp_token" ]; then
  private_file "$sp_token"
  if [ -e "$sp_server_receipt" ] || [ -L "$sp_server_receipt" ]; then private_file "$sp_server_receipt"; sp_readreceipt=$sp_server_receipt
  else private_file "$sp_token_receipt"; sp_readreceipt=$sp_token_receipt; fi
else
  [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] || fail 'Server receipt exists without its token. Review ownership before continuing.'
fi
sp_listener=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
if [ -e "$sp_token" ]; then
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'Saved bearer has an unexpected format; it was not rotated.'
  native server-read "$sp_readreceipt" "$sp_session"
  [ "$(cat "$sp_session/server-tokenIdentity")" = "$(stat -f '%u:%Lp:%i' "$sp_token")" ] && [ "$(cat "$sp_session/server-tokenSHA256")" = "$(shasum -a 256 "$sp_token" | awk '{print $1}')" ] || fail 'Saved bearer no longer matches its ownership receipt.'
  sp_savedpid=$(cat "$sp_session/server-pid"); sp_savedstart=$(cat "$sp_session/server-start")
  if [ -n "$sp_listener" ]; then
    [ "$sp_listener" = "$sp_savedpid" ] && [ "$(process_start "$sp_savedpid")" = "$sp_savedstart" ] || fail 'Port 4500 belongs to an unverified process; nothing was stopped.'
    [ "$(lsof -nP -a -p "$sp_savedpid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p')" = '127.0.0.1:4500' ] || fail 'Owned listener is not exclusively loopback.'
    sp_pid=$sp_savedpid; sp_start=$sp_savedstart
  else
    [ "$sp_savedpid" -eq 0 ] || [ -z "$(process_start "$sp_savedpid")" ] || fail 'Saved App Server is alive without its expected listener. Review it before retrying.'
  fi
else
  [ -z "$sp_listener" ] || fail 'Port 4500 is already occupied by an unknown process. Setup did not stop it.'
  native prepared-receipts "$CODEX_HOME/setup-receipts"
  if [ -e "$sp_token_receipt" ] || [ -L "$sp_token_receipt" ]; then
    private_file "$sp_token_receipt"; native server-read "$sp_token_receipt" "$sp_session"
    [ "$(cat "$sp_session/server-pid")" -eq 0 ] || fail 'Token provenance is not a prepared install.'
  fi
  openssl rand -hex 32 > "$sp_session/new-token"
  native sync "$sp_session/new-token"
  # A no-secret prepared receipt is durable BEFORE publishing the token inode.
  native server-write "$sp_token_receipt" 0 not-started "$(stat -f '%u:%Lp:%i' "$sp_session/new-token")" "$(shasum -a 256 "$sp_session/new-token" | awk '{print $1}')" "$SP_SHA"
  sp_tokenreceipt_hash=$(shasum -a 256 "$sp_token_receipt" | awk '{print $1}')
  mv -n "$sp_session/new-token" "$sp_token"
  [ ! -e "$sp_session/new-token" ] || fail 'A token appeared during setup; review its ownership.'
  sp_token_created=1
  native sync-rename "$sp_token" "$sp_session"
  sp_tokenidentity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_tokenhash=$(shasum -a 256 "$sp_token" | awk '{print $1}')
fi
[ -e "$sp_keys" ] || : > "$sp_keys"
if ! grep -Fqx -- "$sp_keyline" "$sp_keys"; then printf '\n%s\n' "$sp_keyline" >> "$sp_keys"; sp_key_added=1; native sync "$sp_keys"; fi
if [ -z "$sp_pid" ]; then
  # Gate exec until its PID/start identity is durably journaled. A crashed gate exits boundedly.
  (
    sp_gate_count=0
    while [ ! -f "$sp_session/start-server" ]; do
      [ "$sp_gate_count" -lt 100 ] || exit 1
      sleep 0.1; sp_gate_count=$((sp_gate_count + 1))
    done
    cd "$CODEX_HOME/workspace"
    exec "$SP_CODEX" -c features.shell_tool=false -c features.unified_exec=false -c features.apps=false -c features.plugins=false -c features.hooks=false -c features.browser_use=false -c features.browser_use_external=false -c features.computer_use=false -c features.in_app_browser=false -c features.image_generation=false -c features.view_image=false -c features.multi_agent=false -c features.skill_search=false -c features.skill_mcp_dependency_install=false -c features.workspace_dependencies=false -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$sp_token"
  ) 9>&- >/dev/null 2>&1 &
  sp_pid=$!; sp_started=1; sp_start=$(process_start "$sp_pid")
  [ -n "$sp_start" ] || fail 'App Server stopped before startup.'
  if [ -f "$sp_server_receipt" ]; then cp "$sp_server_receipt" "$sp_session/server-original.json"; native sync "$sp_session/server-original.json"; fi
  native server-write "$sp_server_receipt" "$sp_pid" "$sp_start" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(shasum -a 256 "$sp_token" | awk '{print $1}')" "$SP_SHA"
  sp_newreceipt_hash=$(shasum -a 256 "$sp_server_receipt" | awk '{print $1}')
  : > "$sp_session/start-server"
  sp_attempt=0
  while [ "$sp_attempt" -lt 20 ]; do
    [ "$(process_start "$sp_pid")" = "$sp_start" ] || fail 'App Server exited during startup.'
    sp_ready=$(lsof -nP -a -p "$sp_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || :)
    [ "$sp_ready" = '127.0.0.1:4500' ] && break
    sleep 1; sp_attempt=$((sp_attempt + 1))
  done
  [ "$sp_ready" = '127.0.0.1:4500' ] || fail 'App Server did not open its authenticated loopback listener.'

fi
sp_name=$(scutil --get ComputerName 2>/dev/null || printf '%s' "$sp_user Mac")
sp_localhost=$(scutil --get LocalHostName 2>/dev/null || :)
case "$sp_localhost" in ''|-*|*[!A-Za-z0-9-]*) fail 'Set a valid Mac LocalHostName in Sharing settings, then retry.';; esac
native metadata "$sp_session" "$sp_name" "$sp_localhost.local" "$sp_user" "$sp_hostpin" "$CODEX_HOME/workspace"
native reply "$sp_session" "$sp_token"
native receipt-complete "$sp_receipt"
# Display dismissal/expiry is not authenticated iPad acknowledgement and never revokes access.
sp_handoff=1
printf '%s\n' 'Connection code is displayed locally. No bearer was printed, copied or uploaded.'
native display "$sp_session" || printf '%s\n' 'The local display closed. The Terminal server remains available; rerun setup to create a new code.'
rm -f "$sp_session/private-reply.json" "$sp_session/connection.png"
printf '%s\n' 'Private display material cleared. Keep this Terminal open for App Server. Access persists until explicitly revoked using the private setup receipt.'
exec 9>&-; sp_lock_held=0
if [ "$sp_started" -eq 1 ]; then wait "$sp_pid"; else printf '%s\n' 'Reused the verified App Server; keep its original Terminal open.'; fi
