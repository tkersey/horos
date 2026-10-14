// Copyright (c) 2026 Boundary contributors. MIT license.
// Independent higher-order reference semantics. This module reads source terms,
// never BPI2, target blocks, Kosmos frames, or the production evaluator.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { parseExactJson } from "../../tools/v2/exact_json.mjs";

const tag = (value) => typeof value === "string" ? value : Object.keys(value)[0];
const field = (value) => typeof value === "string" ? undefined : value[tag(value)];
const pure = (value) => ({ kind: "value", value });
const delay = (run) => ({ kind: "delay", run });
const bind = (computation, next) => ({ kind: "bind", computation, next });
class Failure extends Error { constructor(value) { super("authored failure"); this.value = value; } }

// Bind is interpreted by a trampoline. Residual positions retain actual native
// higher-order continuations, unlike the defunctionalized production machine.
function normalize(computation) {
  const continuations = [];
  let node = computation;
  for (;;) {
    if (node.kind === "delay") { try { node = node.run(); } catch (error) { if (!(error instanceof Failure)) throw error; node = { kind: "failure", value: error.value }; } }
    else if (node.kind === "bind") { continuations.push(node.next); node = node.computation; }
    else if (node.kind === "value" && continuations.length) node = continuations.pop()(node.value);
    else if (node.kind === "request" || node.kind === "yield") {
      const pending = node;
      return { ...pending, reenter: (replacement) => {
        let rest = pending.reenter(replacement);
        for (let index = continuations.length - 1; index >= 0; index--) rest = bind(rest, continuations[index]);
        return rest;
      } };
    } else return node;
  }
}

function bytes(value) { return typeof value === "string" ? new TextEncoder().encode(value) : Uint8Array.from(value); }
function natural(n) {
  const output = [];
  do { const byte = Number(n & 127n); n >>= 7n; output.push(byte | (n ? 128 : 0)); } while (n);
  return output;
}
export function encode(source, schemaId, value) {
  const schema = source.schemas[schemaId], kind = tag(schema), shape = field(schema);
  if (kind === "unit") return [];
  if (kind === "boolean") return [Number(value)];
  if (/^[iu](8|16|32|64)$/.test(kind)) {
    const width = Number(kind.slice(1)) / 8;
    let bits = BigInt.asUintN(width * 8, value);
    return Array.from({ length: width }, () => { const byte = Number(bits & 255n); bits >>= 8n; return byte; });
  }
  if (kind === "bytes" || kind === "text" || kind === "bounded_bytes" || kind === "bounded_text") {
    const data = bytes(value);
    if (kind.startsWith("bounded_") && BigInt(data.length) > BigInt(shape)) throw new Error("InvalidValue");
    return [...natural(BigInt(data.length)), ...data];
  }
  if (kind === "enumeration") {
    if (!shape.some((tag) => BigInt(tag) === BigInt(value))) throw new Error("InvalidValue");
    let n = BigInt(value);
    return Array.from({ length: 4 }, () => { const byte = Number(n & 255n); n >>= 8n; return byte; });
  }
  if (kind === "product") return shape.flatMap((child, index) => encode(source, child, value[index]));
  if (kind === "sum") return [...natural(BigInt(value.tag)), ...encode(source, shape[value.tag], value.value)];
  if (kind === "seq" || kind === "vector") return [...natural(BigInt(value.length)), ...value.flatMap((item) => encode(source, kind === "seq" ? shape : shape.element, item))];
  if (kind === "array") {
    if (BigInt(value.length) !== BigInt(shape.length)) throw new Error("InvalidValue");
    return value.flatMap((item) => encode(source, shape.element, item));
  }
  throw new Error(`non-exportable oracle value: ${kind}`);
}
function decode(source, schemaId, input, cursor) {
  const schema = source.schemas[schemaId], kind = tag(schema), shape = field(schema);
  const readNatural = () => { let n = 0n, shift = 0n; for (;;) { const byte = input[cursor.offset++]; n |= BigInt(byte & 127) << shift; if (!(byte & 128)) return Number(n); shift += 7n; } };
  if (kind === "unit") return null;
  if (kind === "boolean") return input[cursor.offset++] === 1;
  if (/^[iu](8|16|32|64)$/.test(kind)) {
    const width = Number(kind.slice(1)) / 8;
    let n = 0n;
    for (let index = 0; index < width; index++) n |= BigInt(input[cursor.offset++]) << BigInt(index * 8);
    return kind[0] === "i" ? BigInt.asIntN(width * 8, n) : n;
  }
  if (kind === "bytes" || kind === "text" || kind === "bounded_bytes" || kind === "bounded_text") {
    const n = readNatural(), value = input.slice(cursor.offset, cursor.offset + n); cursor.offset += n;
    if (kind.startsWith("bounded_") && BigInt(n) > BigInt(shape)) throw new Error("InvalidValue");
    return kind === "text" || kind === "bounded_text" ? new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(value) : value;
  }
  if (kind === "enumeration") {
    let n = 0n;
    for (let index = 0; index < 4; index++) n |= BigInt(input[cursor.offset++]) << BigInt(index * 8);
    if (!shape.some((tag) => BigInt(tag) === n)) throw new Error("InvalidValue");
    return n;
  }
  if (kind === "product") return shape.map((child) => decode(source, child, input, cursor));
  if (kind === "sum") { const selected = readNatural(); return { tag: selected, value: decode(source, shape[selected], input, cursor) }; }
  if (kind === "seq" || kind === "vector") return Array.from({ length: readNatural() }, () => decode(source, kind === "seq" ? shape : shape.element, input, cursor));
  if (kind === "array") return Array.from({ length: shape.length }, () => decode(source, shape.element, input, cursor));
  throw new Error(`non-exportable oracle input: ${kind}`);
}

// Lexical capture is a source property. This fixed point reads only source
// variables and binders, independently of emitted environments or target code.
function lexicalCaptures(source, owned) {
  const functions = source.functions.map(() => new Set());
  const values = source.values.map(() => new Set());
  const terms = source.terms.map(() => new Set());
  const valueOwners = source.values.map((value) => owned[value.schema] && tag(value.expression) !== "variable");
  const termOwners = source.terms.map(() => false);
  let changed = true;
  const merge = (into, from, excluded = []) => {
    for (const variable of from) if (!excluded.includes(variable) && !into.has(variable)) { into.add(variable); changed = true; }
  };
  while (changed) {
    changed = false;
    source.values.forEach((definition, id) => {
      const kind = tag(definition.expression), expression = field(definition.expression);
      if (kind === "variable") merge(values[id], [expression]);
      if (kind === "lambda") merge(values[id], functions[expression]);
      if (kind === "primitive") for (const operand of expression.operands) {
        merge(values[id], values[operand]);
        if (!valueOwners[id] && valueOwners[operand]) { valueOwners[id] = true; changed = true; }
      }
    });
    source.terms.forEach((term, id) => {
      const kind = tag(term), expression = field(term), target = terms[id];
      const retains = (present) => { if (present && !termOwners[id]) { termOwners[id] = true; changed = true; } };
      const val = (value) => { if (value !== null) { merge(target, values[value]); retains(valueOwners[value]); } };
      const vals = (ids) => ids.forEach(val);
      const child = (term, excluded = []) => { merge(target, terms[term], excluded); retains(termOwners[term]); };
      switch (kind) {
        case "value": case "fail": case "dispose": val(expression); break;
        case "bind": child(expression.value); child(expression.next, [expression.variable]); break;
        case "conditional": val(expression.condition); child(expression.when_true); child(expression.when_false); break;
        case "call": merge(target, functions[expression.function]); vals(expression.arguments); break;
        case "apply": val(expression.computation); vals(expression.arguments); break;
        case "perform": val(expression.capability); val(expression.payload); vals(expression.bodies); vals(expression.use_site_capabilities); break;
        case "handle": val(expression.body); vals(expression.arguments); vals(expression.state); break;
        case "resume_value": val(expression.resumption); val(expression.argument); break;
        case "resume_with": val(expression.resumption); val(expression.argument); vals(expression.state); break;
        case "resume_computation": val(expression.resumption); val(expression.computation); break;
        case "protect": val(expression.body); val(expression.cleanup); val(expression.resource); vals(expression.arguments); break;
        case "with_region": val(expression.body); vals(expression.arguments); break;
        case "yield_then": child(expression); break;
        case "match_sum": val(expression.value); for (const branch of expression.cases) child(branch.body, [branch.variable]); break;
        case "unpack_product": val(expression.value); child(expression.body, expression.variables); break;
        default: throw new Error(`unknown source binder: ${kind}`);
      }
    });
    source.functions.forEach((definition, id) => merge(functions[id], terms[definition.body], definition.parameters));
  }
  return {
    functions: functions.map((variables) => [...variables].sort((left, right) => left - right)),
    temporaries: source.functions.map((definition) => termOwners[definition.body]),
  };
}

function ownedSchemas(source) {
  const owned = source.schemas.map((schema) => tag(schema) === "internal" && ["resumption", "suspension_package", "abstract_resource", "computation"].includes(tag(schema.internal)) &&
    (tag(schema.internal) !== "resumption" && tag(schema.internal) !== "computation" || ["linear", "affine"].includes(field(schema.internal).use)));
  let changed = true;
  while (changed) {
    changed = false;
    source.schemas.forEach((schema, id) => {
      const kind = tag(schema), shape = field(schema);
      const children = kind === "product" || kind === "sum" ? shape : kind === "seq" ? [shape] : kind === "vector" || kind === "array" ? [shape.element] : [];
      if (!owned[id] && children.some((child) => owned[child])) { owned[id] = true; changed = true; }
    });
  }
  return owned;
}

export function execute(source, initial, responses = [], cancellations = []) {
  const owned = ownedSchemas(source);
  const { functions: free, temporaries } = lexicalCaptures(source, owned);
  const custody = Symbol("source custody"), owners = new WeakMap();
  function take(schema, value) {
    if (owned[schema]) { const entry = owners.get(value); if (entry) entry.active = false; }
  }
  function own(schema, value) {
    take(schema, value);
    const entry = { schema, value, active: true };
    owners.set(value, entry);
    return entry;
  }
  function keep(schema, value, frame) {
    if (owned[schema]) frame.owners.push(own(schema, value));
    return value;
  }
  let memory = { parent: null, cells: new Map() };
  const cellStorage = (cell, view = memory) => view.cells.get(cell) ?? cell;
  function inMemory(computation, view) {
    return delay(() => {
      const previous = memory;
      // An older continuation wrapper must not overwrite a newer snapshot
      // entered beneath it. Sibling resumptions still select their own view.
      let ancestor = previous;
      while (ancestor !== null && ancestor !== view) ancestor = ancestor.parent;
      const current = ancestor === view ? previous : view;
      let node;
      try { memory = current; node = normalize(computation); } finally { memory = previous; }
      if (node.kind !== "request" && node.kind !== "yield") return node;
      return { ...node, memory: node.memory ?? current,
        reenter: (replacement) => inMemory(node.reenter(replacement), current),
        abandon: node.abandon ? (exit) => inMemory(node.abandon(exit), current) : undefined };
    });
  }
  function inRegion(computation, region) {
    return delay(() => {
      const node = normalize(computation);
      if (node.kind !== "request" && node.kind !== "yield") return node;
      return { ...node, regions: [...(node.regions ?? []), region], reenter: (replacement) => inRegion(node.reenter(replacement), region) };
    });
  }
  const abrupt = (exit) => ({ kind: exit.kind, value: exit.value, exit });
  const exitOf = (node) => node.exit ?? { kind: node.kind, value: node.value, cleanupFailures: [], cancellation: null };
  const entries = (variables, env) => variables.filter((variable) => owned[source.variables[variable]]).map((variable) => own(source.variables[variable], env.get(variable)));
  function unwindOwners(computation, ownedValues) {
    return delay(() => {
      const node = normalize(computation);
      if (node.kind === "request" || node.kind === "yield") return { ...node, reenter: (replacement) => unwindOwners(node.reenter(replacement), ownedValues) };
      const exit = exitOf(node), pending = [...ownedValues].reverse();
      while (pending.length) {
        const entry = pending.pop();
        if (entry.active === false) continue;
        entry.active = false;
        const { schema: id, value } = entry;
        if (!owned[id]) continue;
        const schema = source.schemas[id], kind = tag(schema), shape = field(schema);
        if (kind === "product") for (let i = shape.length - 1; i >= 0; i--) pending.push({ schema: shape[i], value: value[i] });
        else if (kind === "sum") pending.push({ schema: shape[value.tag], value: value.value });
        else if (kind === "seq" || kind === "vector" || kind === "array") for (let i = value.length - 1; i >= 0; i--) pending.push({ schema: kind === "seq" ? shape : shape.element, value: value[i] });
        else if (kind === "internal") {
          const internal = tag(shape);
          if (internal === "resumption" && value.owns()) return unwindOwners(value.abandon(exit), pending.reverse());
          if (internal === "suspension_package") pending.push({ schema: shape.suspension_package, value: value.continuation });
          if (internal === "abstract_resource") value.consumed = true;
          if (internal === "computation" && !value.consumed) {
            value.consumed = true;
            pending.push(...[...value.captures].reverse());
          }
        }
      }
      return abrupt(exit);
    });
  }
  function ownScope(computation, frame, mayCreate = false) {
    if (!frame.owners.length && !mayCreate) return computation;
    return delay(() => {
      const node = normalize(computation);
      if (node.kind === "value") {
        if (frame.parent) {
          const retained = frame.owners.filter((entry) => entry.active).map(({ schema, value }) => own(schema, value));
          frame.parent.owners.unshift(...retained);
        }
        return node;
      }
      if (node.kind === "failure" || node.kind === "cancelled" || node.kind === "abandoned") return unwindOwners(node, frame.owners);
      return { ...node, reenter: (replacement) => ownScope(node.reenter(replacement), frame, mayCreate), abandon: (exit) => unwindOwners(node.abandon ? node.abandon(exit) : abrupt(exit), frame.owners) };
    });
  }
  function bindingScope(env, variables, values, body) {
    const local = new Map(env);
    variables.forEach((variable, index) => local.set(variable, values[index]));
    const bound = entries(variables, local);
    local[custody] = bound.length ? { owners: bound, parent: env[custody] } : env[custody];
    const next = evaluate(body, local);
    return bound.length ? ownScope(next, local[custody]) : next;
  }
  function finishCleanup(computation, exit, normalOwner) {
    const leave = (after) => {
      if (!normalOwner) return abrupt(after);
      if (after.kind === "value") { take(normalOwner.schema, normalOwner.value); return abrupt(after); }
      return unwindOwners(abrupt(after), [normalOwner]);
    };
    return delay(() => {
      const node = normalize(computation);
      if (node.kind === "value") return leave(exit);
      if (node.kind === "failure") {
        const failure = node.exit ?? { cleanupFailures: [] };
        exit.cleanupFailures.push(node.value, ...failure.cleanupFailures);
        if (exit.kind === "value" || exit.kind === "abandoned") { exit.kind = "failure"; exit.value = node.value; }
        return leave(exit);
      }
      if (node.kind === "abandoned" || node.kind === "cancelled") {
        const inner = exitOf(node), cancellation = exit.cancellation ?? inner.cancellation;
        return leave({ ...inner,
          kind: exit.kind === "failure" ? "failure" : cancellation ? "cancelled" : inner.kind,
          value: exit.kind === "failure" ? exit.value : inner.value,
          cleanupFailures: [...exit.cleanupFailures, ...inner.cleanupFailures], cancellation });
      }
      return { ...node, runningExit: exit,
        reenter: (replacement) => finishCleanup(node.reenter(replacement), exit, normalOwner),
        abandon: (reason) => finishCleanup(node.abandon ? node.abandon(reason) : abrupt(reason), exit, normalOwner) };
    });
  }
  function protect(computation, cleanup, resultSchema) {
    const release = (exit) => {
      const primary = exit.kind === "value" ? { tag: 0, value: null } : exit.kind === "failure" ? { tag: 1, value: exit.value } : exit.kind === "cancelled" ? { tag: 2, value: exit.cancellation } : { tag: 3, value: null };
      const normalOwner = exit.kind === "value" && owned[resultSchema] ? own(resultSchema, exit.value) : null;
      return finishCleanup(cleanup([[primary, exit.cancellation === null ? { tag: 0, value: null } : { tag: 1, value: exit.cancellation }, [...exit.cleanupFailures]]]), exit, normalOwner);
    };
    return delay(() => {
      const node = normalize(computation);
      if (node.kind !== "request" && node.kind !== "yield") return release(exitOf(node));
      return { ...node, reenter: (replacement) => protect(node.reenter(replacement), cleanup, resultSchema), abandon: (exit) => protect(node.abandon ? node.abandon(exit) : abrupt(exit), cleanup, resultSchema) };
    });
  }
  const constant = (id) => { const literal = source.constants[id]; return decode(source, literal.schema, bytes(literal.bytes), { offset: 0 }); };
  function value(id, env) {
    const definition = source.values[id], kind = tag(definition.expression), expression = field(definition.expression);
    if (kind === "variable") { if (!env.has(expression)) throw new Error("unbound oracle variable"); return env.get(expression); }
    if (kind === "literal") return constant(expression);
    if (kind === "lambda") {
      const captured = new Map([...free[expression]].map((variable) => [variable, env.get(variable)]));
      const closure = (args) => {
        if (owned[definition.schema]) { if (closure.consumed) throw new Error("oracle owned computation reused"); closure.consumed = true; }
        return call(expression, captured, args);
      };
      closure.captures = entries([...free[expression]], captured);
      closure.consumed = false;
      return keep(definition.schema, closure, env[custody]);
    }
    const operands = expression.operands.map((operand) => value(operand, env));
    const result = primitive(definition, expression, operands);
    // Construction transfers operands only after it succeeds. Observers keep
    // their operand's current owner; an intermediate owner belongs to this scope.
    if (!["variant_tag", "sequence_length", "sequence_get"].includes(expression.opcode))
      expression.operands.forEach((operand, index) => take(source.values[operand].schema, operands[index]));
    return keep(definition.schema, result, env[custody]);
  }
  function primitive(definition, expression, operands) {
    const fail = (kind) => { throw new Failure(constant(expression.failures.find((failure) => failure.kind === kind).value)); };
    const [left, right] = operands;
    switch (expression.opcode) {
      case "move": return left;
      case "equal": return left === right;
      case "less": return left < right;
      case "boolean_not": return !left;
      case "integer_add": case "integer_sub": case "integer_mul": case "integer_div": case "integer_rem": case "integer_convert": {
        const scalar = tag(source.schemas[definition.schema]), width = Number(scalar.slice(1));
        const division = expression.opcode === "integer_div" || expression.opcode === "integer_rem";
        if (division && right === 0n) fail("division_by_zero");
        if (division && scalar[0] === "i" && right === -1n && left === -(1n << BigInt(width - 1))) fail("arithmetic_overflow");
        const result = expression.opcode === "integer_add" ? left + right : expression.opcode === "integer_sub" ? left - right : expression.opcode === "integer_mul" ? left * right : expression.opcode === "integer_convert" ? left : expression.opcode === "integer_rem" ? left % right : left / right;
        const exact = scalar[0] === "i" ? BigInt.asIntN(width, result) : BigInt.asUintN(width, result);
        if (exact !== result) fail("arithmetic_overflow");
        return result;
      }
      case "integer_bit_not": case "integer_bit_and": case "integer_bit_or": case "integer_bit_xor": {
        const scalar = tag(source.schemas[definition.schema]), width = Number(scalar.slice(1));
        const result = expression.opcode === "integer_bit_not" ? ~left : expression.opcode === "integer_bit_and" ? left & right : expression.opcode === "integer_bit_or" ? left | right : left ^ right;
        return scalar[0] === "i" ? BigInt.asIntN(width, result) : BigInt.asUintN(width, result);
      }
      case "enum_tag": return left;
      case "select": return left ? right : operands[2];
      case "product": case "sequence": return operands;
      case "field": return left[expression.immediate];
      case "variant": return { tag: expression.immediate, value: left };
      case "variant_tag": return BigInt(left.tag);
      case "variant_payload": if (left.tag !== expression.immediate) fail("invalid_variant"); return left.value;
      case "sequence_length": return BigInt(left.length);
      case "sequence_get": return Number(right) < left.length ? { tag: 1, value: left[Number(right)] } : { tag: 0, value: null };
      case "sequence_append": case "sequence_concat": {
        const result = expression.opcode === "sequence_append" ? [...left, right] : [...left, ...right];
        const shape = source.schemas[definition.schema];
        if (tag(shape) === "vector" && BigInt(result.length) > BigInt(shape.vector.maximum)) fail("capacity_exceeded");
        return result;
      }
      case "sequence_pop": return left.length ? { tag: 1, value: [left[0], left.slice(1)] } : { tag: 0, value: null };
      case "sequence_pop_last": return [left.slice(0, Math.max(0, left.length - 1)), left.length ? { tag: 1, value: left.at(-1) } : { tag: 0, value: null }];
      case "sequence_take": return left.slice(0, Number(right));
      case "sequence_set": {
        if (right >= BigInt(left.length)) fail("invalid_index");
        const result = [...left]; result[Number(right)] = operands[2]; return result;
      }
      case "blob_length": return BigInt(bytes(left).length);
      case "blob_byte": { const data = bytes(left); return right < BigInt(data.length) ? { tag: 1, value: BigInt(data[Number(right)]) } : { tag: 0, value: null }; }
      case "blob_from_byte": return Uint8Array.of(Number(left));
      case "text_integer": return left.toString();
      case "text_scalar": {
        if (left > 0x10ffffn || left >= 0xd800n && left <= 0xdfffn) fail("invalid_utf8");
        return String.fromCodePoint(Number(left));
      }
      case "blob_compare": {
        const a = bytes(left), b = bytes(right);
        for (let index = 0; index < Math.min(a.length, b.length); index++) if (a[index] !== b[index]) return a[index] < b[index] ? -1n : 1n;
        return a.length === b.length ? 0n : a.length < b.length ? -1n : 1n;
      }
      case "blob_concat": case "blob_slice": {
        const a = bytes(left), shape = source.schemas[definition.schema], kind = tag(shape);
        let result;
        if (expression.opcode === "blob_concat") result = Uint8Array.from([...a, ...bytes(right)]);
        else {
          if (right > operands[2] || operands[2] > BigInt(a.length)) fail("capacity_exceeded");
          result = a.slice(Number(right), Number(operands[2]));
        }
        if (kind.startsWith("bounded_") && BigInt(result.length) > BigInt(field(shape))) fail("capacity_exceeded");
        if (kind === "text" || kind === "bounded_text") {
          try { return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(result); }
          catch { fail("invalid_utf8"); }
        }
        return result;
      }
      case "cell_new": { const cell = { region: left, value: right }; left.cells.add(cell); return cell; }
      case "cell_get": return cellStorage(left).value;
      case "cell_set": cellStorage(left).value = right; return null;
      case "package": return { continuation: left };
      case "unpack": return left.continuation;
      case "clone_resumption": return left.toMulti();
      case "resource_pack": return { representation: left, consumed: false };
      case "resource_unpack": {
        if (left.loan) {
          if (!left.loan.active || left.resource.consumed) throw new Error("oracle expired resource borrow");
          return left.resource.representation;
        }
        if (left.consumed) throw new Error("oracle resource reused");
        left.consumed = true;
        return left.representation;
      }
      default: throw new Error(`oracle primitive not implemented: ${expression.opcode}`);
    }
  }
  function call(functionId, env, args) {
    const function_ = source.functions[functionId], local = new Map([...free[functionId]].map((variable) => [variable, env.get(variable)]));
    function_.parameters.forEach((parameter, index) => local.set(parameter, args[index]));
    local[custody] = { owners: entries([...free[functionId], ...function_.parameters], local), parent: null };
    return ownScope(evaluate(function_.body, local), local[custody], temporaries[functionId]);
  }
  function handle(computation, activation) {
    return delay(() => {
      const node = normalize(computation), definition = source.handlers[activation.definition];
      if (node.kind === "value") return call(definition.return_function, activation.env, [...activation.state, node.value]);
      if (node.kind !== "request" && node.kind !== "yield") return node;
      const abandon = (exit) => handle(
        node.abandon ? node.abandon(exit) : abrupt(exit), activation,
      );
      if (node.kind === "yield" || node.capability !== activation.token) {
        return {
          ...node, reenter: (replacement) => handle(node.reenter(replacement), activation), abandon,
        };
      }
      const clause = definition.clauses.find((clause) => clause.effect === node.effect);
      if (!clause) throw new Error("unknown oracle operation clause");
      const signature = source.schemas[clause.resumption].internal.resumption;
      const capturedMemory = node.memory ?? memory;
      const frozen = new Map((node.regions ?? []).flatMap((region) => [...region.cells].map((cell) => [cell, cellStorage(cell, capturedMemory).value])));
      function makeToken(reusable) {
        let consumed = false;
        return {
          enter(replacement, successor) {
            if (!reusable) { if (consumed) throw new Error("oracle one-shot reused"); consumed = true; }
            let rest = node.reenter(replacement);
            if (reusable) {
              const view = { parent: capturedMemory, cells: new Map(capturedMemory.cells) };
              for (const [cell, content] of frozen) view.cells.set(cell, { value: content });
              rest = inMemory(rest, view);
            }
            return successor ? handle(rest, { ...activation, ...successor }) : signature.mode === "deep" ? handle(rest, activation) : rest;
          },
          close() {
            const exit = { kind: "abandoned", value: null, cleanupFailures: [], cancellation: null };
            return bind(mapAbandoned(this.abandon(exit)), () => pure(null));
          },
          owns() { return !reusable && !consumed; },
          abandon(exit) {
            if (consumed) throw new Error("oracle one-shot reused");
            consumed = true;
            return abandon(exit);
          },
          toMulti() {
            if (reusable || consumed) throw new Error("oracle conversion requires an owned one-shot");
            consumed = true;
            return makeToken(true);
          },
          capabilities: node.capabilities,
        };
      }
      const token = makeToken(signature.use === "multi");
      return call(clause.function, activation.env, [...activation.state, node.payload, ...node.bodies, token]);
    });
  }
  function mapAbandoned(computation) {
    return delay(() => {
      const node = normalize(computation);
      if (node.kind === "abandoned") return pure(null);
      if (node.kind === "request" || node.kind === "yield") return { ...node, reenter: (replacement) => mapAbandoned(node.reenter(replacement)) };
      return node;
    });
  }
  function evaluate(id, env) {
    return delay(() => {
      const transfers = [];
      const operand = (id) => {
        const result = value(id, env);
        transfers.push([source.values[id].schema, result]);
        return result;
      };
      const start = prepareTerm(id, env, operand);
      // A later operand may fail. Keep every earlier operand in its current
      // scope until the consuming operation can actually receive them all.
      for (const [schema, result] of transfers) take(schema, result);
      return start();
    });
  }
  function prepareTerm(id, env, operand) {
    const term = source.terms[id], kind = tag(term), expression = field(term);
    const values = (ids) => ids.map(operand);
    switch (kind) {
      case "value": return () => pure(value(expression, env));
      case "bind": return () => bind(evaluate(expression.value, env), (result) => bindingScope(env, [expression.variable], [result], expression.next));
      case "conditional": return () => evaluate(value(expression.condition, env) ? expression.when_true : expression.when_false, env);
      case "call": { const args = values(expression.arguments); return () => call(expression.function, env, args); }
      case "apply": { const computation = operand(expression.computation), args = values(expression.arguments); return () => computation(args); }
      case "perform": {
        const capability = expression.capability === null ? null : operand(expression.capability);
        const payload = operand(expression.payload), bodies = values(expression.bodies);
        const capabilities = values(expression.use_site_capabilities);
        return () => ({ kind: "request", effect: expression.effect, capability, payload, bodies, capabilities, reenter: (replacement) => replacement });
      }
      case "handle": {
        const body = operand(expression.body), args = values(expression.arguments);
        const definition = source.handlers[expression.handler];
        const activation = { definition: expression.handler, state: values(expression.state), env, token: {} };
        return () => handle(body([...definition.clauses.map(() => activation.token), ...args]), activation);
      }
      case "resume_value": {
        const token = operand(expression.resumption), argument = operand(expression.argument);
        return () => token.enter(pure(argument));
      }
      case "resume_with": {
        const token = operand(expression.resumption), argument = operand(expression.argument);
        const successor = { definition: expression.handler, state: values(expression.state), env };
        return () => token.enter(pure(argument), successor);
      }
      case "resume_computation": {
        const token = operand(expression.resumption), computation = operand(expression.computation);
        return () => token.enter(computation(token.capabilities));
      }
      case "with_region": {
        const body = operand(expression.body), args = values(expression.arguments);
        return () => { const region = { cells: new Set() }; return inRegion(body([region, ...args]), region); };
      }
      case "protect": {
        const body = operand(expression.body), cleanup = operand(expression.cleanup);
        const resultSchema = source.schemas[source.values[expression.body].schema].internal.computation.result;
        const args = values(expression.arguments);
        if (expression.resource === null) return () => protect(body(args), cleanup, resultSchema);
        const resource = operand(expression.resource);
        return () => {
          const loan = { active: true };
          return protect(body([{ resource, loan }, ...args]), (exit) => { loan.active = false; return cleanup([...exit, resource]); }, resultSchema);
        };
      }
      case "dispose": { const target = operand(expression); return () => target.close(); }
      case "fail": return () => ({ kind: "failure", value: value(expression, env) });
      case "yield_then": return () => ({ kind: "yield", reenter: () => evaluate(expression, env) });
      case "match_sum": {
        const variant = operand(expression.value), selected = expression.cases[variant.tag];
        return () => bindingScope(env, [selected.variable], [variant.value], selected.body);
      }
      case "unpack_product": {
        const fields = operand(expression.value);
        return () => bindingScope(env, expression.variables, fields, expression.body);
      }
      default: throw new Error(`oracle term not implemented: ${kind}`);
    }
  }
  const cursor = { offset: 0 }, entry = source.functions[source.entry];
  const args = entry.parameters.map((variable) => decode(source, source.variables[variable], initial, cursor));
  if (cursor.offset !== initial.length) throw new Error("oracle initial arguments have trailing bytes");
  let computation = call(source.entry, new Map(), args), index = 0;
  const trace = [];
  const applied = new Set();
  function cancel(node) {
    const controls = cancellations.map((control, id) => ({ ...control, id })).filter((control) => control.at === trace.length - 1 && !applied.has(control.id));
    if (!controls.length) return false;
    const exit = node.runningExit ?? { kind: "cancelled", value: null, cleanupFailures: [], cancellation: null };
    for (const control of controls) {
      applied.add(control.id);
      if (exit.cancellation === null) exit.cancellation = { tag: typeof control.reason === "string" ? 0 : 1, value: control.reason };
      if (exit.kind !== "failure") exit.kind = "cancelled";
    }
    if (node.runningExit) return false; // Resume the same cleanup operation.
    computation = node.abandon ? node.abandon(exit) : abrupt(exit);
    return true;
  }
  for (;;) {
    const node = normalize(computation);
    if (node.kind === "value" || node.kind === "failure" || node.kind === "cancelled") {
      if (index !== responses.length) throw new Error("unused oracle responses");
      if (applied.size !== cancellations.length) throw new Error("unused oracle cancellation");
      const exit = exitOf(node);
      if (node.kind === "cancelled") return { trace, kind: "Cancelled", reason: exit.cancellation.value, cleanupFailures: exit.cleanupFailures.map((value) => encode(source, source.failure, value)) };
      const result = { trace, kind: node.kind === "value" ? "Completed" : "Failed", value: encode(source, node.kind === "value" ? entry.result : source.failure, node.value) };
      if (node.kind === "failure") {
        result.cleanupFailures = exit.cleanupFailures.map((value) => encode(source, source.failure, value));
        if (exit.cancellation !== null) result.cancellation = exit.cancellation.value;
      }
      return result;
    }
    if (node.kind === "yield") { trace.push({ kind: "Yielded" }); if (!cancel(node)) computation = node.reenter(pure(null)); continue; }
    const effect = source.effects[node.effect];
    if (node.capability !== null || !effect.external) throw new Error("unhandled internal oracle effect");
    trace.push({ kind: "Requested", identity: new TextDecoder().decode(bytes(effect.identity)), payload: encode(source, effect.payload, node.payload) });
    if (cancel(node)) continue;
    if (index === responses.length) return { trace, kind: "Requested" };
    const encoded = responses[index++], input = { offset: 0 }, result = decode(source, effect.result, encoded, input);
    if (input.offset !== encoded.length) throw new Error("oracle response has trailing bytes");
    computation = node.reenter(pure(result));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const sources = await Promise.all(process.argv.slice(2).map(async (path) => parseExactJson(await readFile(path))));
  assert.equal(sources.length, 47);
  // Independent expectations: labels are part of the observation, not just the
  // final counter. Commands are unbounded at runtime; these are finite witnesses.
  const word = value => Array.from({ length: 8 }, (_, i) => Number((BigInt(value) >> BigInt(8 * i)) & 255n));
  const command = (id, delta) => [0, ...word(id), ...word(delta)];
  const requested = (identity, payload = []) => ({ kind: "Requested", identity: `example/service-${identity}`, payload });
  const serviceResponses = [command(1, 1), [], command(2, 1), [], [1], []];
  const serviceTrace = [
    requested("command"), { kind: "Yielded" }, requested("reply", [...word(1), ...word(0)]),
    requested("command"), { kind: "Yielded" }, requested("reply", [...word(2), ...word(1)]),
    requested("command"), requested("finalize", word(2)),
  ];
  const service = execute(sources[44], [], serviceResponses);
  assert.deepEqual(service, { kind: "Completed", value: word(2), trace: serviceTrace });
  const swapped = execute(sources[45], [], serviceResponses);
  assert.equal(swapped.kind, "Completed");
  assert.deepEqual(swapped.value, service.value);
  assert.notDeepEqual(swapped.trace, service.trace);
  assert.deepEqual(swapped.trace, serviceTrace.map(event => event.identity === "example/service-reply"
    ? { ...event, payload: [event.payload[0] ^ 3, ...event.payload.slice(1)] } : event));
  assert.deepEqual(execute(sources[44], [], [[1], []]), {
    kind: "Completed", value: word(0), trace: [requested("command"), requested("finalize", word(0))],
  });
  const paired = execute(sources[46], [], [command(1, 1), [], [1], [], command(2, 1), [], [1], []]);
  assert.deepEqual(paired, { kind: "Completed", value: word(2), trace: [
    requested("command"), { kind: "Yielded" }, requested("reply", [...word(1), ...word(0)]), requested("command"), requested("finalize", word(1)),
    requested("command"), { kind: "Yielded" }, requested("reply", [...word(2), ...word(0)]), requested("command"), requested("finalize", word(1)),
  ] });
  const cancelledService = execute(sources[44], [], [command(1, 1), []], [{ at: 1, reason: "stop" }]);
  assert.equal(cancelledService.kind, "Cancelled");
  assert.deepEqual(cancelledService.cleanupFailures, []);
  assert.deepEqual(cancelledService.trace, [requested("command"), { kind: "Yielded" }, requested("finalize", word(1))]);
  const failedService = execute(sources[44], [], [command(1, 1), [], command(2, (1n << 64n) - 1n), []]);
  assert.equal(failedService.kind, "Failed");
  assert.deepEqual(failedService.trace, [...serviceTrace.slice(0, 4), requested("finalize", word(1))]);
  for (let index = 0; index < 20; index++) {
    const populated = index % 2 === 1, owned = index >= 12;
    const result = execute(sources[36], [index]);
    const failed = owned || !populated;
    assert.equal(result.kind, failed ? "Failed" : "Completed");
    assert.deepEqual(result.value,
      [owned ? (populated ? 8 : 9) : (populated ? 7 : 8), 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(result.trace, failed ? [{ kind: "Yielded" }] : []);
  }
  for (let index = 20; index < 42; index++) {
    const result = execute(sources[36], [index], index >= 32 ? [[], []] : []);
    const trace = [{ kind: "Yielded" }];
    if (index >= 32) {
      const order = index === 33 || index === 35 || index >= 36 ? [2, 1] : [1, 2];
      for (const label of order)
        trace.push({ kind: "Requested", identity: "custody/release", payload: [label, 0, 0, 0, 0, 0, 0, 0] });
    }
    assert.equal(result.kind, "Failed");
    assert.deepEqual(result.value, [8, 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(result.trace, trace, `custody case ${index}`);
  }
  for (const index of [31, 32]) {
    assert.deepEqual(execute(sources[index], []), { kind: "Completed", trace: [], value: [7, 0, 0, 0, 0, 0, 0, 0] });
  }
  for (const [mode, order] of [
    [0, [1, 2]], [1, [2, 1]], [2, [1, 2]], [3, [1, 2]], [4, [2, 1]],
    [5, [1, 2]], [6, [1, 2]], [7, [2, 1]], [8, [2, 1]],
    [9, [2, 1]], [10, [1, 2]],
  ]) {
    const result = execute(sources[36], [42 + mode], [[], []]);
    assert.equal(result.kind, "Failed");
    assert.deepEqual(result.value, [8, 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(result.trace, order.map(label => ({
      kind: "Requested", identity: "custody/release", payload: [label, 0, 0, 0, 0, 0, 0, 0],
    })), `operand failure case ${mode}`);
  }
  assert.deepEqual(execute(sources[33], []), {
    kind: "Completed", trace: [{ kind: "Yielded" }],
    value: [42, 0, 0, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0, 0],
  });
  assert.deepEqual(execute(sources[34], []), { kind: "Completed", trace: [{ kind: "Yielded" }], value: [] });
  for (const injected of [0, 1]) {
    const result = execute(sources[30], [injected]);
    assert.equal(result.kind, "Completed");
    assert.deepEqual(result.trace, []);
    assert.deepEqual(result.value, [injected ? 209 : 109, 0, 0, 0, 0, 0, 0, 0]);
  }
  const shallowResumptions = execute(sources[29], []);
  assert.equal(shallowResumptions.kind, "Completed");
  assert.deepEqual(shallowResumptions.trace, []);
  assert.deepEqual(shallowResumptions.value,
    [99, 99, 99, 99, 42, 42, 42, 42].flatMap(value => [value, 0, 0, 0, 0, 0, 0, 0]));
  const ownership = execute(sources[28], []);
  assert.equal(ownership.kind, "Completed");
  assert.deepEqual(ownership.value, [1, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(ownership.trace, [{ kind: "Yielded" }]);
  for (const [index, initial, expected] of [[0, [40, 0, 0, 0, 0, 0, 0, 0], [42, 0, 0, 0, 0, 0, 0, 0]], [1, [], [67, 0, 0, 0, 0, 0, 0, 0]], [2, [16, 39, 0, 0, 0, 0, 0, 0], [1]], [3, [], [4, 0, 0, 0, 1, 1, 0, 1, 1]], [4, [], [1, 0, 0]]]) {
    const result = execute(sources[index], initial);
    assert.equal(result.kind, "Completed"); assert.deepEqual(result.value, expected); assert.deepEqual(result.trace, []);
  }
  const generator = execute(sources[5], [], [[]]);
  assert.equal(generator.kind, "Completed");
  assert.deepEqual(generator.value, [42, 0, 0, 0, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(generator.trace, [{ kind: "Yielded" }, { kind: "Requested", identity: "example/generator-release", payload: [43, 0, 0, 0, 0, 0, 0, 0] }]);
  for (const [index, second] of [[6, 1], [7, 2]]) {
    const result = execute(sources[index], []);
    assert.equal(result.kind, "Completed");
    assert.deepEqual(result.value, [2, 1, 0, 0, 0, 0, 0, 0, 0, second, 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(result.trace, []);
  }
  for (const index of [8, 9]) {
    const result = execute(sources[index], [], [[41, 0, 0, 0, 0, 0, 0, 0], [], []]);
    assert.equal(result.kind, "Completed");
    assert.deepEqual(result.value, [42, 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(result.trace, [
      { kind: "Requested", identity: "example/resource-acquire", payload: [] },
      { kind: "Requested", identity: "example/resource-use", payload: [41, 0, 0, 0, 0, 0, 0, 0] },
      { kind: "Requested", identity: "example/resource-release", payload: [41, 0, 0, 0, 0, 0, 0, 0] },
    ]);
    for (const duringCleanup of [false, true]) {
      const controls = duringCleanup ? [{ at: 2, reason: "stop" }, { at: 2, reason: "later" }] : [{ at: 1, reason: "stop" }, { at: 2, reason: "later" }];
      const cancelled = execute(sources[index], [], duringCleanup ? [[41, 0, 0, 0, 0, 0, 0, 0], [], []] : [[41, 0, 0, 0, 0, 0, 0, 0], []], controls);
      assert.equal(cancelled.kind, "Cancelled");
      assert.equal(cancelled.reason, "stop");
      assert.deepEqual(cancelled.cleanupFailures, []);
      assert.deepEqual(cancelled.trace, result.trace);
    }
  }
  const answers = execute(sources[10], []);
  assert.equal(answers.kind, "Completed");
  assert.deepEqual(answers.value, [1, 10, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0]);
  const scoped = execute(sources[11], [], [[], [], []]);
  assert.equal(scoped.kind, "Completed");
  assert.deepEqual(scoped.value, [20, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(scoped.trace, [2, 1, 1].map((value) => ({ kind: "Requested", identity: "example/reader-log", payload: [value, 0, 0, 0, 0, 0, 0, 0] })));
  const caught = execute(sources[12], []);
  assert.equal(caught.kind, "Completed");
  assert.deepEqual(caught.value, [0, 9, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(caught.trace, []);
  const scheduled = execute(sources[13], []);
  assert.equal(scheduled.kind, "Completed");
  assert.deepEqual(scheduled.value, [30, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(scheduled.trace, [{ kind: "Yielded" }]);
  const scalar = (value) => [value, 0, 0, 0, 0, 0, 0, 0];
  const board = (columns) => [columns.length, ...columns.flatMap(scalar)];
  for (const [index, depthFirst] of [[14, true], [15, false]]) {
    // Independent constraint search has no effects, source terms, or handler
    // continuations. Its worklist contains only boards and untested columns.
    let attempts = 0, queue = [{ board: [], half: 0 }, { board: [], half: 1 }];
    const solutions = [], selectedAt = [];
    while (queue.length) {
      const task = queue.shift();
      let alternatives = [];
      if (task.column === undefined) alternatives = [1, 2].map((n) => ({ board: task.board, column: 2 * task.half + n }));
      else {
        attempts++;
        if (task.board.every((column, row) => column !== task.column && Math.abs(column - task.column) !== task.board.length - row)) {
          const next = [...task.board, task.column];
          if (next.length === 4) { solutions.push(next); selectedAt.push(attempts); }
          else alternatives = [0, 1].map((half) => ({ board: next, half }));
        }
      }
      queue = depthFirst ? [...alternatives, ...queue] : [...queue, ...alternatives];
    }
    assert.deepEqual(solutions, [[2, 4, 1, 3], [3, 1, 4, 2]]);
    assert.equal(attempts, 60);
    assert.deepEqual(selectedAt, depthFirst ? [26, 38] : [51, 54]);
    const result = execute(sources[index], [], [scalar(201), [], [], scalar(202), [], []]);
    assert.equal(result.kind, "Completed");
    assert.deepEqual(result.value, [2, ...solutions.flatMap(board), ...scalar(attempts)]);
    assert.deepEqual(result.trace, [{ kind: "Yielded" }, ...solutions.flatMap((columns, i) => [
      { kind: "Requested", identity: "example/queens-acquire", payload: board(columns) },
      { kind: "Requested", identity: "example/queens-use", payload: [...scalar(201 + i), ...board(columns), ...scalar(selectedAt[i])] },
      { kind: "Requested", identity: "example/queens-release", payload: scalar(201 + i) },
    ])]);
  }
  const ordered = execute(sources[16], []);
  assert.equal(ordered.kind, "Completed");
  assert.deepEqual(ordered.value, [...scalar(1), ...scalar(7)]);
  assert.deepEqual(ordered.trace, []);
  const nested = execute(sources[17], []);
  assert.equal(nested.kind, "Completed");
  assert.deepEqual(nested.value, [165, 2, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(nested.trace, []);
  for (const [first, kind, value] of [[0, "Completed", [1]], [1, "Failed", []]]) {
    const protocol = execute(sources[18], [first]);
    assert.equal(protocol.kind, kind);
    assert.deepEqual(protocol.value, value);
    assert.deepEqual(protocol.trace, []);
  }
  for (const [initial, expected] of [[0, 109], [1, 209]]) {
    const injected = execute(sources[19], [initial]);
    assert.equal(injected.kind, "Completed");
    assert.deepEqual(injected.value, scalar(expected));
    assert.deepEqual(injected.trace, []);
  }
  const indexed = execute(sources[20], [], [scalar(37), [1]]);
  assert.equal(indexed.kind, "Completed");
  assert.deepEqual(indexed.value, [1, ...scalar(37), 1, 1]);
  assert.deepEqual(indexed.trace, ["number", "flag"].map((index) => ({ kind: "Requested", identity: `example/indexed/${index}`, payload: [] })));
  const aborted = execute(sources[21], [0], [[]]);
  assert.equal(aborted.kind, "Failed");
  assert.deepEqual(aborted.value, scalar(9));
  assert.deepEqual(aborted.trace, [{ kind: "Requested", identity: "example/before-abort", payload: [] }]);
  assert.deepEqual(execute(sources[21], [1]), { trace: [], kind: "Completed", value: scalar(41) });
  for (const primary of [0, 1]) for (const cancel of [false, true]) {
    const result = execute(sources[22], [primary], [[], []], cancel ? [{ at: 0, reason: "stop" }, { at: 0, reason: "later" }] : []);
    assert.equal(result.kind, "Failed");
    assert.deepEqual(result.value, scalar(primary ? 9 : 7));
    assert.deepEqual(result.cleanupFailures, [scalar(7), scalar(8)]);
    assert.equal(result.cancellation, cancel ? "stop" : undefined);
    const reason = cancel ? [1, 0, 4, ...new TextEncoder().encode("stop")] : [0];
    assert.deepEqual(result.trace, [
      { kind: "Requested", identity: "example/middle-cleanup", payload: [1, ...scalar(primary ? 9 : 7), 0, 1, ...scalar(7)] },
      { kind: "Requested", identity: "example/outer-cleanup", payload: [1, ...scalar(primary ? 9 : 7), ...reason, 2, ...scalar(7), ...scalar(8)] },
    ]);
  }
  for (const primary of [0, 1]) for (const cancel of [false, true]) {
    const result = execute(sources[35], [primary], [[], []], cancel ? [{ at: 0, reason: "stop" }, { at: 2, reason: "later" }] : []);
    assert.equal(result.kind, "Failed");
    assert.deepEqual(result.value, scalar(primary ? 9 : 7));
    assert.deepEqual(result.cleanupFailures, [scalar(7), scalar(8)]);
    assert.equal(result.cancellation, cancel ? "stop" : undefined);
    const reason = cancel ? [1, 0, 4, ...new TextEncoder().encode("stop")] : [0];
    assert.deepEqual(result.trace, [
      { kind: "Yielded" },
      { kind: "Requested", identity: "example/middle-cleanup", payload: [1, ...scalar(primary ? 9 : 7), 0, 1, ...scalar(7)] },
      { kind: "Yielded" },
      { kind: "Requested", identity: "example/outer-cleanup", payload: [1, ...scalar(primary ? 9 : 7), ...reason, 2, ...scalar(7), ...scalar(8)] },
    ]);
  }
  for (const index of [23, 24]) {
    const reentry = execute(sources[index], []);
    assert.equal(reentry.kind, "Completed");
    assert.deepEqual(reentry.value, scalar(113));
    assert.deepEqual(reentry.trace, [{ kind: "Yielded" }]);
  }
  const clauseAbort = execute(sources[25], [], [[]]);
  assert.equal(clauseAbort.kind, "Failed");
  assert.deepEqual(clauseAbort.value, scalar(9));
  assert.deepEqual(clauseAbort.cleanupFailures, []);
  assert.deepEqual(clauseAbort.trace, [{ kind: "Requested", identity: "example/abandoned-release", payload: [1, ...scalar(9), 0, 0] }]);
  assert.deepEqual(execute(sources[26], []), { trace: [], kind: "Completed", value: [7, 0, 0, 0, 9, 8, 2, 0xc3, 0xa9, 2, 0xff, 0] });
  for (const [index, expected] of [3, "invalid_utf8", "capacity_exceeded", "invalid_utf8", "capacity_exceeded", "capacity_exceeded", "invalid_index", "invalid_variant", "arithmetic_overflow", "arithmetic_overflow", "division_by_zero", 8, 2, 0, 4, 20, 240, 9, "invalid_variant"].entries()) {
    const result = execute(sources[27], [index]);
    const failed = typeof expected === "string";
    assert.equal(result.kind, failed ? "Failed" : "Completed");
    const roles = ["arithmetic_overflow", "division_by_zero", "capacity_exceeded", "invalid_utf8", "invalid_index", "invalid_variant"];
    assert.deepEqual(result.value, failed ? [roles.indexOf(expected)] : scalar(expected), `scalar-contracts ${index}`);
  }
  assert.deepEqual(execute(sources[37], []), { trace: [], kind: "Completed",
    value: [1, ...scalar(1), 4, ...[1, 3, 99, 99].flatMap(scalar)] });
  assert.deepEqual(execute(sources[38], []), { trace: [], kind: "Completed",
    value: [1, ...scalar(3), 3, ...[1, 3, 99].flatMap(scalar)] });
  assert.deepEqual(execute(sources[39], []), { trace: [{ kind: "Yielded" }], kind: "Failed", value: [], cleanupFailures: [] });
  assert.deepEqual(execute(sources[39], [], [], [{ at: 0, reason: "stop" }, { at: 0, reason: "later" }]),
    { trace: [{ kind: "Yielded" }], kind: "Failed", value: [], cleanupFailures: [], cancellation: "stop" });
  assert.deepEqual(execute(sources[40], []), { trace: [], kind: "Completed",
    value: [...scalar(3), 3, ...[3, 7, 99].flatMap(scalar)] });
  assert.deepEqual(execute(sources[41], [0]), { trace: [], kind: "Completed", value: scalar(8) });
  assert.deepEqual(execute(sources[41], [1]), { trace: [], kind: "Failed", value: scalar(77), cleanupFailures: [] });
  for (const [index, result, branches] of [[42, 15, [15]], [43, 32, [15, 17]]]) {
    assert.deepEqual(execute(sources[index], [], [scalar(10), ...branches.map(() => [])]), {
      kind: "Completed", value: scalar(result), trace: [
        { kind: "Requested", identity: "local/producer", payload: [] },
        ...branches.flatMap(value => [{ kind: "Yielded" }, { kind: "Requested", identity: "local/branch", payload: scalar(value) }]),
      ],
    });
  }
  console.log("independent source oracle: 47 compiled source fixtures and cancellation/cleanup scenarios passed");
}
