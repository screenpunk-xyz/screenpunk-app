import {describe, expect, it} from 'vitest';
// @ts-expect-error Node is supplied by the test runner only.
import {readFileSync} from 'node:fs';
import {AUTHORING_DEFINITION, BROWSER_HOST_AUTHORING_PROFILE, browserAuthoringRuntime, browserHostAuthoringRuntime, browserHostAuthoringDesignGuidance, makeAuthoringServices, makeBrowserHostAuthoringServices, checkBrowserHostAuthoringManifest, sealAuthoringRequest, validateAuthoringRequest, validateAuthoringResult, verifyAuthoringRequestDigest, type AuthoringRequestV1, type AuthoringResultV1} from './authoring';
import {makeAuthoringRequestV2, materializeAuthoringResultV2, validateAuthoringRequestV2, validateAuthoringResultV2, type AuthoringResultV2} from './authoring-v2';

const vectors=JSON.parse(readFileSync('packages/contracts/fixtures/conformance-browser-host-v1.json','utf8'));
const legacy=JSON.parse(readFileSync('packages/contracts/fixtures/conformance-v1.json','utf8'));
const manifestCase=(name:string)=>vectors.manifestCases.find((item:{name:string})=>item.name===name).manifest;
const request=():AuthoringRequestV1=>structuredClone(vectors.request);
const result=(r:AuthoringRequestV1):AuthoringResultV1=>({schemaVersion:1,requestID:r.requestID,inputDigest:r.delivery.snapshotDigest,baseRevision:r.context.baseRevision,preferenceRevisions:{},operationID:'browser-host-result',answer:'Ready'});

describe('opt-in browser host authoring profile',()=>{
  it('matches the shared sealed vector and preserves legacy native/offline digests',async()=>{
    const r=request();expect(await sealAuthoringRequest(r)).toEqual(r);expect(await verifyAuthoringRequestDigest(r)).toBe(true);
    expect(validateAuthoringRequest(legacy.request)).toEqual(legacy.request);
    expect((await sealAuthoringRequest(legacy.request)).delivery.snapshotDigest).toBe(vectors.legacyDigests[0]);
    expect(await sealAuthoringRequest(vectors.legacyOfflineRequest)).toEqual(vectors.legacyOfflineRequest);
    expect(browserAuthoringRuntime()).toEqual(AUTHORING_DEFINITION.browser.runtime);
    expect(r.runtime.features).toContain('browser-host-v1');expect(r.runtime.features).not.toContain('data.query');
  });
  it('keeps permission observations independent and defaults unknown without granting reads',async()=>{
    const observations={configured:{state:'yes' as const,observedAt:10},authorized:{state:'no' as 'yes'|'no'|'unknown',observedAt:20}};
    const services=makeBrowserHostAuthoringServices(30,observations);
    expect(services).toHaveLength(1);expect(services[0].provider).toBe('publicHTTP');
    expect(services[0].configured).toEqual(observations.configured);expect(services[0].authorized).toEqual(observations.authorized);
    expect(services[0].reachable.state).toBe('unknown');expect(makeBrowserHostAuthoringServices(30)[0].authorized.state).toBe('unknown');
    observations.authorized.state='yes';expect(services[0].authorized.state).toBe('no');
    const future=request();future.services[0].authorized.observedAt=future.createdAt+1;expect(()=>validateAuthoringRequest(future)).toThrow(/future/);
  });
  it('rejects mixed guidance/features, native providers/descriptors, false service IDs and authoring preferences',()=>{
    const mutations=[
      (r:AuthoringRequestV1)=>{r.designGuidance=structuredClone(AUTHORING_DEFINITION.browser.designGuidance);},
      (r:AuthoringRequestV1)=>{r.runtime.features.push('data.query');},
      (r:AuthoringRequestV1)=>{r.runtime.features.reverse();},
      (r:AuthoringRequestV1)=>{r.services=makeAuthoringServices(r.createdAt);},
      (r:AuthoringRequestV1)=>{r.services[0]=makeAuthoringServices(r.createdAt).find(s=>s.provider==='publicHTTP')!;},
      (r:AuthoringRequestV1)=>{r.services[0].id='home';},
      (r:AuthoringRequestV1)=>{r.preferences=structuredClone(legacy.request.preferences);}
    ];
    for(const mutate of mutations){const r=request();mutate(r);expect(()=>validateAuthoringRequest(r)).toThrow();}
    const native=structuredClone(legacy.request);native.services=makeBrowserHostAuthoringServices(native.createdAt);expect(()=>validateAuthoringRequest(native)).toThrow(/provider/);
  });
  it('validates reviewed public declarations and existing local pages with shared Swift vectors',()=>{
    for(const item of vectors.manifestCases){const check=()=>checkBrowserHostAuthoringManifest(JSON.stringify(item.manifest),vectors.filePaths);if(item.accepted)expect(check,item.name).not.toThrow();else expect(check,item.name).toThrow();}
    const r=request();const v=result(r);v.screen={title:'Weather',entry:'index.html',files:[{path:'index.html',content:'<h1>Weather</h1>'},{path:'manifest.json',content:JSON.stringify(manifestCase('reviewed public source'))}]};
    expect(validateAuthoringResult(v,r)).toEqual(v);
    v.screen.files[1].content=JSON.stringify(manifestCase('native provider'));expect(()=>validateAuthoringResult(v,r)).toThrow();
    const preference={...structuredClone(legacy.preferenceResult),inputDigest:r.delivery.snapshotDigest,baseRevision:r.context.baseRevision,preferenceRevisions:{}};expect(()=>validateAuthoringResult(preference,r)).toThrow(/preference mutations/);
  });
  it('supports v2 without advertising data or accepting unsupported manifests through retained references',async()=>{
    const r=await makeAuthoringRequestV2(request(),'browser-library');expect(validateAuthoringRequestV2(r)).toBe(r);
    const value:AuthoringResultV2={schemaVersion:2,requestID:r.requestID,inputDigest:r.delivery.snapshotDigest,baseRevision:r.context.baseRevision,preferenceRevisions:{},operationID:'browser-v2',screen:{title:'Local',entry:'index.html',files:[{kind:'write',path:'index.html',content:'<h1>Local</h1>'},{kind:'write',path:'manifest.json',content:'{}'}],deletedPaths:[]}};
    expect(validateAuthoringResultV2(value,r)).toBe(value);expect((await materializeAuthoringResultV2(value,r,()=>{throw Error('no references')}))?.files).toHaveLength(2);
    (value.screen!.files[1] as any).content=JSON.stringify(manifestCase('native provider'));expect(()=>validateAuthoringResultV2(value,r)).toThrow();
    const base=request();base.context.baseRevision='existing';const bad=JSON.stringify(manifestCase('native provider'));base.context.currentScreen={title:'Existing',entry:'index.html',files:[{path:'index.html',content:'<h1>Old</h1>'},{path:'manifest.json',content:bad}]};
    const retained=await makeAuthoringRequestV2(await sealAuthoringRequest(base),'browser-library',()=>false);
    const copy:AuthoringResultV2={...value,inputDigest:retained.delivery.snapshotDigest,baseRevision:'existing',screen:{title:'Existing',entry:'index.html',files:retained.context.currentScreen!.files.map(f=>({kind:'retain',path:f.path,sourcePath:f.path,reference:f.reference,digest:f.digest})),deletedPaths:[]}};
    expect(validateAuthoringResultV2(copy,retained)).toBe(copy);
    await expect(materializeAuthoringResultV2(copy,retained,f=>new TextEncoder().encode(base.context.currentScreen!.files.find(b=>b.path===f.path)!.content))).rejects.toThrow();
  });
  it('returns isolated copies and keeps policy/profile definitions frozen',()=>{
    browserHostAuthoringRuntime().features.length=0;browserHostAuthoringDesignGuidance().rules.length=0;
    expect(browserHostAuthoringRuntime()).toEqual(BROWSER_HOST_AUTHORING_PROFILE.runtime);expect(browserHostAuthoringDesignGuidance()).toEqual(BROWSER_HOST_AUTHORING_PROFILE.designGuidance);
    expect(Object.isFrozen(BROWSER_HOST_AUTHORING_PROFILE.policy.publicHTTP.origins)).toBe(true);
  });
});
