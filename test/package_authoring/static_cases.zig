pub const cases = .{
    .{ "policy_state_interpret_unknown", "Horos state.interpret: unknown option unknown" },
    .{
        "policy_state_interpret_missing_captures", "Horos state.interpret: missing option captures",
    },
    .{
        "policy_state_interpret_missing_residual", "Horos state.interpret: missing option residual",
    },
    .{
        "policy_state_interpret_missing_answer", "Horos state.interpret: missing option answer",
    },
    .{
        "policy_state_interpret_nested", "Horos state.interpret.captures: unknown option unknown",
    },
    .{
        "policy_state_interpret_continuation",
        "Horos state.interpret: missing option captures.continuation",
    },
    .{ "policy_reader_family_unknown", "Horos reader.family: unknown option unknown" },
    .{
        "policy_reader_family_missing_inside_captures",
        "Horos reader.family: missing option inside_captures",
    },
    .{
        "policy_reader_family_missing_residual", "Horos reader.family: missing option residual",
    },
    .{
        "policy_reader_family_missing_borrowed_regions",
        "Horos reader.family: missing option borrowed_regions",
    },
    .{ "policy_reader_interpret_unknown", "Horos reader.interpret: unknown option unknown" },
    .{
        "policy_reader_interpret_missing_captures",
        "Horos reader.interpret: missing option captures",
    },
    .{
        "policy_reader_interpret_nested", "Horos reader.interpret.captures: unknown option unknown",
    },
    .{
        "policy_reader_interpret_continuation",
        "Horos reader.interpret: missing option captures.continuation",
    },
    .{ "policy_writer_interpret_unknown", "Horos writer.interpret: unknown option unknown" },
    .{
        "policy_writer_interpret_missing_captures",
        "Horos writer.interpret: missing option captures",
    },
    .{
        "policy_writer_interpret_missing_residual",
        "Horos writer.interpret: missing option residual",
    },
    .{
        "policy_writer_interpret_nested", "Horos writer.interpret.captures: unknown option unknown",
    },
    .{
        "policy_writer_interpret_continuation",
        "Horos writer.interpret: missing option captures.continuation",
    },
    .{ "policy_raise_catching_unknown", "Horos raise.catching: unknown option unknown" },
    .{
        "policy_raise_catching_missing_captures", "Horos raise.catching: missing option captures",
    },
    .{
        "policy_raise_catching_missing_residual", "Horos raise.catching: missing option residual",
    },
    .{
        "policy_raise_catching_missing_borrowed_regions",
        "Horos raise.catching: missing option borrowed_regions",
    },
    .{
        "policy_raise_catching_nested", "Horos raise.catching.captures: unknown option unknown",
    },
    .{
        "policy_raise_catching_continuation",
        "Horos raise.catching: missing option captures.continuation",
    },
    .{ "policy_scheduler_fifo_unknown", "Horos scheduler.fifo: unknown option unknown" },
    .{
        "policy_scheduler_fifo_missing_residual", "Horos scheduler.fifo: missing option residual",
    },
    .{
        "policy_scheduler_fifo_missing_borrowed_regions",
        "Horos scheduler.fifo: missing option borrowed_regions",
    },
    .{
        "policy_scheduler_awaiting_unknown", "Horos scheduler.awaiting: unknown option unknown",
    },
    .{
        "policy_scheduler_awaiting_missing_borrowed_regions",
        "Horos scheduler.awaiting: missing option borrowed_regions",
    },

    .{ "option_handler", "Horos handler: unknown option return_effect" },
    .{ "option_handler_set", "Horos handlerSet: unknown option return_effect" },
    .{ "option_responder", "Horos responder: unknown option return_effect" },
    .{ "option_callable", "Horos callable: unknown option capture" },
    .{ "option_define_callable", "Horos defineCallable: unknown option capture" },
    .{ "option_region_body", "Horos regionBodySchema: unknown option capture" },
    .{ "option_append", "Horos append: unknown option capcity" },
    .{ "option_concat", "Horos concat: unknown option capcity" },
    .{ "option_convert", "Horos convertInteger: unknown option overflw" },
    .{ "option_blob", "Horos blobSlice: unknown option capcity" },
    .{ "option_arithmetic", "Horos checked: unknown option division_by_zerro" },
    .{ "option_choice_all", "Horos Choice.all: unknown option capture" },
    .{ "option_choice_first", "Horos Choice.first: unknown option capture" },
    .{ "option_search", "Horos Search.interpret: unknown option capture" },
    .{ "option_generator", "Horos Generator.create: unknown option capture" },
    .{ "option_nested_capture", "Horos capture bounds: unknown option bodi" },
    .{ "option_named_record", "Horos append: expected a named option record" },
    .{ "nested", "Horos call.input.count: incompatible schema shape" },
    .{ "missing", "Horos product.count: missing field" },
    .{ "extra", "Horos product.extra: extra field" },
    .{ "name", "Horos field.absent: unknown name" },
    .{ "category", "Horos authoring: wrong handle family; expected schema" },
    .{ "fake_schema", "Horos authoring: expected a canonical handle pointer" },
    .{ "fake_value", "Horos authoring: expected a canonical handle pointer" },
    .{ "branch", "Horos conditional result: incompatible schema shape" },
    .{ "text_bound", "Horos call.input: incompatible schema shape" },
    .{ "text_bytes", "Horos call.input: incompatible schema shape" },
    .{ "enum_tags", "Horos call.input: incompatible schema shape" },
    .{ "array_length", "Horos sequenceValue: wrong array length" },
    .{
        "pending_unknown",
        "Horos defineAlternatives.some: refine the unknown input before fulfilling a known " ++
            "declaration shape",
    },
    .{
        "declaration_erasure",
        "Horos authoring: cannot erase a declaration with a known completion shape",
    },
    .{
        "callable_declaration_erasure",
        "Horos authoring: cannot erase a declaration with a known completion shape",
    },
    .{
        "resumption_slot_pointer",
        "Horos handler resumption declaration.reply: incompatible schema shape",
    },
    .{ "recursive_mismatch", "Horos refineSchema.value: incompatible schema shape" },
    .{ "native_pointer", "Horos native schema: value: pointer must be an unsentinelled slice" },
    .{
        "native_recursive",
        "Horos native schema: value.children.element: recursive native type requires an " ++
            "explicit runtime declaration",
    },
    .{ "native_descriptor_recursive", "depends on itself here" },
    .{ "match_arm", "Horos match.no: case belongs to a different arm" },
    .{ "failure_category", "Horos authoring: wrong handle family; expected failure_literal" },
};
