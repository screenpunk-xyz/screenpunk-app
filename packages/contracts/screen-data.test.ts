import { describe, expect, it } from "vitest";
// @ts-expect-error Node test host; production types exclude Node.
import { readFileSync } from "node:fs";
// @ts-expect-error Node test host; production types exclude Node.
import { createContext, runInContext } from "node:vm";
import { authoringDesignGuidance, authoringRuntime, sealAuthoringRequest, validateAuthoringResult, validateAuthoringScreen } from "./authoring";
import { sealAuthoringRequestV2, validateAuthoringResultV2 } from "./authoring-v2";
import { validateCatalogManifest } from "./catalog";
import { validateManifestScreenData, validateScreenDataValue } from "./screen-data";

function fixture(name: string) { return JSON.parse(readFileSync(`packages/contracts/fixtures/${name}.json`, "utf8")); }
const legacyV1 = fixture("conformance-v1");
const legacyV2 = fixture("conformance-v2");
const conformance = fixture("conformance-screen-data-v1");

describe("screen data contract", () => {
  for (const { name, accepted, manifest } of conformance.manifestCases) it(name, () => {
    const content = JSON.stringify(manifest);
    const screen = { ...legacyV1.result.screen, files: [{ path: "index.html", content: "" }, { path: "manifest.json", content }] };
    const checks = [
      () => validateManifestScreenData(content),
      () => validateAuthoringScreen(screen),
      () => validateAuthoringResult({ ...legacyV1.result, screen }),
      () => validateAuthoringResultV2({ ...legacyV2.result, screen: { title: screen.title, entry: "index.html", deletedPaths: [], files: screen.files.map((file: object) => ({ kind: "write", ...file })) } }),
    ];
    for (const check of checks) accepted ? expect(check).not.toThrow() : expect(check).toThrow();
  });

  it("rejects invalid declarations through the catalog manifest entry point", () => {
    const { files: source } = legacyV1.result.screen;
    const manifest = JSON.parse(source.find((file: { path: string }) => file.path === "manifest.json").content);
    const files = manifest.files.map(({ path, bytes, sha256 }: { path: string; bytes: number; sha256: string }) => ({ path, byteLength: bytes, digest: sha256 }));
    expect(() => validateCatalogManifest(files, source)).not.toThrow();
    const changed = [{ path: "manifest.json", content: JSON.stringify({ ...manifest, screenData: null }) }];
    expect(() => validateCatalogManifest(files, changed)).toThrow(/screenData/);
  });

  it("shares exact capability digests for Local and Cloud in both wire versions", async () => {
    const features = ["data.publish", "data.remove", "data.query"];
    for (const { version, route, digest } of conformance.requestDigests) {
      const base = version === 1 ? legacyV1.request : legacyV2.request;
      const seal = version === 1 ? sealAuthoringRequest : sealAuthoringRequestV2;
      const capable = { ...base, designGuidance: authoringDesignGuidance(true), runtime: authoringRuntime(true), delivery: { ...base.delivery, route } };
      expect(base.runtime.features).not.toContain("data.query");
      expect(capable.runtime.features.slice(-3)).toEqual(features);
      expect((await seal(capable)).delivery.snapshotDigest).toBe(digest);
      await expect(seal({ ...capable, runtime: base.runtime })).rejects.toThrow(/unsupported guidance\/runtime/);
    }
  });

  it("requires runtime support for new declarations and preserves an existing declaration on a legacy target", async () => {
    const manifest = conformance.manifestCases.find((item: { name: string }) => item.name === "local and remote").manifest;
    const file = { path: "manifest.json", content: JSON.stringify(manifest) };
    const screen = { ...legacyV1.result.screen, files: [...legacyV1.result.screen.files.filter((item: { path: string }) => item.path !== file.path), file] };
    const v1 = legacyV1.request;
    const result1 = { ...legacyV1.result, screen };
    expect(() => validateAuthoringResult(result1, v1)).toThrow(/does not advertise screen data/);
    const legacyExisting = await sealAuthoringRequest({ ...v1, context: { ...v1.context, currentScreen: screen } });
    expect(() => validateAuthoringResult({ ...result1, inputDigest: legacyExisting.delivery.snapshotDigest }, legacyExisting)).not.toThrow();
    const capable1 = await sealAuthoringRequest({ ...v1, runtime: authoringRuntime(true), designGuidance: authoringDesignGuidance(true) });
    expect(() => validateAuthoringResult({ ...result1, inputDigest: capable1.delivery.snapshotDigest }, capable1)).not.toThrow();

    const v2 = legacyV2.request;
    const result2 = { ...legacyV2.result, screen: { ...legacyV2.result.screen, files: [...legacyV2.result.screen.files, { kind: "write", ...file }] } };
    expect(() => validateAuthoringResultV2(result2, v2)).toThrow(/does not advertise screen data/);
    const capable2 = await sealAuthoringRequestV2({ ...v2, runtime: authoringRuntime(true), designGuidance: authoringDesignGuidance(true) });
    expect(() => validateAuthoringResultV2({ ...result2, inputDigest: capable2.delivery.snapshotDigest }, capable2)).not.toThrow();
  });

  it("counts compact UTF-8, escaped strings and nesting identically", () => {
    for (const vector of conformance.valueCases) {
      let value = vector.unit ? vector.unit.repeat(vector.count) : vector.value;
      if (vector.depth) { value = false; for (let i = 0; i < vector.depth; i++) value = [value]; }
      const check = () => validateScreenDataValue(value);
      vector.accepted ? expect(check).not.toThrow() : expect(check).toThrow();
    }
    expect(() => validateScreenDataValue(Number.POSITIVE_INFINITY)).toThrow();
  });
});

const sdk = readFileSync("packages/ScreenpunkApple/Sources/ScreenpunkApple/Resources/runtime-sdk.js", "utf8");
const stamp = "2026-11-12T12:34:00.123Z";
function sdkHost() {
  const messages: { id: string; method: string; [key: string]: unknown }[] = [];
  const rawKeys: string[][] = [];
  const context = createContext({ TextEncoder, setTimeout, clearTimeout });
  let answer: ((message: (typeof messages)[number]) => unknown) | undefined;
  context.webkit = { messageHandlers: { screenpunk: { postMessage(message: (typeof messages)[number]) {
    rawKeys.push(Object.keys(message).sort());
    messages.push(JSON.parse(JSON.stringify(message)));
    if (answer) {
      const reply = answer(message);
      context.__screenpunkDispatch(JSON.stringify({ protocolVersion: 1, id: message.id, kind: "response", ok: true, value: null, ...(reply as object) }));
    }
  } } } };
  runInContext(sdk, context);
  return { messages, rawKeys, run: (script: string) => runInContext(script, context), reply: (callback: typeof answer) => { answer = callback; } };
}

describe("device browser SDK", () => {
  it("sends no caller identity, exposes explicit snapshot fields, and keeps private state separate", async () => {
    const host = sdkHost();
    host.reply(message => message.method === "data.query" ? { value: { value: null, version: 2, updatedAt: stamp, readAt: stamp } } : message.method === "state.get" ? { value: false } : {});
    await expect(host.run(`screenpunk.data.publish('lastFeeding', { fedAt: '${stamp}' })`)).resolves.toBeUndefined();
    await expect(host.run("screenpunk.data.remove('lastFeeding')")).resolves.toBeUndefined();
    await expect(host.run("screenpunk.data.query('feeding')")).resolves.toEqual({ value: null, version: 2, updatedAt: stamp, readAt: stamp });
    await expect(host.run("screenpunk.state.get('private')")).resolves.toBe(false);
    expect(host.messages.map(message => message.method)).toEqual(["data.publish", "data.remove", "data.query", "state.get"]);
    expect(host.rawKeys[0]).toEqual(["id", "kind", "method", "name", "protocolVersion", "value"]);
    expect(host.rawKeys[2]).toEqual(["alias", "id", "kind", "method", "protocolVersion"]);
  });

  it("rejects explicit errors and malformed success, preserving false as a real published value", async () => {
    const host = sdkHost();
    for (const code of ["permission_required", "not_found", "unavailable", "timeout", "rate_limited", "invalid_request"]) {
      host.reply(() => ({ kind: "error", ok: false, code }));
      await expect(host.run("screenpunk.data.query('feeding')")).rejects.toMatchObject({ code });
    }
    host.reply(() => ({ value: { value: false, version: 2, updatedAt: stamp, readAt: stamp } }));
    await expect(host.run("screenpunk.data.query('feeding')")).resolves.toMatchObject({ value: false });
    host.reply(() => ({ value: { value: false, version: 0, updatedAt: stamp, readAt: stamp } }));
    await expect(host.run("screenpunk.data.query('feeding')")).rejects.toMatchObject({ code: "unavailable" });
    host.reply(undefined);
    await expect(host.run("ScreenpunkSDK.createDashboardClient({timeoutMs: 5}).data.query('feeding')")).rejects.toMatchObject({ code: "timeout" });
  });

  it("rejects non-JSON, oversize and deeply nested values before posting", async () => {
    const host = sdkHost();
    for (const value of ["undefined", "NaN", "new Date()", "{ hidden: undefined }", "Array(2)", "'é'.repeat(8192)", "Array.from({length:17}).reduce(v => [v], false)"]) {
      await expect(host.run(`screenpunk.data.publish('record', ${value})`)).rejects.toMatchObject({ code: "invalid_request" });
    }
    expect(host.messages).toHaveLength(0);
  });
});
