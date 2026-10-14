//! Separate pure-data test entry point; never imported by the production module.
test {
    _ = @import("interactions_tests.zig");
    _ = @import("validator_coverage_tests.zig");
    _ = @import("native_decode_tests.zig");
    _ = @import("reference_roles_tests.zig");
    _ = @import("reference_roles.zig");
    _ = @import("opcode_contract_tests.zig");
    _ = @import("record_dispatch_tests.zig");
    _ = @import("opcode_contract.zig");
    _ = @import("native_shape_tests.zig");
    _ = @import("zig17_tests.zig");
    _ = @import("input_demand_tests.zig");
    _ = @import("call_patterns_tests.zig");
    _ = @import("call_pattern_capture_tests.zig");
    _ = @import("call_pattern_retention_tests.zig");
    _ = @import("call_pattern_variant_tests.zig");
    _ = @import("call_pattern_constant_tests.zig");
    _ = @import("call_pattern_word_tests.zig");
    _ = @import("leaf_inlining_tests.zig");
    _ = @import("contification_tests.zig");
    _ = @import("contification_recursive_tests.zig");
    _ = @import("contification_escape_tests.zig");
    _ = @import("common_tails_tests.zig");
    _ = @import("tail_duplication_tests.zig");
    _ = @import("outlining_tests.zig");
    _ = @import("slot_packing_tests.zig");
    _ = @import("partial_redundancy_tests.zig");
    _ = @import("affine_extract.zig");
    _ = @import("affine_capture_tests.zig");
    _ = @import("affine_parallel_tests.zig");
    _ = @import("capture_unpack_tests.zig");
    _ = @import("root.zig");
    _ = @import("tests.zig");
    _ = @import("compact_sequence_tests.zig");
    _ = @import("activation_structure_tests.zig");
    _ = @import("analysis_sets_tests.zig");
    _ = @import("activation_flow_tests.zig");
    _ = @import("activation_borrow_tests.zig");
    _ = @import("program_image_tests.zig");
    _ = @import("component_tests.zig");
    _ = @import("relocation_tests.zig");
    _ = @import("coalescing_graph_tests.zig");
    _ = @import("coalescing_witness_tests.zig");
    _ = @import("coalescing_view_tests.zig");
    _ = @import("coalescing_candidate_tests.zig");
    _ = @import("coalescing_tests.zig");
    _ = @import("application_specialization_tests.zig");
    _ = @import("aggregate_reduction_tests.zig");
    _ = @import("expression_reuse_tests.zig");
    _ = @import("cell_reduction_tests.zig");
    _ = @import("capture_reduction_tests.zig");
    _ = @import("capture_summary_tests.zig");
    _ = @import("capture_projection_tests.zig");
    _ = @import("closed_compilation_tests.zig");
    _ = @import("coalescing_recursive_tests.zig");
    _ = @import("coalescing_origins_tests.zig");
    _ = @import("coalescing_mutation_tests.zig");
    _ = @import("state_image_tests.zig");
    _ = @import("invocation_tests.zig");
}

test {
    _ = @import("evidence_forwarding_tests.zig");
}

test {
    _ = @import("handler_elimination_tests.zig");
}

test {
    _ = @import("reader_fusion_tests.zig");
}

test {
    _ = @import("sequence_fusion_tests.zig");
}

test {
    _ = @import("unfold_fusion_tests.zig");
}

test {
    _ = @import("thunk_forwarding_tests.zig");
}

test {
    _ = @import("context_compression_tests.zig");
}

test {
    _ = @import("constructor_contexts_tests.zig");
}

test {
    _ = @import("loop_motion_tests.zig");
}

test {
    _ = @import("loop_unswitch_tests.zig");
}

test {
    _ = @import("induction_facts_tests.zig");
    _ = @import("induction_reduction_tests.zig");
    _ = @import("affine_induction_tests.zig");
    _ = @import("rectangular_loops_tests.zig");
    _ = @import("rectangular_tiling_tests.zig");
    _ = @import("equality_saturation_tests.zig");
    _ = @import("recursive_specialization_tests.zig");
}
