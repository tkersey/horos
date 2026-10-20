//! Generic pure-codec wasm32 agreement probe. No evaluator or authored code is linked.
const std = @import("std");
const data = @import("horos_data");
var input: [1 << 20]u8 = undefined;
var output: [1 << 20]u8 = undefined;
var scratch: [8 << 20]u8 = undefined;
var program_identity: [32]u8 = undefined;

export fn program_identity_ptr() usize {
    return @intFromPtr(&program_identity);
}

export fn program_encode(length: usize) usize {
    if (length > input.len) return 0;
    var storage = std.heap.FixedBufferAllocator.init(&scratch);
    const allocator = storage.allocator();
    var decoded = data.program_image.decode(allocator, input[0..length]) catch return 0;
    defer decoded.deinit();
    program_identity = decoded.identity;
    const encoded = data.program_image.encode(allocator, decoded.program, &output) catch return 0;
    return encoded.len;
}

export fn admitted_probe(length: usize) u32 {
    if (length > input.len) return 0;
    var storage = std.heap.FixedBufferAllocator.init(&scratch);
    const allocator = storage.allocator();
    const owner = data.program_image.Admitted.decode(allocator, input[0..length]) catch return 0;
    defer owner.deinit();
    var first = owner.analysis(allocator) catch return 0;
    defer first.deinit();
    var second = owner.analysis(allocator) catch return 0;
    defer second.deinit();
    const base = first.facts.pool.base.?;
    const count = base.nodeCount();
    if (first.facts.pool == second.facts.pool or first.facts.live.ptr != second.facts.live.ptr or
        base != second.facts.pool.base.?) return 0;
    if (first.facts.pool.limit != 0) _ = first.facts.pool.run(0, 1) catch return 0;
    if (base.nodeCount() != count or second.facts.pool.nodeCount() != 0) return 0;
    program_identity = owner.identity();
    return 1;
}

export fn state_encode(length: usize) usize {
    if (length > input.len) return 0;
    var storage = std.heap.FixedBufferAllocator.init(&scratch);
    const allocator = storage.allocator();
    var decoded = data.state_image.decodeGraph(allocator, input[0..length]) catch return 0;
    defer decoded.deinit();
    const encoded = data.state_image.encode(allocator, decoded.state, &output) catch return 0;
    return encoded.len;
}

fn envelope(comptime T: type, length: usize) usize {
    if (length > input.len) return 0;
    var storage = std.heap.FixedBufferAllocator.init(&scratch);
    var decoded = data.invocation.decode(T, storage.allocator(), input[0..length]) catch return 0;
    defer decoded.deinit();
    const encoded = data.invocation.encode(
        T,
        storage.allocator(),
        decoded.value,
        &output,
    ) catch return 0;
    return encoded.len;
}
export fn invocation_encode(kind: u32, length: usize) usize {
    return switch (kind) {
        0 => envelope(data.invocation.Input, length),
        1 => envelope(data.invocation.Outcome, length),
        2 => envelope(data.invocation.Request, length),
        3 => envelope(data.invocation.Result, length),
        else => 0,
    };
}

export fn compact_input_ptr() usize {
    return @intFromPtr(&input);
}

export fn compact_output_ptr() usize {
    return @intFromPtr(&output);
}
