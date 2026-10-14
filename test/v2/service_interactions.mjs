// Independent finite-language membership for actual source/native/WASM traces.
// This observes the checked compiler reduction; it is never runtime admission.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { execute } from "./source_oracle.mjs";

export function containsServiceTrace(analysis, trace, responses) {
  let response = 0, selected = null;
  const events = trace.map(observation => {
    if (observation.kind === "Yielded") return "suspended";
    assert.equal(observation.kind, "Requested");
    const input = responses[response++];
    switch (observation.identity) {
      case "example/service-command":
        selected = input?.[0] === 0 ? input.slice(1, 9) : null;
        return "command";
      case "example/service-reply":
        return selected && selected.every((byte, i) => byte === observation.payload[i]) ? "matching_reply" : "mismatched_reply";
      case "example/service-finalize": return "finalize";
      default: throw new Error(`unbound service operation: ${observation.identity}`);
    }
  });
  const closure = states => {
    let changed = true;
    while (changed) {
      changed = false;
      for (const edge of analysis.edges) if (edge.event === null && states.has(edge.from) && !states.has(edge.to)) {
        states.add(edge.to); changed = true;
      }
    }
    return states;
  };
  let states = closure(new Set([analysis.entry]));
  for (const event of events) {
    const next = new Set();
    for (const edge of analysis.edges) if (edge.event === event && states.has(edge.from)) next.add(edge.to);
    states = closure(next);
  }
  return states.size !== 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const paths = process.argv.slice(2);
  assert.equal(paths.length, 4);
  const word = value => Array.from({ length: 8 }, (_, i) => Number((BigInt(value) >> BigInt(i * 8)) & 255n));
  const command = (id, delta) => [0, ...word(id), ...word(delta)];
  for (let index = 0; index < 2; index++) {
    const source = JSON.parse(await readFile(paths[index * 2], "utf8"));
    const analysis = JSON.parse(await readFile(paths[index * 2 + 1], "utf8"));
    assert.equal(analysis.ordered, index === 0 ? "established" : "potential");
    assert.equal(analysis.waits, "scoped_acyclic");
    for (const scenario of ["empty", "requests", "overflow", "cancelled"]) {
      const responses = scenario === "empty" ? [[1], []]
        : scenario === "cancelled" ? [command(1, 1), []]
        : scenario === "overflow" ? [command(1, 1), [], command(2, (1n << 64n) - 1n), []]
        : [command(1, 1), [], command(2, 1), [], [1], []];
      const result = execute(source, [], responses, scenario === "cancelled" ? [{ at: 1, reason: "stop" }] : []);
      assert.ok(containsServiceTrace(analysis, result.trace, responses), `${index}/${scenario}: source trace absent from abstraction`);
      if (scenario === "requests") {
        const omitted = { ...analysis, edges: analysis.edges.filter(edge => edge.event !== "suspended") };
        assert.equal(containsServiceTrace(omitted, result.trace, responses), false, "omitted edge must be detected");
        const other = { ...analysis, edges: analysis.edges.map(edge => ({ ...edge, event: edge.event === "matching_reply" ? "mismatched_reply" : edge.event === "mismatched_reply" ? "matching_reply" : edge.event })) };
        assert.equal(containsServiceTrace(other, result.trace, responses), false, "labeled reply mapping must be detected");
      }
    }
  }
  console.log("service interactions: independent source traces included; omitted edge and reply mapping rejected");
}
