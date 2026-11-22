import { describe, expect, it } from 'vitest';
import definition from './definitions/authoring-v2.json';
import fixture from './fixtures/conformance-v2.json';
import { authoringDesignGuidance, authoringRuntime, CREDENTIAL_HANDOFF_FEATURE, CREDENTIAL_HANDOFF_RULE } from './authoring';
import { sealAuthoringRequestV2, type AuthoringRequestV2 } from './authoring-v2';

describe('credential handoff negotiation', () => {
  function request(prefill: boolean, handoff: boolean): AuthoringRequestV2 {
    const input = structuredClone(fixture.request) as AuthoringRequestV2;
    input.delivery.route = 'cloud';
    input.runtime = authoringRuntime(true, true, prefill, handoff);
    input.designGuidance = authoringDesignGuidance(true, true, prefill, handoff);
    return input;
  }

  it('adds matching agent instructions only when negotiated', async () => {
    expect(definition.credentialHandoff).toEqual({feature: CREDENTIAL_HANDOFF_FEATURE, rule: CREDENTIAL_HANDOFF_RULE});
    const enabled = await sealAuthoringRequestV2(request(true, true));
    expect(enabled.designGuidance.rules).toContain(CREDENTIAL_HANDOFF_RULE);
    const legacy = await sealAuthoringRequestV2(request(true, false));
    expect(legacy.runtime.features).not.toContain(CREDENTIAL_HANDOFF_FEATURE);
    expect(legacy.designGuidance.rules).not.toContain(CREDENTIAL_HANDOFF_RULE);
  });

  it('rejects a handoff without prefill or on the local authoring route', async () => {
    await expect(sealAuthoringRequestV2(request(false, true))).rejects.toThrow();
    const local = request(true, true);
    local.delivery.route = 'local';
    await expect(sealAuthoringRequestV2(local)).rejects.toThrow();
  });
});
