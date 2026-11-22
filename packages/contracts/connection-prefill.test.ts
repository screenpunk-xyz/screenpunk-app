import {describe, it, expect} from 'vitest';
import fixture from './fixtures/conformance-v2.json';
import {authoringRuntime, authoringDesignGuidance} from './authoring';
import {sealAuthoringRequestV2, validateAuthoringResultV2, type AuthoringRequestV2, type AuthoringResultV2} from './authoring-v2';
const declaration = {id:'synthetic',version:1,label:'Synthetic service',fields:[
 {id:'origin',label:'Server',type:'url'}, {id:'credential',label:'Token',type:'secret'},
 {id:'limit',label:'Limit',type:'number'}, {id:'enabled',label:'Enabled',type:'toggle'},
 {id:'period',label:'Period',type:'choice',options:['daily','weekly']}],originField:'origin',
 auth:{mode:'bearer',field:'credential'},operations:[{name:'status',method:'GET',path:'/status',response:'json',parameters:{}}]};
async function pair(prefill=true) {
 const request=structuredClone(fixture.request) as AuthoringRequestV2;
 request.context.baseRevision=null;delete request.context.currentScreen;
 request.runtime=authoringRuntime(false,true,prefill);request.designGuidance=authoringDesignGuidance(false,true,prefill);
 const sealed=await sealAuthoringRequestV2(request);
 const result:AuthoringResultV2={schemaVersion:2,requestID:sealed.requestID,inputDigest:sealed.delivery.snapshotDigest,baseRevision:null,preferenceRevisions:Object.fromEntries(sealed.preferences.map(p=>[p.id,p.revision])),operationID:'prefill-operation',
 screen:{title:'Synthetic',entry:'index.html',deletedPaths:[],files:[{kind:'write',path:'index.html',content:'<p>Synthetic</p>'},{kind:'write',path:'manifest.json',content:JSON.stringify({connections:[{alias:'synthetic',required:true,customHTTP:declaration}]})}]},
 connectionSetupProposals:[{version:1,alias:'synthetic',declaration:structuredClone(declaration),fields:{origin:'https://synthetic.example',limit:'3',enabled:'false',period:'daily'}}]};
 return {request:sealed,result};
}
describe('request-bound connection prefill',()=>{
 it('accepts typed nonsecret suggestions separately from the package',async()=>{const {request,result}=await pair();expect(validateAuthoringResultV2(result,request)).toBe(result);expect(JSON.stringify(result.screen)).not.toContain('https://synthetic.example');});
 it('preserves old clients and rejects proposals without negotiation',async()=>{const {request,result}=await pair(false);expect(()=>validateAuthoringResultV2(result,request)).toThrow();delete result.connectionSetupProposals;expect(()=>validateAuthoringResultV2(result,request)).not.toThrow();});
 it('rejects malformed, credential, out-of-scope and tampered proposals',async()=>{
  const {request,result}=await pair();
  const mutants:((r:any)=>void)[]=[r=>r.connectionSetupProposals[0].version=2,r=>r.connectionSetupProposals[0].alias='other',r=>r.connectionSetupProposals[0].declaration.operations[0].path='/other',r=>r.connectionSetupProposals[0].fields.credential='synthetic-token',r=>r.connectionSetupProposals[0].fields.unknown='value',r=>r.connectionSetupProposals[0].fields.limit='NaN',r=>r.connectionSetupProposals[0].fields.enabled='yes',r=>r.connectionSetupProposals[0].fields.period='never',r=>r.connectionSetupProposals[0].fields.origin='https://user:pass@synthetic.example',r=>r.connectionSetupProposals[0].fields.origin='https://synthetic.example/?token=value',r=>delete r.connectionSetupProposals[0].fields.origin,r=>r.connectionSetupProposals.push(r.connectionSetupProposals[0]),r=>r.inputDigest='0'.repeat(64),r=>r.requestID='another-request',r=>delete r.screen,r=>r.connectionSetupProposals[0].credentialReference='keychain-key'];
  for(const mutate of mutants){const changed=structuredClone(result);mutate(changed);expect(()=>validateAuthoringResultV2(changed,request)).toThrow();}
  for(const key of ['deviceID','profileID','libraryID','screenID'] as const){const changed=structuredClone(request);changed.context[key]='other';const foreign=await sealAuthoringRequestV2(changed);expect(()=>validateAuthoringResultV2(result,foreign)).toThrow();}
 });
});
