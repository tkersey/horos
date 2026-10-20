const std = @import("std");
const wire = @import("wire.zig");
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
            first: *const anyopaque,
            second: ?*const anyopaque = null,
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
            try Node(T).step(self, .{
                .first = @ptrCast(first),
                .second = @ptrCast(second),
                .step = Node(T).step,
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
            comptime T: type,
            first: *const T,
            second: ?*const T,
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
                .step = Node(T).step,
            });
        }

        fn Node(comptime T: type) type {
            return struct {
                fn step(self: *Self, frame: Frame) Failure!void {
                    const first: *const T = @ptrCast(@alignCast(frame.first));
                    const second: *const T = if (mode == .equal)
                        @ptrCast(@alignCast(frame.second.?))
                    else
                        undefined;
                    switch (@typeInfo(T)) {
                        .@"struct" => |info| inline for (
                            info.field_names,
                            info.field_types,
                            0..,
                        ) |name, Field, index| {
                            if (frame.index == index) return self.child(
                                frame,
                                Field,
                                &@field(first.*, name),
                                if (mode == .equal) &@field(second.*, name) else null,
                                index + 1 < info.field_names.len,
                            );
                        },
                        .pointer => try slice(self, frame, first, second),
                        .array => try array(self, frame, first, second),
                        .optional => try optional(self, frame, first, second),
                        .@"union" => try tagged(self, frame, first, second),
                        else => try scalar(self, first, second),
                    }
                }

                fn scalar(self: *Self, first: *const T, second: *const T) Failure!void {
                    if (mode == .equal) {
                        if (T != void and first.* != second.*) self.stopped = true;
                    } else if (mode == .write) {
                        switch (@typeInfo(T)) {
                            .void => {},
                            .bool => try self.writer.byte(@intFromBool(first.*)),
                            .int => |info| {
                                comptime std.debug.assert(
                                    info.signedness == .unsigned and info.bits <= 64,
                                );
                                try self.writer.natural(first.*);
                            },
                            .@"enum" => try self.writer.natural(@backingInt(first.*)),
                            else => @compileError(
                                "not a logical portable record: " ++ @typeName(T),
                            ),
                        }
                    } else if (mode == .read) {
                        @constCast(first).* = switch (@typeInfo(T)) {
                            .void => {},
                            .bool => switch (try self.reader.byte()) {
                                0 => false,
                                1 => true,
                                else => return error.InvalidTag,
                            },
                            .int => std.math.cast(T, try self.reader.natural()) orelse
                                return error.InvalidLength,
                            .@"enum" => |info| decoded: {
                                const tag = try self.reader.natural();
                                inline for (info.field_values) |value|
                                    if (tag == value) break :decoded @fromBackingInt(value);
                                return error.InvalidTag;
                            },
                            else => @compileError(
                                "not a logical portable record: " ++ @typeName(T),
                            ),
                        };
                    }
                }

                fn slice(
                    self: *Self,
                    frame: Frame,
                    first: *const T,
                    second: *const T,
                ) Failure!void {
                    const info = @typeInfo(T).pointer;
                    comptime std.debug.assert(info.size == .slice and info.sentinel_ptr == null);
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
                    if (mode == .write and info.child == u64) {
                        const writer = self.writer;
                        if (writer.output == null and writer.expected == null and
                            writer.hasher == null)
                        {
                            writer.position = std.math.add(
                                usize,
                                writer.position,
                                try measuredSequence(u64, first.*),
                            ) catch return error.InvalidLength;
                            return;
                        }
                    }
                    if (info.child == u8) {
                        if (mode == .write) try self.writer.put(first.*);
                        if (mode == .equal and !std.mem.eql(u8, first.*, second.*))
                            self.stopped = true;
                        return;
                    }
                    if (frame.index < first.len) try self.child(
                        frame,
                        info.child,
                        &first.*[frame.index],
                        if (mode == .equal) &second.*[frame.index] else null,
                        frame.index + 1 < first.len,
                    );
                }

                fn readSlice(self: *Self, first: *const T) Failure!void {
                    const Child = @typeInfo(T).pointer.child;
                    const count = try self.reader.count();
                    if (count > self.reader.input.len - self.reader.position)
                        return error.Truncated;
                    if (Child == u8) {
                        @constCast(first).* = try self.reader.take(count);
                        return;
                    }
                    const bytes = std.math.mul(usize, @sizeOf(Child), count) catch
                        return error.InvalidLength;
                    if (bytes > self.remaining.*) return error.Capacity;
                    self.remaining.* -= bytes;
                    @constCast(first).* = try self.allocator.alloc(Child, count);
                }

                fn array(
                    self: *Self,
                    frame: Frame,
                    first: *const T,
                    second: *const T,
                ) Failure!void {
                    const info = @typeInfo(T).array;
                    if (info.child == u8) {
                        if (mode == .read)
                            @memcpy(@constCast(first), try self.reader.take(info.len));
                        if (mode == .write) try self.writer.put(first);
                        if (mode == .equal and !std.mem.eql(u8, first, second)) self.stopped = true;
                        return;
                    }
                    if (frame.index < info.len) try self.child(
                        frame,
                        info.child,
                        &first[frame.index],
                        if (mode == .equal) &second[frame.index] else null,
                        frame.index + 1 < info.len,
                    );
                }

                fn optional(
                    self: *Self,
                    frame: Frame,
                    first: *const T,
                    second: *const T,
                ) Failure!void {
                    const Child = @typeInfo(T).optional.child;
                    if (mode == .read) @constCast(first).* = switch (try self.reader.byte()) {
                        0 => null,
                        1 => @as(Child, undefined),
                        else => return error.InvalidTag,
                    };
                    if (mode == .write) try self.writer.byte(@intFromBool(first.* != null));
                    if (mode == .equal and (first.* != null) != (second.* != null)) {
                        self.stopped = true;
                        return;
                    }
                    if (first.*) |*present| try self.child(
                        frame,
                        Child,
                        present,
                        if (mode == .equal) &second.*.? else null,
                        false,
                    );
                }

                fn tagged(
                    self: *Self,
                    frame: Frame,
                    first: *const T,
                    second: *const T,
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
                            @FieldType(T, @tagName(known)),
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
