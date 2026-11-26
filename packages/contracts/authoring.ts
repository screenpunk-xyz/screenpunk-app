import definition from "./generated/authoring-definition";
import { validateManifestScreenData } from "./screen-data";

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
export interface AuthoringDefinitionV1 { schemaVersion: 1; designGuidance: AuthoringDesignGuidanceV1; runtime: AuthoringRuntimeV1; browser: {designGuidance: AuthoringDesignGuidanceV1; runtime: AuthoringRuntimeV1}; serviceCatalog: AuthoringServiceDefinitionV1[]; schemas: Record<"Request" | "Result" | "Preference" | "Receipt", JSONSchema>; screenData: { version: 1; features: string[]; rules: string[]; manifestSchema: JSONSchema }; customHTTP: { rules: string[] } }
const baseDefinition = definition as unknown as AuthoringDefinitionV1;
function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === "object") { for (const item of Object.values(value)) deepFreeze(item); Object.freeze(value); }
  return value;
}
export const AUTHORING_DEFINITION = deepFreeze({ ...baseDefinition, schemas: { ...baseDefinition.schemas, request: baseDefinition.schemas.Request, result: baseDefinition.schemas.Result, preference: baseDefinition.schemas.Preference, receipt: baseDefinition.schemas.Receipt } });
export const SCREEN_AUTHORING_GUIDANCE: readonly string[] = AUTHORING_DEFINITION.designGuidance.rules;
export function browserAuthoringRuntime(): AuthoringRuntimeV1 {
  return structuredClone(AUTHORING_DEFINITION.browser.runtime);
}
export function browserAuthoringDesignGuidance(): AuthoringDesignGuidanceV1 {
  return structuredClone(AUTHORING_DEFINITION.browser.designGuidance);
}
function isBrowserRuntime(runtime: AuthoringRuntimeV1): boolean {
  return canonicalJSON(runtime) === canonicalJSON(AUTHORING_DEFINITION.browser.runtime);
}
export function authoringRuntime(supportsScreenData: boolean, supportsCustomHTTP = false, supportsConnectionPrefill = false, supportsCredentialHandoff = false, supportsCredentialRegistration = false, supportsPublicPageText = false): AuthoringRuntimeV1 {
  const { runtime, screenData } = AUTHORING_DEFINITION;
  return { ...runtime, features: [...runtime.features, ...(supportsScreenData ? screenData.features : []), ...(supportsCustomHTTP ? [CUSTOM_HTTP_FEATURE] : []), ...(supportsConnectionPrefill ? [CONNECTION_PREFILL_FEATURE] : []), ...(supportsCredentialHandoff ? [CREDENTIAL_HANDOFF_FEATURE] : []), ...(supportsCredentialRegistration ? [CREDENTIAL_REGISTRATION_FEATURE] : []), ...(supportsPublicPageText ? [PUBLIC_PAGE_TEXT_FEATURE] : [])] };
}
export function authoringDesignGuidance(supportsScreenData: boolean, supportsCustomHTTP = false, supportsConnectionPrefill = false, supportsCredentialHandoff = false, supportsCredentialRegistration = false, supportsPublicPageText = false): AuthoringDesignGuidanceV1 {
  const { designGuidance, screenData } = AUTHORING_DEFINITION;
  return { ...designGuidance, rules: [...designGuidance.rules, ...(supportsScreenData ? screenData.rules : []), ...(supportsCustomHTTP ? AUTHORING_DEFINITION.customHTTP.rules : []), ...(supportsConnectionPrefill ? [CONNECTION_PREFILL_RULE] : []), ...(supportsCredentialHandoff ? [CREDENTIAL_HANDOFF_RULE] : []), ...(supportsCredentialRegistration ? [CREDENTIAL_REGISTRATION_RULE] : []), ...(supportsPublicPageText ? [PUBLIC_PAGE_TEXT_RULE] : [])] };
}
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
  const manifest = screen.files.find(f => f.path === "manifest.json");
  if (manifest) checkAuthoringManifestScreenData(manifest.content);
}
export const PUBLIC_PAGE_TEXT_FEATURE = "public-page-text-v1";
export const PUBLIC_PAGE_TEXT_RULE = "Prefer a documented structured feed when it provides the same information. With public-page-text-v1, a server-rendered public HTTPS page can use publicHTTP with an operation such as {\"name\":\"status\",\"path\":\"/status\",\"response\":\"text\",\"parameters\":{},\"maxAgeSeconds\":900,\"staleSeconds\":3600}. Use the actual fixed path without query or fragment and mark the connection required for an inline approval prompt. If a documented month-paged calendar requires cal_date, declare it as a bounded integer query parameter and pass the documented date value as a string. Call await screenpunk.connections.read(alias, operation, parameters, {signal}) with {} for unparameterized pages and read result.text. The native host fetches UTF-8 HTML or plain text directly and returns the decoded response as text, up to 256 KiB. Website scripts, subresources, forms, sign-in and redirects are unavailable. Parse expected labels or values as inert data. Render only the extracted values with textContent. Never insert response markup into a document. Keep private data in supported native integrations or documented custom HTTP JSON operations whose origin and credentials the user configures in Settings. Refresh on open and when visible on the requested cadence, honor retryAfterSeconds, keep one read in flight, and stop while inactive. After a stale result or transient error, show the timestamped last valid reading, or an unavailable state if there is none. Ask the user to approve the source when permission is required.";
export const CREDENTIAL_REGISTRATION_FEATURE = "credential-registration-v1";
export const CREDENTIAL_REGISTRATION_LEGACY_RULE = "For a Cloud V2 request advertising credential-registration-v1, first complete the request with the matching HTTPS bearer connectionSetupProposals entry. If this is a source you are independently authorized and able to configure to accept a device-generated SHA-256 verifier, call announce_credential_registration with the request ID and alias. Do not announce provider-issued credentials as configurable. The device must separately initiate registration. Do not request or handle the bearer. The agent must independently confirm source configuration and the exact endpoint certificate before reporting success. Manual entry remains available.";
export const CREDENTIAL_REGISTRATION_RULE = "For a Cloud V2 request advertising credential-registration-v1, complete the request with a matching eligible HTTPS bearer connectionSetupProposals entry. Setup starts only after an explicit action on the device. No advance agent announcement is needed. After receiving assigned registration work, independently verify source authorization and support for device-generated SHA-256 verifiers before making any change. Report unsupported if you verified that no source write was attempted. Do not request or handle the bearer. Confirm source configuration and the exact endpoint certificate before reporting success. Manual entry remains available.";
export const CREDENTIAL_HANDOFF_FEATURE = "credential-handoff-v1";
export const CREDENTIAL_HANDOFF_RULE = "For a Cloud V2 request advertising credential-handoff-v1, a paired helper can deliver a bearer for an HTTPS custom connection. After complete_request succeeds with the matching connectionSetupProposals entry, call request_credential_handoff with the request ID, connection alias and operator-configured credential name. The name identifies the entry on the helper. Never read the bearer or include it in a tool call, screen, setup proposal, progress message or result. Delivery requires separate review on the requesting device. Manual entry is available.";
export const CONNECTION_PREFILL_FEATURE = "custom-http-prefill-v1";
export const CONNECTION_PREFILL_RULE = "When runtime.features includes custom-http-prefill-v1 and schemaVersion is 2, complete_request may include connectionSetupProposals: [{version:1,alias,declaration,fields}]. Write manifest.json in the same result; declaration must exactly equal that alias’s customHTTP declaration. fields contains only nonsecret declared field IDs and string values validated by their types; include the origin URL. Never include credentials, credential references, tokens, headers, or private-network approvals. These are device-local form suggestions for this request’s device and screen, never saved settings or permission. Existing settings remain unchanged. The user reviews setup and access in native UI before any request.";
export const CUSTOM_HTTP_FEATURE = "custom-http-v1";
const customReservedAliases = new Set(["home", "googletv", "googlecalendar", "applemaps"]);
const customReservedParameters = new Set([
  "authorization", "x-api-key", "token", "password", "access_token", "api_key", "apikey", "secret",
  "path", "url", "host", "origin", "method", "headers", "scheme", "port"
]);
const customName = (value: unknown) => typeof value === "string" && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/u.test(value) && !/\s/u.test(value);
const customText = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.trim().length > 0 && utf8(value) <= max && !/[\p{Cc}\p{Cf}]/u.test(value);
const customPath = (value: unknown): boolean => typeof value === "string" && (
  value === "/" || (
    value.length <= 512 && value.startsWith("/") &&
    value.slice(1).split("/").every(part => part.length > 0 && part.length <= 256 && part !== "." && part !== ".." && !/[^A-Za-z0-9._~-]/u.test(part))
  )
);

function checkCustomHTTPManifest(content: string, previous: string | undefined, supported: boolean): void {
  const path = "$.screen.files.manifest.json";
  const reject = () => fail("invalid custom HTTP declaration", path);
  function object(value: unknown, required: string[], optional: string[] = []): Record<string, any> {
    if (!plain(value) || !required.every(key => Object.hasOwn(value, key)) ||
        !Object.keys(value).every(key => required.includes(key) || optional.includes(key))) return reject();
    return value;
  }
  function checkType(value: Record<string, any>, fields: boolean): void {
    if (value.type === "choice") {
      if (!Array.isArray(value.options) || value.options.length < 1 || value.options.length > 32 ||
          new Set(value.options).size !== value.options.length || !value.options.every(option => customText(option, 128))) reject();
    } else {
      const types = fields ? ["text", "number", "toggle", "url", "secret"] : ["text", "number", "toggle"];
      if (!types.includes(value.type) || Object.hasOwn(value, "options")) reject();
    }
  }
  function declarations(source: string): Record<string, any>[] {
    const manifest: unknown = JSON.parse(source);
    if (!plain(manifest) || !Array.isArray(manifest.connections)) return [];
    const custom = manifest.connections.filter(value => plain(value) && Object.hasOwn(value, "customHTTP"));
    if (custom.length > 8) reject();
    const ids = new Set<string>();
    for (const value of custom) {
      const connection = object(value, ["alias", "required", "customHTTP"]);
      if (!customName(connection.alias) || customReservedAliases.has(connection.alias.toLowerCase()) ||
          typeof connection.required !== "boolean" || manifest.connections.filter(other =>
            plain(other) && typeof other.alias === "string" && other.alias.toLowerCase() === connection.alias.toLowerCase()
          ).length !== 1) reject();
      const declaration = object(connection.customHTTP, ["id", "version", "label", "fields", "originField", "operations"], ["auth"]);
      if (typeof declaration.id !== "string" || declaration.id.length > 64 ||
          !/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/u.test(declaration.id) || /\s/u.test(declaration.id) || ids.has(declaration.id) ||
          !Number.isSafeInteger(declaration.version) || declaration.version < 1 || declaration.version > 2147483647 ||
          !customText(declaration.label, 96) || !Array.isArray(declaration.fields) || declaration.fields.length < 1 || declaration.fields.length > 12 ||
          !Array.isArray(declaration.operations) || declaration.operations.length < 1 || declaration.operations.length > 16) reject();
      ids.add(declaration.id);
      const fields = new Map<string, Record<string, any>>();
      for (const raw of declaration.fields) {
        const field = object(raw, ["id", "label", "type"], ["options"]);
        if (!customName(field.id) || !customText(field.label, 96) || fields.has(field.id)) reject();
        checkType(field, true);
        fields.set(field.id, field);
      }
      const origin = [...fields.values()].filter(field => field.type === "url");
      const secrets = [...fields.values()].filter(field => field.type === "secret");
      if (origin.length !== 1 || origin[0].id !== declaration.originField) reject();
      if (Object.hasOwn(declaration, "auth")) {
        const auth = object(declaration.auth, ["mode", "field"]);
        if (auth.mode !== "bearer" || secrets.length !== 1 || secrets[0].id !== auth.field) reject();
      } else if (secrets.length) reject();
      const names = new Set<string>();
      for (const raw of declaration.operations) {
        const operation = object(raw, ["name", "method", "path", "response", "parameters"]);
        if (!customName(operation.name) || names.has(operation.name) || operation.method !== "GET" ||
            operation.response !== "json" || !customPath(operation.path) || !plain(operation.parameters) ||
            Object.keys(operation.parameters).length > 12) reject();
        names.add(operation.name);
        for (const [name, rawParameter] of Object.entries(operation.parameters)) {
          if (!customName(name) || customReservedParameters.has(name.toLowerCase())) reject();
          const parameter = object(rawParameter, ["type"], ["options", "field"]);
          checkType(parameter, false);
          if (Object.hasOwn(parameter, "field")) {
            const field = fields.get(parameter.field);
            if (!field || field.type !== parameter.type ||
                canonicalJSON(field.options ?? null) !== canonicalJSON(parameter.options ?? null)) reject();
          }
        }
      }
    }
    return custom;
  }
  const current = declarations(content);
  if (!supported && current.length && canonicalJSON(current) !== canonicalJSON(previous === undefined ? [] : declarations(previous))) {
    fail("target runtime does not advertise custom HTTP", path);
  }
}

export function checkAuthoringManifestScreenData(content: string, previous?: string, supportsScreenData = true, supportsCustomHTTP = true): void {
  const read = (source: string) => {
    try { return validateManifestScreenData(source); } catch { return fail("invalid manifest or screenData declaration", "$.screen.files.manifest.json"); }
  };
  const current = read(content);
  if (current && !supportsScreenData && canonicalJSON(current) !== canonicalJSON((previous === undefined ? undefined : read(previous)) ?? null)) {
    fail("target runtime does not advertise screen data", "$.screen.files.manifest.json");
  }
  checkCustomHTTPManifest(content, previous, supportsCustomHTTP);
}
export function makeAuthoringServices(observedAt: number): AuthoringServiceV1[] {
  return AUTHORING_DEFINITION.serviceCatalog.map(service => ({id:service.id,provider:service.provider,operations:structuredClone(service.operations),supported:{state:"yes",observedAt},configured:{state:service.provider === "googleCalendar" ? "no" : "unknown",observedAt},authorized:{state:"unknown",observedAt},entitled:{state:"unknown",observedAt},reachable:{state:"unknown",observedAt}}));
}
export function validatePreferenceRecord(value: unknown): PreferenceRecordV1 { validate("Preference",value); return value as PreferenceRecordV1; }
export function validateAuthoringRequest(value: unknown, validatingV2 = false): AuthoringRequestV1 {
  validate("Request", value); const request = value as AuthoringRequestV1;
  if (request.deadlineAt <= request.createdAt) fail("deadline must follow creation");
  const runtime = canonicalJSON(request.runtime);
  const screenData = AUTHORING_DEFINITION.screenData.features.every(feature => request.runtime.features.includes(feature));
  const customHTTP = request.runtime.features.includes(CUSTOM_HTTP_FEATURE);
  const prefill = request.runtime.features.includes(CONNECTION_PREFILL_FEATURE);
  const handoff = request.runtime.features.includes(CREDENTIAL_HANDOFF_FEATURE);
  const registration = request.runtime.features.includes(CREDENTIAL_REGISTRATION_FEATURE);
  const pageText = request.runtime.features.includes(PUBLIC_PAGE_TEXT_FEATURE);
  if (registration && (!validatingV2 || !prefill || request.delivery.route !== "cloud"))
    fail("credential registration requires Cloud V2 connection prefill");
  if (handoff && (!prefill || request.delivery.route !== "cloud")) fail("credential handoff requires Cloud connection prefill");
  if (prefill && !customHTTP) fail("prefill requires custom HTTP");
  const browser = isBrowserRuntime(request.runtime);
  const expectedRuntime = browser ? browserAuthoringRuntime() : authoringRuntime(screenData, customHTTP, prefill, handoff, registration, pageText);
  const expectedGuidance = browser ? browserAuthoringDesignGuidance() : authoringDesignGuidance(screenData, customHTTP, prefill, handoff, registration, pageText);
  const guidance = canonicalJSON(request.designGuidance);
  const legacyRegistrationGuidance = registration ? canonicalJSON({...expectedGuidance,
    rules:expectedGuidance.rules.map(rule => rule === CREDENTIAL_REGISTRATION_RULE ? CREDENTIAL_REGISTRATION_LEGACY_RULE : rule),
  }) : undefined;
  if (runtime !== canonicalJSON(expectedRuntime) || (guidance !== canonicalJSON(expectedGuidance) && guidance !== legacyRegistrationGuidance))
    fail("unsupported guidance/runtime definition");
  if (browser && (request.services.length || request.preferences.length)) fail("browser runtime requires empty services and preferences");
  const seen = new Set<string>();
  for (const service of request.services) {
    if (seen.has(service.id)) fail("duplicate service id"); seen.add(service.id);
    const catalog = AUTHORING_DEFINITION.serviceCatalog.find(x => x.provider === service.provider);
    if (!catalog || canonicalJSON(catalog.operations) !== canonicalJSON(service.operations)) fail("unsupported provider operation definitions");
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
export function validateAuthoringResult(value: unknown, request?: AuthoringRequestV1, validatingV2 = false): AuthoringResultV1 {
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
    validateAuthoringRequest(request, validatingV2);
    if (isBrowserRuntime(request.runtime) && mutations.length) fail("browser runtime does not support preference mutations");
    const manifest = result.screen?.files.find(f => f.path === "manifest.json");
    if (manifest) checkAuthoringManifestScreenData(manifest.content, request.context.currentScreen?.files.find(f => f.path === "manifest.json")?.content,
      AUTHORING_DEFINITION.screenData.features.every(feature => request.runtime.features.includes(feature)), request.runtime.features.includes(CUSTOM_HTTP_FEATURE));
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
