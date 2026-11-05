// SPDX-License-Identifier: Apache-2.0
// Catalog capability is independent of authoring contract negotiation.
import definition from './generated/catalog-definition';
import { canonicalJSON, validateAuthoringScreen } from './authoring';
import { authoringContentDigestV2, authoringMediaTypeV2 } from './authoring-v2';
export const CATALOG_CAPABILITY = 'catalog-backup-v1';
export const CATALOG_VERSION = '1';
export const CATALOG_LIMITS = Object.freeze({ versionsPerScreen:3, screensPerAccount:20, packageBytes:10*1024*1024, previewBytes:512*1024, previewDimension:2048, accountBytes:1024*1024*1024, publicationOverlapBytes:20*1024*1024, queueRevisions:100, queueBytes:100*1024*1024, files:20, fileBytes:204800 });
export const CATALOG_ROUTES = Object.freeze({ capabilities:'/api/catalog/capabilities', begin:'/api/catalog/backups/begin', uploads:'/api/catalog/backups/', operations:'/api/catalog/backups/operations/', list:'/api/catalog', screens:'/api/catalog/screens/' });
export type CatalogErrorCode = 'not_entitled'|'offline'|'quota_exceeded'|'invalid_package'|'conflict'|'deleted'|'retry_later'|'unauthorized'|'not_found';
export interface CatalogError { code:CatalogErrorCode; message:string; retryAfterSeconds?:number; restartOperation?:true }
export interface CatalogEntitlement { backupEnabled:boolean; reason:string; versionsPerScreen:number; screensPerAccount:number; packageBytes:number; previewBytes:number; previewDimension:number; accountBytes:number; publicationOverlapBytes:number }
export interface CatalogCapability { version:'1'; feature:'catalog-backup-v1'; previewMediaTypes:('image/png'|'image/jpeg')[]; entitlement:CatalogEntitlement }
export interface CatalogPackageFile { path:string; mediaType:string; byteLength:number; digest:string; contentBase64:string }
export interface CatalogPackage { schemaVersion:1; screen:{ title:string; entry:'index.html'; requiredAssets:string[]; externalDependencies:string[] }; files:CatalogPackageFile[] }
export interface CatalogObjectDeclaration { byteLength:number; digest:string }
export interface CatalogPreviewDeclaration extends CatalogObjectDeclaration { mediaType:'image/png'|'image/jpeg'; width:number; height:number }
export interface CatalogGapDeclaration { checkpointCounter:number; checkpointRevisionID:string; skippedFromCounter:number; skippedThroughCounter:number; reason:'user_acknowledged_backup_pause' }
export interface CatalogBeginBackup {
 schemaVersion:1; operationID:string; libraryID:string; localScreenID:string; sourceRevisionID:string;
 parentRevisionIDs:string[]; predecessorRevisionID:string|null; commitCounter:number; origin:'applied'|'seed'; sourceAppliedAt:string;
 screenName:string; versionName?:string; note?:string; gap?:CatalogGapDeclaration; package:CatalogObjectDeclaration; preview?:CatalogPreviewDeclaration;
}
export type CatalogBackupState = 'pending'|'uploaded'|'completed'|'duplicate'|'superseded'|'deleted'|'failed';
export interface CatalogBackupStatus { schemaVersion:1; operationID:string; state:CatalogBackupState; catalogScreenID:string; uploadID?:string; versionID?:string; displayVersion?:number; expiresAt?:string; error?:CatalogError }
export interface CatalogCompleteBackup { schemaVersion:1; operationID:string }
export type CatalogPreview = { status:'available'; mediaType:'image/png'|'image/jpeg'; byteLength:number; digest:string; width:number; height:number } | { status:'unavailable'; reason:'not_provided'|'invalid'|'capture_failed' };
export interface CatalogVersion { versionID:string; catalogScreenID:string; displayVersion:number; sourceRevisionID:string; parentRevisionIDs:string[]; copyID:string; commitCounter:number; screenName:string; versionName?:string; note?:string; sourceAppliedAt:string; backedUpAt:string; packageSchema:1; packageDigest:string; sizeBytes:number; deviceDisplayName:string; deviceLinked:boolean; integrity?:'missing'; preview:CatalogPreview }
export interface CatalogScreen { catalogScreenID:string; latest:CatalogVersion; history:CatalogVersion[] }
export interface CatalogList { schemaVersion:1; catalogRevision:number; entitlement:CatalogEntitlement; usage:{storedBytes:number;reservedBytes:number;cleanupBytes:number}; screens:CatalogScreen[]; nextCursor?:string }
export interface CatalogDeleteResult { schemaVersion:1; catalogScreenID:string; versionID:string; deleted:true; catalogRevision:number }
export const CATALOG_SCHEMAS = definition.schemas;
/** Structural validation for every public wire shape; package integrity needs the async validator. */
export function validateCatalogWire(name:keyof typeof CATALOG_SCHEMAS,value:unknown):void {
 const check=(schema:any,v:any,depth=0):void=>{
  if(depth>32)throw Error('Catalog schema depth');
  if(schema.$ref)return check((CATALOG_SCHEMAS as any)[schema.$ref.split('/').pop()],v,depth+1);
  if(schema.anyOf){for(const option of schema.anyOf){try{check(option,v,depth+1);return;}catch{}}throw Error('Catalog schema union');}
  if('const' in schema&&v!==schema.const||schema.enum&&!schema.enum.includes(v))throw Error('Catalog schema value');
  if(schema.type==='object'){if(!v||typeof v!=='object'||Array.isArray(v))throw Error('Catalog object');if(schema.required.some((k:string)=>!Object.hasOwn(v,k))||Object.keys(v).some(k=>!Object.hasOwn(schema.properties,k)))throw Error('Catalog fields');for(const [k,x]of Object.entries(v))check(schema.properties[k],x,depth+1);}
  if(schema.type==='array'){if(!Array.isArray(v)||v.length<schema.minItems||v.length>schema.maxItems||schema.uniqueItems&&new Set(v.map(x=>canonicalJSON(x))).size!==v.length)throw Error('Catalog array');for(const x of v)check(schema.items,x,depth+1);}
  if(schema.type==='string'&&(typeof v!=='string'||v.length<schema.minLength||v.length>schema.maxLength||schema.pattern&&!new RegExp(schema.pattern).test(v)))throw Error('Catalog string');
  if(schema.type==='integer'&&(!Number.isSafeInteger(v)||v<schema.minimum||v>schema.maximum))throw Error('Catalog integer');
  if(schema.type==='boolean'&&typeof v!=='boolean'||schema.type==='null'&&v!==null)throw Error('Catalog type');
 };check(CATALOG_SCHEMAS[name],value);
 const v=value as any;if(name==='Error'&&v.restartOperation&&v.code!=='retry_later'||name==='BackupStatus'&&v.error?.restartOperation&&(v.state!=='failed'||v.error.code!=='retry_later'))throw Error('Catalog restart requires expired failed operation');
}
const fail = (message:string):never => { throw new Error(`Catalog: ${message}`); };
const plain = (v:unknown):v is Record<string,any> => !!v && typeof v==='object' && !Array.isArray(v);
const keys = (v:unknown,required:string[],optional:string[]=[]) => { if(!plain(v)||required.some(k=>!Object.hasOwn(v,k))||Object.keys(v).some(k=>![...required,...optional].includes(k)))fail('invalid fields'); };
const bounded = (v:unknown,max:number) => typeof v==='string' && v.trim().length>0 && v.length<=max;
const id = (v:unknown) => typeof v==='string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(v);
const integer = (v:unknown,max:number,min=1) => typeof v==='number'&&Number.isSafeInteger(v)&&v>=min&&v<=max;
const digest = (v:unknown) => typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const timestamp = (v:unknown) => typeof v==='string'&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(v)&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
export function validateCatalogObject(value:unknown,max=CATALOG_LIMITS.packageBytes):CatalogObjectDeclaration { keys(value,['byteLength','digest']);const v=value as CatalogObjectDeclaration;if(!integer(v.byteLength,max)||!digest(v.digest))fail('invalid object declaration');return v; }
export function validateCatalogBeginBackup(value:unknown):CatalogBeginBackup {
 validateCatalogWire('BeginBackup',value);
 keys(value,['schemaVersion','operationID','libraryID','localScreenID','sourceRevisionID','parentRevisionIDs','predecessorRevisionID','commitCounter','origin','sourceAppliedAt','screenName','package'],['versionName','note','preview','gap']);
 const v=value as CatalogBeginBackup;
 if(v.schemaVersion!==1||![v.operationID,v.libraryID,v.localScreenID,v.sourceRevisionID].every(id)||!integer(v.commitCounter,Number.MAX_SAFE_INTEGER)||!['applied','seed'].includes(v.origin)||!timestamp(v.sourceAppliedAt)||!bounded(v.screenName,100))fail('invalid begin metadata');
 if(!Array.isArray(v.parentRevisionIDs)||v.parentRevisionIDs.length>8||!v.parentRevisionIDs.every(id)||new Set(v.parentRevisionIDs).size!==v.parentRevisionIDs.length||v.parentRevisionIDs.includes(v.sourceRevisionID)||!(v.predecessorRevisionID===null||id(v.predecessorRevisionID))||v.predecessorRevisionID===v.sourceRevisionID)fail('invalid lineage');
 if(v.predecessorRevisionID!==null&&!v.parentRevisionIDs.includes(v.predecessorRevisionID))fail('predecessor must be a parent');
 if(v.versionName!==undefined&&!bounded(v.versionName,100)||v.note!==undefined&&!bounded(v.note,1000))fail('invalid label');
 if(v.gap!==undefined){const g=v.gap;keys(g,['checkpointCounter','checkpointRevisionID','skippedFromCounter','skippedThroughCounter','reason']);if(v.origin!=='seed'||!integer(g.checkpointCounter,Number.MAX_SAFE_INTEGER)||!id(g.checkpointRevisionID)||!integer(g.skippedFromCounter,Number.MAX_SAFE_INTEGER)||!integer(g.skippedThroughCounter,Number.MAX_SAFE_INTEGER)||g.skippedFromCounter!==g.checkpointCounter+1||g.skippedThroughCounter<g.skippedFromCounter||v.commitCounter!==g.skippedThroughCounter+1||v.predecessorRevisionID!==g.checkpointRevisionID||g.reason!=='user_acknowledged_backup_pause')fail('invalid gap checkpoint');}
 validateCatalogObject(v.package);
 if(v.preview!==undefined){ keys(v.preview,['byteLength','digest','mediaType','width','height']);validateCatalogObject({byteLength:v.preview.byteLength,digest:v.preview.digest},CATALOG_LIMITS.previewBytes);if(!['image/png','image/jpeg'].includes(v.preview.mediaType)||!integer(v.preview.width,2048)||!integer(v.preview.height,2048))fail('invalid preview'); }
 return v;
}
export function catalogSafePath(path:unknown):path is string { return typeof path==='string'&&path.length<=160&&/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(path)&&path.split('/').every(p=>!!p&&p!=='.'&&p!=='..'&&!p.startsWith('.')); }
export async function validateCatalogPackage(value:unknown):Promise<CatalogPackage> {
 validateCatalogWire('Package',value);
 keys(value,['schemaVersion','screen','files']);const v=value as CatalogPackage;
 keys(v.screen,['title','entry','requiredAssets','externalDependencies']);
 if(v.schemaVersion!==1||v.screen.entry!=='index.html'||!bounded(v.screen.title,100)||!Array.isArray(v.files)||v.files.length<1||v.files.length>20)fail('invalid package');
 if(!Array.isArray(v.screen.requiredAssets)||v.screen.requiredAssets.length>20||!v.screen.requiredAssets.every(catalogSafePath)||new Set(v.screen.requiredAssets).size!==v.screen.requiredAssets.length)fail('invalid required assets');
 if(!Array.isArray(v.screen.externalDependencies)||v.screen.externalDependencies.length>20||!v.screen.externalDependencies.every(s=>bounded(s,160)))fail('invalid external dependencies');
 let previous='';const folded=new Set<string>();const textFiles:{path:string;content:string}[]=[];
 for(const file of v.files){keys(file,['path','mediaType','byteLength','digest','contentBase64']);if(!catalogSafePath(file.path)||file.path<=previous||folded.has(file.path.toLowerCase())||!integer(file.byteLength,204800,0)||!digest(file.digest)||file.mediaType!==authoringMediaTypeV2(file.path)||typeof file.contentBase64!=='string'||file.contentBase64.length>273068)fail('invalid file');previous=file.path;folded.add(file.path.toLowerCase());let raw:string;try{raw=atob(file.contentBase64);}catch{return fail('invalid base64');}if(btoa(raw)!==file.contentBase64)fail('noncanonical base64');const bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));if(bytes.length!==file.byteLength||await authoringContentDigestV2(bytes)!==file.digest)fail('file integrity mismatch');let content:string;try{content=new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes);}catch{return fail('invalid UTF-8');}if(catalogContainsCredentials(file.path,content))fail('credential-bearing package');textFiles.push({path:file.path,content});}
 if(!folded.has('index.html')||v.screen.requiredAssets.some(p=>!v.files.some(f=>f.path===p)))fail('missing package asset');
 // Existing screen rules remain stricter than the catalog transport budget.
 validateCatalogManifest(v.files,textFiles);
 const dependencies=catalogDependencies(textFiles);if(dependencies.requiredAssets.some(p=>!v.screen.requiredAssets.includes(p))||dependencies.externalDependencies.some(p=>!v.screen.externalDependencies.includes(p)))fail('undeclared package dependency');
 validateAuthoringScreen({title:v.screen.title,entry:'index.html',files:textFiles});
 if(new TextEncoder().encode(canonicalJSON(v)).length>CATALOG_LIMITS.packageBytes)fail('package exceeds limit');return v;
}
export async function encodeCatalogPackage(value:unknown):Promise<Uint8Array> { return new TextEncoder().encode(canonicalJSON(await validateCatalogPackage(value))); }
export async function verifyCatalogPackageUpload(bytes:Uint8Array,declaration:CatalogObjectDeclaration):Promise<CatalogPackage> {validateCatalogObject(declaration);if(bytes.length!==declaration.byteLength||await authoringContentDigestV2(bytes)!==declaration.digest)fail('package integrity mismatch');let text:string;try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes);}catch{return fail('invalid UTF-8');}const value=await validateCatalogPackage(JSON.parse(text));const canonicalBytes=new TextEncoder().encode(canonicalJSON(value));if(canonicalBytes.length!==bytes.length||canonicalBytes.some((byte,index)=>byte!==bytes[index]))fail('noncanonical package JSON');return value;}
export async function catalogBeginDigest(value:unknown):Promise<string> {return authoringContentDigestV2(canonicalJSON(validateCatalogBeginBackup(value)));}

/** High-confidence secret markers only; external/live credentials must never be snapshotted. */
export function catalogContainsCredentials(path:string,content:string):boolean {
 return /(?:^|\/)(?:credentials|secrets?|id_rsa|id_ed25519|keychain)(?:[./_-]|$)/i.test(path)||/-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----/.test(content)||/\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,})\b/.test(content);
}
/** Bounded static dependency subset. Dynamic JS fetches are not snapshots. */
export function catalogDependencies(files:{path:string;content:string}[]):{requiredAssets:string[];externalDependencies:string[]} {
 const local=new Set<string>(),external=new Set<string>(),paths=new Set(files.map(f=>f.path));
 const admit=(raw:string,file:string)=>{const value=raw.trim();if(!value||value.startsWith('#')||value.startsWith('data:'))return;if(value.length>160||/[\\&\x00-\x20]/.test(value))fail('unsupported dependency encoding');if(/^https?:\/\//i.test(value)){const url=new URL(value);if(url.username||url.password)fail('credential URL');external.add(value);return;}if(/^[a-z][a-z0-9+.-]*:|^\/\//i.test(value))fail('unsupported dependency scheme');const path=value.split(/[?#]/,1)[0];if(path.includes('%')||path.startsWith('/'))fail('unsupported dependency path');const parts=file.split('/').slice(0,-1);for(const p of path.split('/')){if(p==='..'){if(!parts.length)fail('dependency traversal');parts.pop();}else if(p!=='.'&&p)parts.push(p);}const resolved=parts.join('/');if(!paths.has(resolved))fail('missing package dependency');local.add(resolved);};
 const space=(c:string)=>/[\t\n\r\f ]/.test(c);
 // Character scanner, not a tag regex: quoted > is data and cannot end a tag.
 const css=(text:string,file:string)=>{let i=0;const skip=()=>{while(i<text.length){if(space(text[i]))i++;else if(text.startsWith('/*',i)){const end=text.indexOf('*/',i+2);if(end<0)fail('unclosed CSS comment');i=end+2;}else break;}};const quoted=()=>{const q=text[i++],start=i;while(i<text.length&&text[i]!==q){if(text[i]==='\\'||/[\n\r\f]/.test(text[i]))fail('unsupported CSS string');i++;}if(i===text.length)fail('unclosed CSS string');const value=text.slice(start,i);i++;return value;};while(i<text.length){skip();if(i>=text.length)break;if(text[i]==='"'||text[i]==="'"){quoted();continue;}if(text[i]==='\\')fail('unsupported CSS escape');const boundary=i===0||!/[A-Za-z0-9_-]/.test(text[i-1]);if(boundary&&text.slice(i,i+7).toLowerCase()==='@import'&&!/[A-Za-z0-9_-]/.test(text[i+7]??'')){i+=7;skip();if(text[i]==='"'||text[i]==="'"){admit(quoted(),file);continue;}if(text.slice(i,i+4).toLowerCase()!=='url(')fail('unsupported CSS import');}if((i===0||!/[A-Za-z0-9_-]/.test(text[i-1]))&&text.slice(i,i+4).toLowerCase()==='url('){i+=4;skip();let value:string;if(text[i]==='"'||text[i]==="'")value=quoted();else{const start=i;while(i<text.length&&!space(text[i])&&text[i]!==')'){if(/["'(\\\x00]/.test(text[i])||text.startsWith('/*',i))fail('invalid CSS URL');i++;}value=text.slice(start,i);}skip();if(text[i]!==')')fail('unclosed CSS URL');i++;admit(value,file);continue;}i++;}};
 for(const file of files){if(/\.css$/i.test(file.path)){css(file.content,file.path);continue;}if(!/\.(html|svg)$/i.test(file.path))continue;const text=file.content;let i=0;while(i<text.length){if(text[i++]!=='<')continue;if(text.startsWith('!--',i)){const end=text.indexOf('-->',i+3);if(end<0)fail('unclosed markup comment');i=end+3;continue;}if(text[i]==='!'){const end=text.indexOf('>',i);if(end<0||!/^!doctype\s/i.test(text.slice(i))||text.slice(i,end).includes('['))fail('unsupported markup declaration');i=end+1;continue;}if(text[i]==='?')fail('unsupported markup declaration');const closing=text[i]==='/';if(closing)i++;if(!/[A-Za-z]/.test(text[i]??''))continue;const start=i;while(i<text.length&&/[A-Za-z0-9:_-]/.test(text[i]))i++;const tag=text.slice(start,i).toLowerCase();if(tag==='base')fail('HTML base unsupported');let selfClosing=false,ended=false;
 while(i<text.length){while(i<text.length&&space(text[i]))i++;if(text[i]==='>'){i++;ended=true;break;}if(text[i]==='/'&&text[i+1]==='>'){i+=2;selfClosing=true;ended=true;break;}if(closing)fail('invalid closing tag');const start=i;while(i<text.length&&/[A-Za-z0-9:_-]/.test(text[i]))i++;if(i===start)fail('invalid attribute');const name=text.slice(start,i).toLowerCase();while(i<text.length&&space(text[i]))i++;if(text[i]!=='=')continue;i++;while(i<text.length&&space(text[i]))i++;let value:string;if(text[i]==='"'||text[i]==="'"){const quote=text[i++],start=i;while(i<text.length&&text[i]!==quote)i++;if(i===text.length)fail('unclosed attribute');value=text.slice(start,i++);if(i<text.length&&!space(text[i])&&text[i]!=='>'&&text[i]!=='/')fail('invalid quoted attribute');}else{const start=i;while(i<text.length&&!space(text[i])&&text[i]!=='>'){if(/["'<=`\x00]/.test(text[i]))fail('invalid unquoted attribute');i++;}if(i===start)fail('empty unquoted attribute');value=text.slice(start,i);}
 if(['src','href','xlink:href','poster','data'].includes(name))admit(value,file.path);else if(name==='srcset'){if(value.startsWith('data:'))fail('unsupported srcset data');for(const entry of value.split(',')){const parts=entry.trim().split(/\s+/);if(parts.length>2||parts[1]&&!/^(?:[0-9]+w|[0-9]+(?:\.[0-9]+)?x)$/.test(parts[1]))fail('invalid srcset');admit(parts[0],file.path);}}else if(['style','fill','stroke','filter','mask','clip-path','marker-start','marker-mid','marker-end'].includes(name)){if(value.includes('&'))fail('unsupported dependency entity');css(value,file.path);}}
 if(!ended)fail('unclosed tag');if(!closing&&(tag==='script'||tag==='style')){if(selfClosing&&/\.html$/i.test(file.path))fail('self-closing raw HTML');if(!selfClosing){const lower=text.toLowerCase();let end=lower.indexOf('</'+tag,i);while(end>=0&&!/[\t\n\r\f >]/.test(text[end+tag.length+2]??''))end=lower.indexOf('</'+tag,end+2);if(end<0)fail('unclosed raw text');if(tag==='style')css(text.slice(i,end),file.path);i=end;}}}}
 return {requiredAssets:[...local].sort(),externalDependencies:[...external].sort()};
}
/** Optional SDK manifest must enumerate the complete materialized package. */
export function validateCatalogManifest(files:CatalogPackageFile[],textFiles:{path:string;content:string}[]):void {
 const source=textFiles.find(f=>f.path==='manifest.json');if(!source)return;let m:any;try{m=JSON.parse(source.content);}catch{return fail('invalid SDK manifest JSON');}
 if(!plain(m)||m.schemaVersion!==1||m.sdkVersion!=='1'||m.entrypoint!=='index.html'||!['dashboardId','name','revision'].every(k=>bounded(m[k],160))||/password|secret|token|api[_-]?key|bearer/.test(m.dashboardId+m.name+m.entrypoint)||!plain(m.target)||!bounded(m.target.profileId,160)||!integer(m.target.width,Number.MAX_SAFE_INTEGER)||!integer(m.target.height,Number.MAX_SAFE_INTEGER)||typeof m.target.scale!=='number'||!Number.isFinite(m.target.scale)||!['portrait','landscape'].includes(m.target.orientation)||!Array.isArray(m.connections)||m.connections.length>20||!Array.isArray(m.files)||m.files.length>20)fail('invalid SDK manifest');
 const aliases=new Set<string>();for(const c of m.connections){if(!plain(c)||!bounded(c.alias,160)||typeof c.required!=='boolean'||aliases.has(c.alias))fail('invalid manifest connection');aliases.add(c.alias);if(c.operations!==undefined&&(!Array.isArray(c.operations)||c.operations.some((o:any)=>!plain(o)||!bounded(o.name,160)||!bounded(o.kind,160))))fail('invalid manifest operations');}
 const actual=new Map(files.filter(f=>f.path!=='manifest.json').map(f=>[f.path,f]));if(m.files.length!==actual.size)fail('incomplete SDK manifest');const seen=new Set();let total=0;for(const d of m.files){if(!plain(d)||!catalogSafePath(d.path)||seen.has(d.path)||!integer(d.bytes,204800,0)||!digest(d.sha256))fail('invalid SDK manifest file');const file=actual.get(d.path);if(!file||d.bytes!==file.byteLength||d.sha256!==file.digest)fail('SDK manifest integrity mismatch');seen.add(d.path);total+=d.bytes;}if(!seen.has('index.html')||total>204800)fail('invalid SDK manifest entry');
}
