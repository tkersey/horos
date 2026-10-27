// Copyright (c) 2026 Boundary contributors. MIT license.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { execute } from "./source_oracle.mjs";
import { parseExactJson } from "../../tools/v2/exact_json.mjs";

const cases = JSON.parse(await readFile(process.argv[2], "utf8"));
assert.deepEqual(cases.map(({ mode }) => mode), ["yielding", "requesting", "disposing"]);
for (const { mode, source } of cases) {
  const trace = mode === "yielding" ? [{ kind: "Yielded" }] : mode === "requesting"
    ? [{ kind: "Requested", identity: "regression/cleanup-pause", payload: [] }] : [];
  const responses = mode === "requesting" ? [[]] : [];
  assert.deepEqual(execute(source, [], responses), { trace, kind: "Completed", value: [] });
  if (mode === "disposing") continue;
  for (const repeated of [false, true]) {
    const controls = [{ at: 0, reason: "stop" }];
    if (repeated) controls.push({ at: 0, reason: "later" });
    assert.deepEqual(execute(source, [], [], controls), {
      trace, kind: "Cancelled", reason: "stop", cleanupFailures: [],
    });
  }
}
console.log("source oracle preserves cleanup handlers across yield, request, and disposal");

const emitter = process.argv[3];
assert.ok(emitter, "authoring fixture emitter required for nested-memory regression");
const word = value => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(value)); return [...b]; };
for (const [kind, values] of [
  ["state_recursive_local", [2, 2, 2, 2]],
  ["state_recursive_shared", [2, 3, 5, 6]],
]) {
  const source = parseExactJson(execFileSync(emitter, [kind, "json"], {encoding: "utf8"}));
  assert.deepEqual(execute(source, [], []), {
    trace: [], kind: "Completed", value: [4, ...values.flatMap(word)],
  }, kind);
}
console.log("source oracle preserves nested owned snapshots and deliberately shared cells");

for (const [kind, value] of [
  ["hyper_constant_peer", 42],
  ["hyper_ignored_argument", 43],
  ["hyper_unused_query", 42],
  ["hyper_ignored_successor", 42],
  ["hyper_demanded_successor", 42],
  ["hyper_lazy_product", 23],
  ["hyper_lazy_sum", 1],
  ["hyper_lazy_stream", 1],
  ["hyper_stream_head", 23],
  ["hyper_identity_project", 42],
  ["hyper_run_constant", 42],
  ["hyper_nested_need", 1103],
]) {
  const source = parseExactJson(execFileSync(emitter, [kind, "json"], {encoding: "utf8"}));
  assert.deepEqual(execute(source, [], []), {
    trace: [], kind: "Completed", value: word(value),
  }, kind);
}
console.log("source oracle preserves hyperfunction peer and successor demand boundaries");

for (const [kind, payloads, value] of [
  ["obtain", [], 7],
  ["run", [20, 10, 21, 205, 215], 35],
  ["repeated", [20, 10, 21, 205, 10, 21, 205, 230], 50],
  ["adaptive", [20, 10, 21, 205, 10, 21, 205, 230], 50],
  ["dispose", [20, 10, 21, 205], 99],
]) {
  const source = parseExactJson(execFileSync(emitter, [`hyper_task_${kind}`, "json"], {encoding: "utf8"}));
  assert.deepEqual(execute(source, [], payloads.map(() => word(5))), {
    trace: payloads.map(value => ({kind: "Requested", identity: "hyper/task", payload: word(value)})),
    kind: "Completed", value: word(value),
  }, kind);
}
const adaptive = parseExactJson(execFileSync(emitter, ["hyper_task_adaptive", "json"], {encoding: "utf8"}));
assert.deepEqual(execute(adaptive, [], [5, 5, 3, 5, 5].map(word)), {
  trace: [20, 10, 21, 203, 213].map(value => ({kind: "Requested", identity: "hyper/task", payload: word(value)})),
  kind: "Completed", value: word(33),
});
for (const kind of ["obtain", "resume", "repeated", "dispose"]) {
  const source = parseExactJson(execFileSync(emitter, [`hyper_captured_${kind}`, "json"], {encoding: "utf8"}));
  for (const [producer, consumer] of [[10, 20], [3, 40]]) {
    const produced = [producer, consumer, producer, producer + 5, producer + 100];
    const payloads = kind === "obtain" ? [] : kind === "dispose"
      ? [consumer, ...produced, consumer, consumer + 100] : kind === "repeated"
        ? [consumer, ...produced, consumer, ...produced, consumer,
          consumer + 2 * (producer + 5), consumer + 100, consumer + 100]
        : [consumer, ...produced, consumer, consumer + producer + 5, consumer + 100];
    const value = kind === "obtain" ? 7 : kind === "dispose" ? consumer
      : consumer + (kind === "repeated" ? 2 : 1) * (producer + 5);
    assert.deepEqual(execute(source, [...word(producer), ...word(consumer)], payloads.map(() => word(5))), {
      trace: payloads.map(value => ({kind: "Requested", identity: "hyper/captured", payload: word(value)})),
      kind: "Completed", value: word(value),
    }, `captured ${kind} producer=${producer} consumer=${consumer}`);
  }
}
const capturedLocal = parseExactJson(execFileSync(emitter, ["hyper_captured_local", "json"], {encoding: "utf8"}));
assert.deepEqual(execute(capturedLocal, [], [word(5), word(5)]), {
  trace: [7, 7].map(value => ({kind: "Requested", identity: "hyper/captured", payload: word(value)})),
  kind: "Completed", value: word(13),
});
const composition = parseExactJson(execFileSync(emitter, ["hyper_composition", "json"], {encoding: "utf8"}));
for (let input = 0; input < 256; input += 1) {
  assert.deepEqual(execute(composition, [input], []), {
    trace: [], kind: "Completed", value: [...word(2 * (input + 3)), Number(input === 7)],
  }, `composition ${input}`);
}
for (const [kind, values] of [
  ["hyper_duplicate", [12, 13]],
  ["hyper_configured", [12, 14]],
  ["hyper_lazy", [2, 3]],
]) {
  const source = parseExactJson(execFileSync(emitter, [kind, "json"], {encoding: "utf8"}));
  assert.deepEqual(execute(source, [...word(2), ...word(3)], []), {
    trace: [], kind: "Completed", value: values.flatMap(word),
  }, kind);
}
console.log("source oracle preserves typed task effects, retained requesters, composition and configured definitions");
