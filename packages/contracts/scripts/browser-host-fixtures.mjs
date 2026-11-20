import { createHash } from 'node:crypto';

const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']' :
  value !== null && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}' : JSON.stringify(value);
const seal = request => {
  delete request.delivery.snapshotDigest;
  request.delivery.snapshotDigest = createHash('sha256').update(canonical(request)).digest('hex');
  return request;
};

export function browserHostFixtures(profile, legacyDefinition, legacyV1, legacyV2) {
  const request = structuredClone(legacyV1), observedAt = request.createdAt;
  request.runtime = structuredClone(profile.runtime);
  request.designGuidance = structuredClone(profile.designGuidance);
  request.preferences = [];
  request.services = profile.serviceCatalog.map(service => ({id:service.id,provider:service.provider,operations:structuredClone(service.operations),
    supported:{state:'yes',observedAt},configured:{state:'yes',observedAt:observedAt-20},authorized:{state:'unknown',observedAt:observedAt-10},entitled:{state:'unknown',observedAt},reachable:{state:'unknown',observedAt}}));
  delete request.context.currentScreen; request.context.baseRevision = null;
  const offline = structuredClone(legacyV1);
  offline.runtime = structuredClone(legacyDefinition.browser.runtime);
  offline.designGuidance = structuredClone(legacyDefinition.browser.designGuidance);
  offline.services = []; offline.preferences = []; offline.context.baseRevision = null;
  const connection = {alias:'weather',required:true,publicHTTP:{origin:'https://api.weather.gov',userAgent:'Screenpunk/1 (browser display)',operations:[{
    name:'forecast',path:'/gridpoints/DTX/42,30/forecast',response:'json',parameters:{},maxAgeSeconds:900,staleSeconds:3600
  }]}};
  const cases = [
    {name:'local default',accepted:true,manifest:{}},
    {name:'reviewed public source',accepted:true,manifest:{connections:[connection]}},
    {name:'local pages',accepted:true,manifest:{pages:[{id:'home',name:'Home',path:'index.html'},{id:'detail',name:'Detail',path:'detail.html'}],defaultPageId:'detail'}},
    {name:'null connections',accepted:false,manifest:{connections:null}},
    {name:'null pages',accepted:false,manifest:{pages:null}},
    {name:'newline page ID',accepted:false,manifest:{pages:[{id:'home\n',name:'Home',path:'index.html'}]}},
    {name:'native provider',accepted:false,manifest:{connections:[{alias:'home',required:true}]}},
    {name:'unreviewed origin',accepted:false,manifest:{connections:[{...connection,publicHTTP:{...connection.publicHTTP,origin:'https://example.org'}}]}},
    {name:'port spelling not supported',accepted:false,manifest:{connections:[{...connection,publicHTTP:{...connection.publicHTTP,origin:'https://api.weather.gov:443'}}]}},
    {name:'duplicate alias',accepted:false,manifest:{connections:[connection,connection]}},
    {name:'screen data',accepted:false,manifest:{screenData:{exports:[{name:'value',description:'Value'}]}}},
    {name:'missing local page',accepted:false,manifest:{pages:[{id:'bad',name:'Bad',path:'missing.html'}]}},
    {name:'duplicate page ID',accepted:false,manifest:{pages:[{id:'home',name:'Home',path:'index.html'},{id:'home',name:'Again',path:'detail.html'}]}},
    {name:'unknown default page',accepted:false,manifest:{defaultPageId:'missing'}},
  ];
  return {request:seal(request),legacyOfflineRequest:seal(offline),legacyDigests:[legacyV1.delivery.snapshotDigest,legacyV2.delivery.snapshotDigest],filePaths:['index.html','detail.html','manifest.json'],manifestCases:cases};
}
