import definition from './generated/authoring-v2-definition';
import { AUTHORING_DEFINITION, AuthoringContractError, canonicalJSON, sealAuthoringRequest, validateAuthoringRequest, validateAuthoringResult, validateAuthoringScreen, type AuthoringRequestV1, type AuthoringResultV1, type AuthoringScreen, type JSONSchema } from './authoring';
export interface AuthoringSourceFileV2 { path: string; mediaType: string; byteLength: number; digest: string; reference: string; content?: string }
export interface AuthoringSourceScreenV2 { title: string; entry: 'index.html'; files: AuthoringSourceFileV2[] }
export interface AuthoringContextV2 extends Omit<AuthoringRequestV1['context'],'currentScreen'> { libraryID: string; currentScreen?: AuthoringSourceScreenV2 }
export interface AuthoringRequestV2 extends Omit<AuthoringRequestV1,'schemaVersion'|'context'|'delivery'> { schemaVersion: 2; context: AuthoringContextV2; delivery: { route: 'cloud'|'local'|'fixture'; contractVersion: '2'; snapshotDigest: string } }
export type AuthoringFileMutationV2 = {kind:'write';path:string;content:string} | {kind:'retain';path:string;sourcePath:string;reference:string;digest:string};
export interface AuthoringScreenMutationV2 { title:string;entry:'index.html';files:AuthoringFileMutationV2[];deletedPaths:string[];requiredAssets?:string[] }
export interface AuthoringResultV2 extends Omit<AuthoringResultV1,'schemaVersion'|'screen'> { schemaVersion:2;screen?:AuthoringScreenMutationV2 }
export interface AuthoringCapabilitiesV2 { contractVersions: string[]; features: string[] }
export const AUTHORING_V2_CAPABILITIES: Readonly<AuthoringCapabilitiesV2> = Object.freeze({contractVersions:Object.freeze(['1','2']) as unknown as string[],features:Object.freeze(['asset-references-v2']) as unknown as string[]});
export function supportsAuthoringV2(value: unknown): boolean { const v = value as AuthoringCapabilitiesV2 | null; return !!v && Array.isArray(v.contractVersions) && v.contractVersions.includes('2') && Array.isArray(v.features) && v.features.includes('asset-references-v2'); }
const fail = (message:string):never => {throw new AuthoringContractError(message)};
const utf8 = (text:string) => new TextEncoder().encode(text);
const plain = (v:unknown):v is Record<string,any> => typeof v === 'object' && v !== null && !Array.isArray(v) && (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
function inline(schema:JSONSchema,defs:JSONSchema = schema.$defs):JSONSchema { if(schema.$ref) return inline(defs[schema.$ref.split('/').pop()!],defs); return Object.fromEntries(Object.entries(schema).filter(([k])=>!['$defs','$id','$schema'].includes(k)).map(([k,v])=>[k,Array.isArray(v)?v.map(x=>plain(x)?inline(x,defs):x):plain(v)?inline(v,defs):v])); }
export const AUTHORING_REQUEST_V2_SCHEMA = inline(definition.schemas.Request);
export const AUTHORING_RESULT_V2_SCHEMA = inline(definition.schemas.Result);

const schemaFail = (message:string,path="$"):never => {throw new AuthoringContractError(message,path)};
function check(schema: JSONSchema, value: any, defs: JSONSchema, path: string, depth = 0): void {
  if (depth > 64) schemaFail("nesting limit", path);
  if (schema.$ref) {
    const key = schema.$ref.split("/").pop()!;
    if (!Object.hasOwn(defs,key)) schemaFail("unknown schema reference",path);
    return check(defs[key], value, defs, path, depth + 1);
  }
  if (schema.anyOf) { for (const option of schema.anyOf) { try { check(option, value, defs, path, depth + 1); return; } catch {} } schemaFail("does not match allowed value", path); }
  if ("const" in schema && canonicalJSON(value) !== canonicalJSON(schema.const)) schemaFail("unexpected constant/version", path);
  if (schema.enum && !schema.enum.includes(value)) schemaFail("unsupported enum", path);
  const types = schema.type ? (Array.isArray(schema.type) ? schema.type : [schema.type]) : [];
  const matches = (t: string) => t === "null" ? value === null : t === "object" ? plain(value) : t === "array" ? Array.isArray(value) : t === "integer" ? typeof value === "number" && Number.isSafeInteger(value) : t === "number" ? typeof value === "number" && Number.isFinite(value) : typeof value === t;
  if (types.length && !types.some(matches)) schemaFail("invalid type", path);
  if (typeof value === "string") {
    const length = Array.from(value).length;
    if ((schema.minLength !== undefined && length < schema.minLength) || (schema.maxLength !== undefined && length > schema.maxLength) || (schema.maxBytes !== undefined && utf8(value).length > schema.maxBytes)) schemaFail("string size limit", path);
    if (schema.pattern) { const match = new RegExp(schema.pattern, "u").exec(value); if (!match || match[0] !== value) schemaFail("invalid string", path); }
  }
  if (typeof value === "number" && ((schema.minimum !== undefined && value < schema.minimum) || (schema.maximum !== undefined && value > schema.maximum))) schemaFail("number out of bounds", path);
  if (Array.isArray(value)) {
    if ((schema.minItems !== undefined && value.length < schema.minItems) || (schema.maxItems !== undefined && value.length > schema.maxItems)) schemaFail("array size limit", path);
    if (schema.items) value.forEach((v, i) => check(schema.items, v, defs, `${path}[${i}]`, depth + 1));
  }
  if (plain(value)) {
    if (schema.maxProperties !== undefined && Object.keys(value).length > schema.maxProperties) schemaFail("object size limit", path);
    for (const key of schema.required ?? []) if (!Object.hasOwn(value, key)) schemaFail("missing required field", `${path}.${key}`);
    for (const [key, v] of Object.entries(value)) {
      if (schema.propertyNames) check(schema.propertyNames, key, defs, `${path}.${key}`, depth + 1);
      const properties = schema.properties ?? {};
      const child = Object.hasOwn(properties,key) ? properties[key] : undefined;
      if (child) check(child, v, defs, `${path}.${key}`, depth + 1);
      else if (schema.additionalProperties === false) schemaFail("unknown field", `${path}.${key}`);
      else if (plain(schema.additionalProperties)) check(schema.additionalProperties, v, defs, `${path}.${key}`, depth + 1);
    }
  }
}
function validateSchema(name:'Request'|'Result',value:unknown):void { const schema = definition.schemas[name] as JSONSchema; canonicalJSON(value);check(schema,value,schema.$defs,'$'); }
export function authoringMediaTypeV2(path:string):string { return ({html:'text/html',css:'text/css',js:'text/javascript',json:'application/json',svg:'image/svg+xml',txt:'text/plain'} as Record<string,string>)[path.split('.').pop()!] ?? fail('unsupported file extension'); }
export async function authoringContentDigestV2(data:Uint8Array|string):Promise<string> { const bytes=typeof data==='string'?utf8(data):new Uint8Array(data);const hash=await crypto.subtle.digest('SHA-256',bytes);return Array.from(new Uint8Array(hash),b=>b.toString(16).padStart(2,'0')).join(''); }
export async function authoringReferenceV2(request:AuthoringRequestV2,file:AuthoringSourceFileV2):Promise<string> { return authoringContentDigestV2(canonicalJSON({version:2,requestID:request.requestID,profileID:request.context.profileID,libraryID:request.context.libraryID,screenID:request.context.screenID,baseRevision:request.context.baseRevision,path:file.path,mediaType:file.mediaType,byteLength:file.byteLength,digest:file.digest})); }
export async function authoringSnapshotDigestV2(request:AuthoringRequestV2):Promise<string> {const copy=structuredClone(request) as any;delete copy.delivery.snapshotDigest;return authoringContentDigestV2(canonicalJSON(copy));}
function legacyRequest(request:AuthoringRequestV2):AuthoringRequestV1 {const {libraryID,currentScreen,...context}=request.context;return {...request,schemaVersion:1,context,delivery:{...request.delivery,contractVersion:'1'}};}
export function validateAuthoringRequestV2(value:unknown):AuthoringRequestV2 {
 validateSchema('Request',value);const request=value as AuthoringRequestV2;validateAuthoringRequest(legacyRequest(request));
 const source=request.context.currentScreen;
 if(!!source !== (request.context.baseRevision !== null)) fail('base revision and source manifest must appear together');
 if(source) {
  if(!source.title.trim() || source.title.length>100) fail('invalid source title');
  const paths=new Set<string>();let bytes=0;
  for(const file of source.files) {if(paths.has(file.path.toLowerCase()))fail('duplicate source path');paths.add(file.path.toLowerCase());if(file.mediaType!==authoringMediaTypeV2(file.path))fail('source media type mismatch');bytes+=file.byteLength;if(file.content!==undefined&&utf8(file.content).length!==file.byteLength)fail('source byte length mismatch');}
  if(!source.files.some(f=>f.path==='index.html') || bytes>204800)fail('source package limit/entry');
 }
 if(utf8(canonicalJSON(request)).length>393216)fail('request byte limit');
 return request;
}
export async function verifyAuthoringReferencesV2(request:AuthoringRequestV2):Promise<boolean> {validateAuthoringRequestV2(request);for(const file of request.context.currentScreen?.files??[])if(file.reference!==await authoringReferenceV2(request,file)||(file.content!==undefined&&file.digest!==await authoringContentDigestV2(file.content)))return false;return true;}
export async function verifyAuthoringRequestDigestV2(request:AuthoringRequestV2):Promise<boolean> {return await verifyAuthoringReferencesV2(request)&&(await authoringSnapshotDigestV2(request))===request.delivery.snapshotDigest;}
export async function sealAuthoringRequestV2(request:AuthoringRequestV2):Promise<AuthoringRequestV2> {const copy=structuredClone(request);for(const file of copy.context.currentScreen?.files??[])file.reference=await authoringReferenceV2(copy,file);copy.delivery.snapshotDigest=await authoringSnapshotDigestV2(copy);validateAuthoringRequestV2(copy);if(!await verifyAuthoringReferencesV2(copy))fail('source content digest mismatch');return copy;}
export async function makeAuthoringRequestV2(request:AuthoringRequestV1,libraryID:string,includeContent:(file:{path:string;content:string})=>boolean=file=>!(file.path.endsWith('.svg')&&/data:image\/|base64,/i.test(file.content))):Promise<AuthoringRequestV2> {
 validateAuthoringRequest(request);const {currentScreen,...context}=request.context;const files:AuthoringSourceFileV2[]=[];
 for(const file of currentScreen?.files??[])files.push({path:file.path,mediaType:authoringMediaTypeV2(file.path),byteLength:utf8(file.content).length,digest:await authoringContentDigestV2(file.content),reference:'0'.repeat(64),...(includeContent(file)?{content:file.content}:{})});
 return sealAuthoringRequestV2({...request,schemaVersion:2,context:{...context,libraryID,...(currentScreen?{currentScreen:{title:currentScreen.title,entry:currentScreen.entry,files}}:{})},delivery:{...request.delivery,contractVersion:'2'}});
}
export function validateAuthoringResultV2(value:unknown,request?:AuthoringRequestV2):AuthoringResultV2 {
 validateSchema('Result',value);const result=value as AuthoringResultV2;
 if(!result.screen&&!result.answer&&!result.preferenceMutations?.length)fail('empty result');
 const {screen,...metadata}=result;
 const legacy:AuthoringResultV1={...metadata,schemaVersion:1,...(!result.answer&&!result.preferenceMutations?.length?{answer:'v2 screen validation'}:{})};
 if(request){validateAuthoringRequestV2(request);if(result.requestID!==request.requestID||result.inputDigest!==request.delivery.snapshotDigest||result.baseRevision!==request.context.baseRevision)fail('result is not bound to request snapshot');}
 validateAuthoringResult(legacy,request?legacyRequest(request):undefined);
 if(utf8(canonicalJSON(result)).length>393216||utf8(canonicalJSON(metadata)).length>131072)fail('result byte limit');
 if(screen){
  if(!screen.title.trim()||screen.title.length>100)fail('invalid screen title');
  const targets=new Set<string>();const deleted=new Set<string>();const base=request?.context.currentScreen?.files??[];
  for(const path of screen.deletedPaths){if(deleted.has(path.toLowerCase()))fail('duplicate deleted path');deleted.add(path.toLowerCase());}
  let total=0;
  for(const file of screen.files){const path=file.path.toLowerCase();if(targets.has(path)||deleted.has(path))fail('duplicate/overlapping destination');targets.add(path);
   if(file.kind==='write')total+=utf8(file.content).length;
   else if(request){const source=base.find(f=>f.path===file.sourcePath&&f.reference===file.reference&&f.digest===file.digest);if(!source)fail('unknown/out-of-scope source reference');total+=source!.byteLength;}
  }
  if(!screen.files.some(f=>f.path==='index.html')||total>204800)fail('materialized entry/byte limit');
  const required=new Set<string>();for(const path of screen.requiredAssets??[]){if(required.has(path.toLowerCase())||!screen.files.some(f=>f.path===path))fail('missing/duplicate declared asset');required.add(path.toLowerCase());}
  if(request){for(const path of screen.deletedPaths)if(!base.some(f=>f.path===path))fail('delete outside base snapshot');for(const file of base)if(!screen.files.some(f=>f.path===file.path)&&!screen.deletedPaths.includes(file.path))fail('unaccounted base file');}
 }
 return result;
}
/** Materialize exact UTF8 bytes after request digest/reference verification, before native dependency checks and atomic installation. */
export async function materializeAuthoringResultV2(result:AuthoringResultV2,request:AuthoringRequestV2,resolve:(file:AuthoringSourceFileV2)=>Promise<Uint8Array>|Uint8Array):Promise<AuthoringScreen|undefined> {
 if(!await verifyAuthoringRequestDigestV2(request))fail('snapshot/reference digest mismatch');validateAuthoringResultV2(result,request);if(!result.screen)return undefined;const files=[];
 for(const file of result.screen.files){if(file.kind==='write'){files.push({path:file.path,content:file.content});continue;}const source=request.context.currentScreen!.files.find(f=>f.path===file.sourcePath)!;const bytes=await resolve(source);if(bytes.length!==source.byteLength||await authoringContentDigestV2(bytes)!==source.digest)fail('pinned source corrupt/missing');let content:string;try{content=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);}catch{fail('source is not UTF8');}files.push({path:file.path,content:content!});}
 return validateAuthoringScreen({title:result.screen.title,entry:result.screen.entry,files});
}
