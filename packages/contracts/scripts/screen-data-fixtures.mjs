import { createHash } from 'node:crypto';

const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']' :
  value !== null && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}' : JSON.stringify(value);

export function screenDataFixtures(definition, legacyV1, legacyV2) {
  const exportRecord = { name: 'lastFeeding', description: 'Last recorded feeding time' };
  const queryRecord = { alias: 'feeding', screenId: 'installed-screen', exportName: 'lastFeeding' };
  const manifest = (name, accepted, screenData) => ({ name, accepted, manifest: screenData === undefined ? {} : { screenData } });
  const manifestCases = [
    manifest('legacy', true),
    manifest('empty', true, {}),
    manifest('local and remote', true, { exports: [exportRecord], queries: [queryRecord, { ...queryRecord, alias: 'FeedingRemote', deviceId: 'device-2' }] }),
    manifest('exact name and description bounds', true, { exports: [{ name: 'n'.repeat(64), description: 'é'.repeat(120) }] }),
    manifest('null declaration', false, null),
    manifest('null arrays', false, { queries: null }),
    manifest('duplicate export names', false, { exports: [exportRecord, { ...exportRecord, description: 'Different' }] }),
    manifest('duplicate query aliases', false, { queries: [queryRecord, { ...queryRecord, deviceId: 'different' }] }),
    manifest('too many exports', false, { exports: Array.from({ length: 17 }, (_, index) => ({ ...exportRecord, name: `export${index}` })) }),
    manifest('too many queries', false, { queries: Array.from({ length: 17 }, (_, index) => ({ ...queryRecord, alias: `query${index}` })) }),
    manifest('overlong name', false, { exports: [{ ...exportRecord, name: 'n'.repeat(65) }] }),
    manifest('alias newline', false, { queries: [{ ...queryRecord, alias: 'feeding\n' }] }),
    manifest('overlong UTF8 description', false, { exports: [{ ...exportRecord, description: 'é'.repeat(121) }] }),
    manifest('blank Unicode description', false, { exports: [{ ...exportRecord, description: ' \u2002 ' }] }),
    manifest('next line Unicode whitespace description', false, { exports: [{ ...exportRecord, description: '\u0085' }] }),
    manifest('control in description', false, { exports: [{ ...exportRecord, description: 'Name\nOther name' }] }),
    manifest('unknown declaration field', false, { extra: [] }),
    manifest('reader identity injection', false, { queries: [{ ...queryRecord, readerId: 'fake' }] }),
    manifest('unsafe target ID', false, { queries: [{ ...queryRecord, screenId: '../target' }] }),
    manifest('null optional target', false, { queries: [{ ...queryRecord, deviceId: null }] }),
  ];
  const requestDigests = [legacyV1, legacyV2].flatMap(legacy => ['local', 'cloud'].map(route => {
    const request = structuredClone(legacy);
    request.designGuidance.rules.push(...definition.screenData.rules);
    request.runtime.features.push(...definition.screenData.features);
    request.delivery.route = route;
    delete request.delivery.snapshotDigest;
    return { version: request.schemaVersion, route, digest: createHash('sha256').update(canonical(request)).digest('hex') };
  }));
  const valueCases = [
    { value: null, accepted: true }, { value: false, accepted: true },
    { unit: 'x', count: 16382, accepted: true }, { unit: 'x', count: 16383, accepted: false },
    { unit: 'é', count: 8191, accepted: true }, { unit: 'é', count: 8192, accepted: false },
    { unit: '"', count: 8191, accepted: true }, { unit: '"', count: 8192, accepted: false },
    { depth: 16, accepted: true }, { depth: 17, accepted: false },
  ];
  return { version: 1, manifestCases, requestDigests, valueCases };
}
