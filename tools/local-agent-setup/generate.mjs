import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const root = fileURLToPath(new URL('../../', import.meta.url));
const version = '6';
const frozenV1SHA256 = '2d208f5fc45737dc2aa89c00db96c784fa3142ff13508c7ada7f7a53dd5f8957';
const frozenV1 = readFileSync(root + 'tools/local-agent-setup/releases/v1/macos.sh', 'utf8');
if (createHash('sha256').update(frozenV1).digest('hex') !== frozenV1SHA256) {
  throw Error('Frozen setup v1 changed; preserve its published bytes and checksum.');
}
const frozenV2SHA256 = '5f46adbf5a0582e0734fdc8d7ea7aab0e200edd103351248c344162783fe2e6d';
const frozenV2 = readFileSync(root + 'tools/local-agent-setup/releases/v2/macos.sh', 'utf8');
if (createHash('sha256').update(frozenV2).digest('hex') !== frozenV2SHA256) {
  throw Error('Frozen setup v2 changed; preserve its published bytes and checksum.');
}
const frozenV3SHA256 = '0945173fe87e98d2e3a168dd3f461b59acdfa10eef6e0897f2931205779d1ed5';
const frozenV3 = readFileSync(root + 'tools/local-agent-setup/releases/v3/macos.sh', 'utf8');
if (createHash('sha256').update(frozenV3).digest('hex') !== frozenV3SHA256) {
  throw Error('Frozen setup v3 changed; preserve its published bytes and checksum.');
}
const frozenV4SHA256 = '311a4d48ccd6c84637521e9c6291c38813202f3fa869dadf5db7eb05f7557e5e';
const frozenV4 = readFileSync(root + 'tools/local-agent-setup/releases/v4/macos.sh', 'utf8');
if (createHash('sha256').update(frozenV4).digest('hex') !== frozenV4SHA256) throw Error('Frozen setup v4 changed; preserve its published bytes and checksum.');
const frozenV5SHA256 = 'a54dc9fc1daedd4f95b8e2be126629c0dc83bdd63eb8bbc6076fb88734102fe3';
const frozenV5 = readFileSync(root + 'tools/local-agent-setup/releases/v5/macos.sh', 'utf8');
if (createHash('sha256').update(frozenV5).digest('hex') !== frozenV5SHA256) throw Error('Frozen setup v5 changed; preserve its published bytes and checksum.');
const native = readFileSync(root + 'tools/local-agent-setup/macos/native.js', 'utf8').trimEnd()
  + '\n' + readFileSync(root + 'tools/local-agent-setup/macos/service-native.js', 'utf8').trimEnd()
  + '\n' + readFileSync(root + 'tools/local-agent-setup/macos/service-upgrade-native.js', 'utf8').trimEnd();
const sshAudit = readFileSync(root + 'tools/local-agent-setup/macos/ssh-audit.sh', 'utf8');
// Keep the service controller ABI and bytes unchanged for helper-only v4 repair.
// Native service-job parsing owns the corrected diagnostic-format contract.
const serviceShell = readFileSync(root + 'tools/local-agent-setup/macos/service.sh', 'utf8');
const serviceControlTemplate = readFileSync(root + 'tools/local-agent-setup/macos/service-control.sh.in', 'utf8');
if (serviceControlTemplate.split('@@SERVICE_SHELL@@').length !== 2) throw Error('Service controller must contain exactly one library marker.');
const serviceControl = serviceControlTemplate.replace('@@SERVICE_SHELL@@', () => serviceShell.trimEnd());
const template = readFileSync(root + 'tools/local-agent-setup/macos/macos.sh.in', 'utf8');
const replacements = new Map([['@@NATIVE_JS@@', native], ['@@SSH_AUDIT@@', sshAudit], ['@@SERVICE_SHELL@@', serviceShell], ['@@SERVICE_CONTROL@@', serviceControl], ['@@SERVICE_UPGRADE@@', readFileSync(root + 'tools/local-agent-setup/macos/service-upgrade.sh', 'utf8')]]);
let script = template;
for (const [marker, content] of replacements) {
  if (template.split(marker).length !== 2) throw Error('Setup template must contain exactly one ' + marker + ' marker.');
  script = script.replace(marker, () => content.trimEnd());
}
if (!script.startsWith(`#!/bin/sh\n# Screenpunk Mac setup v${version}.`)) {
  throw Error('Setup template header does not match the generated release version.');
}
const sha = createHash('sha256').update(script).digest('hex');
const command = `screenpunk_setup=$(mktemp "$HOME/Downloads/screenpunk-setup-v${version}.XXXXXX") && curl --fail --silent --show-error --proto '=https' --tlsv1.2 '<ORIGIN>/local/setup/v${version}/macos.sh' -o "$screenpunk_setup" && printf '%s  %s\\n' '${sha}' "$screenpunk_setup" | shasum -a 256 -c - && /bin/sh "$screenpunk_setup"`;
const inlineScript = `const command=${JSON.stringify(command)}.replace('<ORIGIN>',location.origin);document.getElementById('command-text').textContent=command;const copy=document.getElementById('copy');const status=document.getElementById('copy-status');copy.disabled=false;copy.onclick=async()=>{try{await navigator.clipboard.writeText(command);status.textContent='Command copied. Paste it into Terminal on this Mac, then press Return.';}catch{status.textContent='Copy was unavailable. Select the command below, copy it, and paste it into Terminal.';document.getElementById('command').focus();}};`;
const csp = `default-src 'none'; script-src 'sha256-${createHash('sha256').update(inlineScript).digest('base64')}'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connect Screenpunk to your Mac</title>
<style>
:root{color-scheme:light;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#17251e;background:#fafbf8;font-size:17px;line-height:1.55}
*{box-sizing:border-box}body{margin:0}main{max-width:800px;margin:0 auto;padding:48px 24px 64px}header{margin-bottom:32px}h1{font-size:clamp(2rem,6vw,2.7rem);line-height:1.13;margin:12px 0 18px;letter-spacing:-.035em}h2{font-size:1.2rem;line-height:1.3;margin:0 0 10px}p{margin:10px 0}.eyebrow,.secondary{color:#4d5952}.eyebrow{font-size:.85rem;font-weight:650;letter-spacing:.04em}.steps{padding-left:1.55rem;margin:0}.steps>li{padding:0 0 26px 12px;margin-bottom:28px;border-bottom:1px solid #dbe3da}.steps>li::marker{font-size:1.15rem;font-weight:700;color:#14674e}.actions{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:16px 0}.control{display:inline-flex;justify-content:center;align-items:center;min-height:48px;padding:10px 18px;border:1px solid #14674e;border-radius:10px;background:#fff;color:#115d46;font:inherit;font-weight:650;text-decoration:none;cursor:pointer}.control.primary{background:#14674e;color:#fff}.control:hover{filter:brightness(.95)}.control:disabled{opacity:.6;cursor:default}a{color:#115d46}a:focus-visible,button:focus-visible,summary:focus-visible,pre:focus-visible{outline:3px solid #ad6700;outline-offset:4px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#edf1eb;border:1px solid #dbe3da;border-radius:10px;padding:16px;margin:12px 0;font-size:.78rem;line-height:1.6}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}details{margin:14px 0}summary{cursor:pointer;min-height:44px;display:list-item;padding:8px 0;font-weight:600}.status{min-height:1.5em;color:#285c45;font-size:.9rem}.success{background:#e8f3e9;border-left:4px solid #14674e;padding:16px 18px;border-radius:6px;margin:18px 0}.success p{margin:5px 0}.setup-details{border-top:1px solid #dbe3da;padding-top:12px}.checksum{font-size:.8rem}.file-note{font-size:.95rem}
@media(max-width:520px){main{padding:28px 18px 40px}.steps>li{padding-left:6px}.actions{align-items:stretch}.control{width:100%}pre{font-size:.74rem;padding:12px}}
</style>
</head>
<body>
<main>
<header>
<div class="eyebrow">SCREENPUNK · MAC SETUP V${version}</div>
<h1>Connect Screenpunk to your Mac</h1>
<p>Follow these steps on your Mac, with Screenpunk open on your iPad. You’ll send a public request file, run setup here, then scan the connection code.</p>
<p class="secondary">Your setup request and private connection code stay on your devices. This page never receives them.</p>
<p class="secondary">If setup v4 reported a <code>job.Label</code> error, current setup offers a verified helper repair. It preserves the running service and saved credential; it does not restart the Mac server.</p>
</header>
<ol class="steps">
<li>
<h2>Send the iPad request to this Mac</h2>
<p>On iPad, open <strong>Settings → Agents</strong>. If a local agent is already configured, choose <strong>Connection details → Advanced → Pair again</strong>. Otherwise, choose <strong>Add agent</strong>.</p>
<p>Tap <strong>Send setup request to computer</strong> and choose AirDrop, or transfer the file locally.</p>
<p>On this Mac, find the received <code>Screenpunk-setup-request.json</code> file, usually in Downloads. You’ll select it in step 4.</p>
<p class="secondary">If the request expires, tap <strong>Prepare a new request</strong> on iPad and send the fresh file.</p>
</li>
<li>
<h2>Download and review setup v${version}</h2>
<p>Download the Mac script and read it before continuing.</p>
<div class="actions"><a class="control" href="/local/setup/v${version}/macos.sh" download="screenpunk-setup-v${version}.sh">Download setup v${version}</a></div>
<p class="secondary file-note">The downloaded <code>.sh</code> file is the Mac script. Keep the iPad’s <code>Screenpunk-setup-request.json</code> handy for the file picker.</p>
</li>
<li>
<h2>Run the verified command in Terminal</h2>
<p>Open Terminal on this Mac. Copy the command, paste it into Terminal, then press <strong>Return</strong>. It downloads setup v${version} and checks its SHA256 before running it.</p>
<div class="actions"><button class="control primary" type="button" id="copy" aria-describedby="copy-status" disabled>Copy Terminal command</button></div>
<p class="status" id="copy-status" role="status" aria-live="polite" aria-atomic="true"></p>
<pre id="command" tabindex="0" aria-label="Checksum-verified Terminal command"><code id="command-text">Enable JavaScript to show the verified command for this site.</code></pre>
<details class="checksum"><summary>Setup v${version} SHA256</summary><code>${sha}</code></details>
</li>
<li>
<h2>Select the public iPad request</h2>
<p>When the Mac file picker opens, select the <code>Screenpunk-setup-request.json</code> received from your iPad.</p>
<p class="secondary">Setup checks that the request is valid and belongs to a supported iPad key.</p>
</li>
<li>
<h2>Complete the Mac prompts</h2>
<p>Follow the messages in Terminal and the Mac dialogs. Sign in to Codex if asked, then review the SSH access changes before authorizing them.</p>
<p>Choose <strong>Enable background startup</strong> when asked to keep Screenpunk available after closing Terminal. It starts when you sign in to this Mac and restarts if the server exits. The Mac must stay signed in, awake and reachable.</p>
<p>If setup reports that <strong>Remote Login</strong> is off, turn it on in <strong>System Settings → General → Sharing</strong> and allow your Mac account, then run the command again. Setup never turns it on automatically.</p>
</li>
<li>
<h2>Scan the code and connect on iPad</h2>
<p>The Mac displays a private connection QR for five minutes. On iPad, tap <strong>Next</strong> to reach <strong>Scan connection code</strong>, then tap <strong>Scan connection code</strong> and scan the Mac.</p>
<p>Review the Mac name and tap <strong>Connect</strong>. Screenpunk checks the connection and runs one small Codex-allowance test. Wait for <strong>Connected</strong> and <strong>Ready</strong>.</p>
<div class="success"><strong>Terminal can close after background startup is verified.</strong><p>Keep the Mac signed in, awake and reachable. After restarting the Mac, sign in before connecting from iPad.</p></div>
<details><summary>If you chose Terminal only</summary><p>This foreground alternative requires keeping the setup Terminal open. Run setup again to review enabling background startup.</p></details>
<details><summary>If you cannot scan the code</summary><p>On the Mac, choose <strong>Show private file</strong> and transfer it locally. On iPad, choose <strong>Import private connection file</strong>. The file contains a private connection credential: keep it on your devices and never upload or email it.</p></details>
</li>
</ol>
<details class="setup-details"><summary>Requirements, access changes and recovery</summary>
<p>Requires Apple Silicon, macOS 13 or later, and the supported Codex <code>0.164.0-alpha.11.1</code> bundled with ChatGPT. Setup checks the exact build and never installs or downgrades software.</p>
<p>Setup asks before adding a restricted iPad SSH key. Its account-wide policy disables reverse TCP and Unix-socket forwarding for <strong>all SSH keys on the selected Mac account</strong>. Missing system host keys require separate approval. SSH policy installation and validation use <code>sudo</code>.</p>
<p>Background startup is optional and requires your approval. It installs a LaunchAgent for your Mac account, with no helper app or system daemon. It runs while you are signed in, including when the screen is locked; logging out stops it. Sleep, a closed lid or an offline Mac can make the connection unavailable. Setup does not change power settings.</p>
<p>Existing verified connections and their saved credential are preserved. Moving a verified foreground server to background startup asks separately before a brief disconnect. Dismissing the QR clears its display material and leaves authorized access in place.</p>
<p>After uninstalling background startup, rerun this setup command and choose background startup again to review and approve re-enabling it. Terminal only leaves background startup uninstalled.</p>
<p>If setup stops, follow its Terminal message and run the command again after resolving the issue. A request that has expired needs a fresh file from iPad. Ownership conflicts stop setup for review. Exact access changes and revocation instructions are saved privately under <code>~/.codex/screenpunk-local/setup-receipts</code>.</p>
</details>
<details class="setup-details"><summary>Troubleshooting an earlier Mac setup</summary>
<p>If an earlier manual setup has a saved credential and its server is not running, setup may ask your approval to reuse that unchanged credential with a new server using your chosen startup mode. A running server without ownership receipts stops setup for review; your working connection stays unchanged.</p>
</details>
</main>
<script>${inlineScript}</script>
</body>
</html>`;

const generated = `// Generated by tools/local-agent-setup/generate.mjs. Do not edit.\nexport const localAgentSetupVersion = ${JSON.stringify(version)};\nexport const localAgentSetupSHA256 = ${JSON.stringify(sha)};\nexport const localAgentSetupCSP = ${JSON.stringify(csp)};\nexport const localAgentSetupScript = ${JSON.stringify(script)};\nexport const localAgentSetupHTML = ${JSON.stringify(html)};\nexport const localAgentSetupScripts = {\n  '1': { script: ${JSON.stringify(frozenV1)}, sha256: ${JSON.stringify(frozenV1SHA256)} },\n  '2': { script: ${JSON.stringify(frozenV2)}, sha256: ${JSON.stringify(frozenV2SHA256)} },\n  '3': { script: ${JSON.stringify(frozenV3)}, sha256: ${JSON.stringify(frozenV3SHA256)} },\n  '4': { script: ${JSON.stringify(frozenV4)}, sha256: ${JSON.stringify(frozenV4SHA256)} },\n  '5': { script: ${JSON.stringify(frozenV5)}, sha256: ${JSON.stringify(frozenV5SHA256)} },\n  '6': { script: localAgentSetupScript, sha256: localAgentSetupSHA256 },\n} as const;\n`;
const outputs = new Map([
  [root + 'tools/local-agent-setup/macos/macos.sh', script],
  [root + 'tools/local-agent-setup/generated/local-agent-setup.ts', generated],
]);
for (const [path, text] of outputs) {
  if (process.argv.includes('--check')) {
    if (readFileSync(path, 'utf8') !== text) throw Error('Generated setup is stale: ' + path);
  } else {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  }
}
console.log(`Screenpunk setup v${version} SHA256 ${sha}`);
