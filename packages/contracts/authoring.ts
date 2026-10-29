import definition from "./generated/authoring-definition";

export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
export type JSONSchema = { [key: string]: any };
export interface AuthoringDesignGuidanceV1 { version: "1"; rules: string[] }
export interface AuthoringRuntimeV1 { version: "1"; packageFormat: "utf8-files-v1"; features: string[]; limits: { metadataBytes: 131072; requestBytes: 393216; screenBytes: 204800; screenFiles: 20 } }
export interface AuthoringOperationV1 { name: string; kind: "http" | "event"; inputSchema: JSONSchema; outputSchema: JSONSchema; requirements: string[]; instructions: string }
export interface CapabilityState { state: "yes" | "no" | "unknown"; observedAt: number }
export interface AuthoringServiceV1 { id: string; provider: "home" | "googleTV" | "googleCalendar" | "appleMaps" | "publicHTTP"; operations: AuthoringOperationV1[]; supported: CapabilityState; configured: CapabilityState; authorized: CapabilityState; entitled: CapabilityState; reachable: CapabilityState }
export interface AuthoringServiceDefinitionV1 { id: string; provider: AuthoringServiceV1["provider"]; operations: AuthoringOperationV1[]; setupInstructions: string }
export interface AuthoringScreen { title: string; entry: "index.html"; files: { path: string; content: string }[] }
export interface PreferenceRecordV1 { id: string; scope: "profile" | "device" | "screen"; targetID: string; category: string; value: string | number | boolean | null; revision: number; originRequestID: string; deleted: boolean }
export interface PreferenceMutationV1 { kind: "upsert" | "delete"; id: string; expectedRevision: number | null; record?: PreferenceRecordV1 }
export interface DurablePreferenceAuthorizationV1 { requestID: string; quote: string }
export interface AuthoringRequestV1 { schemaVersion: 1; requestID: string; createdAt: number; deadlineAt: number; designGuidance: AuthoringDesignGuidanceV1; runtime: AuthoringRuntimeV1; services: AuthoringServiceV1[]; preferences: PreferenceRecordV1[]; context: { profileID: string; deviceID: string; screenID: string; baseRevision: string | null; userRequest: string; currentScreen?: AuthoringScreen; viewport: { width: number; height: number; scale: number; orientation: "portrait" | "landscape" } }; delivery: { route: "cloud" | "fixture" | "local"; contractVersion: "1"; snapshotDigest: string } }
export interface AuthoringResultV1 { schemaVersion: 1; requestID: string; inputDigest: string; baseRevision: string | null; preferenceRevisions: Record<string, number>; operationID: string; screen?: AuthoringScreen; answer?: string; preferenceMutations?: PreferenceMutationV1[]; durablePreferenceAuthorization?: DurablePreferenceAuthorizationV1 }
export interface ApplicationReceiptV1 { schemaVersion: 1; requestID: string; operationID: string; inputDigest: string; status: "applied" | "conflict" | "rejected"; appliedAt: number; message?: string }
export interface AuthoringDefinitionV1 { schemaVersion: 1; designGuidance: AuthoringDesignGuidanceV1; runtime: AuthoringRuntimeV1; serviceCatalog: AuthoringServiceDefinitionV1[]; schemas: Record<"Request" | "Result" | "Preference" | "Receipt", JSONSchema> }
const baseDefinition = definition as unknown as AuthoringDefinitionV1;
function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === "object") { for (const item of Object.values(value)) deepFreeze(item); Object.freeze(value); }
  return value;
}
export const AUTHORING_DEFINITION = deepFreeze({ ...baseDefinition, schemas: { ...baseDefinition.schemas, request: baseDefinition.schemas.Request, result: baseDefinition.schemas.Result, preference: baseDefinition.schemas.Preference, receipt: baseDefinition.schemas.Receipt } });
export const SCREEN_AUTHORING_GUIDANCE: readonly string[] = AUTHORING_DEFINITION.designGuidance.rules;
function inlineSchema(schema: JSONSchema, defs: JSONSchema = schema.$defs): JSONSchema {
  if (schema.$ref) return inlineSchema(defs[schema.$ref.split("/").pop()!], defs);
  return Object.fromEntries(Object.entries(schema).filter(([key]) => !["$defs", "$id", "$schema"].includes(key)).map(([key, value]) => [key, Array.isArray(value) ? value.map(v => plainSchema(v) ? inlineSchema(v, defs) : v) : plainSchema(value) ? inlineSchema(value, defs) : value]));
}
function plainSchema(v: unknown): v is JSONSchema { return typeof v === "object" && v !== null && !Array.isArray(v); }
export const AUTHORING_REQUEST_SCHEMA = inlineSchema(baseDefinition.schemas.Request);
export const AUTHORING_RESULT_SCHEMA = inlineSchema(baseDefinition.schemas.Result);
export const AUTHORING_PREFERENCE_SCHEMA = inlineSchema(baseDefinition.schemas.Preference);
export const AUTHORING_RECEIPT_SCHEMA = inlineSchema(baseDefinition.schemas.Receipt);
export const AUTHORING_RESULT_LIMITS = Object.freeze({ metadataBytes: 131072, resultBytes: 393216 });
export class AuthoringContractError extends Error {
  constructor(message: string, public path = "$") { super(`${path}: ${message}`); this.name = "AuthoringContractError"; }
}
const utf8 = (s: string) => new TextEncoder().encode(s).byteLength;
const fail = (message: string, path = "$"): never => { throw new AuthoringContractError(message, path); };
const plain = (v: unknown): v is Record<string, any> => typeof v === "object" && v !== null && !Array.isArray(v) && (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
/** Deterministic UTF-8 JSON: UTF-16 sorted keys, JSON string escaping, finite IEEE-754 numbers. No Unicode normalization. */
export function canonicalJSON(value: unknown): string {
  const visit = (v: unknown, depth: number): string => {
    if (depth > 64) return fail("JSON nesting exceeds 64");
    if (v === null || typeof v === "boolean" || typeof v === "string") return JSON.stringify(v);
    if (typeof v === "number") { if (!Number.isFinite(v)) return fail("nonfinite number"); return JSON.stringify(v); }
    if (Array.isArray(v)) return `[${v.map(x => visit(x, depth + 1)).join(",")}]`;
    if (plain(v)) return `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${visit(v[k], depth + 1)}`).join(",")}}`;
    return fail("unsupported JSON value");
  };
  return visit(value, 0);
}
function check(schema: JSONSchema, value: any, defs: JSONSchema, path: string, depth = 0): void {
  if (depth > 64) fail("nesting limit", path);
  if (schema.$ref) {
    const key = schema.$ref.split("/").pop()!;
    if (!Object.hasOwn(defs,key)) fail("unknown schema reference",path);
    return check(defs[key], value, defs, path, depth + 1);
  }
  if (schema.anyOf) { for (const option of schema.anyOf) { try { check(option, value, defs, path, depth + 1); return; } catch {} } fail("does not match allowed value", path); }
  if ("const" in schema && canonicalJSON(value) !== canonicalJSON(schema.const)) fail("unexpected constant/version", path);
  if (schema.enum && !schema.enum.includes(value)) fail("unsupported enum", path);
  const types = schema.type ? (Array.isArray(schema.type) ? schema.type : [schema.type]) : [];
  const matches = (t: string) => t === "null" ? value === null : t === "object" ? plain(value) : t === "array" ? Array.isArray(value) : t === "integer" ? typeof value === "number" && Number.isSafeInteger(value) : t === "number" ? typeof value === "number" && Number.isFinite(value) : typeof value === t;
  if (types.length && !types.some(matches)) fail("invalid type", path);
  if (typeof value === "string") {
    const length = Array.from(value).length;
    if ((schema.minLength !== undefined && length < schema.minLength) || (schema.maxLength !== undefined && length > schema.maxLength) || (schema.maxBytes !== undefined && utf8(value) > schema.maxBytes)) fail("string size limit", path);
    if (schema.pattern) { const match = new RegExp(schema.pattern, "u").exec(value); if (!match || match[0] !== value) fail("invalid string", path); }
  }
  if (typeof value === "number" && ((schema.minimum !== undefined && value < schema.minimum) || (schema.maximum !== undefined && value > schema.maximum))) fail("number out of bounds", path);
  if (Array.isArray(value)) {
    if ((schema.minItems !== undefined && value.length < schema.minItems) || (schema.maxItems !== undefined && value.length > schema.maxItems)) fail("array size limit", path);
    if (schema.items) value.forEach((v, i) => check(schema.items, v, defs, `${path}[${i}]`, depth + 1));
  }
  if (plain(value)) {
    if (schema.maxProperties !== undefined && Object.keys(value).length > schema.maxProperties) fail("object size limit", path);
    for (const key of schema.required ?? []) if (!Object.hasOwn(value, key)) fail("missing required field", `${path}.${key}`);
    for (const [key, v] of Object.entries(value)) {
      if (schema.propertyNames) check(schema.propertyNames, key, defs, `${path}.${key}`, depth + 1);
      const properties = schema.properties ?? {};
      const child = Object.hasOwn(properties,key) ? properties[key] : undefined;
      if (child) check(child, v, defs, `${path}.${key}`, depth + 1);
      else if (schema.additionalProperties === false) fail("unknown field", `${path}.${key}`);
      else if (plain(schema.additionalProperties)) check(schema.additionalProperties, v, defs, `${path}.${key}`, depth + 1);
    }
  }
}
function validate(name: "Request" | "Result" | "Preference" | "Receipt", value: unknown): void {
  const schema = AUTHORING_DEFINITION.schemas[name];
  canonicalJSON(value); check(schema, value, schema.$defs, "$");
}
export function validateAuthoringScreen(value: unknown): AuthoringScreen {
  const schema = AUTHORING_DEFINITION.schemas.Request.$defs;
  canonicalJSON(value); check(schema.Screen,value,schema,"$.screen");
  const screen = value as AuthoringScreen;
  screenBounds(screen); return screen;
}
function screenBounds(screen: AuthoringScreen): void {
  if (!screen.title.trim() || screen.title.length > 100) fail("screen title requires 1–100 UTF16 code units", "$.screen.title");
  const paths = new Set<string>();
  for (const file of screen.files) {
    const path = file.path;
    if (!/^[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*\.(?:html|css|js|json|svg|txt)$/.test(path) || paths.has(path.toLowerCase())) fail("unsafe/duplicate screen path", "$.screen.files");
    paths.add(path.toLowerCase());
  }
  if (!screen.files.some(f => f.path === "index.html") || utf8(canonicalJSON(screen)) > 204800) fail("screen entry/serialized size limit", "$.screen");
}
export function makeAuthoringServices(observedAt: number): AuthoringServiceV1[] {
  return AUTHORING_DEFINITION.serviceCatalog.map(service => ({id:service.id,provider:service.provider,operations:structuredClone(service.operations),supported:{state:"yes",observedAt},configured:{state:service.provider === "googleCalendar" ? "no" : "unknown",observedAt},authorized:{state:"unknown",observedAt},entitled:{state:"unknown",observedAt},reachable:{state:"unknown",observedAt}}));
}
export function validatePreferenceRecord(value: unknown): PreferenceRecordV1 { validate("Preference",value); return value as PreferenceRecordV1; }
export function validateAuthoringRequest(value: unknown): AuthoringRequestV1 {
  validate("Request", value); const request = value as AuthoringRequestV1;
  if (request.deadlineAt <= request.createdAt) fail("deadline must follow creation");
  if (canonicalJSON(request.designGuidance) !== canonicalJSON(AUTHORING_DEFINITION.designGuidance) || canonicalJSON(request.runtime) !== canonicalJSON(AUTHORING_DEFINITION.runtime)) fail("unsupported guidance/runtime definition");
  const seen = new Set<string>();
  for (const service of request.services) {
    if (seen.has(service.id)) fail("duplicate service id"); seen.add(service.id);
    const catalog = AUTHORING_DEFINITION.serviceCatalog.find(x => x.provider === service.provider);
    if (!catalog || canonicalJSON(catalog.operations) !== canonicalJSON(service.operations)) fail("unsupported provider operation definitions");
    if (service.provider === "googleCalendar" && service.configured.state !== "no") fail("Calendar OAuth configuration is unavailable in this build");
    for (const key of ["supported","configured","authorized","entitled","reachable"] as const) if (service[key].observedAt > request.createdAt) fail("capability observation is in the future");
  }
  const prefs = new Set<string>();
  for (const p of request.preferences) {
    if (prefs.has(p.id)) fail("duplicate preference id"); prefs.add(p.id);
    const target = p.scope === "profile" ? request.context.profileID : p.scope === "device" ? request.context.deviceID : request.context.screenID;
    if (p.targetID !== target) fail("preference target does not match request scope");
  }
  if (request.context.currentScreen) screenBounds(request.context.currentScreen);
  const metadata = structuredClone(request); delete metadata.context.currentScreen;
  if (utf8(canonicalJSON(metadata)) > 131072 || utf8(canonicalJSON(request)) > 393216) fail("request byte limit");
  return request;
}
export function validateAuthoringResult(value: unknown, request?: AuthoringRequestV1): AuthoringResultV1 {
  validate("Result", value); const result = value as AuthoringResultV1;
  if (result.answer !== undefined && (!result.answer.trim() || result.answer.length > 16000)) fail("answer requires 1–16000 UTF16 code units", "$.answer");
  if (utf8(canonicalJSON(result)) > AUTHORING_RESULT_LIMITS.resultBytes) fail("result byte limit");
  const metadata = structuredClone(result); delete metadata.screen;
  if (utf8(canonicalJSON(metadata)) > AUTHORING_RESULT_LIMITS.metadataBytes) fail("result metadata byte limit");
  if (!result.screen && !result.answer && !result.preferenceMutations?.length) fail("empty result");
  if (result.screen) screenBounds(result.screen);
  const mutations = result.preferenceMutations ?? []; const seen = new Set<string>();
  if (mutations.length && (!result.durablePreferenceAuthorization || result.durablePreferenceAuthorization.requestID !== result.requestID || !/\b(remember|always)\b/i.test(result.durablePreferenceAuthorization.quote))) fail("explicit durable preference authorization required");
  for (const mutation of mutations) {
    if (seen.has(mutation.id)) fail("duplicate preference mutation"); seen.add(mutation.id);
    if (mutation.kind === "upsert") {
      if (!mutation.record || mutation.record.id !== mutation.id || mutation.record.revision !== (mutation.expectedRevision ?? 0) + 1 || mutation.record.originRequestID !== result.requestID || mutation.record.deleted) fail("invalid upsert revision/record");
    } else if (mutation.record !== undefined || mutation.expectedRevision === null) fail("invalid delete mutation");
  }
  if (request) {
    validateAuthoringRequest(request);
    if (result.requestID !== request.requestID || result.inputDigest !== request.delivery.snapshotDigest || result.baseRevision !== request.context.baseRevision) fail("result is not bound to request snapshot");
    const revisions = Object.fromEntries(request.preferences.map(p => [p.id,p.revision]));
    if (canonicalJSON(revisions) !== canonicalJSON(result.preferenceRevisions)) fail("preference revisions differ from snapshot");
    if (mutations.length && !request.context.userRequest.includes(result.durablePreferenceAuthorization!.quote)) fail("authorization quote not present in user request");
    for (const mutation of mutations) {
      const old = request.preferences.find(x => x.id === mutation.id);
      if ((old?.revision ?? null) !== mutation.expectedRevision) fail("mutation expected revision differs from snapshot");
      if (mutation.record) {
        const p = mutation.record; const target = p.scope === "profile" ? request.context.profileID : p.scope === "device" ? request.context.deviceID : request.context.screenID;
        if (p.targetID !== target) fail("mutation target outside request scope");
        if (old && (old.scope !== p.scope || old.targetID !== p.targetID)) fail("cannot move preference scope/target");
      }
    }
  }
  return result;
}
export function validateApplicationReceipt(value: unknown): ApplicationReceiptV1 { validate("Receipt",value); return value as ApplicationReceiptV1; }
export async function authoringSnapshotDigest(request: AuthoringRequestV1): Promise<string> {
  const copy = structuredClone(request) as any; delete copy.delivery.snapshotDigest;
  const digest = await crypto.subtle.digest("SHA-256",new TextEncoder().encode(canonicalJSON(copy)));
  return Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,"0")).join("");
}
export async function sealAuthoringRequest(request: AuthoringRequestV1): Promise<AuthoringRequestV1> {
  const copy = structuredClone(request); copy.delivery.snapshotDigest = await authoringSnapshotDigest(copy); return validateAuthoringRequest(copy);
}
export async function verifyAuthoringRequestDigest(request: AuthoringRequestV1): Promise<boolean> { validateAuthoringRequest(request); return (await authoringSnapshotDigest(request)) === request.delivery.snapshotDigest; }
