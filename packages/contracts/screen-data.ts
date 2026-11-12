import type { JSONValue } from "./authoring";

export const SCREEN_DATA_LIMITS = Object.freeze({ declarations: 16, descriptionBytes: 240, valueBytes: 16 * 1024, depth: 16 });
export interface ScreenDataExport { name: string; description: string }
export interface ScreenDataQuery { alias: string; deviceId?: string; screenId: string; exportName: string }
export interface ScreenDataDeclaration { exports: ScreenDataExport[]; queries: ScreenDataQuery[] }
export interface ScreenDataSnapshot { value: JSONValue; version: number; updatedAt: string; readAt: string }

const utf8 = (value: string) => new TextEncoder().encode(value).length;
const invalid = (): never => { throw new Error("Invalid screenData declaration or value"); };
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const matches = (pattern: RegExp, value: unknown): value is string => typeof value === "string" && pattern.exec(value)?.[0] === value;
export const isScreenDataName = (value: unknown): value is string => matches(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/, value);
export const isScreenDataInstalledID = (value: unknown): value is string => matches(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/, value);

function fields(value: unknown, allowed: string[]): Record<string, unknown> {
  if (!record(value) || Object.keys(value).some(key => !allowed.includes(key))) return invalid();
  return value;
}

function declarations<T>(value: unknown, parse: (item: unknown) => T, key: (item: T) => string): T[] {
  if (!Array.isArray(value) || value.length > SCREEN_DATA_LIMITS.declarations) return invalid();
  const parsed = Array.from(value, parse);
  if (new Set(parsed.map(key)).size !== parsed.length) return invalid();
  return parsed;
}

export function validateScreenDataDeclaration(value: unknown): ScreenDataDeclaration {
  const declaration = fields(value, ["exports", "queries"]);
  const exports = declarations(Object.hasOwn(declaration, "exports") ? declaration.exports : [], raw => {
    const { name, description } = fields(raw, ["name", "description"]);
    if (!isScreenDataName(name) || typeof description !== "string" || !/[^\p{White_Space}]/u.test(description) ||
        /[\x00-\x1F\x7F]/.test(description) || utf8(description) > SCREEN_DATA_LIMITS.descriptionBytes) return invalid();
    return { name, description };
  }, item => item.name);
  const queries = declarations(Object.hasOwn(declaration, "queries") ? declaration.queries : [], raw => {
    const item = fields(raw, ["alias", "deviceId", "screenId", "exportName"]);
    const { alias, deviceId, screenId, exportName } = item;
    if (!isScreenDataName(alias) || !isScreenDataName(exportName) || !isScreenDataInstalledID(screenId)) return invalid();
    if (Object.hasOwn(item, "deviceId")) {
      if (!isScreenDataInstalledID(deviceId)) return invalid();
      return { alias, deviceId, screenId, exportName };
    }
    return { alias, screenId, exportName };
  }, item => item.alias);
  return { exports, queries };
}

/** Package-specific screenData checks shared by V1 and V2 authoring. */
export function validateManifestScreenData(content: string): ScreenDataDeclaration | undefined {
  const manifest: unknown = JSON.parse(content);
  if (!record(manifest)) return invalid();
  return Object.hasOwn(manifest, "screenData") ? validateScreenDataDeclaration(manifest.screenData) : undefined;
}

export function validateScreenDataValue(value: unknown): JSONValue {
  let minimumBytes = 0;
  function spend(size: number) { minimumBytes += size; if (minimumBytes > SCREEN_DATA_LIMITS.valueBytes) invalid(); }
  function visit(item: unknown, depth: number): void {
    spend(1);
    if (typeof item === "string") { spend(item.length); return; }
    if (item === null || typeof item === "boolean" || (typeof item === "number" && Number.isFinite(item))) return;
    if (depth >= SCREEN_DATA_LIMITS.depth) return invalid();
    if (Array.isArray(item)) { for (const child of item) visit(child, depth + 1); return; }
    if (!record(item)) return invalid();
    const seen = new Set<string>();
    for (const [key, child] of Object.entries(item)) {
      spend(key.length);
      const normalized = key.normalize("NFC");
      if (seen.has(normalized)) return invalid();
      seen.add(normalized);
      visit(child, depth + 1);
    }
  }
  visit(value, 0);
  if (utf8(JSON.stringify(value)) > SCREEN_DATA_LIMITS.valueBytes) return invalid();
  return value as JSONValue;
}
