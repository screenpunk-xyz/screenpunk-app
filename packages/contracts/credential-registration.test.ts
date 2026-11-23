import { describe, expect, it } from 'vitest';
import definition from './definitions/authoring-v2.json';
import fixture from './fixtures/conformance-v2.json';
import {
  authoringDesignGuidance, authoringRuntime, CREDENTIAL_REGISTRATION_FEATURE, CREDENTIAL_REGISTRATION_LEGACY_RULE, CREDENTIAL_REGISTRATION_RULE, validateAuthoringRequest,
} from './authoring';
import { sealAuthoringRequestV2, validateAuthoringResultV2, type AuthoringRequestV2 } from './authoring-v2';

describe('device-generated credential registration negotiation', () => {
  function request(prefill: boolean, registration: boolean): AuthoringRequestV2 {
    const input = structuredClone(fixture.request) as AuthoringRequestV2;
    input.delivery.route = 'cloud';
    input.runtime = authoringRuntime(true, true, prefill, false, registration);
    input.designGuidance = authoringDesignGuidance(true, true, prefill, false, registration);
    return input;
  }

  it('includes exact opt-in instructions only for a capable Cloud V2 device', async () => {
    expect(definition.credentialRegistration).toEqual({feature:CREDENTIAL_REGISTRATION_FEATURE,rule:CREDENTIAL_REGISTRATION_RULE,
      legacyRule:CREDENTIAL_REGISTRATION_LEGACY_RULE});
    const enabled = await sealAuthoringRequestV2(request(true, true));
    expect(enabled.designGuidance.rules).toContain(CREDENTIAL_REGISTRATION_RULE);
    expect(validateAuthoringResultV2({schemaVersion:2, requestID:enabled.requestID,
      inputDigest:enabled.delivery.snapshotDigest,baseRevision:enabled.context.baseRevision,
      preferenceRevisions:Object.fromEntries(enabled.preferences.map(record => [record.id,record.revision])),
      operationID:"registration-enabled-result",answer:"Synthetic answer"},enabled).answer).toBe("Synthetic answer");
    const legacy = await sealAuthoringRequestV2(request(true, false));
    expect(legacy.runtime.features).not.toContain(CREDENTIAL_REGISTRATION_FEATURE);
    expect(legacy.designGuidance.rules).not.toContain(CREDENTIAL_REGISTRATION_RULE);
  });

  it('accepts exact previously sealed announcement guidance and rejects arbitrary rule drift', async () => {
    const input = request(true, true);
    input.designGuidance.rules = input.designGuidance.rules.map(rule => rule === CREDENTIAL_REGISTRATION_RULE ? CREDENTIAL_REGISTRATION_LEGACY_RULE : rule);
    await expect(sealAuthoringRequestV2(input)).resolves.toMatchObject({designGuidance:input.designGuidance});
    input.designGuidance.rules[input.designGuidance.rules.length - 1] = 'Arbitrary legacy hint';
    await expect(sealAuthoringRequestV2(input)).rejects.toThrow('unsupported guidance/runtime');
  });

  it('requires prefill, Cloud and V2', async () => {
    await expect(sealAuthoringRequestV2(request(false, true))).rejects.toThrow('requires Cloud V2');
    const local = request(true, true);
    local.delivery.route = 'local';
    await expect(sealAuthoringRequestV2(local)).rejects.toThrow('requires Cloud V2');
    const { libraryID, ...context } = request(true, true).context;
    const v1 = request(true, true);
    expect(() => validateAuthoringRequest({...v1, schemaVersion:1, context:{...context,currentScreen:undefined},delivery:{...v1.delivery,contractVersion:'1'}})).toThrow();
  });
});
