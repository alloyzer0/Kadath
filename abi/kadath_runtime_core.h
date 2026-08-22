#ifndef KADATH_RUNTIME_CORE_H
#define KADATH_RUNTIME_CORE_H

#include <stddef.h>
#include <stdint.h>

#include "kadath_errors.h"

#ifdef __cplusplus
extern "C" {
#endif

#define KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1 1U

#define KADATH_RUNTIME_MAX_OBJECTS 128U
#define KADATH_RUNTIME_MAX_OBJECT_ID_BYTES 63U
#define KADATH_RUNTIME_ENTITY_INVALID UINT64_C(0)

#define KADATH_RUNTIME_TARGET_LIVE 1U
#define KADATH_RUNTIME_TARGET_CANDIDATE 2U

#define KADATH_RUNTIME_PREPARE_INITIAL 1U
#define KADATH_RUNTIME_PREPARE_RESTART 2U
#define KADATH_RUNTIME_PREPARE_SCENE_RELOAD 3U

#define KADATH_RUNTIME_OBJECT_KIND_SPRITE 1U
#define KADATH_RUNTIME_OBJECT_KIND_PLAYER 2U
#define KADATH_RUNTIME_OBJECT_KIND_GOAL 3U
#define KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD 4U

#define KADATH_RUNTIME_LIFECYCLE_PENDING_SPAWN 1U
#define KADATH_RUNTIME_LIFECYCLE_ACTIVE 2U

#define KADATH_RUNTIME_ORIGIN_SOURCE 1U
#define KADATH_RUNTIME_ORIGIN_TRANSIENT 2U

#define KADATH_RUNTIME_QUERY_STATE_INFO 1U
#define KADATH_RUNTIME_QUERY_FIND_BY_ID 2U
#define KADATH_RUNTIME_QUERY_RESOLVE_EXACT_REF 3U
#define KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS 4U
#define KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS 5U
#define KADATH_RUNTIME_QUERY_FIND_BY_ENTITY 6U

#define KADATH_RUNTIME_NOT_FOUND 0U
#define KADATH_RUNTIME_FOUND 1U

#define KADATH_RUNTIME_MUTATION_SET_BOUNDS 1U
#define KADATH_RUNTIME_MUTATION_STEP_FIXED 2U
#define KADATH_RUNTIME_MUTATION_APPLY_POSITIONS 3U
#define KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT 4U
#define KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT 5U
#define KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION 6U
#define KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY 7U
#define KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY 8U

#define KADATH_RUNTIME_PHASE_INTERFACE_V1 1U
#define KADATH_RUNTIME_PHASE_DOMAIN_FIXED 1U
#define KADATH_RUNTIME_PHASE_DOMAIN_FRAME 2U
#define KADATH_RUNTIME_PHASE_MAX_GENERATION 8U
#define KADATH_RUNTIME_PHASE_MAX_BINDINGS 256U
#define KADATH_RUNTIME_PHASE_MAX_BEHAVIORS_PER_BINDING 4U
#define KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN 64U
#define KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN 64U
#define KADATH_RUNTIME_PHASE_MAX_EVENT_NAME_BYTES 63U
#define KADATH_RUNTIME_PHASE_MAX_EVENT_FIELDS 8U
#define KADATH_RUNTIME_PHASE_MAX_EVENT_KEY_BYTES 31U
#define KADATH_RUNTIME_PHASE_MAX_EVENT_STRING_BYTES 127U

#define KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT 1U
#define KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY 2U
#define KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION 3U

#define KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED 1U
#define KADATH_RUNTIME_PHASE_COMPLETION_REJECTED 2U
#define KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED 3U

#define KADATH_RUNTIME_PHASE_EVENT_VALUE_BOOLEAN 1U
#define KADATH_RUNTIME_PHASE_EVENT_VALUE_NUMBER 2U
#define KADATH_RUNTIME_PHASE_EVENT_VALUE_STRING 3U
#define KADATH_RUNTIME_PHASE_EVENT_VALUE_OBJECT 4U

#define KADATH_RUNTIME_DESTROY_DISPOSITION_NONE 0U
#define KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN 1U
#define KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE 2U

typedef struct kadath_runtime_core_t kadath_runtime_core_t;
typedef struct kadath_runtime_phase_interface_v1_t kadath_runtime_phase_interface_v1_t;
typedef struct kadath_runtime_phase_activation_batch_v1_t kadath_runtime_phase_activation_batch_v1_t;

typedef struct kadath_runtime_object_ref_v1_t {
    uint32_t struct_size;
    uint32_t kind;
    uint64_t world_epoch;
    uint64_t logical_generation;
    uint32_t object_id_length;
    uint32_t reserved0;
    uint8_t object_id[64];
    uint64_t reserved[4];
} kadath_runtime_object_ref_v1_t;

typedef struct kadath_runtime_object_view_v1_t {
    uint32_t struct_size;
    uint32_t lifecycle;
    uint32_t origin;
    uint32_t origin_key;
    kadath_runtime_object_ref_v1_t object_ref;
    uint64_t entity_value;
    float position[2];
    float size[2];
    float color[4];
    uint32_t texture_id;
    uint32_t reserved0;
    uint64_t reserved[4];
} kadath_runtime_object_view_v1_t;

typedef struct kadath_runtime_object_buffer_t {
    /* Caller-owned output storage; callee writes views only during query and never retains it. */
    void* objects;
    size_t object_capacity;
    size_t object_stride;
} kadath_runtime_object_buffer_t;

typedef struct kadath_runtime_string_view_t {
    /* Caller-owned read-only bytes borrowed for this call; callee never retains the pointer. */
    const uint8_t* data;
    size_t length;
} kadath_runtime_string_view_t;

typedef struct kadath_runtime_state_info_v1_t {
    uint64_t world_epoch;
    size_t object_count;
    uint64_t reserved[4];
} kadath_runtime_state_info_v1_t;

typedef struct kadath_runtime_snapshot_result_v1_t {
    uint64_t world_epoch;
    size_t object_count;
    uint64_t reserved[4];
} kadath_runtime_snapshot_result_v1_t;

typedef union kadath_runtime_query_payload_v1_t {
    kadath_runtime_string_view_t object_id;
    kadath_runtime_object_ref_v1_t object_ref;
    uint64_t entity_value;
    kadath_runtime_object_buffer_t object_buffer;
} kadath_runtime_query_payload_v1_t;

typedef struct kadath_runtime_query_item_v1_t {
    uint32_t struct_size;
    uint32_t tag;
    kadath_runtime_query_payload_v1_t payload;
    uint64_t reserved[4];
} kadath_runtime_query_item_v1_t;

typedef struct kadath_runtime_query_batch_t {
    uint32_t struct_size;
    uint32_t target;
    /* Caller-owned input item array borrowed for this call; callee never retains it. */
    const kadath_runtime_query_item_v1_t* items;
    size_t item_count;
    size_t item_stride;
    uint64_t reserved[6];
} kadath_runtime_query_batch_t;

typedef union kadath_runtime_query_result_payload_v1_t {
    kadath_runtime_state_info_v1_t state_info;
    kadath_runtime_object_view_v1_t object;
    kadath_runtime_snapshot_result_v1_t snapshot;
} kadath_runtime_query_result_payload_v1_t;

typedef struct kadath_runtime_query_result_t {
    uint32_t struct_size;
    uint32_t tag;
    uint32_t found;
    uint32_t reserved0;
    kadath_runtime_query_result_payload_v1_t payload;
    uint64_t reserved[4];
} kadath_runtime_query_result_t;

typedef struct kadath_runtime_sprite_desc_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    float position[2];
    float size[2];
    float color[4];
    uint32_t texture_id;
    float move_speed;
    uint32_t reserved[6];
} kadath_runtime_sprite_desc_v1_t;

typedef struct kadath_runtime_bounds_desc_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    float min[2];
    float max[2];
    uint64_t reserved[4];
} kadath_runtime_bounds_desc_v1_t;

typedef struct kadath_runtime_fixed_step_desc_v1_t {
    uint32_t struct_size;
    float dt_seconds;
    int8_t move_x;
    int8_t move_y;
    uint8_t reserved_input[2];
    uint32_t reserved0;
    uint64_t reserved[4];
} kadath_runtime_fixed_step_desc_v1_t;

typedef struct kadath_runtime_position_patch_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    kadath_runtime_object_ref_v1_t object_ref;
    float position[2];
    uint64_t reserved[4];
} kadath_runtime_position_patch_v1_t;

typedef struct kadath_runtime_position_batch_v1_t {
    /* Caller-owned read-only patch array borrowed for this call; callee never retains it. */
    const kadath_runtime_position_patch_v1_t* patches;
    size_t patch_count;
    size_t patch_stride;
} kadath_runtime_position_batch_v1_t;

typedef struct kadath_runtime_transient_desc_v1_t {
    uint32_t struct_size;
    uint32_t prototype_key;
    uint32_t kind;
    uint32_t reserved0;
    kadath_runtime_sprite_desc_v1_t sprite;
    uint64_t reserved[4];
} kadath_runtime_transient_desc_v1_t;

typedef union kadath_runtime_mutation_payload_v1_t {
    kadath_runtime_bounds_desc_v1_t bounds;
    kadath_runtime_fixed_step_desc_v1_t fixed_step;
    kadath_runtime_position_batch_v1_t positions;
    kadath_runtime_transient_desc_v1_t transient;
    kadath_runtime_object_ref_v1_t object_ref;
} kadath_runtime_mutation_payload_v1_t;

typedef struct kadath_runtime_mutation_item_v1_t {
    uint32_t struct_size;
    uint32_t tag;
    kadath_runtime_mutation_payload_v1_t payload;
    uint64_t reserved[4];
} kadath_runtime_mutation_item_v1_t;

typedef struct kadath_runtime_mutation_batch_t {
    uint32_t struct_size;
    uint32_t target;
    /* Caller-owned input item array borrowed for this call; callee never retains it. */
    const kadath_runtime_mutation_item_v1_t* items;
    size_t item_count;
    size_t item_stride;
    uint64_t reserved[6];
} kadath_runtime_mutation_batch_t;

typedef struct kadath_runtime_mutation_result_t {
    uint32_t struct_size;
    uint32_t tag;
    uint32_t destroy_disposition;
    uint32_t reserved0;
    kadath_runtime_object_view_v1_t object;
    uint64_t reserved[4];
} kadath_runtime_mutation_result_t;

typedef struct kadath_runtime_source_object_desc_v1_t {
    uint32_t struct_size;
    uint32_t kind;
    uint32_t object_id_length;
    uint32_t reserved0;
    uint8_t object_id[64];
    kadath_runtime_sprite_desc_v1_t sprite;
    uint64_t reserved[4];
} kadath_runtime_source_object_desc_v1_t;

typedef struct kadath_runtime_scene_prepare_desc_t {
    uint32_t struct_size;
    uint32_t mode;
    float bounds_min[2];
    float bounds_max[2];
    /* Caller-owned source descriptor array borrowed for prepare; success copies it, never retains it. */
    const kadath_runtime_source_object_desc_v1_t* source_objects;
    size_t source_object_count;
    size_t source_object_stride;
    uint64_t reserved[6];
} kadath_runtime_scene_prepare_desc_t;

typedef struct kadath_runtime_scene_candidate_info_t {
    uint32_t struct_size;
    uint32_t mode;
    uint64_t world_epoch;
    size_t source_object_count;
    uint64_t reserved[6];
} kadath_runtime_scene_candidate_info_t;

typedef struct kadath_runtime_core_create_desc_t {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t reserved[4];
} kadath_runtime_core_create_desc_t;

typedef struct kadath_runtime_object_authority_interface_t {
    uint32_t struct_size;
    uint32_t interface_version;

    // Mode A create desc + Mode D Rust-owned Core + ADR-0003 section 3.2 caller-owned out slot.
    // Desc and slot are borrowed only for this call; no pointer is retained.
    // Thread-safe for distinct new Core instances. Reentrant: no.
    // Success publishes one owned Core; failure leaves *out_core byte-for-byte unchanged.
    int32_t (*create)(
        const kadath_runtime_core_create_desc_t* desc,
        kadath_runtime_core_t** out_core);

    // Mode D Rust-owned Core + ADR-0003 section 3.2 caller-owned in/out slot.
    // The slot is borrowed only for this call; no caller allocator or pointer is retained.
    // Single-thread: owner thread. Reentrant: no.
    // Success consumes the Core and writes null; failure leaves the handle unchanged.
    int32_t (*destroy)(kadath_runtime_core_t** in_out_core);

    // Mode A source/bounds + Mode D Core + ADR-0003 section 3.2 caller-owned candidate info.
    // Inputs and output are borrowed only for this call; successful prepare copies all inputs.
    // Single-thread: owner thread. Reentrant: no.
    // Success publishes only a private candidate; failure leaves live/candidate/output unchanged.
    int32_t (*prepare_scene)(
        kadath_runtime_core_t* core,
        const kadath_runtime_scene_prepare_desc_t* desc,
        kadath_runtime_scene_candidate_info_t* out_info);

    // Mode D Rust-owned Core; no caller-owned output and no borrowed pointer beyond this call.
    // Single-thread: owner thread. Reentrant: no.
    // A legal candidate is published by a no-fail swap; invalid state changes nothing.
    int32_t (*commit_scene)(kadath_runtime_core_t* core);

    // Mode D Rust-owned Core; no caller-owned output and no borrowed pointer beyond this call.
    // Single-thread: owner thread. Reentrant: no.
    // Discards the private candidate; no candidate is an idempotent success.
    int32_t (*abort_scene)(kadath_runtime_core_t* core);

    // Mode A batch/items/buffer descriptors + Mode D Core + ADR-0003 section 3.2 caller-owned outputs.
    // All input, result, and pointed-to object-buffer storage is borrowed only for this call.
    // Single-thread: owner thread. Reentrant: no.
    // Success publishes every result/buffer; any error leaves all output storage unchanged.
    int32_t (*query)(
        kadath_runtime_core_t* core,
        const kadath_runtime_query_batch_t* batch,
        kadath_runtime_query_result_t* results,
        size_t result_capacity);

    // Mode A batch/items/patches + Mode D Core + ADR-0003 section 3.2 caller-owned results.
    // All pointers are borrowed only for this call and are never retained.
    // Single-thread: owner thread. Reentrant: no.
    // The whole batch is all-or-nothing; any error leaves state and all results unchanged.
    int32_t (*mutate)(
        kadath_runtime_core_t* core,
        const kadath_runtime_mutation_batch_t* batch,
        kadath_runtime_mutation_result_t* results,
        size_t result_capacity);

    uint64_t reserved[8];
} kadath_runtime_object_authority_interface_t;

// Mode A + ADR-0003 section 3.2 caller-owned in/out descriptor.
// Lifetime: borrowed for this call; the callee does not retain the pointer.
// Thread-safe. Reentrant: yes.
int32_t kadath_runtime_core_query_object_authority_interface(
    kadath_runtime_object_authority_interface_t* in_out_interface);

typedef struct kadath_runtime_phase_begin_desc_v1_t {
    uint32_t struct_size;
    uint32_t domain;
    uint64_t phase_sequence;
    uint32_t reserved0;
    uint32_t reserved1;
    uint64_t reserved[4];
} kadath_runtime_phase_begin_desc_v1_t;

typedef struct kadath_runtime_phase_binding_desc_v1_t {
    uint32_t struct_size;
    uint32_t behavior_count;
    uint32_t script_id;
    uint32_t reserved0;
    kadath_runtime_object_ref_v1_t object_ref;
    uint64_t reserved[4];
} kadath_runtime_phase_binding_desc_v1_t;

typedef struct kadath_runtime_phase_state_prepare_desc_v1_t {
    uint32_t struct_size;
    uint32_t target;
    /* Mode A: borrowed for this call; Core does not retain the pointer. */
    const kadath_runtime_phase_binding_desc_v1_t* bindings;
    size_t binding_count;
    size_t binding_stride;
    uint64_t reserved[6];
} kadath_runtime_phase_state_prepare_desc_v1_t;

typedef union kadath_runtime_phase_event_value_v1_t {
    int32_t boolean_value;
    double number_value;
    struct {
        uint32_t length;
        uint8_t bytes[128];
    } string_value;
    kadath_runtime_object_ref_v1_t object_value;
} kadath_runtime_phase_event_value_v1_t;

typedef struct kadath_runtime_phase_event_field_v1_t {
    uint32_t struct_size;
    uint32_t value_kind;
    uint32_t key_length;
    uint32_t reserved0;
    uint8_t key[32];
    kadath_runtime_phase_event_value_v1_t value;
    uint64_t reserved[2];
} kadath_runtime_phase_event_field_v1_t;

typedef struct kadath_runtime_phase_event_v1_t {
    uint32_t struct_size;
    uint32_t domain;
    uint64_t sequence;
    uint32_t generation;
    uint32_t field_count;
    uint32_t has_sender;
    uint32_t has_other;
    kadath_runtime_object_ref_v1_t target;
    kadath_runtime_object_ref_v1_t sender;
    kadath_runtime_object_ref_v1_t other;
    uint32_t name_length;
    uint8_t name[64];
    kadath_runtime_phase_event_field_v1_t fields[8];
    uint64_t reserved[4];
} kadath_runtime_phase_event_v1_t;

typedef struct kadath_runtime_phase_structural_v1_t {
    uint32_t struct_size;
    uint32_t operation;
    uint64_t sequence;
    uint32_t domain;
    uint32_t generation;
    uint32_t behavior_count;
    uint32_t prototype_key;
    uint32_t script_id;
    kadath_runtime_object_ref_v1_t object_ref;
    kadath_runtime_object_ref_v1_t origin;
    kadath_runtime_sprite_desc_v1_t transient_sprite;
    uint64_t reserved[4];
} kadath_runtime_phase_structural_v1_t;

typedef struct kadath_runtime_phase_flush_info_v1_t {
    uint32_t struct_size;
    uint32_t domain;
    uint64_t flush_token;
    uint64_t phase_sequence;
    size_t request_count;
    uint64_t reserved[4];
} kadath_runtime_phase_flush_info_v1_t;

typedef struct kadath_runtime_phase_request_completion_v1_t {
    uint32_t struct_size;
    uint32_t status;
    uint64_t sequence;
    uint32_t error_code;
    uint32_t destroy_disposition;
    kadath_runtime_object_view_v1_t object;
    uint64_t reserved[4];
} kadath_runtime_phase_request_completion_v1_t;

typedef struct kadath_runtime_phase_activation_structural_result_v1_t {
    uint32_t struct_size;
    uint32_t status;
    uint64_t sequence;
    uint32_t error_code;
    uint32_t destroy_disposition;
    kadath_runtime_object_ref_v1_t object_ref;
    uint64_t reserved[4];
} kadath_runtime_phase_activation_structural_result_v1_t;

typedef struct kadath_runtime_phase_activation_batch_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t transaction_id;
    size_t active_binding_capacity;
    /* Mode A: borrowed for submit_activation only; no pointer retention. */
    const kadath_runtime_position_patch_v1_t* positions;
    size_t position_count;
    size_t position_stride;
    /* Mode A: borrowed for submit_activation only; no pointer retention. */
    const kadath_runtime_phase_event_v1_t* events;
    size_t event_count;
    size_t event_stride;
    /* Mode A: borrowed for submit_activation only; no pointer retention. */
    const kadath_runtime_phase_structural_v1_t* structural;
    size_t structural_count;
    size_t structural_stride;
    /* Caller-owned output array borrowed for submit_activation only; Core writes exactly
     * structural_count entries after complete preflight and retains no pointer. */
    kadath_runtime_phase_activation_structural_result_v1_t* structural_results;
    size_t structural_result_capacity;
    uint64_t reserved[6];
} kadath_runtime_phase_activation_batch_v1_t;

typedef struct kadath_runtime_phase_state_candidate_info_v1_t {
    uint32_t struct_size;
    uint32_t target;
    uint32_t binding_count;
    uint32_t reserved0;
    uint64_t phase_epoch;
    uint64_t reserved[4];
} kadath_runtime_phase_state_candidate_info_v1_t;

typedef struct kadath_runtime_phase_begin_result_v1_t {
    uint32_t struct_size;
    uint32_t domain;
    uint64_t phase_sequence;
    uint64_t reserved[4];
} kadath_runtime_phase_begin_result_v1_t;

typedef struct kadath_runtime_phase_batch_result_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    size_t accepted_count;
    uint64_t first_sequence;
    uint64_t last_sequence;
    uint64_t reserved[4];
} kadath_runtime_phase_batch_result_v1_t;

typedef struct kadath_runtime_phase_transaction_info_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t transaction_id;
    uint64_t root_sequence;
    uint64_t reserved[4];
} kadath_runtime_phase_transaction_info_v1_t;

typedef struct kadath_runtime_phase_activation_result_v1_t {
    uint32_t struct_size;
    uint32_t reserved0;
    uint32_t accepted_event_count;
    uint32_t accepted_structural_count;
    uint32_t cancelled_structural_count;
    uint32_t active_binding_count;
    kadath_runtime_object_view_v1_t root_object;
    uint64_t reserved[4];
} kadath_runtime_phase_activation_result_v1_t;

struct kadath_runtime_phase_interface_v1_t {
    uint32_t struct_size;
    uint32_t interface_version;
    /* Every pointer/count/stride argument below is caller-owned and borrowed only for the call.
     * The Core retains POD values and opaque numeric tokens, never a caller pointer. All entry
     * points are owner-thread-only and non-reentrant; output slots are caller-owned and are
     * published only after complete preflight succeeds. */
    int32_t (*prepare_phase_state)(
        kadath_runtime_core_t* core,
        const kadath_runtime_phase_state_prepare_desc_v1_t* desc,
        kadath_runtime_phase_state_candidate_info_v1_t* out_info);
    int32_t (*commit_phase_state)(kadath_runtime_core_t* core);
    int32_t (*abort_phase_state)(kadath_runtime_core_t* core);
    int32_t (*begin_phase)(
        kadath_runtime_core_t* core,
        const kadath_runtime_phase_begin_desc_v1_t* desc,
        kadath_runtime_phase_begin_result_v1_t* out_result);
    int32_t (*submit_events)(
        kadath_runtime_core_t* core,
        const kadath_runtime_phase_event_v1_t* events,
        size_t item_count,
        size_t item_stride,
        kadath_runtime_phase_batch_result_v1_t* out_result);
    int32_t (*drain_events)(
        kadath_runtime_core_t* core,
        uint32_t domain,
        uint64_t phase_sequence,
        kadath_runtime_phase_event_v1_t* output_events,
        size_t output_capacity,
        size_t* out_count);
    int32_t (*submit_structural)(
        kadath_runtime_core_t* core,
        const kadath_runtime_phase_structural_v1_t* items,
        size_t item_count,
        size_t item_stride,
        kadath_runtime_phase_request_completion_v1_t* acceptance_results,
        size_t acceptance_capacity,
        kadath_runtime_phase_batch_result_v1_t* out_result);
    int32_t (*take_structural)(
        kadath_runtime_core_t* core,
        uint32_t domain,
        uint64_t phase_sequence,
        kadath_runtime_phase_flush_info_v1_t* out_flush_info,
        kadath_runtime_phase_structural_v1_t* output_structural,
        size_t output_capacity,
        size_t* out_count);
    int32_t (*begin_activation)(
        kadath_runtime_core_t* core,
        uint64_t flush_token,
        uint64_t root_sequence,
        kadath_runtime_phase_transaction_info_v1_t* out_info);
    int32_t (*submit_activation)(
        kadath_runtime_core_t* core,
        uint64_t transaction_id,
        const kadath_runtime_phase_activation_batch_v1_t* batch);
    int32_t (*commit_activation)(
        kadath_runtime_core_t* core,
        uint64_t transaction_id,
        kadath_runtime_phase_activation_result_v1_t* out_result);
    int32_t (*abort_activation)(kadath_runtime_core_t* core, uint64_t transaction_id);
    int32_t (*complete_structural)(
        kadath_runtime_core_t* core,
        uint64_t flush_token,
        const kadath_runtime_phase_request_completion_v1_t* completions,
        size_t completion_count,
        size_t reserved_size);
    int32_t (*abort_structural)(kadath_runtime_core_t* core, uint64_t flush_token);
    int32_t (*end_phase)(kadath_runtime_core_t* core, uint32_t domain, uint64_t phase_sequence);
    uint64_t reserved[8];
};

// Mode A + ADR-0003 section 3.2 caller-owned in/out descriptor.
// The descriptor is borrowed for this call; the Core retains no function-table pointer.
// Thread-safe and reentrant, like the Object Authority query.
int32_t kadath_runtime_core_query_phase_interface(
    kadath_runtime_phase_interface_v1_t* in_out_interface);

#ifdef __cplusplus
}
#endif

#endif
