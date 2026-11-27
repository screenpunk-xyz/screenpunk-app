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

describe("authenticated JSON POST declaration", () => {
  const describePost = () => {
    const input = manifest();
    Object.assign(input.connections[0].customHTTP.operations[0],
      {method: "POST", path: "/v1/chat/completions", body: "json"});
    return input;
  };
  it("allows a fixed POST path with bearer and an exact runtime opt-in", () => {
    const input = describePost();
    const source = JSON.stringify(input);
    expect(() => checkAuthoringManifestScreenData(source, undefined, true, true, true)).not.toThrow();
    expect(() => checkAuthoringManifestScreenData(source, undefined, true, true, false)).toThrow(/does not advertise custom HTTP JSON POST/);
    expect(() => checkAuthoringManifestScreenData(source, source, true, true, false)).not.toThrow();
    input.connections[0].customHTTP.operations[0].path = "/v1/responses";
    expect(() => checkAuthoringManifestScreenData(JSON.stringify(input), source, true, true, false)).toThrow(/does not advertise/);
    expect(() => checkAuthoringManifestScreenData(JSON.stringify(input), source, true, true, true)).not.toThrow();
  });
  it("requires bearer, empty parameters and a distinct body mode", () => {
    for (const changes of [{body:null}, {body:"text"}, {body:undefined}, {method:"GET"},
      {parameters:{model:{type:"text"}}}, {path:"/v1/chat/completions?stream=false"}]) {
      const input = describePost();
      Object.assign(input.connections[0].customHTTP.operations[0], changes);
      expect(() => checkAuthoringManifestScreenData(JSON.stringify(input))).toThrow(/invalid custom HTTP/);
    }
    const input = describePost();
    const {auth:_, ...declaration} = input.connections[0].customHTTP;
    declaration.fields.pop();
    expect(() => checkAuthoringManifestScreenData(JSON.stringify({connections:[{...input.connections[0],customHTTP:declaration}]})))
      .toThrow(/invalid custom HTTP/);
  });
});
