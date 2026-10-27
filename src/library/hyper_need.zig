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
            comptime R: type,
        ) type {
            return a.HandlerShape(
                native.Fields(&.{"capability"}, &.{Op(S, C)}),
                R,
                R,
                native.Fields(&.{"response"}, &.{Response(S, C, R)}),
                bridge.Empty,
                .deep,
            );
        }

        fn ResponseSignature(comptime S: type, comptime C: type, comptime R: type) type {
            return a.Signature(native.Fields(
                &.{ "payload", "resumption" },
                &.{ S, a.Internal(.{ .resumption = a.ResumptionSignature(C, R, .deep) }) },
            ), R);
        }

        fn Response(comptime S: type, comptime C: type, comptime R: type) type {
            return a.Internal(.{ .callable = ResponseSignature(S, C, R) });
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
            comptime R: type,
        ) type {
            return struct {
                handler: *const a.Handler(H(S, C, R)),
                body: *const a.Schema(Work(S, C, R)),
                response: *const a.Function(ResponseSignature(S, C, R)),
                response_schema: *const a.Schema(Response(S, C, R)),
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
                fn data(self: *const @This()) *const InterpretationData(S, C, R) {
                    return @ptrCast(@alignCast(self));
                }
                pub fn body(self: *const @This()) *const a.Schema(Work(S, C, R)) {
                    return self.data().body;
                }
                pub fn handler(self: *const @This()) *const a.Handler(H(S, C, R)) {
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
            const N = familyType(@TypeOf(need));
            const R = bridge.schemaShape(@TypeOf(result));
            const declaration = try c.declareSchema(
                .callable,
                Response(N.State, N.Contribution, R),
            );
            try inferResponseCaptures(c, query, options, declaration);
            const handler = try makeHandler(c, query, need, result, options, declaration.schema());
            try defineResponseSchema(c, need, result, options, handler, declaration);
            const response = try c.functionFor("hyper.need.response", declaration.schema());
            try defineResponse(body, query, need, response, completion);
            const returns = try c.returnFunction(handler);
            const return_body = try c.body(returns);
            try c.define(returns, try return_body.ret(try return_body.parameter("result")));
            try defineClause(c, handler);
            const stored = try bridge.raw.interop.namedStorage(
                bridge.context(c),
                InterpretationData(
                    N.State,
                    N.Contribution,
                    bridge.schemaShape(@TypeOf(result)),
                ),
                .{
                    .handler = handler,
                    .body = try c.handledSchema(handler),
                    .response = response,
                    .response_schema = declaration.schema(),
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
            response: anytype,
        ) a.Error!*const a.Handler(H(
            familyType(@TypeOf(need)).State,
            familyType(@TypeOf(need)).Contribution,
            bridge.schemaShape(@TypeOf(result)),
        )) {
            const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
            const length = std.math.add(usize, captures.slice().len, 3) catch return error.Capacity;
            const allocator = a.interop.builder(c).allocator();
            const bound = try allocator.alloc(*const a.Schema(a.Dynamic), length);
            for (captures.slice(), bound[0..captures.slice().len]) |schema, *item| {
                item.* = @ptrCast(schema);
            }
            bound[length - 3] = a.interop.erase(need.capability());
            bound[length - 2] = a.interop.erase(query.types().peerBackward());
            bound[length - 1] = a.interop.erase(response);
            return c.handler(need.effect(), result, result, .{
                .mode = .deep,
                .use = .linear,
                .state = .{ .response = response },
                .captures = bound,
                .body_captures = bridge.option(options, "captures", .{}),
                .residual = bridge.option(options, "residual", .{}),
                .return_effects = .{},
                .owned_regions = bridge.option(options, "owned_regions", .{}),
                .borrowed_regions = bridge.option(options, "borrowed_regions", .{}),
                .obligations = bridge.option(options, "obligations", false),
            });
        }

        fn inferResponseCaptures(
            c: *a.Context,
            query: anytype,
            options: anytype,
            declaration: anytype,
        ) a.Error!void {
            const inherited = try bridge.schema(query.types().forward()).checkedCaptures();
            const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
            const length = std.math.add(usize, inherited.len, captures.slice().len) catch
                return error.Capacity;
            const allocator = a.interop.builder(c).allocator();
            const allowed = try allocator.alloc(*const bridge.raw.Schema, length);
            @memcpy(allowed[0..inherited.len], inherited);
            @memcpy(allowed[inherited.len..], captures.slice());
            try bridge.context(c).inferCallableCaptures(@ptrCast(declaration), allowed);
        }
        fn defineResponseSchema(
            c: *a.Context,
            need: anytype,
            result: anytype,
            options: anytype,
            handler: anytype,
            declaration: anytype,
        ) a.Error!void {
            try c.defineCallable(declaration, .{
                .payload = need.state(),
                .resumption = try c.resumptionSchemaFor(handler, need.effect()),
            }, result, bridge.option(options, "residual", .{}), .{
                .use = .reusable,
                .captures = .{},
                .regions = bridge.option(options, "borrowed_regions", .{}),
            });
        }

        fn defineResponse(
            body: anytype,
            query: anytype,
            need: anytype,
            function: anytype,
            completion: anytype,
        ) a.Error!void {
            const c = try body.context();
            const nested = try body.closureBody(function);
            const state = try nested.parameter("payload");
            const delay = try hyper.delayed(c, need.state(), .{ .captures = .{need.state()} });
            const successor = try hyper.deferValue(nested, delay, state);
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

        fn defineClause(c: *a.Context, handler: anytype) a.Error!void {
            const function = try c.clauseFunction(handler);
            const body = try c.body(function);
            const result = try body.apply(try body.parameter("response"), .{
                .payload = try body.parameter("payload"),
                .resumption = try body.parameter("resumption"),
            });
            try c.define(function, try body.ret(result));
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
                .response = try body.lambda(
                    interpretation.data().response,
                    interpretation.data().response_schema,
                ),
            });
        }
    };
}
