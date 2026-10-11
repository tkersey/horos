// Copyright (c) 2026 Boundary contributors. MIT license.
//! Logical process nodes. Runtime allocation and transitions are Kosmos-owned.
const p = @import("program.zig");
pub const NodeRef = struct { id: p.Id };
pub const BlobRef = struct { id: p.Id };
pub const OwnedRef = struct { node: NodeRef };
pub const ValueTag = enum(u8) { scalar = 0, blob = 1, reference = 2, owned = 3 };
pub const Value = struct {
    schema: p.Id,
    body: union(ValueTag) { scalar: [8]u8, blob: BlobRef, reference: NodeRef, owned: OwnedRef },
};
pub const Blob = struct { schema: p.Id, bytes: []const u8 };
pub const Control = struct {
    block: p.Id,
    parent: ?NodeRef = null,
    evidence: ?NodeRef = null,
    region: ?NodeRef = null,
};
pub const Continuation = struct {
    source_block: p.Id,
    parent: ?NodeRef = null,
    evidence: ?NodeRef = null,
    region: ?NodeRef = null,
};
pub const ExitReasonTag = enum(u8) { normal = 0, failure = 1, cancellation = 2, abandoned = 3 };
pub const Exit = struct {
    reason: union(ExitReasonTag) { normal: Value, failure: Value, cancellation, abandoned },
    cleanup_failures: []const Value = &.{},
    cancellation: ?@import("invocation.zig").Reason = null,
    /// Borrowed destination. The current unwind/cleanup position owns its frames.
    stop: ?NodeRef = null,
    outer: ?NodeRef = null,
    discarded: []const Value = &.{},
};
pub const Capture = struct {
    schema: p.Id,
    capture: ?NodeRef,
    delimiter: NodeRef,
    evidence: ?NodeRef,
    use_site_capabilities: []const Value = &.{},
};
pub const NodeTag = enum(u8) { control = 0, continuation = 1, handler = 2, attachment = 3, environment = 4, aggregate = 5, region = 6, region_scope = 7, injection = 8, protection = 9, cleanup_return = 10, disposal_return = 11, unwind = 12, cell = 13, one_shot = 14, multi_template = 15, branch = 16, package = 17, computation = 18, resource = 19, borrow = 20, obligation = 21, pending = 22, exit = 23 };
pub const ObligationStatusTag = enum(u8) { pending = 0, running = 1, completed = 2, failed = 3 };
pub const Node = union(NodeTag) {
    control: Control,
    continuation: Continuation,
    handler: struct { definition: p.Id, state: []const Value, evidence: ?NodeRef, region: ?NodeRef = null },
    attachment: struct {
        handler: NodeRef,
        outer: ?NodeRef,
        return_to: ?NodeRef,
        phase: enum(u8) { active = 0, suspended = 1 } = .active,
        region: ?NodeRef = null,
    },
    environment: struct { values: []const Value, tail: ?NodeRef },
    aggregate: struct { schema: p.Id, tag: p.Id, fields: []const Value },
    region: struct { descriptor: p.Id, outer: ?NodeRef, obligations: []const OwnedRef },
    region_scope: struct { source_block: p.Id, region: NodeRef, return_to: ?NodeRef },
    injection: struct { continuation: NodeRef },
    protection: struct { source_block: p.Id, obligation: OwnedRef, return_to: ?NodeRef, evidence: ?NodeRef, region: ?NodeRef, loan: ?NodeRef = null },
    cleanup_return: struct { obligation: OwnedRef, parent: ?NodeRef, exit: NodeRef },
    disposal_return: struct { schema: p.Id, parent: ?NodeRef, values: []const Value = &.{} },
    unwind: struct { cursor: ?NodeRef, values: []const Value = &.{} },
    cell: struct { schema: p.Id, region: NodeRef, value: ?Value },
    one_shot: Capture,
    multi_template: Capture,
    branch: struct { template: NodeRef, attachment: NodeRef, regions: []const struct { source: NodeRef, target: NodeRef } },
    /// The token owns its captured frames, including private regions and cleanup.
    package: struct { schema: p.Id, continuation: Value },
    computation: struct { constructor: p.Id, environment: NodeRef },
    resource: struct { schema: p.Id, value: Value },
    borrow: struct { schema: p.Id, resource: NodeRef, region: NodeRef },
    obligation: struct {
        source_block: p.Id,
        cleanup: ?Value,
        resource: ?Value = null,
        status: union(ObligationStatusTag) { pending, running: NodeRef, completed, failed: Value },
    },
    pending: struct { effect: p.Id, payload: Value, continuation: NodeRef, source_block: p.Id },
    exit: Exit,
};
pub const Roots = struct {
    current: ?NodeRef = null,
    evidence: ?NodeRef = null,
    detached: []const OwnedRef = &.{},
    exit: ?NodeRef = null,
    pending: ?NodeRef = null,
};
pub const Status = enum(u8) { active = 0, yielded = 1, parked = 2, unwinding = 3 };
