// Copyright (c) 2026 Boundary contributors. MIT license.
//! Exit information is ordinary first-order data available to authored cleanup.
const p = @import("program.zig");
const a = @import("admission.zig");
pub const Types = struct {
    primary: p.Id,
    reason: p.Id,
    optional_reason: p.Id,
    failures: p.Id,
    unit: p.Id,
    text: p.Id,
    bytes: p.Id,
};

/// (Normal | Failure<E> | Cancelled<Reason> | Abandoned, Option<Reason>, Seq<E>).
pub fn types(image: anytype, schema: p.Id) a.Error!Types {
    const shape = try a.schemaAt(image.schemas, schema);
    if (shape != .product or shape.product.len != 3) return error.TypeMismatch;
    const primary = try a.schemaAt(image.schemas, shape.product[0]);
    const optional = try a.schemaAt(image.schemas, shape.product[1]);
    const failures = try a.schemaAt(image.schemas, shape.product[2]);
    if (primary != .sum or
        primary.sum.len != 4 or
        optional != .sum or
        optional.sum.len != 2 or
        failures != .seq or
        failures.seq != image.roots.failure)
        return error.TypeMismatch;
    if (primary.sum[1] != image.roots.failure or
        primary.sum[2] != optional.sum[1] or
        primary.sum[0] != primary.sum[3] or
        primary.sum[0] != optional.sum[0])
        return error.TypeMismatch;
    if (try a.schemaAt(image.schemas, primary.sum[0]) != .unit) return error.TypeMismatch;
    const reason = try a.schemaAt(image.schemas, primary.sum[2]);
    if (reason != .sum or reason.sum.len != 2 or try a.schemaAt(
        image.schemas,
        reason.sum[0],
    ) != .text or try a.schemaAt(
        image.schemas,
        reason.sum[1],
    ) != .bytes) return error.TypeMismatch;
    return .{
        .primary = shape.product[0],
        .reason = primary.sum[2],
        .optional_reason = shape.product[1],
        .failures = shape.product[2],
        .unit = primary.sum[0],
        .text = reason.sum[0],
        .bytes = reason.sum[1],
    };
}
