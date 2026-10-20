const std = @import("std");
const wire = @import("wire.zig");
const record = @import("record.zig");
const Error = wire.Error || std.mem.Allocator.Error;
pub const Mode = enum { write, read, equal, overlaps };

pub fn measuredSequence(comptime T: type, values: []const T) wire.Error!usize {
    var total: usize = 0;
    for (values) |value| {
        comptime std.debug.assert(T == u64);
        const length = wire.naturalLength(value);
        total = std.math.add(usize, total, length) catch return error.InvalidLength;
    }
    return total;
}

pub fn Shape(comptime T: type, comptime ancestors: []const type) type {
    return struct {
        pub const recursive = blk: {
            for (ancestors) |ancestor| if (T == ancestor) break :blk true;
            const next = ancestors ++ .{T};
            break :blk switch (@typeInfo(T)) {
                inline .pointer, .array, .optional => |info| Shape(info.child, next).recursive,
                inline .@"struct", .@"union" => |info| fields: {
                    for (info.field_types) |Field|
                        if (Shape(Field, next).recursive) break :fields true;
                    break :fields false;
                },
                else => false,
            };
        };
    };
}

pub fn Walk(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        const Failure = if (mode == .equal or mode == .overlaps)
            std.mem.Allocator.Error
        else
            Error;
        const Frame = struct {
            first: *align(1) const volatile anyopaque,
            second: ?*align(1) const volatile anyopaque = null,
            index: usize = 0,
            step: *const fn (*Self, Frame) Failure!void,
        };
        allocator: std.mem.Allocator,
        frames: std.ArrayList(Frame) = .empty,
        writer: *wire.Writer = undefined,
        reader: *wire.Reader = undefined,
        remaining: *usize = undefined,
        output: []const u8 = &.{},
        stopped: bool = false,

        pub fn run(self: *Self, comptime T: type, first: *const T, second: ?*const T) Failure!bool {
            defer self.frames.deinit(self.allocator);
            try Node(@TypeOf(first)).step(self, .{
                .first = @ptrCast(first),
                .second = @ptrCast(second),
                .step = Node(@TypeOf(first)).step,
            });
            while (self.frames.items.len != 0 and !self.stopped) {
                const frame = self.frames.pop().?;
                try frame.step(self, frame);
            }
            return if (mode == .equal) !self.stopped else self.stopped;
        }

        fn child(
            self: *Self,
            frame: Frame,
            first: anytype,
            second: ?@TypeOf(first),
            more: bool,
        ) Failure!void {
            if (more) {
                var next = frame;
                next.index += 1;
                try self.frames.append(self.allocator, next);
            }
            try self.frames.append(self.allocator, .{
                .first = @ptrCast(first),
                .second = @ptrCast(second),
                .step = Node(@TypeOf(first)).step,
            });
        }

        fn Node(comptime Pointer: type) type {
            const T = @typeInfo(Pointer).pointer.child;
            return struct {
                fn restore(address: *align(1) const volatile anyopaque) Pointer {
                    return @ptrCast(@alignCast(@constCast(@volatileCast(address))));
                }

                fn finite(self: *Self, first: Pointer, second: Pointer) Failure!void {
                    switch (mode) {
                        .write => try record.write(T, first.*, self.writer),
                        .read => @constCast(first).* = try record.readBounded(
                            T,
                            self.reader,
                            self.allocator,
                            self.remaining,
                        ),
                        .equal => self.stopped = !record.equal(T, first.*, second.*),
                        .overlaps => self.stopped = record.overlaps(T, first.*, self.output),
                    }
                }

                fn step(self: *Self, frame: Frame) Failure!void {
                    const first = restore(frame.first);
                    const second: Pointer = if (mode == .equal)
                        restore(frame.second.?)
                    else
                        undefined;
                    if (comptime !Shape(T, &.{}).recursive)
                        return finite(self, first, second);
                    switch (@typeInfo(T)) {
                        .@"struct" => |info| inline for (
                            info.field_names,
                            0..,
                        ) |name, index| {
                            if (frame.index == index) return self.child(
                                frame,
                                &@field(first.*, name),
                                if (mode == .equal) &@field(second.*, name) else null,
                                index + 1 < info.field_names.len,
                            );
                        },
                        .pointer => try slice(self, frame, first, second),
                        .array => try array(self, frame, first, second),
                        .optional => try optional(self, frame, first, second),
                        .@"union" => try tagged(self, frame, first, second),
                        else => unreachable,
                    }
                }

                fn slice(
                    self: *Self,
                    frame: Frame,
                    first: Pointer,
                    second: Pointer,
                ) Failure!void {
                    const info = @typeInfo(T).pointer;
                    comptime std.debug.assert(info.size == .slice);
                    if (frame.index == 0) {
                        if (mode == .read) try readSlice(self, first);
                        if (mode == .write) try self.writer.natural(first.len);
                        if (mode == .equal and first.len != second.len) {
                            self.stopped = true;
                            return;
                        }
                        if (mode == .overlaps and
                            wire.overlap(std.mem.sliceAsBytes(first.*), self.output))
                        {
                            self.stopped = true;
                            return;
                        }
                    }
                    if (frame.index < first.len) try self.child(
                        frame,
                        &first.*[frame.index],
                        if (mode == .equal) &second.*[frame.index] else null,
                        frame.index + 1 < first.len,
                    );
                }

                fn readSlice(self: *Self, first: Pointer) Failure!void {
                    const Child = @typeInfo(T).pointer.child;
                    const count = try self.reader.count();
                    if (count > self.reader.input.len - self.reader.position)
                        return error.Truncated;
                    const bytes = std.math.mul(usize, @sizeOf(Child), count) catch
                        return error.InvalidLength;
                    if (bytes > self.remaining.*) return error.Capacity;
                    self.remaining.* -= bytes;
                    @constCast(first).* = try self.allocator.alloc(Child, count);
                }

                fn array(
                    self: *Self,
                    frame: Frame,
                    first: Pointer,
                    second: Pointer,
                ) Failure!void {
                    const info = @typeInfo(T).array;
                    if (frame.index < info.len) try self.child(
                        frame,
                        &first[frame.index],
                        if (mode == .equal) &second[frame.index] else null,
                        frame.index + 1 < info.len,
                    );
                }

                fn optional(
                    self: *Self,
                    frame: Frame,
                    first: Pointer,
                    second: Pointer,
                ) Failure!void {
                    const Child = @typeInfo(T).optional.child;
                    if (mode == .read) @constCast(first).* = switch (try self.reader.byte()) {
                        0 => null,
                        1 => switch (@typeInfo(Child)) {
                            .pointer => |pointer| try self.allocator.alloc(pointer.child, 0),
                            else => @as(Child, undefined),
                        },
                        else => return error.InvalidTag,
                    };
                    if (mode == .write) try self.writer.byte(@intFromBool(first.* != null));
                    if (mode == .equal and (first.* != null) != (second.* != null)) {
                        self.stopped = true;
                        return;
                    }
                    if (first.*) |*present| try self.child(
                        frame,
                        present,
                        if (mode == .equal) &second.*.? else null,
                        false,
                    );
                }

                fn tagged(
                    self: *Self,
                    frame: Frame,
                    first: Pointer,
                    second: Pointer,
                ) Failure!void {
                    const Tag = @typeInfo(T).@"union".tag_type.?;
                    if (mode == .read) {
                        const tag = std.enums.fromInt(Tag, try self.reader.natural()) orelse
                            return error.InvalidTag;
                        switch (tag) {
                            inline else => |known| @constCast(first).* = @unionInit(
                                T,
                                @tagName(known),
                                undefined,
                            ),
                        }
                    }
                    const tag = std.meta.activeTag(first.*);
                    if (mode == .write) try self.writer.natural(@backingInt(tag));
                    if (mode == .equal and tag != std.meta.activeTag(second.*)) {
                        self.stopped = true;
                        return;
                    }
                    switch (tag) {
                        inline else => |known| try self.child(
                            frame,
                            &@field(first.*, @tagName(known)),
                            if (mode == .equal) &@field(second.*, @tagName(known)) else null,
                            false,
                        ),
                    }
                }
            };
        }
    };
}
