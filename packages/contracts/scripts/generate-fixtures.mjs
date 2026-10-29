import fs from 'node:fs';
import crypto from 'node:crypto';
const definition = JSON.parse(fs.readFileSync('packages/contracts/definitions/authoring-v1.json','utf8'));
const canonical = value => Array.isArray(value)?'['+value.map(canonical).join(',')+']':value && typeof value === 'object'?'{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}':JSON.stringify(value);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const time=1803600000000;
const files=[{path:'index.html',content:'<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="style.css"></head><body><main><h1>Fixture clock</h1></main></body></html>'},{path:'style.css',content:'html,body{margin:0}*{box-sizing:border-box}main{height:100dvh;display:grid;place-items:center}'}];
const manifest={schemaVersion:1,dashboardId:'screen-fixture',name:'Fixture clock',revision:'revision-fixture-2',entrypoint:'index.html',sdkVersion:'1',target:{profileId:'profile-fixture',width:1024,height:768,scale:1,orientation:'landscape'},connections:[],files:files.map(f=>({path:f.path,bytes:Buffer.byteLength(f.content),sha256:sha(f.content)}))};
const screen={title:'Fixture clock',entry:'index.html',files:[...files,{path:'manifest.json',content:JSON.stringify(manifest)}]};
const preference={id:'pref-color',scope:'profile',targetID:'profile-fixture',category:'appearance',value:'blue',revision:1,originRequestID:'request-prior',deleted:false};
const request={schemaVersion:1,requestID:'request-fixture',createdAt:time,deadlineAt:time+600000,designGuidance:definition.designGuidance,runtime:definition.runtime,services:definition.serviceCatalog.map(s=>({id:s.id,provider:s.provider,operations:s.operations,supported:{state:'yes',observedAt:time},configured:{state:s.provider==='googleCalendar'?'no':'unknown',observedAt:time},authorized:{state:'unknown',observedAt:time},entitled:{state:'unknown',observedAt:time},reachable:{state:'unknown',observedAt:time}})),preferences:[preference],context:{profileID:'profile-fixture',deviceID:'device-fixture',screenID:'screen-fixture',baseRevision:'revision-fixture-1',userRequest:'Make a clock. Remember that I always prefer blue controls for my profile.',viewport:{width:1024,height:768,scale:1,orientation:'landscape'}},delivery:{route:'fixture',contractVersion:'1'}};
request.delivery.snapshotDigest=sha(canonical(request));
const result={schemaVersion:1,requestID:request.requestID,inputDigest:request.delivery.snapshotDigest,baseRevision:'revision-fixture-1',preferenceRevisions:{'pref-color':1},operationID:'operation-fixture',screen,answer:'Created a clock with blue controls.'};
const preferenceResult={...result,preferenceMutations:[{kind:'upsert',id:'pref-color',expectedRevision:1,record:{...preference,revision:2,originRequestID:request.requestID}}],durablePreferenceAuthorization:{requestID:request.requestID,quote:'Remember that I always prefer blue controls for my profile.'}};
const receipt={schemaVersion:1,requestID:request.requestID,operationID:result.operationID,inputDigest:result.inputDigest,status:'applied',appliedAt:time+2000};
const vectors=[{z:'slash / quote " backslash \\ \n 😀 é',a:[null,true,false,1,0,1.5,1e-7,0.000001,1e20,1e21,-0]}, {'\u{1F600}':1,'\uE000':2}, {numbers:[1.2345678901234567,9007199254740991,-0.0000001,0.1,1.0000000000000002]}].map(input=>({input,canonical:canonical(input),sha256:sha(canonical(input))}));
const invalidCases=[
{name:'identifier-trailing-newline',kind:'request',path:['requestID'],value:'request-fixture\n'},
{name:'unknown-request-version',kind:'request',path:['schemaVersion'],value:2},
{name:'unknown-field',kind:'request',path:['context','unexpected'],value:'no'},
{name:'missing-required-nullable',kind:'request',path:['context','baseRevision'],remove:true},
{name:'unsupported-runtime',kind:'request',path:['runtime','features',0],value:'arbitrarySocket'},
{name:'unknown-provider',kind:'request',path:['services',0,'provider'],value:'invented'},
{name:'unavailable-calendar-config',kind:'request',path:['services',2,'configured','state'],value:'yes'},
{name:'future-capability',kind:'request',path:['services',0,'reachable','observedAt'],value:time+1},
{name:'credential-shaped-capability-extra',kind:'request',path:['services',0,'token'],value:'not-a-credential'},
{name:'preference-target-mismatch',kind:'request',path:['preferences',0,'targetID'],value:'other-profile'},
{name:'preference-object-value',kind:'preference',path:['value'],value:{unsupported:'object'}},
{name:'unknown-preference-scope',kind:'preference',path:['scope'],value:'account'},
{name:'result-inherited-constructor',kind:'result',path:['constructor'],value:123},
{name:'result-inherited-toString',kind:'result',path:['toString'],value:123},
{name:'result-inherited-prototype',kind:'result',path:['__proto__'],value:123},
{name:'request-inherited-constructor',kind:'request',path:['context','constructor'],value:123},
{name:'request-inherited-toString',kind:'request',path:['context','toString'],value:123},
{name:'request-inherited-prototype',kind:'request',path:['context','__proto__'],value:123},
{name:'result-input-mismatch',kind:'result',path:['inputDigest'],value:'0'.repeat(64)},
{name:'result-stale-base',kind:'result',path:['baseRevision'],value:'revision-old'},
{name:'result-stale-preferences',kind:'result',path:['preferenceRevisions','pref-color'],value:2},
{name:'result-unknown-field',kind:'result',path:['misc'],value:{}},
{name:'result-path-traversal',kind:'result',path:['screen','files',0,'path'],value:'../index.html'},
{name:'receipt-unknown-status',kind:'receipt',path:['status'],value:'completed'},
{name:'receipt-unsupported-version',kind:'receipt',path:['schemaVersion'],value:99},
{name:'mutation-missing-authorization',kind:'preferenceResult',path:['durablePreferenceAuthorization'],remove:true},
{name:'mutation-unquoted-authorization',kind:'preferenceResult',path:['durablePreferenceAuthorization','quote'],value:'Always make everything orange.'},
{name:'mutation-wrong-origin',kind:'preferenceResult',path:['preferenceMutations',0,'record','originRequestID'],value:'request-other'},
{name:'mutation-revision-skip',kind:'preferenceResult',path:['preferenceMutations',0,'record','revision'],value:8},
{name:'mutation-target-mismatch',kind:'preferenceResult',path:['preferenceMutations',0,'record','targetID'],value:'other-profile'},
{name:'mutation-cas-mismatch',kind:'preferenceResult',path:['preferenceMutations',0,'expectedRevision'],value:2},
];
for(const change of invalidCases.filter(c=>c.kind==='request')) {
  const invalid=structuredClone(request); let parent=invalid;
  for(const key of change.path.slice(0,-1)) parent=parent[key];
  if(change.remove) delete parent[change.path.at(-1)]; else Object.defineProperty(parent,change.path.at(-1),{value:change.value,enumerable:true,writable:true,configurable:true});
  delete invalid.delivery.snapshotDigest;
  change.snapshotDigest=sha(canonical(invalid));
}
const screenBoundaryVectors=[];
for (const character of ['a','"','\n','é','😀']) {
  const empty={title:'Boundary',entry:'index.html',files:[{path:'index.html',content:''}]};
  const overhead=Buffer.byteLength(canonical(empty));
  const unit=Buffer.byteLength(JSON.stringify(character))-2;
  const within=Math.floor((204800-overhead)/unit);
  screenBoundaryVectors.push({name:`${JSON.stringify(character)}-within`,character,count:within,accepted:true});
  screenBoundaryVectors.push({name:`${JSON.stringify(character)}-over`,character,count:within+1,accepted:false});
}
function boundaryResult(metadataCharacter, metadataCharacterCount, screenCharacter, screenCharacterCount, includeScreen, answerPadding=0) {
  const value={...structuredClone(result),preferenceMutations:[],durablePreferenceAuthorization:preferenceResult.durablePreferenceAuthorization};
  delete value.screen; value.answer += "a".repeat(answerPadding);
  let remaining=metadataCharacterCount;
  for(let i=0;i<16;i++) {
    const count=Math.min(4096,remaining); remaining-=count;
    const id=`boundary-pref-${i}`;
    value.preferenceMutations.push({kind:'upsert',id,expectedRevision:null,record:{...preference,id,value:metadataCharacter.repeat(count),revision:1,originRequestID:request.requestID}});
  }
  if(remaining>0) throw new Error('Boundary fixture exceeds scalar capacity');
  if(includeScreen) value.screen={title:'Boundary',entry:'index.html',files:[{path:'index.html',content:screenCharacter.repeat(screenCharacterCount)}]};
  return value;
}
const resultBoundaryVectors=[];
const metadataBase=Buffer.byteLength(canonical(boundaryResult('\0',0,'',0,false)));
const metadataWithin=Math.floor((131072-metadataBase)/6);
const screenBase=Buffer.byteLength(canonical({title:'Boundary',entry:'index.html',files:[{path:'index.html',content:''}]}));
const screenWithin=Math.floor((204800-screenBase)/2);
const metadataPadding=131072-(metadataBase+metadataWithin*6);
const fullBase=Buffer.byteLength(canonical(boundaryResult('\0',0,'"',screenWithin,true)));
const fullAtCount=Math.floor((393216-fullBase)/6);
const fullPadding=393216-(fullBase+fullAtCount*6);
for(const [name,metadataCount,screenCount,includeScreen,answerPadding,accepted] of [
  ['escaped-metadata-at-cap',metadataWithin,0,false,metadataPadding,true],
  ['escaped-metadata-one-byte-over',metadataWithin,0,false,metadataPadding+1,false],
  ['escaped-combined-within',metadataWithin,screenWithin,true,metadataPadding,true],
  ['escaped-full-at-cap-metadata-rejected',fullAtCount,screenWithin,true,fullPadding,false],
  ['escaped-full-one-byte-over',fullAtCount,screenWithin,true,fullPadding+1,false],
]) {
  const value=boundaryResult('\0',metadataCount,'"',screenCount,includeScreen,answerPadding);
  const metadata=structuredClone(value); delete metadata.screen;
  resultBoundaryVectors.push({name,metadataCharacter:'\0',metadataCharacterCount:metadataCount,screenCharacter:'"',screenCharacterCount:screenCount,includeScreen,answerPadding,accepted,metadataBytes:Buffer.byteLength(canonical(metadata)),fullBytes:Buffer.byteLength(canonical(value))});
}
const unicodeCompatibilityVectors=[
  {name:'title-100-BMP',kind:'title',character:'界',count:100,accepted:true},
  {name:'title-101-BMP',kind:'title',character:'界',count:101,accepted:false},
  {name:'title-50-surrogate-pairs',kind:'title',character:'😀',count:50,accepted:true},
  {name:'title-51-surrogate-pairs',kind:'title',character:'😀',count:51,accepted:false},
  {name:'answer-16000-BMP',kind:'answer',character:'界',count:16000,accepted:true},
  {name:'answer-16001-BMP',kind:'answer',character:'界',count:16001,accepted:false},
  {name:'answer-8000-surrogate-pairs',kind:'answer',character:'😀',count:8000,accepted:true},
  {name:'answer-8001-surrogate-pairs',kind:'answer',character:'😀',count:8001,accepted:false},
];
fs.writeFileSync('packages/contracts/fixtures/conformance-v1.json',JSON.stringify({schemaVersion:1,request,result,preference,receipt,preferenceResult,canonicalVectors:vectors,invalidCases,screenBoundaryVectors,resultBoundaryVectors,unicodeCompatibilityVectors},null,2)+'\n');
