import { describe, expect, it } from "vitest";
import {
  checkAuthoringManifestScreenData
} from "./authoring";

function manifest() {
  return {
    connections: [{
      alias: "generator",
      required: true,
      customHTTP: {
        id: "generator-telemetry",
        version: 1,
        label: "Generator telemetry",
        fields: [
          {id: "server", label: "Address", type: "url"},
          {id: "credential", label: "Token", type: "secret"}
        ],
        originField: "server",
        auth: {mode: "bearer", field: "credential"},
        operations: [{name: "telemetry", method: "GET", path: "/telemetry", response: "json", parameters: {}}]
      }
    }]
  };
}

describe("custom HTTP declarations", () => {
  it("keeps existing declarations while requiring runtime support for new ones", () => {
    const source = JSON.stringify(manifest());
    expect(() => checkAuthoringManifestScreenData(source, undefined, true, false)).toThrow(/does not advertise custom HTTP/);
    expect(() => checkAuthoringManifestScreenData(source, source, true, false)).not.toThrow();
    expect(() => checkAuthoringManifestScreenData(source, undefined, true, true)).not.toThrow();
  });

  it("rejects unsafe or unsupported declarations", () => {
    for (const path of ["//example.com/telemetry", "/../telemetry", "/%2e%2e/telemetry", "/telemetry?token=x"]) {
      const input = manifest();
      input.connections[0].customHTTP.operations[0].path = path;
      expect(() => checkAuthoringManifestScreenData(JSON.stringify(input))).toThrow(/invalid custom HTTP/);
    }
    const withSecretValue = manifest();
    Object.assign(withSecretValue.connections[0].customHTTP.fields[1], {value: "embedded"});
    expect(() => checkAuthoringManifestScreenData(JSON.stringify(withSecretValue))).toThrow(/invalid custom HTTP/);
    const withAuthOverride = manifest();
    withAuthOverride.connections[0].customHTTP.operations[0].parameters = {authorization: {type: "text"}};
    expect(() => checkAuthoringManifestScreenData(JSON.stringify(withAuthOverride))).toThrow(/invalid custom HTTP/);
  });
});
