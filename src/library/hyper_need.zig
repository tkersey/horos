const std = @import("std");
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const hyper = @import("hyper.zig");
const option_contract = @import("../authoring/option_contract.zig");

pub fn API(comptime QueryAccess: type) type {
    return struct {
        fn Op(comptime S: type, comptime C: type) type {
            return a.OperationSignature(S, C, bridge.Empty);
        }

        fn FamilyData(comptime S: type, comptime C: type) type {
            return struct {
                state: *const a.Schema(S),
                contribution: *const a.Schema(C),
                effect: *const a.Operation(Op(S, C)),
                capability: *const a.Schema(a.Internal(.{ .capability = Op(S, C) })),
                state_delay: *const a.Schema(hyper.Delayed(S)),
            };
        }

        pub fn Family(comptime S: type, comptime C: type) type {
            return opaque {
                pub const State = S;
                pub const Contribution = C;
                fn data(self: *const @This()) *const FamilyData(S, C) {
                    return @ptrCast(@alignCast(self));
                }
                pub fn state(self: *const @This()) *const a.Schema(S) {
                    return self.data().state;
                }
                pub fn contribution(self: *const @This()) *const a.Schema(C) {
                    return self.data().contribution;
                }
                pub fn effect(self: *const @This()) *const a.Operation(Op(S, C)) {
                    return self.data().effect;
                }
                pub fn capability(
                    self: *const @This(),
                ) *const a.Schema(a.Internal(.{ .capability = Op(S, C) })) {
                    return self.data().capability;
                }
                pub fn stateDelay(self: *const @This()) *const a.Schema(hyper.Delayed(S)) {
                    return self.data().state_delay;
                }
            };
        }

        fn familyType(comptime T: type) type {
            if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
                @compileError("Horos hyper demand: expected a canonical family");
            const Child = @typeInfo(T).pointer.child;
            if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "State") or
                !@hasDecl(Child, "Contribution"))
                @compileError("Horos hyper demand: expected a canonical family");
            if (T != *const Family(Child.State, Child.Contribution))
                @compileError("Horos hyper demand: expected a canonical family");
            return Child;
        }

        pub fn family(
            c: *a.Context,
            name: []const u8,
            state: anytype,
            contribution: anytype,
        ) a.Error!*const Family(
            bridge.schemaShape(@TypeOf(state)),
            bridge.schemaShape(@TypeOf(contribution)),
        ) {
            const effect = try c.local(name, state, contribution, .linear);
            const stored = try bridge.raw.interop.namedStorage(
                bridge.context(c),
                FamilyData(
                    bridge.schemaShape(@TypeOf(state)),
                    bridge.schemaShape(@TypeOf(contribution)),
                ),
                .{
                    .state = state,
                    .contribution = contribution,
                    .effect = effect,
                    .capability = try c.capability(effect),
                    .state_delay = try hyper.delayed(c, state, .{ .captures = .{state} }),
                },
            );
            return @ptrCast(stored);
        }

        pub fn request(
            body: anytype,
            need: anytype,
            capability: anytype,
            state: anytype,
        ) a.Error!*const a.Value(familyType(@TypeOf(need)).Contribution) {
            return body.performLocal(need.effect(), capability, state);
        }

        fn H(
            comptime S: type,
            comptime C: type,
            comptime A: type,
            comptime B: type,
            comptime R: type,
        ) type {
            return a.HandlerShape(
                native.Fields(&.{"capability"}, &.{Op(S, C)}),
                R,
                R,
                native.Fields(&.{"peer"}, &.{hyper.Delayed(hyper.Hyper(B, A))}),
                bridge.Empty,
                .deep,
            );
        }

        fn Work(comptime S: type, comptime C: type, comptime R: type) type {
            return a.Internal(.{ .callable = a.Signature(native.Fields(
                &.{"capability"},
                &.{a.Internal(.{ .capability = Op(S, C) })},
            ), R) });
        }

        fn InterpretationData(
            comptime S: type,
            comptime C: type,
            comptime A: type,
            comptime B: type,
            comptime R: type,
        ) type {
            return struct {
                handler: *const a.Handler(H(S, C, A, B, R)),
                body: *const a.Schema(Work(S, C, R)),
                peer: *const a.Value(hyper.Delayed(hyper.Hyper(B, A))),
            };
        }

        pub fn Interpretation(
            comptime S: type,
            comptime C: type,
            comptime A: type,
            comptime B: type,
            comptime R: type,
        ) type {
            return opaque {
                pub const State = S;
                pub const Contribution = C;
                pub const Input = A;
                pub const Output = B;
                pub const Result = R;
                fn data(self: *const @This()) *const InterpretationData(S, C, A, B, R) {
                    return @ptrCast(@alignCast(self));
                }
                pub fn body(self: *const @This()) *const a.Schema(Work(S, C, R)) {
                    return self.data().body;
                }
                pub fn handler(self: *const @This()) *const a.Handler(H(S, C, A, B, R)) {
                    return self.data().handler;
                }
            };
        }

        fn interpretationType(comptime T: type) type {
            if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
                @compileError("Horos hyper demand: expected a canonical interpretation");
            const Child = @typeInfo(T).pointer.child;
            if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "State") or
                !@hasDecl(Child, "Contribution") or !@hasDecl(Child, "Input") or
                !@hasDecl(Child, "Output") or !@hasDecl(Child, "Result"))
                @compileError("Horos hyper demand: expected a canonical interpretation");
            if (T != *const Interpretation(
                Child.State,
                Child.Contribution,
                Child.Input,
                Child.Output,
                Child.Result,
            )) @compileError("Horos hyper demand: expected a canonical interpretation");
            return Child;
        }

        fn Interpreted(comptime Q: type, comptime N: type, comptime R: type) type {
            const Query = QueryAccess.Shape(Q);
            const Need = familyType(N);
            return Interpretation(
                Need.State,
                Need.Contribution,
                Query.Input,
                Query.Output,
                bridge.schemaShape(R),
            );
        }

        pub fn interpret(
            body: anytype,
            query: anytype,
            need: anytype,
            result: anytype,
            options: anytype,
        ) a.Error!*const Interpreted(@TypeOf(query), @TypeOf(need), @TypeOf(result)) {
            return interpretWith(body, query, need, result, options, Resume{});
        }

        pub fn interpretWith(
            body: anytype,
            query: anytype,
            need: anytype,
            result: anytype,
            options: anytype,
            completion: anytype,
        ) a.Error!*const Interpreted(@TypeOf(query), @TypeOf(need), @TypeOf(result)) {
            comptime option_contract.check("hyper.demand.interpret", @TypeOf(options), &.{
                "captures", "residual", "owned_regions", "borrowed_regions", "obligations",
            });
            const c = try body.context();
            _ = try body.schemaOf(QueryAccess.peer(query));
            const handler = try makeHandler(c, query, need, result, options);
            const returns = try c.returnFunction(handler);
            const return_body = try body.closureBody(returns);
            try c.define(returns, try return_body.ret(try return_body.parameter("result")));
            try defineClause(body, query, need, handler, completion);
            const Q = QueryAccess.Shape(@TypeOf(query));
            const N = familyType(@TypeOf(need));
            const stored = try bridge.raw.interop.namedStorage(
                bridge.context(c),
                InterpretationData(
                    N.State,
                    N.Contribution,
                    Q.Input,
                    Q.Output,
                    bridge.schemaShape(@TypeOf(result)),
                ),
                .{
                    .handler = handler,
                    .body = try c.handledSchema(handler),
                    .peer = QueryAccess.peer(query),
                },
            );
            return @ptrCast(stored);
        }

        fn makeHandler(
            c: *a.Context,
            query: anytype,
            need: anytype,
            result: anytype,
            options: anytype,
        ) a.Error!*const a.Handler(H(
            familyType(@TypeOf(need)).State,
            familyType(@TypeOf(need)).Contribution,
            QueryAccess.Shape(@TypeOf(query)).Input,
            QueryAccess.Shape(@TypeOf(query)).Output,
            bridge.schemaShape(@TypeOf(result)),
        )) {
            const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
            const length = std.math.add(usize, captures.slice().len, 2) catch return error.Capacity;
            const allocator = a.interop.builder(c).allocator();
            const bound = try allocator.alloc(*const a.Schema(a.Dynamic), length);
            for (captures.slice(), bound[0..captures.slice().len]) |schema, *item| {
                item.* = @ptrCast(schema);
            }
            bound[length - 2] = a.interop.erase(need.capability());
            bound[length - 1] = a.interop.erase(query.types().peerBackward());
            return c.handler(need.effect(), result, result, .{
                .mode = .deep,
                .use = .linear,
                .state = .{ .peer = query.types().peerBackward() },
                .captures = bound,
                .body_captures = bridge.option(options, "captures", .{}),
                .residual = bridge.option(options, "residual", .{}),
                .return_effects = .{},
                .owned_regions = bridge.option(options, "owned_regions", .{}),
                .borrowed_regions = bridge.option(options, "borrowed_regions", .{}),
                .obligations = bridge.option(options, "obligations", false),
            });
        }

        fn defineClause(
            body: anytype,
            original: anytype,
            need: anytype,
            handler: anytype,
            completion: anytype,
        ) a.Error!void {
            const c = try body.context();
            const function = try c.clauseFunction(handler);
            const nested = try body.closureBody(function);
            const state = try nested.parameter("payload");
            const query = try QueryAccess.rebind(
                original,
                nested,
                state,
                try nested.parameter("peer"),
            );
            const successor = try hyper.deferValue(nested, need.stateDelay(), state);
            const task = try hyper.force(nested, try query.ask(nested, successor));
            const contribution = try a.interop.refineValue(
                nested,
                try nested.apply(task, .{}),
                need.contribution(),
            );
            try c.define(function, try completion.emit(
                nested,
                try nested.parameter("resumption"),
                contribution,
            ));
        }

        const Resume = struct {
            pub fn emit(
                _: @This(),
                body: anytype,
                token: anytype,
                contribution: anytype,
            ) a.Error!*const a.Computation(a.ShapeOf(@TypeOf(token)).internal.resumption.result) {
                return body.ret(try body.resumeValue(token, contribution));
            }
        };

        pub fn handle(
            body: anytype,
            interpretation: anytype,
            work: anytype,
        ) a.Error!*const a.Value(interpretationType(@TypeOf(interpretation)).Result) {
            return body.handleWith(interpretation.handler(), work, .{
                .peer = interpretation.data().peer,
            });
        }
    };
}
