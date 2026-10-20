//! Inspect the generated resource fixture for deliberate source-IR mutations.
//! Pure staging binds are followed explicitly; acquisition and protection remain
//! the operations produced by the current public example.
const source = @import("../source.zig");
const Id = source.Id;
const Binding = @FieldType(source.ast.Term, "bind");

fn binding(b: *const source.Builder, variable: Id) !Binding {
    for (b.terms.items) |term|
        if (term == .bind and
            term.bind.variable == variable)
            return term.bind;
    return error.InvalidSource;
}
fn staticValue(b: *const source.Builder, initial: Id) !Id {
    var id = initial;
    for (0..b.values.items.len + 1) |_| {
        const value = b.values.items[@intCast(id)];
        if (value.expression == .lambda) return id;
        if (value.expression != .variable) return error.InvalidSource;
        const definition = b.terms.items[
            @intCast((try binding(b, value.expression.variable)).value)
        ];
        if (definition != .value) return error.InvalidSource;
        id = definition.value;
    }
    return error.InvalidSource;
}
fn mutableBody(b: *source.Builder, value_id: Id) !Id {
    const value = b.values.items[@intCast(value_id)];
    const target = value.expression.lambda;
    const signature = b.functions.items[@intCast(target)];
    const schemas = try b.allocator().alloc(Id, signature.parameters.len);
    for (
        signature.parameters,
        schemas,
    ) |parameter, *schema| schema.* = b.variables.items[@intCast(parameter)];
    const wrapper = try b.declare(schemas, signature.result, signature.effects, signature.regions);
    const arguments = try b.allocator().alloc(Id, schemas.len);
    for (
        arguments,
        0..,
    ) |*argument, index| argument.* = try b.reference(b.parameter(wrapper, index));
    try b.define(wrapper, try b.term(.{ .call = .{ .function = target, .arguments = arguments } }));
    return b.lambda(wrapper, value.schema);
}
pub fn resourceEntry(b: *source.Builder, entry: Id) !Binding {
    var cursor = b.functions.items[@intCast(entry)].body orelse return error.InvalidSource;
    for (0..b.terms.items.len + 1) |_| {
        const term = b.terms.items[@intCast(cursor)];
        const candidate = if (term == .bind) b.terms.items[@intCast(term.bind.value)] else term;
        if (candidate == .protect and candidate.protect.resource != null) {
            var protection = candidate.protect;
            const owner = b.values.items[@intCast(protection.resource.?)].expression;
            if (owner != .variable) return error.InvalidSource;
            var acquired = try binding(b, owner.variable);
            // Mutation tests may change the body result type. Give them a fresh
            // declaration/value so earlier staged bindings retain valid types.
            protection.body = try mutableBody(b, try staticValue(b, protection.body));
            protection.cleanup = try staticValue(b, protection.cleanup);
            acquired.next = try b.term(.{ .protect = protection });
            return acquired;
        }
        if (term != .bind) return error.InvalidSource;
        cursor = term.bind.next;
    }
    return error.InvalidSource;
}
