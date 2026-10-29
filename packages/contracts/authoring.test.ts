import { describe, expect, it } from "vitest";
// @ts-expect-error Vitest supplies the Node runtime; production types intentionally exclude Node.
import { readFileSync } from "node:fs";
import {
  AUTHORING_DEFINITION, AUTHORING_REQUEST_SCHEMA, AUTHORING_RESULT_SCHEMA, AUTHORING_RESULT_LIMITS,
  canonicalJSON, authoringSnapshotDigest, sealAuthoringRequest, verifyAuthoringRequestDigest,
  validateAuthoringRequest, validateAuthoringResult, validatePreferenceRecord, validateApplicationReceipt, validateAuthoringScreen,
} from "./authoring";
const fixtures = JSON.parse(readFileSync("packages/contracts/fixtures/conformance-v1.json","utf8"));
function changed(value: any, change: any) {
  const copy = structuredClone(value); let parent = copy;
  for (const key of change.path.slice(0,-1)) parent = parent[key];
  const key = change.path.at(-1); if (change.remove) delete parent[key]; else Object.defineProperty(parent,key,{value:change.value,enumerable:true,writable:true,configurable:true});
  return copy;
}
describe("canonical authoring v1 shared conformance", () => {
  it("binds the explicit local route without changing Cloud snapshots", async () => {
    const request = structuredClone(fixtures.request);
    request.delivery.route = "local";
    const local = await sealAuthoringRequest(request);
    expect(local.delivery.route).toBe("local");
    expect(await verifyAuthoringRequestDigest(local)).toBe(true);
    expect(local.delivery.snapshotDigest).not.toBe(fixtures.request.delivery.snapshotDigest);
    expect(validateAuthoringRequest(fixtures.request)).toEqual(fixtures.request);
  });
  it("validates safe request, screen result, preference, explicit preference proposal and receipt", async () => {
    expect(validateAuthoringRequest(fixtures.request)).toEqual(fixtures.request);
    expect(await verifyAuthoringRequestDigest(fixtures.request)).toBe(true);
    expect(await authoringSnapshotDigest(fixtures.request)).toBe(fixtures.request.delivery.snapshotDigest);
    expect(validateAuthoringResult(fixtures.result,fixtures.request)).toEqual(fixtures.result);
    expect(validateAuthoringResult(fixtures.preferenceResult,fixtures.request)).toEqual(fixtures.preferenceResult);
    expect(validatePreferenceRecord(fixtures.preference)).toEqual(fixtures.preference);
    expect(validateApplicationReceipt(fixtures.receipt)).toEqual(fixtures.receipt);
  });
  for (const vector of fixtures.canonicalVectors) it(`canonical UTF8 parity ${vector.sha256.slice(0,8)}`, async () => {
    expect(canonicalJSON(vector.input)).toBe(vector.canonical);
    const digest = await crypto.subtle.digest("SHA-256",new TextEncoder().encode(canonicalJSON(vector.input)));
    expect(Array.from(new Uint8Array(digest), b=>b.toString(16).padStart(2,"0")).join("")).toBe(vector.sha256);
  });
  for (const change of fixtures.invalidCases) it(`rejects ${change.name}`, () => {
    const value = changed(fixtures[change.kind],change);
    if (change.snapshotDigest) value.delivery.snapshotDigest = change.snapshotDigest;
    const validate = change.kind === "request" ? () => validateAuthoringRequest(value) : change.kind === "preference" ? () => validatePreferenceRecord(value) : change.kind === "receipt" ? () => validateApplicationReceipt(value) : () => validateAuthoringResult(value,fixtures.request);
    expect(validate).toThrow();
  });
  it("binds all input context, capability facts, preferences, runtime and route to digest", async () => {
    for (const path of [["context","userRequest"],["context","baseRevision"],["delivery","route"],["services",0,"reachable","state"],["preferences",0,"value"]]) {
      const value = changed(fixtures.request,{path,value:path.at(-1)==="route"?"cloud":path.at(-1)==="state"?"no":"tampered"});
      expect(await verifyAuthoringRequestDigest(value)).toBe(false);
    }
    const unsealed = structuredClone(fixtures.request); unsealed.delivery.snapshotDigest="";
    expect(await sealAuthoringRequest(unsealed)).toEqual(fixtures.request);
  });
  it("keeps configuration and reachability independent", async () => {
    const value = structuredClone(fixtures.request);
    value.services[0].configured.state="yes"; value.services[0].reachable.state="no";
    expect(await sealAuthoringRequest(value)).toBeDefined();
    value.services[0].reachable.state="unknown";
    expect(await sealAuthoringRequest(value)).toBeDefined();
  });
  it("enforces UTF8 byte bounds and limits result files", () => {
    const preference = {...fixtures.preference,value:"😀".repeat(1025)};
    expect(()=>validatePreferenceRecord(preference)).toThrow();
    const result=structuredClone(fixtures.result); result.screen.files[0].content="😀".repeat(51201);
    expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow();
    result.screen.files=Array.from({length:21},(_,i)=>({path:`${i}.txt`,content:""}));
    expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow();
  });
  for (const vector of fixtures.screenBoundaryVectors) it(`serialized screen boundary ${vector.name}`, () => {
    const screen={title:"Boundary",entry:"index.html",files:[{path:"index.html",content:vector.character.repeat(vector.count)}]};
    if (vector.accepted) expect(()=>validateAuthoringScreen(screen)).not.toThrow();
    else expect(()=>validateAuthoringScreen(screen)).toThrow();
  });
  for (const vector of fixtures.resultBoundaryVectors) it(`serialized result boundary ${vector.name}`, () => {
    const result=structuredClone(fixtures.result); delete result.screen; result.answer += "a".repeat(vector.answerPadding);
    result.preferenceMutations=[]; result.durablePreferenceAuthorization=fixtures.preferenceResult.durablePreferenceAuthorization;
    let remaining=vector.metadataCharacterCount;
    for(let i=0;i<16;i++) {
      const count=Math.min(4096,remaining); remaining-=count; const id=`boundary-pref-${i}`;
      result.preferenceMutations.push({kind:"upsert",id,expectedRevision:null,record:{...fixtures.preference,id,value:vector.metadataCharacter.repeat(count),revision:1,originRequestID:result.requestID}});
    }
    if(vector.includeScreen) result.screen={title:"Boundary",entry:"index.html",files:[{path:"index.html",content:vector.screenCharacter.repeat(vector.screenCharacterCount)}]};
    const metadata=structuredClone(result); delete metadata.screen;
    expect(new TextEncoder().encode(canonicalJSON(metadata)).byteLength).toBe(vector.metadataBytes);
    expect(new TextEncoder().encode(canonicalJSON(result)).byteLength).toBe(vector.fullBytes);
    if(vector.accepted) expect(()=>validateAuthoringResult(result,fixtures.request)).not.toThrow();
    else expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow(vector.fullBytes>AUTHORING_RESULT_LIMITS.resultBytes?"result byte limit":"result metadata byte limit");
  });
  it("canonicalizes and validates null-prototype JSON without inheriting schema properties", () => {
    const result=Object.assign(Object.create(null),fixtures.result);
    expect(canonicalJSON(result)).toBe(canonicalJSON(fixtures.result));
    expect(validateAuthoringResult(result,fixtures.request)).toEqual(fixtures.result);
    for(const key of ["constructor","toString","__proto__"]) {
      Object.defineProperty(result,key,{value:123,enumerable:true,configurable:true});
      expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow("unknown field");
      delete result[key];
    }
  });
  for(const vector of fixtures.unicodeCompatibilityVectors) it(`legacy Unicode envelope ${vector.name}`, () => {
    const result=structuredClone(fixtures.result); const text=vector.character.repeat(vector.count);
    if(vector.kind==="title") result.screen.title=text; else result.answer=text;
    if(vector.accepted) expect(()=>validateAuthoringResult(result,fixtures.request)).not.toThrow();
    else expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow();
  });
  it("exports MCP-safe inline schemas and canonical implemented operations", () => {
    expect(JSON.stringify(AUTHORING_REQUEST_SCHEMA)).not.toContain('"$ref"');
    expect(JSON.stringify(AUTHORING_RESULT_SCHEMA)).not.toContain('"$ref"');
    expect(AUTHORING_DEFINITION.serviceCatalog.map(s=>s.provider)).toEqual(["home","googleTV","googleCalendar","appleMaps","publicHTTP"]);
    expect(AUTHORING_DEFINITION.runtime.features).not.toContain("fetch");
  });
  it("rejects automatic preference persistence and unbound or implicit authorizations", () => {
    const result=structuredClone(fixtures.preferenceResult);
    result.durablePreferenceAuthorization.quote="Make a clock.";
    expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow();
    result.durablePreferenceAuthorization={requestID:"other",quote:"Remember that I always prefer blue controls for my profile."};
    expect(()=>validateAuthoringResult(result,fixtures.request)).toThrow();
  });
});
