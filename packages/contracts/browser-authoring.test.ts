import {describe, expect, it} from 'vitest';
// @ts-expect-error Vitest supplies Node; production types intentionally exclude it.
import {readFileSync} from 'node:fs';
import {AUTHORING_DEFINITION, authoringRuntime, authoringDesignGuidance, browserAuthoringRuntime, browserAuthoringDesignGuidance, sealAuthoringRequest, validateAuthoringRequest, validateAuthoringResult, verifyAuthoringRequestDigest, type AuthoringRequestV1} from './authoring';
import {makeAuthoringRequestV2, validateAuthoringRequestV2, verifyAuthoringRequestDigestV2} from './authoring-v2';

const fixtures = JSON.parse(readFileSync('packages/contracts/fixtures/conformance-v1.json','utf8'));
function browserRequest(): AuthoringRequestV1 {
  const request={...structuredClone(fixtures.request), designGuidance:browserAuthoringDesignGuidance(), runtime:browserAuthoringRuntime(), services:[], preferences:[]};
  request.context.baseRevision=null;
  return request;
}
describe('canonical browser authoring profile', () => {
  it('seals truthful empty-capability browser requests without changing native snapshots',async()=>{
    const request = await sealAuthoringRequest(browserRequest());
    expect(validateAuthoringRequest(request)).toEqual(request);
    expect(await verifyAuthoringRequestDigest(request)).toBe(true);
    expect(request.runtime).toEqual({...authoringRuntime(false),features:['html','css','javascript','bundled-classic-scripts','bundled-local-assets']});
    expect(request.services).toEqual([]); expect(request.preferences).toEqual([]);
    expect(validateAuthoringRequest(fixtures.request)).toEqual(fixtures.request);
    expect(await sealAuthoringRequest(fixtures.request)).toEqual(fixtures.request);
    expect(authoringRuntime(false)).toEqual(fixtures.request.runtime);
    expect(authoringDesignGuidance(false)).toEqual(fixtures.request.designGuidance);
    expect(request.delivery.snapshotDigest).not.toBe(fixtures.request.delivery.snapshotDigest);
  });
  it('rejects mixed guidance, extra or missing features, and modified limits',()=>{
    for(const mutate of [
      (r:AuthoringRequestV1)=>{r.designGuidance=authoringDesignGuidance(false);},
      (r:AuthoringRequestV1)=>{r.runtime=authoringRuntime(false);},
      (r:AuthoringRequestV1)=>{r.runtime.features.push('runtime.ready');},
      (r:AuthoringRequestV1)=>{r.runtime.features.pop();},
      (r:AuthoringRequestV1)=>{r.runtime.features.reverse();},
      (r:AuthoringRequestV1)=>{r.designGuidance.rules.push('Pretend a native bridge exists.');},
      (r:AuthoringRequestV1)=>{(r.runtime.limits as any).screenFiles=19;}
    ]) { const request=browserRequest();mutate(request);expect(()=>validateAuthoringRequest(request)).toThrow(); }
  });
  it('rejects native services and durable preferences even when otherwise valid',()=>{
    const service=browserRequest(); service.services=structuredClone(fixtures.request.services);
    expect(()=>validateAuthoringRequest(service)).toThrow(/empty services and preferences/);
    const preference=browserRequest();preference.preferences=structuredClone(fixtures.request.preferences);
    expect(()=>validateAuthoringRequest(preference)).toThrow(/empty services and preferences/);
  });
  it('validates bound screen results and rejects preference mutations and foreign digests',async()=>{
    const request=await sealAuthoringRequest(browserRequest());
    const result={...structuredClone(fixtures.result),inputDigest:request.delivery.snapshotDigest,baseRevision:request.context.baseRevision,preferenceRevisions:{},screen:{title:'Browser clock',entry:'index.html',files:[{path:'index.html',content:'<!doctype html><h1>Clock</h1>'}]}};
    expect(validateAuthoringResult(result,request)).toEqual(result);
    expect(()=>validateAuthoringResult({...result,inputDigest:fixtures.request.delivery.snapshotDigest},request)).toThrow(/bound/);
    const preferenceResult={...structuredClone(fixtures.preferenceResult),inputDigest:request.delivery.snapshotDigest,baseRevision:request.context.baseRevision,preferenceRevisions:{}};
    expect(()=>validateAuthoringResult(preferenceResult,request)).toThrow(/browser runtime does not support preference mutations/);
    const dataResult={...result,screen:{...result.screen,files:[...result.screen.files,{path:'manifest.json',content:JSON.stringify({screenData:{exports:[{name:'clock',description:'Clock'}]}})}]}};
    expect(()=>validateAuthoringResult(dataResult,request)).toThrow(/screen data/);
  });
  it('binds browser context and pair into digest, including v2 conversion',async()=>{
    const request=await sealAuthoringRequest(browserRequest());
    const altered=structuredClone(request);altered.context.userRequest+=' altered';
    expect(await verifyAuthoringRequestDigest(altered)).toBe(false);
    const native=structuredClone(request);native.runtime=authoringRuntime(false);native.designGuidance=authoringDesignGuidance(false);
    expect(await verifyAuthoringRequestDigest(native)).toBe(false);
    const v2=await makeAuthoringRequestV2(request,'browser-library');
    expect(validateAuthoringRequestV2(v2)).toEqual(v2);expect(await verifyAuthoringRequestDigestV2(v2)).toBe(true);
  });
  it('returns independent copies without changing the frozen canonical definition',()=>{
    browserAuthoringRuntime().features.push('fetch');browserAuthoringDesignGuidance().rules.length=0;
    expect(browserAuthoringRuntime()).toEqual(AUTHORING_DEFINITION.browser.runtime);
    expect(browserAuthoringDesignGuidance()).toEqual(AUTHORING_DEFINITION.browser.designGuidance);
  });
});
