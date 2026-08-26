#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <threads.h>
#endif

#include "kadath_runtime_core.h"
#include "test_hooks.h"

_Static_assert(KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1 == 1U, "interface version");
_Static_assert(KADATH_RUNTIME_PHASE_INTERFACE_V1 == 1U, "phase interface version");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1 == 1U, "gameplay interface version");
_Static_assert(KADATH_RUNTIME_PHASE_MAX_GENERATION == 8U, "phase generation limit");
_Static_assert(KADATH_RUNTIME_PHASE_MAX_BINDINGS == 256U, "phase admission limit");
_Static_assert(KADATH_RUNTIME_PHASE_MAX_BEHAVIORS_PER_BINDING == 4U, "phase per-binding behavior limit");
_Static_assert(KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN == 64U, "phase event limit");
_Static_assert(KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN == 64U, "phase structural limit");
_Static_assert(KADATH_RUNTIME_MAX_OBJECTS == 128U, "object limit");
_Static_assert(KADATH_RUNTIME_TARGET_LIVE == 1U, "live target");
_Static_assert(KADATH_RUNTIME_TARGET_CANDIDATE == 2U, "candidate target");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING == 1U, "gameplay playing phase");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_PHASE_WON == 2U, "gameplay won phase");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_PHASE_LOST == 3U, "gameplay lost phase");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_CAUSE_NONE == 0U, "gameplay none cause");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_CAUSE_TIMER == 1U, "gameplay timer cause");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_CAUSE_HAZARD == 2U, "gameplay hazard cause");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_CAUSE_GOAL == 3U, "gameplay goal cause");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE == 0U, "gameplay static hazard movement");
_Static_assert(KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL == 1U, "gameplay legacy hazard movement");
_Static_assert(KADATH_RUNTIME_QUERY_FIND_BY_ENTITY == 6U, "query tags");
_Static_assert(KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY == 8U, "mutation tags");
_Static_assert(KADATH_ERR_RUNTIME_WRONG_THREAD == 0x4101, "runtime error start");
_Static_assert(KADATH_ERR_RUNTIME_DUPLICATE_OBJECT_ID == 0x410B, "runtime error end");
_Static_assert(KADATH_ERR_RUNTIME_PHASE_BUSY == 0x4110, "phase error start");
_Static_assert(KADATH_ERR_RUNTIME_PHASE_NOT_DRAINED == 0x411B, "phase error end");
_Static_assert(KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE == 0x4120, "gameplay error start");
_Static_assert(KADATH_ERR_RUNTIME_GAMEPLAY_SEQUENCE_EXHAUSTED == 0x4123, "gameplay error end");

_Static_assert(sizeof(kadath_runtime_object_ref_v1_t) == 128U, "ObjectRef ABI");
_Static_assert(offsetof(kadath_runtime_object_ref_v1_t, object_id) == 32U, "ObjectRef ID offset");
_Static_assert(sizeof(kadath_runtime_object_view_v1_t) == 224U, "ObjectView ABI");
_Static_assert(offsetof(kadath_runtime_object_view_v1_t, entity_value) == 144U, "Entity offset");
_Static_assert(sizeof(kadath_runtime_query_item_v1_t) == 168U, "query item ABI");
_Static_assert(sizeof(kadath_runtime_query_batch_t) == 80U, "query batch ABI");
_Static_assert(sizeof(kadath_runtime_query_result_t) == 272U, "query result ABI");
_Static_assert(sizeof(kadath_runtime_sprite_desc_v1_t) == 72U, "sprite descriptor ABI");
_Static_assert(sizeof(kadath_runtime_mutation_item_v1_t) == 168U, "mutation item ABI");
_Static_assert(sizeof(kadath_runtime_mutation_batch_t) == 80U, "mutation batch ABI");
_Static_assert(sizeof(kadath_runtime_mutation_result_t) == 272U, "mutation result ABI");
_Static_assert(sizeof(kadath_runtime_source_object_desc_v1_t) == 184U, "source descriptor ABI");
_Static_assert(sizeof(kadath_runtime_scene_prepare_desc_t) == 96U, "prepare descriptor ABI");
_Static_assert(sizeof(kadath_runtime_object_authority_interface_t) == 128U, "function table ABI");
_Static_assert(sizeof(kadath_runtime_phase_begin_desc_v1_t) == 56U, "phase begin ABI");
_Static_assert(sizeof(kadath_runtime_phase_binding_desc_v1_t) == 176U, "phase binding ABI");
_Static_assert(sizeof(kadath_runtime_phase_state_prepare_desc_v1_t) == 80U, "phase prepare ABI");
_Static_assert(sizeof(kadath_runtime_phase_event_field_v1_t) == 200U, "phase event field ABI");
_Static_assert(sizeof(kadath_runtime_phase_structural_v1_t) == 400U, "phase structural ABI");
_Static_assert(sizeof(kadath_runtime_phase_flush_info_v1_t) == 64U, "phase flush ABI");
_Static_assert(sizeof(kadath_runtime_phase_request_completion_v1_t) == 280U, "phase completion ABI");
_Static_assert(sizeof(kadath_runtime_phase_activation_structural_result_v1_t) == 184U, "phase activation structural result ABI");
_Static_assert(offsetof(kadath_runtime_phase_activation_structural_result_v1_t, object_ref) == 24U, "phase activation result object ref offset");
_Static_assert(sizeof(kadath_runtime_phase_state_candidate_info_v1_t) == 56U, "phase candidate info ABI");
_Static_assert(sizeof(kadath_runtime_phase_begin_result_v1_t) == 48U, "phase begin result ABI");
_Static_assert(sizeof(kadath_runtime_phase_batch_result_v1_t) == 64U, "phase batch result ABI");
_Static_assert(sizeof(kadath_runtime_phase_transaction_info_v1_t) == 56U, "phase transaction ABI");
_Static_assert(sizeof(kadath_runtime_phase_activation_result_v1_t) == 280U, "phase activation result ABI");
_Static_assert(sizeof(kadath_runtime_phase_activation_batch_v1_t) == 160U, "phase activation batch ABI");
_Static_assert(offsetof(kadath_runtime_phase_activation_batch_v1_t, structural_results) == 96U, "phase activation result array offset");
_Static_assert(sizeof(kadath_runtime_phase_interface_v1_t) == 192U, "phase interface ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_hazard_desc_v1_t) == 184U, "gameplay hazard ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_desc_v1_t) == 336U, "gameplay descriptor ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_candidate_info_v1_t) == 48U, "gameplay candidate ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_begin_fixed_desc_v1_t) == 48U, "gameplay begin ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_commit_fixed_desc_v1_t) == 56U, "gameplay commit ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_outcome_buffer_v1_t) == 64U, "gameplay outcome buffer ABI");
_Static_assert(sizeof(kadath_runtime_render_buffer_v1_t) == 64U, "gameplay render buffer ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_snapshot_v1_t) == 80U, "gameplay snapshot ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_step_result_v1_t) == 80U, "gameplay step ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_outcome_v1_t) == 312U, "gameplay outcome ABI");
_Static_assert(sizeof(kadath_runtime_render_item_v1_t) == 216U, "gameplay render item ABI");
_Static_assert(sizeof(kadath_runtime_gameplay_interface_v1_t) == 112U, "gameplay interface ABI");
_Static_assert(offsetof(kadath_runtime_gameplay_outcome_v1_t, player) > offsetof(kadath_runtime_gameplay_outcome_v1_t, sequence), "gameplay outcome order");
_Static_assert(offsetof(kadath_runtime_render_item_v1_t, final_color) > offsetof(kadath_runtime_render_item_v1_t, position), "gameplay render order");
_Static_assert(offsetof(kadath_runtime_phase_begin_desc_v1_t, phase_sequence) == 8U, "phase sequence offset");
_Static_assert(offsetof(kadath_runtime_phase_event_v1_t, fields) > offsetof(kadath_runtime_phase_event_v1_t, name), "phase fields order");
_Static_assert(offsetof(kadath_runtime_phase_structural_v1_t, object_ref) == 40U, "phase object ref offset");

static kadath_runtime_object_authority_interface_t query_interface(void) {
    kadath_runtime_object_authority_interface_t interface_value;
    memset(&interface_value, 0, sizeof(interface_value));
    interface_value.struct_size = (uint32_t)sizeof(interface_value);
    interface_value.interface_version = KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1;

    if (kadath_runtime_core_query_object_authority_interface(&interface_value) != KADATH_OK) {
        memset(&interface_value, 0, sizeof(interface_value));
        return interface_value;
    }
    return interface_value;
}

static kadath_runtime_phase_interface_v1_t query_phase_interface(void) {
    kadath_runtime_phase_interface_v1_t interface_value;
    memset(&interface_value, 0, sizeof(interface_value));
    interface_value.struct_size = (uint32_t)sizeof(interface_value);
    interface_value.interface_version = KADATH_RUNTIME_PHASE_INTERFACE_V1;
    if (kadath_runtime_core_query_phase_interface(&interface_value) != KADATH_OK) {
        memset(&interface_value, 0, sizeof(interface_value));
    }
    return interface_value;
}

static kadath_runtime_gameplay_interface_v1_t query_gameplay_interface(void) {
    kadath_runtime_gameplay_interface_v1_t interface_value;
    memset(&interface_value, 0, sizeof(interface_value));
    interface_value.struct_size = (uint32_t)sizeof(interface_value);
    interface_value.interface_version = KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1;
    if (kadath_runtime_core_query_gameplay_interface(&interface_value) != KADATH_OK) {
        memset(&interface_value, 0, sizeof(interface_value));
    }
    return interface_value;
}

static void fill_source(
    kadath_runtime_source_object_desc_v1_t* source,
    const char* object_id,
    uint32_t kind,
    float x,
    float move_speed) {
    size_t object_id_length = strlen(object_id);
    memset(source, 0, sizeof(*source));
    source->struct_size = (uint32_t)sizeof(*source);
    source->kind = kind;
    source->object_id_length = (uint32_t)object_id_length;
    memcpy(source->object_id, object_id, object_id_length);
    source->sprite.struct_size = (uint32_t)sizeof(source->sprite);
    source->sprite.position[0] = x;
    source->sprite.position[1] = 20.0F;
    source->sprite.size[0] = 8.0F;
    source->sprite.size[1] = 8.0F;
    source->sprite.color[0] = 1.0F;
    source->sprite.color[1] = 1.0F;
    source->sprite.color[2] = 1.0F;
    source->sprite.color[3] = 1.0F;
    source->sprite.texture_id = 1U;
    source->sprite.move_speed = move_speed;
}

static void fill_canonical_sources(kadath_runtime_source_object_desc_v1_t sources[3]) {
    fill_source(&sources[0], "player", KADATH_RUNTIME_OBJECT_KIND_PLAYER, 10.0F, 20.0F);
    fill_source(&sources[1], "hazard", KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD, 60.0F, 0.0F);
    fill_source(&sources[2], "goal", KADATH_RUNTIME_OBJECT_KIND_GOAL, 80.0F, 0.0F);
}

static int prepare_gameplay_candidate(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_core_t* core);
static int prepare_empty_phase_candidate(kadath_runtime_core_t* core);
static int make_gameplay_terminal(kadath_runtime_core_t* core);

static int normal_path(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_create_desc_t create_desc;
    kadath_runtime_core_t* core = NULL;
    memset(&create_desc, 0, sizeof(create_desc));
    create_desc.struct_size = (uint32_t)sizeof(create_desc);
    if (interface_value->create(&create_desc, &core) != KADATH_OK || core == NULL) {
        return 10;
    }

    kadath_runtime_source_object_desc_v1_t sources[3];
    fill_canonical_sources(sources);

    kadath_runtime_scene_prepare_desc_t prepare_desc;
    kadath_runtime_scene_candidate_info_t candidate_info;
    memset(&prepare_desc, 0, sizeof(prepare_desc));
    memset(&candidate_info, 0, sizeof(candidate_info));
    prepare_desc.struct_size = (uint32_t)sizeof(prepare_desc);
    prepare_desc.mode = KADATH_RUNTIME_PREPARE_INITIAL;
    prepare_desc.bounds_max[0] = 100.0F;
    prepare_desc.bounds_max[1] = 100.0F;
    prepare_desc.source_objects = sources;
    prepare_desc.source_object_count = 3U;
    prepare_desc.source_object_stride = sizeof(sources[0]);
    candidate_info.struct_size = (uint32_t)sizeof(candidate_info);
    if (interface_value->prepare_scene(core, &prepare_desc, &candidate_info) != KADATH_OK ||
        candidate_info.world_epoch != 1U || candidate_info.source_object_count != 3U) {
        return 11;
    }

    kadath_runtime_query_item_v1_t item;
    kadath_runtime_query_batch_t batch;
    kadath_runtime_query_result_t result;
    memset(&item, 0, sizeof(item));
    memset(&batch, 0, sizeof(batch));
    memset(&result, 0, sizeof(result));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_QUERY_STATE_INFO;
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_CANDIDATE;
    batch.items = &item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(item);
    result.struct_size = (uint32_t)sizeof(result);
    if (interface_value->query(core, &batch, &result, 1U) != KADATH_OK ||
        result.found != KADATH_RUNTIME_FOUND || result.payload.state_info.world_epoch != 1U ||
        result.payload.state_info.object_count != 3U) {
        return 12;
    }

    if (prepare_gameplay_candidate(interface_value, core) != 0 ||
        prepare_empty_phase_candidate(core) != 0 ||
        interface_value->commit_scene(core) != KADATH_OK) {
        return 13;
    }

    kadath_runtime_object_view_v1_t objects[3];
    memset(objects, 0xA5, sizeof(objects));
    memset(&item, 0, sizeof(item));
    memset(&batch, 0, sizeof(batch));
    memset(&result, 0, sizeof(result));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS;
    item.payload.object_buffer.objects = objects;
    item.payload.object_buffer.object_capacity = 3U;
    item.payload.object_buffer.object_stride = sizeof(objects[0]);
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = &item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(item);
    result.struct_size = (uint32_t)sizeof(result);
    if (interface_value->query(core, &batch, &result, 1U) != KADATH_OK ||
        result.payload.snapshot.object_count != 3U ||
        objects[0].object_ref.object_id_length != 6U ||
        memcmp(objects[0].object_ref.object_id, "player", 6U) != 0 ||
        objects[1].object_ref.object_id_length != 6U ||
        memcmp(objects[1].object_ref.object_id, "hazard", 6U) != 0 ||
        objects[2].object_ref.object_id_length != 4U ||
        memcmp(objects[2].object_ref.object_id, "goal", 4U) != 0) {
        return 14;
    }

    if (interface_value->destroy(&core) != KADATH_OK || core != NULL) {
        return 15;
    }
    return 0;
}

static int create_live_core(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t** out_core) {
    kadath_runtime_core_create_desc_t create_desc;
    kadath_runtime_source_object_desc_v1_t sources[3];
    kadath_runtime_scene_prepare_desc_t prepare_desc;
    kadath_runtime_scene_candidate_info_t candidate_info;

    memset(&create_desc, 0, sizeof(create_desc));
    create_desc.struct_size = (uint32_t)sizeof(create_desc);
    if (interface_value->create(&create_desc, out_core) != KADATH_OK || *out_core == NULL) {
        return 20;
    }
    fill_canonical_sources(sources);
    memset(&prepare_desc, 0, sizeof(prepare_desc));
    memset(&candidate_info, 0, sizeof(candidate_info));
    prepare_desc.struct_size = (uint32_t)sizeof(prepare_desc);
    prepare_desc.mode = KADATH_RUNTIME_PREPARE_INITIAL;
    prepare_desc.bounds_max[0] = 100.0F;
    prepare_desc.bounds_max[1] = 100.0F;
    prepare_desc.source_objects = sources;
    prepare_desc.source_object_count = 3U;
    prepare_desc.source_object_stride = sizeof(sources[0]);
    candidate_info.struct_size = (uint32_t)sizeof(candidate_info);
    if (interface_value->prepare_scene(*out_core, &prepare_desc, &candidate_info) != KADATH_OK ||
        prepare_gameplay_candidate(interface_value, *out_core) != 0 ||
        prepare_empty_phase_candidate(*out_core) != 0 ||
        interface_value->commit_scene(*out_core) != KADATH_OK) {
        return 21;
    }
    return 0;
}

static int mutate_one(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    kadath_runtime_mutation_item_v1_t* item,
    kadath_runtime_mutation_result_t* result) {
    kadath_runtime_mutation_batch_t batch;
    memset(&batch, 0, sizeof(batch));
    memset(result, 0, sizeof(*result));
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(*item);
    result->struct_size = (uint32_t)sizeof(*result);
    return interface_value->mutate(core, &batch, result, 1U);
}

static int mutate_many(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    kadath_runtime_mutation_item_v1_t* items,
    size_t item_count,
    kadath_runtime_mutation_result_t* results) {
    kadath_runtime_mutation_batch_t batch;
    memset(&batch, 0, sizeof(batch));
    memset(results, 0, item_count * sizeof(*results));
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = items;
    batch.item_count = item_count;
    batch.item_stride = sizeof(*items);
    for (size_t index = 0; index < item_count; ++index) {
        results[index].struct_size = (uint32_t)sizeof(results[index]);
    }
    return interface_value->mutate(core, &batch, results, item_count);
}

static int query_exact(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    const kadath_runtime_object_ref_v1_t* object_ref,
    kadath_runtime_query_result_t* result) {
    kadath_runtime_query_item_v1_t item;
    kadath_runtime_query_batch_t batch;
    memset(&item, 0, sizeof(item));
    memset(&batch, 0, sizeof(batch));
    memset(result, 0, sizeof(*result));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_QUERY_RESOLVE_EXACT_REF;
    item.payload.object_ref = *object_ref;
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = &item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(item);
    result->struct_size = (uint32_t)sizeof(*result);
    return interface_value->query(core, &batch, result, 1U);
}

static int query_id(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    const char* object_id,
    kadath_runtime_query_result_t* result) {
    kadath_runtime_query_item_v1_t item;
    kadath_runtime_query_batch_t batch;
    memset(&item, 0, sizeof(item));
    memset(&batch, 0, sizeof(batch));
    memset(result, 0, sizeof(*result));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    item.payload.object_id.data = (const uint8_t*)object_id;
    item.payload.object_id.length = strlen(object_id);
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = &item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(item);
    result->struct_size = (uint32_t)sizeof(*result);
    return interface_value->query(core, &batch, result, 1U);
}

static int query_candidate_id(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    const char* object_id,
    kadath_runtime_query_result_t* result) {
    kadath_runtime_query_item_v1_t item;
    kadath_runtime_query_batch_t batch;
    memset(&item, 0, sizeof(item));
    memset(&batch, 0, sizeof(batch));
    memset(result, 0, sizeof(*result));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    item.payload.object_id.data = (const uint8_t*)object_id;
    item.payload.object_id.length = strlen(object_id);
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_CANDIDATE;
    batch.items = &item;
    batch.item_count = 1U;
    batch.item_stride = sizeof(item);
    result->struct_size = (uint32_t)sizeof(*result);
    return interface_value->query(core, &batch, result, 1U);
}

static int prepare_gameplay_candidate(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_core_t* core) {
    kadath_runtime_query_result_t player;
    kadath_runtime_query_result_t hazard;
    kadath_runtime_query_result_t goal;
    if (query_candidate_id(object_interface, core, "player", &player) != KADATH_OK ||
        query_candidate_id(object_interface, core, "hazard", &hazard) != KADATH_OK ||
        query_candidate_id(object_interface, core, "goal", &goal) != KADATH_OK ||
        player.found != KADATH_RUNTIME_FOUND || hazard.found != KADATH_RUNTIME_FOUND ||
        goal.found != KADATH_RUNTIME_FOUND) {
        return 1;
    }

    kadath_runtime_gameplay_hazard_desc_v1_t hazard_desc;
    kadath_runtime_gameplay_desc_v1_t gameplay_desc;
    kadath_runtime_gameplay_candidate_info_v1_t gameplay_info;
    memset(&hazard_desc, 0, sizeof(hazard_desc));
    memset(&gameplay_desc, 0, sizeof(gameplay_desc));
    memset(&gameplay_info, 0, sizeof(gameplay_info));
    hazard_desc.struct_size = (uint32_t)sizeof(hazard_desc);
    hazard_desc.movement_mode = KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE;
    hazard_desc.object_ref = hazard.payload.object.object_ref;
    gameplay_desc.struct_size = (uint32_t)sizeof(gameplay_desc);
    gameplay_desc.time_limit_seconds = 3.0F;
    gameplay_desc.hazard_count = 1U;
    gameplay_desc.player = player.payload.object.object_ref;
    gameplay_desc.goal = goal.payload.object.object_ref;
    gameplay_desc.hazards = &hazard_desc;
    gameplay_desc.hazard_stride = sizeof(hazard_desc);
    gameplay_info.struct_size = (uint32_t)sizeof(gameplay_info);
    kadath_runtime_gameplay_interface_v1_t gameplay_interface = query_gameplay_interface();
    return gameplay_interface.prepare_gameplay_state != NULL &&
                   gameplay_interface.prepare_gameplay_state(core, &gameplay_desc, &gameplay_info) == KADATH_OK
               ? 0
               : 2;
}

static int prepare_empty_phase_candidate(kadath_runtime_core_t* core) {
    kadath_runtime_phase_interface_v1_t phase_interface = query_phase_interface();
    kadath_runtime_phase_state_prepare_desc_v1_t desc;
    kadath_runtime_phase_state_candidate_info_v1_t info;
    memset(&desc, 0, sizeof(desc));
    memset(&info, 0, sizeof(info));
    desc.struct_size = (uint32_t)sizeof(desc);
    desc.target = KADATH_RUNTIME_TARGET_CANDIDATE;
    desc.binding_stride = sizeof(kadath_runtime_phase_binding_desc_v1_t);
    info.struct_size = (uint32_t)sizeof(info);
    return phase_interface.prepare_phase_state != NULL &&
                   phase_interface.prepare_phase_state(core, &desc, &info) == KADATH_OK &&
                   phase_interface.commit_phase_state(core) == KADATH_OK
               ? 0
               : 3;
}

static int make_gameplay_terminal(kadath_runtime_core_t* core) {
    kadath_runtime_gameplay_interface_v1_t gameplay_interface = query_gameplay_interface();
    kadath_runtime_gameplay_begin_fixed_desc_v1_t desc;
    kadath_runtime_gameplay_outcome_v1_t outcome;
    kadath_runtime_gameplay_outcome_buffer_v1_t buffer;
    kadath_runtime_gameplay_step_result_v1_t result;
    memset(&desc, 0, sizeof(desc));
    memset(&outcome, 0, sizeof(outcome));
    memset(&buffer, 0, sizeof(buffer));
    memset(&result, 0, sizeof(result));
    desc.struct_size = (uint32_t)sizeof(desc);
    desc.dt_seconds = 3.0F;
    outcome.struct_size = (uint32_t)sizeof(outcome);
    buffer.struct_size = (uint32_t)sizeof(buffer);
    buffer.outcomes = &outcome;
    buffer.outcome_capacity = 1U;
    buffer.outcome_stride = sizeof(outcome);
    result.struct_size = (uint32_t)sizeof(result);
    if (gameplay_interface.begin_fixed_step == NULL ||
        gameplay_interface.begin_fixed_step(core, &desc, &buffer, &result) != KADATH_OK ||
        result.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_LOST ||
        gameplay_interface.abort_fixed_step(core, result.step_token) != KADATH_OK) {
        return 4;
    }
    return 0;
}

static int prepare_candidate_again(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    uint32_t mode) {
    kadath_runtime_source_object_desc_v1_t sources[3];
    kadath_runtime_scene_prepare_desc_t prepare_desc;
    kadath_runtime_scene_candidate_info_t candidate_info;
    fill_canonical_sources(sources);
    memset(&prepare_desc, 0, sizeof(prepare_desc));
    memset(&candidate_info, 0, sizeof(candidate_info));
    prepare_desc.struct_size = (uint32_t)sizeof(prepare_desc);
    prepare_desc.mode = mode;
    prepare_desc.bounds_max[0] = 100.0F;
    prepare_desc.bounds_max[1] = 100.0F;
    prepare_desc.source_objects = sources;
    prepare_desc.source_object_count = 3U;
    prepare_desc.source_object_stride = sizeof(sources[0]);
    candidate_info.struct_size = (uint32_t)sizeof(candidate_info);
    int32_t prepare_result =
        interface_value->prepare_scene(core, &prepare_desc, &candidate_info);
    if (prepare_result != KADATH_OK || candidate_info.mode != mode) {
        return 30;
    }
    return 0;
}

static int prepare_again(
    kadath_runtime_object_authority_interface_t* interface_value,
    kadath_runtime_core_t* core,
    uint32_t mode) {
    if ((mode != KADATH_RUNTIME_PREPARE_RESTART || make_gameplay_terminal(core) == 0) &&
        prepare_candidate_again(interface_value, core, mode) == 0 &&
        prepare_gameplay_candidate(interface_value, core) == 0 &&
        prepare_empty_phase_candidate(core) == 0) {
        return interface_value->commit_scene(core) == KADATH_OK ? 0 : 31;
    } else {
        return 30;
    }
}

static int transient_lifecycle(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) {
        return create_result;
    }

    kadath_runtime_mutation_item_v1_t item;
    kadath_runtime_mutation_result_t mutation_result;
    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    item.payload.transient.struct_size = (uint32_t)sizeof(item.payload.transient);
    item.payload.transient.prototype_key = 7U;
    item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    item.payload.transient.sprite.struct_size =
        (uint32_t)sizeof(item.payload.transient.sprite);
    item.payload.transient.sprite.position[0] = 30.0F;
    item.payload.transient.sprite.position[1] = 40.0F;
    item.payload.transient.sprite.size[0] = 4.0F;
    item.payload.transient.sprite.size[1] = 4.0F;
    item.payload.transient.sprite.color[0] = 1.0F;
    item.payload.transient.sprite.color[1] = 1.0F;
    item.payload.transient.sprite.color[2] = 1.0F;
    item.payload.transient.sprite.color[3] = 1.0F;
    item.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        mutation_result.object.lifecycle != KADATH_RUNTIME_LIFECYCLE_PENDING_SPAWN ||
        mutation_result.object.entity_value != KADATH_RUNTIME_ENTITY_INVALID ||
        mutation_result.object.object_ref.object_id_length != 24U ||
        memcmp(mutation_result.object.object_ref.object_id, "runtime-0000000000000001", 24U) != 0) {
        return 22;
    }
    kadath_runtime_object_ref_v1_t first_ref = mutation_result.object.object_ref;

    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT;
    item.payload.object_ref = first_ref;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK) {
        return 23;
    }

    kadath_runtime_query_result_t query_result;
    if (query_exact(interface_value, core, &first_ref, &query_result) != KADATH_OK ||
        query_result.found != KADATH_RUNTIME_FOUND ||
        query_result.payload.object.lifecycle != KADATH_RUNTIME_LIFECYCLE_ACTIVE ||
        query_result.payload.object.entity_value == KADATH_RUNTIME_ENTITY_INVALID) {
        return 24;
    }

    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
    item.payload.object_ref = first_ref;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        mutation_result.destroy_disposition !=
            KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE) {
        return 25;
    }
    if (query_exact(interface_value, core, &first_ref, &query_result) != KADATH_OK ||
        query_result.found != KADATH_RUNTIME_NOT_FOUND) {
        return 26;
    }

    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY;
    item.payload.object_ref = first_ref;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK) {
        return 27;
    }

    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    item.payload.transient.struct_size = (uint32_t)sizeof(item.payload.transient);
    item.payload.transient.prototype_key = 7U;
    item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    item.payload.transient.sprite.struct_size =
        (uint32_t)sizeof(item.payload.transient.sprite);
    item.payload.transient.sprite.position[0] = 1.0F;
    item.payload.transient.sprite.position[1] = 2.0F;
    item.payload.transient.sprite.size[0] = 4.0F;
    item.payload.transient.sprite.size[1] = 4.0F;
    item.payload.transient.sprite.color[3] = 1.0F;
    item.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        memcmp(mutation_result.object.object_ref.object_id, "runtime-0000000000000002", 24U) != 0 ||
        mutation_result.object.object_ref.logical_generation == first_ref.logical_generation) {
        return 28;
    }

    if (interface_value->destroy(&core) != KADATH_OK || core != NULL) {
        return 29;
    }
    return 0;
}

static int restart_and_reload(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) {
        return create_result;
    }

    kadath_runtime_query_result_t player_result;
    if (query_id(interface_value, core, "player", &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND) {
        return 32;
    }
    kadath_runtime_object_ref_v1_t original_player = player_result.payload.object.object_ref;
    uint64_t original_entity = player_result.payload.object.entity_value;

    kadath_runtime_mutation_item_v1_t item;
    kadath_runtime_mutation_result_t mutation_result;
    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    item.payload.transient.struct_size = (uint32_t)sizeof(item.payload.transient);
    item.payload.transient.prototype_key = 1U;
    item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    item.payload.transient.sprite.struct_size =
        (uint32_t)sizeof(item.payload.transient.sprite);
    item.payload.transient.sprite.size[0] = 2.0F;
    item.payload.transient.sprite.size[1] = 2.0F;
    item.payload.transient.sprite.color[3] = 1.0F;
    item.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK) {
        return 33;
    }
    kadath_runtime_object_ref_v1_t original_transient = mutation_result.object.object_ref;

    if (prepare_again(interface_value, core, KADATH_RUNTIME_PREPARE_RESTART) != 0) {
        return 34;
    }
    if (query_exact(interface_value, core, &original_player, &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND ||
        player_result.payload.object.entity_value == original_entity) {
        return 35;
    }
    kadath_runtime_object_ref_v1_t restart_player = player_result.payload.object.object_ref;
    if (query_exact(interface_value, core, &original_transient, &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_NOT_FOUND) {
        return 36;
    }

    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    item.payload.transient.struct_size = (uint32_t)sizeof(item.payload.transient);
    item.payload.transient.prototype_key = 1U;
    item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    item.payload.transient.sprite.struct_size =
        (uint32_t)sizeof(item.payload.transient.sprite);
    item.payload.transient.sprite.size[0] = 2.0F;
    item.payload.transient.sprite.size[1] = 2.0F;
    item.payload.transient.sprite.color[3] = 1.0F;
    item.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        memcmp(mutation_result.object.object_ref.object_id, "runtime-0000000000000002", 24U) != 0) {
        return 37;
    }

    if (prepare_again(interface_value, core, KADATH_RUNTIME_PREPARE_SCENE_RELOAD) != 0) {
        return 38;
    }
    if (query_exact(interface_value, core, &restart_player, &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_NOT_FOUND) {
        return 39;
    }
    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    item.payload.transient.struct_size = (uint32_t)sizeof(item.payload.transient);
    item.payload.transient.prototype_key = 1U;
    item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    item.payload.transient.sprite.struct_size =
        (uint32_t)sizeof(item.payload.transient.sprite);
    item.payload.transient.sprite.size[0] = 2.0F;
    item.payload.transient.sprite.size[1] = 2.0F;
    item.payload.transient.sprite.color[3] = 1.0F;
    item.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        memcmp(mutation_result.object.object_ref.object_id, "runtime-0000000000000001", 24U) != 0) {
        return 40;
    }
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 41;
}

static int world_and_position_batch(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) {
        return create_result;
    }
    kadath_runtime_query_result_t player;
    kadath_runtime_query_result_t goal;
    if (query_id(interface_value, core, "player", &player) != KADATH_OK ||
        query_id(interface_value, core, "goal", &goal) != KADATH_OK) {
        return 42;
    }
    kadath_runtime_object_ref_v1_t player_ref = player.payload.object.object_ref;
    kadath_runtime_object_ref_v1_t goal_ref = goal.payload.object.object_ref;

    kadath_runtime_mutation_item_v1_t item;
    kadath_runtime_mutation_result_t mutation_result;
    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_STEP_FIXED;
    item.payload.fixed_step.struct_size = (uint32_t)sizeof(item.payload.fixed_step);
    item.payload.fixed_step.dt_seconds = 0.5F;
    item.payload.fixed_step.move_x = 1;
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        query_exact(interface_value, core, &player_ref, &player) != KADATH_OK ||
        player.payload.object.position[0] != 20.0F) {
        return 43;
    }

    kadath_runtime_position_patch_v1_t patches[2];
    memset(patches, 0, sizeof(patches));
    patches[0].struct_size = (uint32_t)sizeof(patches[0]);
    patches[0].object_ref = player_ref;
    patches[0].position[0] = 95.0F;
    patches[0].position[1] = 95.0F;
    patches[1].struct_size = (uint32_t)sizeof(patches[1]);
    patches[1].object_ref = goal_ref;
    patches[1].position[0] = 50.0F;
    patches[1].position[1] = 60.0F;
    memset(&item, 0, sizeof(item));
    item.struct_size = (uint32_t)sizeof(item);
    item.tag = KADATH_RUNTIME_MUTATION_APPLY_POSITIONS;
    item.payload.positions.patches = patches;
    item.payload.positions.patch_count = 2U;
    item.payload.positions.patch_stride = sizeof(patches[0]);
    if (mutate_one(interface_value, core, &item, &mutation_result) != KADATH_OK ||
        query_exact(interface_value, core, &player_ref, &player) != KADATH_OK ||
        player.payload.object.position[0] != 92.0F || player.payload.object.position[1] != 92.0F ||
        query_exact(interface_value, core, &goal_ref, &goal) != KADATH_OK ||
        goal.payload.object.position[0] != 50.0F || goal.payload.object.position[1] != 60.0F) {
        return 44;
    }

    patches[0].position[0] = 1.0F;
    patches[1].position[0] = NAN;
    if (mutate_one(interface_value, core, &item, &mutation_result) !=
            KADATH_ERR_INVALID_ARGUMENT ||
        query_exact(interface_value, core, &player_ref, &player) != KADATH_OK ||
        player.payload.object.position[0] != 92.0F) {
        return 45;
    }
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 46;
}

static int activation_batch_atomic(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) return create_result;

    kadath_runtime_query_result_t player;
    if (query_id(interface_value, core, "player", &player) != KADATH_OK) return 50;

    kadath_runtime_mutation_item_v1_t reserve;
    kadath_runtime_mutation_result_t reserve_result;
    memset(&reserve, 0, sizeof(reserve));
    reserve.struct_size = (uint32_t)sizeof(reserve);
    reserve.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    reserve.payload.transient.struct_size = (uint32_t)sizeof(reserve.payload.transient);
    reserve.payload.transient.prototype_key = 3U;
    reserve.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    reserve.payload.transient.sprite.struct_size = (uint32_t)sizeof(reserve.payload.transient.sprite);
    reserve.payload.transient.sprite.size[0] = 2.0F;
    reserve.payload.transient.sprite.size[1] = 2.0F;
    reserve.payload.transient.sprite.color[3] = 1.0F;
    reserve.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &reserve, &reserve_result) != KADATH_OK) return 51;
    kadath_runtime_object_ref_v1_t root_ref = reserve_result.object.object_ref;

    kadath_runtime_position_patch_v1_t patches[2];
    memset(patches, 0, sizeof(patches));
    patches[0].struct_size = (uint32_t)sizeof(patches[0]);
    patches[0].object_ref = player.payload.object.object_ref;
    patches[0].position[0] = 25.0F;
    patches[0].position[1] = 20.0F;
    patches[1].struct_size = (uint32_t)sizeof(patches[1]);
    patches[1].object_ref = root_ref;
    patches[1].position[0] = 35.0F;
    patches[1].position[1] = 45.0F;

    kadath_runtime_mutation_item_v1_t items[3];
    kadath_runtime_mutation_result_t results[3];
    memset(items, 0, sizeof(items));
    for (size_t index = 0; index < 3U; ++index) items[index].struct_size = (uint32_t)sizeof(items[index]);
    items[0].tag = KADATH_RUNTIME_MUTATION_APPLY_POSITIONS;
    items[0].payload.positions.patches = patches;
    items[0].payload.positions.patch_count = 2U;
    items[0].payload.positions.patch_stride = sizeof(patches[0]);
    items[1].tag = KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT;
    items[1].payload.object_ref = root_ref;
    items[2].tag = KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
    items[2].payload.object_ref = root_ref;
    if (mutate_many(interface_value, core, items, 3U, results) != KADATH_OK ||
        results[2].destroy_disposition != KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE ||
        query_exact(interface_value, core, &root_ref, &player) != KADATH_OK ||
        player.found != KADATH_RUNTIME_NOT_FOUND) {
        return 52;
    }

    memset(&reserve, 0, sizeof(reserve));
    reserve.struct_size = (uint32_t)sizeof(reserve);
    reserve.tag = KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY;
    reserve.payload.object_ref = root_ref;
    if (mutate_one(interface_value, core, &reserve, &reserve_result) != KADATH_OK) return 53;

    /* The only permitted duplicate ObjectRef lifecycle pair is ACTIVATE -> REQUEST.
     * Repeating REQUEST must reject atomically instead of replaying the first step. */
    memset(&reserve, 0, sizeof(reserve));
    reserve.struct_size = (uint32_t)sizeof(reserve);
    reserve.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    reserve.payload.transient.struct_size = (uint32_t)sizeof(reserve.payload.transient);
    reserve.payload.transient.prototype_key = 3U;
    reserve.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    reserve.payload.transient.sprite.struct_size = (uint32_t)sizeof(reserve.payload.transient.sprite);
    reserve.payload.transient.sprite.size[0] = 2.0F;
    reserve.payload.transient.sprite.size[1] = 2.0F;
    reserve.payload.transient.sprite.color[3] = 1.0F;
    reserve.payload.transient.sprite.texture_id = 1U;
    if (mutate_one(interface_value, core, &reserve, &reserve_result) != KADATH_OK) return 57;
    kadath_runtime_object_ref_v1_t repeated_destroy_ref = reserve_result.object.object_ref;
    memset(items, 0, sizeof(items));
    for (size_t index = 0; index < 2U; ++index) items[index].struct_size = (uint32_t)sizeof(items[index]);
    items[0].tag = KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
    items[0].payload.object_ref = repeated_destroy_ref;
    items[1].tag = KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
    items[1].payload.object_ref = repeated_destroy_ref;
    if (mutate_many(interface_value, core, items, 2U, results) != KADATH_ERR_INVALID_ARGUMENT ||
        query_exact(interface_value, core, &repeated_destroy_ref, &player) != KADATH_OK ||
        player.found != KADATH_RUNTIME_FOUND) {
        return 58;
    }

    if (query_id(interface_value, core, "player", &player) != KADATH_OK ||
        player.payload.object.position[0] != 25.0F) return 54;

    memset(items, 0, sizeof(items));
    for (size_t index = 0; index < 2U; ++index) items[index].struct_size = (uint32_t)sizeof(items[index]);
    patches[0].position[0] = 40.0F;
    items[0].tag = KADATH_RUNTIME_MUTATION_APPLY_POSITIONS;
    items[0].payload.positions.patches = patches;
    items[0].payload.positions.patch_count = 1U;
    items[0].payload.positions.patch_stride = sizeof(patches[0]);
    items[1].tag = KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT;
    items[1].payload.object_ref = root_ref;
    if (mutate_many(interface_value, core, items, 2U, results) != KADATH_ERR_RUNTIME_STALE_OBJECT ||
        query_id(interface_value, core, "player", &player) != KADATH_OK ||
        player.payload.object.position[0] != 25.0F) {
        return 55;
    }
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 56;
}

static int query_batch_atomic(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) return create_result;

    kadath_runtime_query_item_v1_t items[3];
    kadath_runtime_query_result_t results[3];
    kadath_runtime_query_batch_t batch;
    memset(items, 0, sizeof(items));
    memset(results, 0xA5, sizeof(results));
    memset(&batch, 0, sizeof(batch));
    for (size_t index = 0; index < 3U; ++index) {
        items[index].struct_size = (uint32_t)sizeof(items[index]);
        results[index].struct_size = (uint32_t)sizeof(results[index]);
    }
    items[0].tag = KADATH_RUNTIME_QUERY_STATE_INFO;
    items[1].tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    items[1].payload.object_id.data = (const uint8_t*)"player";
    items[1].payload.object_id.length = 6U;
    items[2].tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    items[2].payload.object_id.data = (const uint8_t*)"missing";
    items[2].payload.object_id.length = 7U;
    batch.struct_size = (uint32_t)sizeof(batch);
    batch.target = KADATH_RUNTIME_TARGET_LIVE;
    batch.items = items;
    batch.item_count = 3U;
    batch.item_stride = sizeof(items[0]);
    if (interface_value->query(core, &batch, results, 3U) != KADATH_OK ||
        results[0].payload.state_info.object_count != 3U ||
        results[1].found != KADATH_RUNTIME_FOUND ||
        results[2].found != KADATH_RUNTIME_NOT_FOUND) {
        return 60;
    }

    memset(results, 0xA5, sizeof(results));
    for (size_t index = 0; index < 3U; ++index) results[index].struct_size = (uint32_t)sizeof(results[index]);
    kadath_runtime_query_result_t sentinels[3];
    memcpy(sentinels, results, sizeof(results));
    items[2].tag = 0xFFFFFFFFU;
    if (interface_value->query(core, &batch, results, 3U) != KADATH_ERR_NOT_SUPPORTED ||
        memcmp(results, sentinels, sizeof(results)) != 0) {
        return 61;
    }

    /* Known tags must zero inactive union bytes, and borrowed ranges may not alias. */
    memset(results, 0xA5, sizeof(results));
    for (size_t index = 0; index < 3U; ++index) results[index].struct_size = (uint32_t)sizeof(results[index]);
    memcpy(sentinels, results, sizeof(results));
    items[0].tag = KADATH_RUNTIME_QUERY_STATE_INFO;
    items[0].payload.entity_value = 1U;
    if (interface_value->query(core, &batch, results, 3U) != KADATH_ERR_INVALID_ARGUMENT ||
        memcmp(results, sentinels, sizeof(results)) != 0) {
        return 63;
    }
    memset(results, 0xA5, sizeof(results));
    for (size_t index = 0; index < 3U; ++index) results[index].struct_size = (uint32_t)sizeof(results[index]);
    memcpy(sentinels, results, sizeof(results));
    memset(&items[0], 0, sizeof(items[0]));
    items[0].struct_size = (uint32_t)sizeof(items[0]);
    items[0].tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    items[0].payload.object_id.data = (const uint8_t*)items;
    items[0].payload.object_id.length = 1U;
    memset(&items[1], 0, sizeof(items[1]));
    items[1].struct_size = (uint32_t)sizeof(items[1]);
    items[1].tag = KADATH_RUNTIME_QUERY_STATE_INFO;
    memset(&items[2], 0, sizeof(items[2]));
    items[2].struct_size = (uint32_t)sizeof(items[2]);
    items[2].tag = KADATH_RUNTIME_QUERY_STATE_INFO;
    if (interface_value->query(core, &batch, results, 3U) != KADATH_ERR_INVALID_ARGUMENT ||
        memcmp(results, sentinels, sizeof(results)) != 0) {
        return 64;
    }
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 62;
}

static int arm_fault(kadath_runtime_core_t* core, uint32_t entry, uint32_t fault) {
    kadath_runtime_test_fault_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.struct_size = (uint32_t)sizeof(desc);
    desc.entry = entry;
    desc.fault = fault;
    return kadath_runtime_core_test_arm_next_fault(core, &desc);
}

static int fault_containment(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_core_create_desc_t create_desc;
    kadath_runtime_core_t* prepare_core = NULL;
    memset(&create_desc, 0, sizeof(create_desc));
    create_desc.struct_size = (uint32_t)sizeof(create_desc);
    if (interface_value->create(&create_desc, &prepare_core) != KADATH_OK) return 69;
    kadath_runtime_source_object_desc_v1_t source;
    kadath_runtime_scene_prepare_desc_t prepare_desc;
    kadath_runtime_scene_candidate_info_t candidate_info;
    kadath_runtime_scene_candidate_info_t candidate_sentinel;
    fill_source(&source, "player", KADATH_RUNTIME_OBJECT_KIND_PLAYER, 10.0F, 20.0F);
    memset(&prepare_desc, 0, sizeof(prepare_desc));
    memset(&candidate_info, 0xA5, sizeof(candidate_info));
    prepare_desc.struct_size = (uint32_t)sizeof(prepare_desc);
    prepare_desc.mode = KADATH_RUNTIME_PREPARE_INITIAL;
    prepare_desc.bounds_max[0] = 100.0F;
    prepare_desc.bounds_max[1] = 100.0F;
    prepare_desc.source_objects = &source;
    prepare_desc.source_object_count = 1U;
    prepare_desc.source_object_stride = sizeof(source);
    candidate_info.struct_size = (uint32_t)sizeof(candidate_info);
    memcpy(&candidate_sentinel, &candidate_info, sizeof(candidate_info));
    if (arm_fault(prepare_core, KADATH_RUNTIME_TEST_ENTRY_PREPARE, KADATH_RUNTIME_TEST_FAULT_ALLOCATION_FAILURE) != KADATH_OK ||
        interface_value->prepare_scene(prepare_core, &prepare_desc, &candidate_info) != KADATH_ERR_OUT_OF_MEMORY ||
        memcmp(&candidate_info, &candidate_sentinel, sizeof(candidate_info)) != 0 ||
        interface_value->prepare_scene(prepare_core, &prepare_desc, &candidate_info) != KADATH_OK ||
        interface_value->abort_scene(prepare_core) != KADATH_OK ||
        interface_value->destroy(&prepare_core) != KADATH_OK) {
        return 73;
    }

    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) return create_result;

    kadath_runtime_query_item_v1_t query_item;
    kadath_runtime_query_batch_t query_batch;
    kadath_runtime_query_result_t query_result;
    kadath_runtime_query_result_t query_sentinel;
    memset(&query_item, 0, sizeof(query_item));
    memset(&query_batch, 0, sizeof(query_batch));
    memset(&query_result, 0xA5, sizeof(query_result));
    query_item.struct_size = (uint32_t)sizeof(query_item);
    query_item.tag = KADATH_RUNTIME_QUERY_FIND_BY_ID;
    query_item.payload.object_id.data = (const uint8_t*)"player";
    query_item.payload.object_id.length = 6U;
    query_batch.struct_size = (uint32_t)sizeof(query_batch);
    query_batch.target = KADATH_RUNTIME_TARGET_LIVE;
    query_batch.items = &query_item;
    query_batch.item_count = 1U;
    query_batch.item_stride = sizeof(query_item);
    query_result.struct_size = (uint32_t)sizeof(query_result);
    memcpy(&query_sentinel, &query_result, sizeof(query_result));
    if (arm_fault(core, KADATH_RUNTIME_TEST_ENTRY_QUERY, KADATH_RUNTIME_TEST_FAULT_PANIC_BEFORE_PUBLICATION) != KADATH_OK ||
        interface_value->query(core, &query_batch, &query_result, 1U) != KADATH_ERR_INTERNAL ||
        memcmp(&query_result, &query_sentinel, sizeof(query_result)) != 0) {
        return 70;
    }

    kadath_runtime_mutation_item_v1_t mutation_item;
    kadath_runtime_mutation_batch_t mutation_batch;
    kadath_runtime_mutation_result_t mutation_result;
    kadath_runtime_mutation_result_t mutation_sentinel;
    memset(&mutation_item, 0, sizeof(mutation_item));
    memset(&mutation_batch, 0, sizeof(mutation_batch));
    memset(&mutation_result, 0xA5, sizeof(mutation_result));
    mutation_item.struct_size = (uint32_t)sizeof(mutation_item);
    mutation_item.tag = KADATH_RUNTIME_MUTATION_SET_BOUNDS;
    mutation_item.payload.bounds.struct_size = (uint32_t)sizeof(mutation_item.payload.bounds);
    mutation_item.payload.bounds.max[0] = 50.0F;
    mutation_item.payload.bounds.max[1] = 50.0F;
    mutation_batch.struct_size = (uint32_t)sizeof(mutation_batch);
    mutation_batch.target = KADATH_RUNTIME_TARGET_LIVE;
    mutation_batch.items = &mutation_item;
    mutation_batch.item_count = 1U;
    mutation_batch.item_stride = sizeof(mutation_item);
    mutation_result.struct_size = (uint32_t)sizeof(mutation_result);
    memcpy(&mutation_sentinel, &mutation_result, sizeof(mutation_result));
    if (arm_fault(core, KADATH_RUNTIME_TEST_ENTRY_MUTATE, KADATH_RUNTIME_TEST_FAULT_ALLOCATION_FAILURE) != KADATH_OK ||
        interface_value->mutate(core, &mutation_batch, &mutation_result, 1U) != KADATH_ERR_OUT_OF_MEMORY ||
        memcmp(&mutation_result, &mutation_sentinel, sizeof(mutation_result)) != 0 ||
        query_id(interface_value, core, "goal", &query_result) != KADATH_OK ||
        query_result.payload.object.position[0] != 80.0F) {
        return 71;
    }
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 72;
}

typedef struct wrong_thread_context_t {
    kadath_runtime_object_authority_interface_t* interface_value;
    kadath_runtime_core_t* core;
    int32_t result;
} wrong_thread_context_t;

#if defined(_WIN32)
static DWORD WINAPI call_core_on_wrong_thread(LPVOID userdata) {
#else
static int call_core_on_wrong_thread(void* userdata) {
#endif
    wrong_thread_context_t* context = (wrong_thread_context_t*)userdata;
    context->result = context->interface_value->abort_scene(context->core);
    return 0;
}

static int misuse_contract(kadath_runtime_object_authority_interface_t* interface_value) {
    kadath_runtime_object_authority_interface_t probe;
    kadath_runtime_object_authority_interface_t sentinel;
    memset(&probe, 0xA5, sizeof(probe));
    probe.struct_size = 4U;
    probe.interface_version = KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1;
    memcpy(&sentinel, &probe, sizeof(probe));
    if (kadath_runtime_core_query_object_authority_interface(NULL) != KADATH_ERR_INVALID_ARGUMENT ||
        kadath_runtime_core_query_object_authority_interface(&probe) != KADATH_ERR_INVALID_ARGUMENT ||
        memcmp(&probe, &sentinel, sizeof(probe)) != 0) {
        return 80;
    }
    memset(&probe, 0, sizeof(probe));
    probe.struct_size = (uint32_t)sizeof(probe);
    probe.interface_version = 0xFFFFFFFFU;
    memcpy(&sentinel, &probe, sizeof(probe));
    if (kadath_runtime_core_query_object_authority_interface(&probe) != KADATH_ERR_NOT_SUPPORTED ||
        memcmp(&probe, &sentinel, sizeof(probe)) != 0) {
        return 81;
    }

    kadath_runtime_core_create_desc_t create_desc;
    kadath_runtime_core_t* core = (kadath_runtime_core_t*)(uintptr_t)0x1U;
    memset(&create_desc, 0, sizeof(create_desc));
    create_desc.struct_size = 4U;
    if (interface_value->create(&create_desc, &core) != KADATH_ERR_INVALID_ARGUMENT ||
        core != (kadath_runtime_core_t*)(uintptr_t)0x1U ||
        interface_value->destroy(NULL) != KADATH_ERR_INVALID_ARGUMENT) {
        return 82;
    }
    core = NULL;
    if (interface_value->destroy(&core) != KADATH_OK) return 83;
    int create_result = create_live_core(interface_value, &core);
    if (create_result != 0) return create_result;
    if (interface_value->abort_scene(core) != KADATH_OK ||
        interface_value->commit_scene(core) != KADATH_ERR_RUNTIME_INVALID_STATE) {
        return 84;
    }
    wrong_thread_context_t context = { interface_value, core, KADATH_OK };
#if defined(_WIN32)
    HANDLE thread = CreateThread(NULL, 0U, call_core_on_wrong_thread, &context, 0U, NULL);
    DWORD thread_result = 1U;
    if (thread == NULL || WaitForSingleObject(thread, INFINITE) != WAIT_OBJECT_0 ||
        GetExitCodeThread(thread, &thread_result) == 0 || CloseHandle(thread) == 0 ||
        thread_result != 0U || context.result != KADATH_ERR_RUNTIME_WRONG_THREAD) {
        return 85;
    }
#else
    thrd_t thread;
    int thread_result = 0;
    if (thrd_create(&thread, call_core_on_wrong_thread, &context) != thrd_success ||
        thrd_join(thread, &thread_result) != thrd_success || thread_result != 0 ||
        context.result != KADATH_ERR_RUNTIME_WRONG_THREAD) {
        return 85;
    }
#endif
    return interface_value->destroy(&core) == KADATH_OK ? 0 : 86;
}

static int gameplay_contract_path(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_phase_interface_v1_t* phase_interface,
    kadath_runtime_gameplay_interface_v1_t* gameplay_interface) {
    kadath_runtime_gameplay_interface_v1_t probe;
    kadath_runtime_gameplay_interface_v1_t probe_sentinel;
    memset(&probe, 0xA5, sizeof(probe));
    probe.struct_size = 4U;
    probe.interface_version = KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1;
    memcpy(&probe_sentinel, &probe, sizeof(probe));
    if (kadath_runtime_core_query_gameplay_interface(NULL) != KADATH_ERR_INVALID_ARGUMENT ||
        kadath_runtime_core_query_gameplay_interface(&probe) != KADATH_ERR_INVALID_ARGUMENT ||
        memcmp(&probe, &probe_sentinel, sizeof(probe)) != 0) return 97;
    memset(&probe, 0, sizeof(probe));
    probe.struct_size = (uint32_t)sizeof(probe);
    probe.interface_version = UINT32_MAX;
    memcpy(&probe_sentinel, &probe, sizeof(probe));
    if (kadath_runtime_core_query_gameplay_interface(&probe) != KADATH_ERR_NOT_SUPPORTED ||
        memcmp(&probe, &probe_sentinel, sizeof(probe)) != 0) return 98;
    memset(&probe, 0, sizeof(probe));
    probe.struct_size = (uint32_t)sizeof(probe);
    probe.interface_version = KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1;
    probe.reserved[0] = 1U;
    memcpy(&probe_sentinel, &probe, sizeof(probe));
    if (kadath_runtime_core_query_gameplay_interface(&probe) != KADATH_ERR_INVALID_ARGUMENT ||
        memcmp(&probe, &probe_sentinel, sizeof(probe)) != 0) return 99;

    kadath_runtime_core_t* core = NULL;
    if (create_live_core(object_interface, &core) != 0) return 87;

    kadath_runtime_render_item_v1_t render_items[3];
    kadath_runtime_render_buffer_v1_t render_buffer;
    kadath_runtime_gameplay_snapshot_v1_t snapshot;
    memset(render_items, 0, sizeof(render_items));
    for (size_t index = 0; index < 3U; ++index) {
        render_items[index].struct_size = (uint32_t)sizeof(render_items[index]);
    }
    memset(&render_buffer, 0, sizeof(render_buffer));
    memset(&snapshot, 0, sizeof(snapshot));
    render_buffer.struct_size = (uint32_t)sizeof(render_buffer);
    render_buffer.items = render_items;
    render_buffer.item_capacity = 3U;
    render_buffer.item_stride = sizeof(render_items[0]);
    snapshot.struct_size = (uint32_t)sizeof(snapshot);
    if (gameplay_interface->publish_snapshot(core, &render_buffer, &snapshot) != KADATH_OK ||
        snapshot.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING || snapshot.accepts_input != 1U ||
        snapshot.render_count != 3U || snapshot.last_outcome_sequence != 0U) return 88;

    kadath_runtime_render_item_v1_t panic_render_sentinel[3];
    kadath_runtime_gameplay_snapshot_v1_t panic_snapshot_sentinel;
    memcpy(panic_render_sentinel, render_items, sizeof(render_items));
    memset(&snapshot, 0xA5, sizeof(snapshot));
    snapshot.struct_size = (uint32_t)sizeof(snapshot);
    memcpy(&panic_snapshot_sentinel, &snapshot, sizeof(snapshot));
    if (arm_fault(core, KADATH_RUNTIME_TEST_ENTRY_QUERY, KADATH_RUNTIME_TEST_FAULT_PANIC_BEFORE_PUBLICATION) != KADATH_OK ||
        gameplay_interface->publish_snapshot(core, &render_buffer, &snapshot) != KADATH_ERR_INTERNAL ||
        memcmp(render_items, panic_render_sentinel, sizeof(render_items)) != 0 ||
        memcmp(&snapshot, &panic_snapshot_sentinel, sizeof(snapshot)) != 0) return 100;

    kadath_runtime_gameplay_begin_fixed_desc_v1_t begin;
    kadath_runtime_gameplay_outcome_v1_t outcome;
    kadath_runtime_gameplay_outcome_buffer_v1_t outcome_buffer;
    kadath_runtime_gameplay_step_result_v1_t step;
    memset(&begin, 0, sizeof(begin));
    memset(&outcome, 0, sizeof(outcome));
    memset(&outcome_buffer, 0, sizeof(outcome_buffer));
    memset(&step, 0, sizeof(step));
    begin.struct_size = (uint32_t)sizeof(begin);
    outcome.struct_size = (uint32_t)sizeof(outcome);
    outcome_buffer.struct_size = (uint32_t)sizeof(outcome_buffer);
    outcome_buffer.outcomes = &outcome;
    outcome_buffer.outcome_capacity = 1U;
    outcome_buffer.outcome_stride = sizeof(outcome);
    step.struct_size = (uint32_t)sizeof(step);
    if (gameplay_interface->begin_fixed_step(core, &begin, &outcome_buffer, &step) != KADATH_OK ||
        step.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING || step.outcome_count != 0U) return 89;

    kadath_runtime_gameplay_step_result_v1_t busy_step;
    kadath_runtime_gameplay_outcome_v1_t busy_outcome;
    memset(&busy_step, 0xA5, sizeof(busy_step));
    memset(&busy_outcome, 0xA5, sizeof(busy_outcome));
    busy_step.struct_size = (uint32_t)sizeof(busy_step);
    busy_outcome.struct_size = (uint32_t)sizeof(busy_outcome);
    kadath_runtime_gameplay_step_result_v1_t busy_step_sentinel = busy_step;
    kadath_runtime_gameplay_outcome_v1_t busy_outcome_sentinel = busy_outcome;
    outcome_buffer.outcomes = &busy_outcome;
    if (gameplay_interface->begin_fixed_step(core, &begin, &outcome_buffer, &busy_step) !=
            KADATH_ERR_RUNTIME_GAMEPLAY_STEP_BUSY ||
        memcmp(&busy_step, &busy_step_sentinel, sizeof(busy_step)) != 0 ||
        memcmp(&busy_outcome, &busy_outcome_sentinel, sizeof(busy_outcome)) != 0) return 90;
    outcome_buffer.outcomes = &outcome;

    kadath_runtime_phase_begin_desc_v1_t phase_begin;
    kadath_runtime_phase_begin_result_v1_t phase_begin_result;
    memset(&phase_begin, 0, sizeof(phase_begin));
    memset(&phase_begin_result, 0, sizeof(phase_begin_result));
    phase_begin.struct_size = (uint32_t)sizeof(phase_begin);
    phase_begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    phase_begin_result.struct_size = (uint32_t)sizeof(phase_begin_result);
    if (phase_interface->begin_phase(core, &phase_begin, &phase_begin_result) != KADATH_OK) return 91;
    const uint64_t phase_sequence = phase_begin_result.phase_sequence;

    kadath_runtime_gameplay_commit_fixed_desc_v1_t commit;
    kadath_runtime_gameplay_step_result_v1_t committed;
    memset(&commit, 0, sizeof(commit));
    memset(&committed, 0, sizeof(committed));
    commit.struct_size = (uint32_t)sizeof(commit);
    commit.step_token = step.step_token;
    memset(&committed, 0xA5, sizeof(committed));
    committed.struct_size = (uint32_t)sizeof(committed);
    memset(&outcome, 0xA5, sizeof(outcome));
    outcome.struct_size = (uint32_t)sizeof(outcome);
    kadath_runtime_gameplay_step_result_v1_t committed_sentinel = committed;
    kadath_runtime_gameplay_outcome_v1_t commit_outcome_sentinel = outcome;
    if (arm_fault(core, KADATH_RUNTIME_TEST_ENTRY_MUTATE, KADATH_RUNTIME_TEST_FAULT_ALLOCATION_FAILURE) != KADATH_OK ||
        gameplay_interface->commit_fixed_step(core, &commit, &outcome_buffer, &committed) != KADATH_ERR_OUT_OF_MEMORY ||
        memcmp(&committed, &committed_sentinel, sizeof(committed)) != 0 ||
        memcmp(&outcome, &commit_outcome_sentinel, sizeof(outcome)) != 0) return 101;
    memset(&committed, 0, sizeof(committed));
    memset(&outcome, 0, sizeof(outcome));
    committed.struct_size = (uint32_t)sizeof(committed);
    outcome.struct_size = (uint32_t)sizeof(outcome);
    if (gameplay_interface->commit_fixed_step(core, &commit, &outcome_buffer, &committed) != KADATH_OK ||
        committed.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING || committed.outcome_count != 0U ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence) != KADATH_OK) return 92;

    begin.dt_seconds = 3.0F;
    memset(&outcome, 0, sizeof(outcome));
    memset(&step, 0, sizeof(step));
    outcome.struct_size = (uint32_t)sizeof(outcome);
    step.struct_size = (uint32_t)sizeof(step);
    if (gameplay_interface->begin_fixed_step(core, &begin, &outcome_buffer, &step) != KADATH_OK ||
        step.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_LOST || step.outcome_count != 1U ||
        outcome.sequence != 1U || outcome.cause != KADATH_RUNTIME_GAMEPLAY_CAUSE_TIMER ||
        gameplay_interface->abort_fixed_step(core, step.step_token) != KADATH_OK) return 93;

    kadath_runtime_gameplay_snapshot_v1_t small_snapshot;
    memset(render_items, 0xA5, sizeof(render_items));
    for (size_t index = 0; index < 3U; ++index) {
        render_items[index].struct_size = (uint32_t)sizeof(render_items[index]);
    }
    kadath_runtime_render_item_v1_t render_sentinels[3];
    memcpy(render_sentinels, render_items, sizeof(render_items));
    memset(&small_snapshot, 0xA5, sizeof(small_snapshot));
    small_snapshot.struct_size = (uint32_t)sizeof(small_snapshot);
    kadath_runtime_gameplay_snapshot_v1_t small_snapshot_sentinel = small_snapshot;
    render_buffer.item_capacity = 2U;
    if (gameplay_interface->publish_snapshot(core, &render_buffer, &small_snapshot) != KADATH_ERR_BUFFER_TOO_SMALL ||
        memcmp(&small_snapshot, &small_snapshot_sentinel, sizeof(small_snapshot)) != 0 ||
        memcmp(render_items, render_sentinels, sizeof(render_items)) != 0) return 94;
    render_buffer.item_capacity = 3U;
    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.struct_size = (uint32_t)sizeof(snapshot);
    if (gameplay_interface->publish_snapshot(core, &render_buffer, &snapshot) != KADATH_OK ||
        snapshot.phase != KADATH_RUNTIME_GAMEPLAY_PHASE_LOST || snapshot.accepts_input != 0U ||
        snapshot.last_outcome_sequence != 1U || render_items[0].final_color[0] != 0.95F) return 95;

    return object_interface->destroy(&core) == KADATH_OK ? 0 : 96;
}

static int phase_commit_path(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_phase_interface_v1_t* phase_interface) {
    kadath_runtime_core_t* core = NULL;
    int create_result = create_live_core(object_interface, &core);
    if (create_result != 0) return 100 + create_result;
    if (make_gameplay_terminal(core) != 0) return 149;

    kadath_runtime_query_result_t player_result;
    if (query_id(object_interface, core, "player", &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND) {
        return 150;
    }
    kadath_runtime_object_ref_v1_t player = player_result.payload.object.object_ref;

    kadath_runtime_phase_begin_desc_v1_t begin;
    kadath_runtime_phase_begin_result_v1_t begin_result;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    union {
        kadath_runtime_phase_begin_desc_v1_t desc;
        kadath_runtime_phase_begin_result_v1_t result;
    } aliased_begin;
    memset(&aliased_begin, 0, sizeof(aliased_begin));
    aliased_begin.desc.struct_size = (uint32_t)sizeof(aliased_begin.desc);
    aliased_begin.desc.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    aliased_begin.desc.phase_sequence = 76U;
    if (phase_interface->begin_phase(core, &aliased_begin.desc, &aliased_begin.result) != KADATH_ERR_INVALID_ARGUMENT ||
        aliased_begin.desc.phase_sequence != 76U) {
        return 249;
    }
    _Alignas(kadath_runtime_phase_begin_desc_v1_t) unsigned char misaligned_begin_storage[
        sizeof(kadath_runtime_phase_begin_desc_v1_t) + 1U];
    memset(misaligned_begin_storage, 0, sizeof(misaligned_begin_storage));
    uint32_t misaligned_begin_size = (uint32_t)sizeof(kadath_runtime_phase_begin_desc_v1_t);
    memcpy(misaligned_begin_storage + 1U, &misaligned_begin_size, sizeof(misaligned_begin_size));
    if (phase_interface->begin_phase(
            core,
            (const kadath_runtime_phase_begin_desc_v1_t*)(const void*)(misaligned_begin_storage + 1U),
            &begin_result) != KADATH_ERR_INVALID_ARGUMENT ||
        begin_result.phase_sequence != 0U) {
        return 252;
    }
    begin.phase_sequence = 1U;
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_ERR_INVALID_ARGUMENT ||
        begin_result.phase_sequence != 0U) {
        return 253;
    }
    begin.phase_sequence = 0U;
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK ||
        begin_result.phase_sequence == 0U) {
        return 151;
    }
    const uint64_t phase_sequence = begin_result.phase_sequence;

    /* 错误domain/phase identity必须返回stale，且不得写caller count。 */
    size_t stale_drain_count = 88U;
    kadath_runtime_phase_event_v1_t stale_drain;
    memset(&stale_drain, 0, sizeof(stale_drain));
    stale_drain.struct_size = (uint32_t)sizeof(stale_drain);
    if (phase_interface->drain_events(core, KADATH_RUNTIME_PHASE_DOMAIN_FRAME, phase_sequence,
                                      &stale_drain, 1U, &stale_drain_count) != KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST ||
        stale_drain_count != 88U) {
        return 224;
    }

    size_t empty_drain_count = 99U;
    uintptr_t invalid_event_address = UINTPTR_MAX & ~((uintptr_t)_Alignof(kadath_runtime_phase_event_v1_t) - 1U);
    kadath_runtime_phase_event_v1_t* invalid_event_output =
        (kadath_runtime_phase_event_v1_t*)invalid_event_address;
    if (phase_interface->drain_events(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence,
                                      invalid_event_output, 2U, &empty_drain_count) != KADATH_ERR_INVALID_ARGUMENT ||
        empty_drain_count != 99U) {
        return 152;
    }

    kadath_runtime_phase_event_v1_t event;
    kadath_runtime_phase_batch_result_v1_t event_batch;
    memset(&event, 0, sizeof(event));
    memset(&event_batch, 0, sizeof(event_batch));
    event.struct_size = (uint32_t)sizeof(event);
    event.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    event.target = player;
    event.name_length = 5U;
    memcpy(event.name, "hello", 5U);
    event_batch.struct_size = (uint32_t)sizeof(event_batch);
    if (phase_interface->submit_events(core, &event, 1U, sizeof(event), &event_batch) != KADATH_OK ||
        event_batch.accepted_count != 1U || event_batch.first_sequence == 0U) {
        return 153;
    }
    kadath_runtime_phase_event_v1_t drained;
    size_t drained_count = 0U;
    memset(&drained, 0, sizeof(drained));
    drained.struct_size = (uint32_t)sizeof(drained);
    if (phase_interface->drain_events(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &drained, 1U, &drained_count) != KADATH_OK ||
        drained_count != 1U || drained.sequence != event_batch.first_sequence || drained.generation != 0U) {
        return 154;
    }

    /* The Phase Interface has one active phase globally, regardless of domain. */
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FRAME;
    memset(&begin_result, 0, sizeof(begin_result));
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    begin_result.phase_sequence = UINT64_MAX;
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_ERR_RUNTIME_PHASE_BUSY ||
        begin_result.phase_sequence != UINT64_MAX) return 154;
    if (prepare_candidate_again(object_interface, core, KADATH_RUNTIME_PREPARE_RESTART) != 0 ||
        prepare_gameplay_candidate(object_interface, core) != 0 ||
        object_interface->commit_scene(core) != KADATH_ERR_RUNTIME_PHASE_BUSY) return 155;

    kadath_runtime_phase_structural_v1_t structural;
    kadath_runtime_phase_request_completion_v1_t acceptance;
    kadath_runtime_phase_batch_result_v1_t structural_batch;
    memset(&structural, 0, sizeof(structural));
    memset(&acceptance, 0, sizeof(acceptance));
    memset(&structural_batch, 0, sizeof(structural_batch));
    structural.struct_size = (uint32_t)sizeof(structural);
    structural.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    structural.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    structural.behavior_count = 1U;
    structural.prototype_key = 7U;
    structural.script_id = 11U;
    structural.origin = player;
    structural.transient_sprite.struct_size = (uint32_t)sizeof(structural.transient_sprite);
    structural.transient_sprite.size[0] = 4.0F;
    structural.transient_sprite.size[1] = 4.0F;
    structural.transient_sprite.color[3] = 1.0F;
    structural.transient_sprite.texture_id = 1U;
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    structural_batch.struct_size = (uint32_t)sizeof(structural_batch);
    if (phase_interface->submit_structural(core, &structural, 1U, sizeof(structural), &acceptance, 1U, &structural_batch) != KADATH_OK ||
        acceptance.status != KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED ||
        acceptance.object.object_ref.object_id_length == 0U) {
        return 154;
    }
    kadath_runtime_phase_structural_v1_t taken;
    kadath_runtime_phase_flush_info_v1_t flush;
    size_t taken_count = 0U;
    memset(&taken, 0, sizeof(taken));
    memset(&flush, 0, sizeof(flush));
    flush.struct_size = (uint32_t)sizeof(flush);
    taken.struct_size = (uint32_t)sizeof(taken);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &flush,
                                         &taken, 1U, (size_t*)&flush) != KADATH_ERR_INVALID_ARGUMENT ||
        flush.struct_size != (uint32_t)sizeof(flush)) {
        return 156;
    }
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &flush, &taken, 1U, &taken_count) != KADATH_OK ||
        taken_count != 1U || flush.request_count != 1U || taken.sequence != structural_batch.first_sequence) {
        return 157;
    }
    if (phase_interface->abort_structural(core, flush.flush_token + 1U) != KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST) {
        return 232;
    }
    kadath_runtime_phase_transaction_info_v1_t transaction;
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, flush.flush_token, taken.sequence, &transaction) != KADATH_OK) {
        return 158;
    }
    if (phase_interface->abort_activation(core, transaction.transaction_id + 1U) != KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST) {
        return 225;
    }
    kadath_runtime_phase_activation_batch_v1_t activation_batch;
    kadath_runtime_phase_structural_v1_t nested_structural;
    kadath_runtime_phase_activation_structural_result_v1_t nested_result;
    memset(&activation_batch, 0, sizeof(activation_batch));
    memset(&nested_structural, 0, sizeof(nested_structural));
    memset(&nested_result, 0, sizeof(nested_result));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    kadath_runtime_position_patch_v1_t activation_positions[KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN];
    memset(activation_positions, 0, sizeof(activation_positions));
    for (size_t index = 0; index < KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN; ++index) {
        activation_positions[index].struct_size = (uint32_t)sizeof(activation_positions[index]);
        activation_positions[index].object_ref = taken.object_ref;
        activation_positions[index].position[0] = (float)index;
        activation_positions[index].position[1] = (float)(index + 1U);
    }
    activation_batch.positions = activation_positions;
    activation_batch.position_count = KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN;
    activation_batch.position_stride = sizeof(activation_positions[0]);
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK) {
        return 250;
    }
    nested_structural.struct_size = (uint32_t)sizeof(nested_structural);
    nested_structural.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    nested_structural.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    nested_structural.behavior_count = 1U;
    nested_structural.prototype_key = 13U;
    nested_structural.script_id = 17U;
    nested_structural.origin = player;
    nested_structural.transient_sprite.struct_size = (uint32_t)sizeof(nested_structural.transient_sprite);
    nested_structural.transient_sprite.size[0] = 3.0F;
    nested_structural.transient_sprite.size[1] = 3.0F;
    nested_structural.transient_sprite.color[3] = 1.0F;
    nested_structural.transient_sprite.texture_id = 1U;
    nested_result.struct_size = (uint32_t)sizeof(nested_result);
    activation_batch.structural = &nested_structural;
    activation_batch.structural_count = 1U;
    activation_batch.structural_stride = sizeof(nested_structural);
    activation_batch.structural_results = &nested_result;
    activation_batch.structural_result_capacity = 1U;
    activation_batch.position_count = 0U;
    nested_result.reserved[0] = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_ERR_INVALID_ARGUMENT ||
        nested_result.reserved[0] != 1U || nested_result.status != 0U) {
        return 159;
    }
    nested_result.reserved[0] = 0U;
    activation_batch.position_count = 0U;
    activation_batch.active_binding_capacity = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_ERR_BUFFER_TOO_SMALL ||
        nested_result.status != 0U || nested_result.sequence != 0U) {
        return 160;
    }
    /* Root plus nested reservation requires exactly two caller slots. */
    activation_batch.active_binding_capacity = 2U;
    activation_batch.position_count = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY ||
        nested_result.status != 0U || nested_result.sequence != 0U) {
        return 251;
    }
    activation_batch.position_count = 0U;
    activation_batch.positions = NULL;
    activation_batch.position_stride = 0U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK) {
        return 161;
    }
    if (nested_result.status != KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED ||
        nested_result.sequence != taken.sequence + 1U || nested_result.object_ref.object_id_length == 0U ||
        nested_result.destroy_disposition != KADATH_RUNTIME_DESTROY_DISPOSITION_NONE) {
        return 161;
    }
    kadath_runtime_phase_activation_result_v1_t activation_result;
    memset(&activation_result, 0, sizeof(activation_result));
    activation_result.struct_size = (uint32_t)sizeof(activation_result);
    if (phase_interface->commit_activation(core, transaction.transaction_id, &activation_result) != KADATH_OK ||
        activation_result.root_object.lifecycle != KADATH_RUNTIME_LIFECYCLE_ACTIVE ||
        activation_result.root_object.entity_value == KADATH_RUNTIME_ENTITY_INVALID ||
        activation_result.accepted_structural_count != 1U) {
        return 162;
    }
    kadath_runtime_phase_structural_v1_t nested_taken;
    kadath_runtime_phase_flush_info_v1_t nested_flush;
    size_t nested_taken_count = 0U;
    memset(&nested_taken, 0, sizeof(nested_taken));
    memset(&nested_flush, 0, sizeof(nested_flush));
    nested_taken.struct_size = (uint32_t)sizeof(nested_taken);
    nested_flush.struct_size = (uint32_t)sizeof(nested_flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &nested_flush,
                                         &nested_taken, 1U, &nested_taken_count) != KADATH_OK ||
        nested_taken_count != 1U || nested_taken.sequence != nested_result.sequence ||
        memcmp(&nested_taken.object_ref, &nested_result.object_ref, sizeof(nested_result.object_ref)) != 0) {
        return 163;
    }
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, nested_flush.flush_token, nested_taken.sequence, &transaction) != KADATH_OK) {
        return 164;
    }
    memset(&activation_batch, 0, sizeof(activation_batch));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK) {
        return 165;
    }
    memset(&activation_result, 0, sizeof(activation_result));
    activation_result.struct_size = (uint32_t)sizeof(activation_result);
    if (phase_interface->commit_activation(core, transaction.transaction_id, &activation_result) != KADATH_OK ||
        activation_result.root_object.lifecycle != KADATH_RUNTIME_LIFECYCLE_ACTIVE) {
        return 166;
    }
    if (phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence) != KADATH_OK) {
        return 167;
    }
    if (prepare_empty_phase_candidate(core) != 0 ||
        object_interface->commit_scene(core) != KADATH_OK) return 168;
    memset(&begin_result, 0, sizeof(begin_result));
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK ||
        begin_result.domain != KADATH_RUNTIME_PHASE_DOMAIN_FRAME) return 169;
    const uint64_t frame_phase_sequence = begin_result.phase_sequence;
    if (prepare_candidate_again(object_interface, core, KADATH_RUNTIME_PREPARE_SCENE_RELOAD) != 0 ||
        prepare_gameplay_candidate(object_interface, core) != 0 ||
        object_interface->commit_scene(core) != KADATH_ERR_RUNTIME_PHASE_BUSY) return 170;
    memset(&event, 0, sizeof(event));
    memset(&event_batch, 0, sizeof(event_batch));
    event.struct_size = (uint32_t)sizeof(event);
    event.domain = KADATH_RUNTIME_PHASE_DOMAIN_FRAME;
    event.target = player;
    event.name_length = 5U;
    memcpy(event.name, "frame", 5U);
    event_batch.struct_size = (uint32_t)sizeof(event_batch);
    if (phase_interface->submit_events(core, &event, 1U, sizeof(event), &event_batch) != KADATH_OK) return 171;
    memset(&drained, 0, sizeof(drained));
    drained.struct_size = (uint32_t)sizeof(drained);
    drained_count = 0U;
    if (phase_interface->drain_events(core, KADATH_RUNTIME_PHASE_DOMAIN_FRAME, frame_phase_sequence, &drained, 1U, &drained_count) != KADATH_OK ||
        drained_count != 1U || drained.domain != KADATH_RUNTIME_PHASE_DOMAIN_FRAME) return 172;
    if (phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FRAME, frame_phase_sequence) != KADATH_OK ||
        prepare_empty_phase_candidate(core) != 0 ||
        object_interface->commit_scene(core) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 173;

    if (create_live_core(object_interface, &core) != 0) return 180;
    if (query_id(object_interface, core, "player", &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND) {
        return 181;
    }
    player = player_result.payload.object.object_ref;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK) return 182;
    const uint64_t cancelled_pair_phase_sequence = begin_result.phase_sequence;
    memset(&structural, 0, sizeof(structural));
    structural.struct_size = (uint32_t)sizeof(structural);
    structural.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    structural.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    structural.behavior_count = 1U;
    structural.prototype_key = 7U;
    structural.origin = player;
    structural.transient_sprite.struct_size = (uint32_t)sizeof(structural.transient_sprite);
    structural.transient_sprite.size[0] = 2.0F;
    structural.transient_sprite.size[1] = 2.0F;
    structural.transient_sprite.color[3] = 1.0F;
    structural.transient_sprite.texture_id = 1U;
    memset(&acceptance, 0, sizeof(acceptance));
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    memset(&structural_batch, 0, sizeof(structural_batch));
    structural_batch.struct_size = (uint32_t)sizeof(structural_batch);
    if (phase_interface->submit_structural(core, &structural, 1U, sizeof(structural), &acceptance, 1U, &structural_batch) != KADATH_OK) return 183;
    kadath_runtime_phase_structural_v1_t destroy_request;
    kadath_runtime_phase_request_completion_v1_t destroy_acceptance;
    memset(&destroy_request, 0, sizeof(destroy_request));
    destroy_request.struct_size = (uint32_t)sizeof(destroy_request);
    destroy_request.operation = KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY;
    destroy_request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    destroy_request.script_id = 11U;
    destroy_request.object_ref = acceptance.object.object_ref;
    destroy_request.origin = player;
    memset(&destroy_acceptance, 0, sizeof(destroy_acceptance));
    destroy_acceptance.struct_size = (uint32_t)sizeof(destroy_acceptance);
    memset(&structural_batch, 0, sizeof(structural_batch));
    structural_batch.struct_size = (uint32_t)sizeof(structural_batch);
    if (phase_interface->submit_structural(core, &destroy_request, 1U, sizeof(destroy_request), &destroy_acceptance, 1U, &structural_batch) != KADATH_OK ||
        destroy_acceptance.destroy_disposition != KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN) return 184;
    kadath_runtime_phase_structural_v1_t taken_pair[2];
    kadath_runtime_phase_flush_info_v1_t pair_flush;
    size_t pair_count = 0U;
    memset(taken_pair, 0, sizeof(taken_pair));
    taken_pair[0].struct_size = (uint32_t)sizeof(taken_pair[0]);
    taken_pair[1].struct_size = (uint32_t)sizeof(taken_pair[1]);
    memset(&pair_flush, 0, sizeof(pair_flush));
    pair_flush.struct_size = (uint32_t)sizeof(pair_flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, cancelled_pair_phase_sequence, &pair_flush, taken_pair, 2U, &pair_count) != KADATH_OK || pair_count != 2U) return 185;
    kadath_runtime_phase_request_completion_v1_t pair_completions[2];
    memset(pair_completions, 0, sizeof(pair_completions));
    for (size_t index = 0; index < 2U; ++index) {
        pair_completions[index].struct_size = (uint32_t)sizeof(pair_completions[index]);
        pair_completions[index].status = KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED;
        pair_completions[index].sequence = taken_pair[index].sequence;
    }
    if (phase_interface->complete_structural(core, pair_flush.flush_token, pair_completions, 2U, 0U) != KADATH_OK ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, cancelled_pair_phase_sequence) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 186;

    /* A root self-destroy activates first, then publishes a destroy successor. */
    if (create_live_core(object_interface, &core) != 0) return 190;
    if (query_id(object_interface, core, "player", &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND) return 191;
    player = player_result.payload.object.object_ref;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK) return 192;
    const uint64_t self_destroy_phase_sequence = begin_result.phase_sequence;
    memset(&structural, 0, sizeof(structural));
    structural.struct_size = (uint32_t)sizeof(structural);
    structural.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    structural.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    structural.behavior_count = 1U;
    structural.prototype_key = 23U;
    structural.origin = player;
    structural.transient_sprite.struct_size = (uint32_t)sizeof(structural.transient_sprite);
    structural.transient_sprite.size[0] = 2.0F;
    structural.transient_sprite.size[1] = 2.0F;
    structural.transient_sprite.color[3] = 1.0F;
    structural.transient_sprite.texture_id = 1U;
    memset(&acceptance, 0, sizeof(acceptance));
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    memset(&structural_batch, 0, sizeof(structural_batch));
    structural_batch.struct_size = (uint32_t)sizeof(structural_batch);
    if (phase_interface->submit_structural(core, &structural, 1U, sizeof(structural), &acceptance, 1U, &structural_batch) != KADATH_OK) return 193;
    memset(&taken, 0, sizeof(taken));
    memset(&flush, 0, sizeof(flush));
    taken.struct_size = (uint32_t)sizeof(taken);
    flush.struct_size = (uint32_t)sizeof(flush);
    taken_count = 0U;
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, self_destroy_phase_sequence, &flush, &taken, 1U, &taken_count) != KADATH_OK ||
        taken_count != 1U) return 194;
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, flush.flush_token, taken.sequence, &transaction) != KADATH_OK) return 195;
    memset(&destroy_request, 0, sizeof(destroy_request));
    destroy_request.struct_size = (uint32_t)sizeof(destroy_request);
    destroy_request.operation = KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY;
    destroy_request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    destroy_request.script_id = 11U;
    destroy_request.object_ref = taken.object_ref;
    destroy_request.origin = player;
    memset(&nested_result, 0, sizeof(nested_result));
    nested_result.struct_size = (uint32_t)sizeof(nested_result);
    memset(&activation_batch, 0, sizeof(activation_batch));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    activation_batch.structural = &destroy_request;
    activation_batch.structural_count = 1U;
    activation_batch.structural_stride = sizeof(destroy_request);
    activation_batch.structural_results = &nested_result;
    activation_batch.structural_result_capacity = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK ||
        nested_result.status != KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED ||
        nested_result.destroy_disposition != KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE ||
        memcmp(&nested_result.object_ref, &taken.object_ref, sizeof(taken.object_ref)) != 0) return 196;
    memset(&activation_result, 0, sizeof(activation_result));
    activation_result.struct_size = (uint32_t)sizeof(activation_result);
    if (phase_interface->commit_activation(core, transaction.transaction_id, &activation_result) != KADATH_OK ||
        activation_result.root_object.struct_size != 0U ||
        activation_result.accepted_structural_count != 1U ||
        activation_result.cancelled_structural_count != 0U ||
        activation_result.active_binding_count != 0U) return 197;
    if (query_exact(object_interface, core, &taken.object_ref, &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_NOT_FOUND) return 198;
    memset(&nested_taken, 0, sizeof(nested_taken));
    memset(&nested_flush, 0, sizeof(nested_flush));
    nested_taken.struct_size = (uint32_t)sizeof(nested_taken);
    nested_flush.struct_size = (uint32_t)sizeof(nested_flush);
    nested_taken_count = 0U;
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, self_destroy_phase_sequence, &nested_flush,
                                         &nested_taken, 1U, &nested_taken_count) != KADATH_OK ||
        nested_taken_count != 1U || nested_taken.operation != KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY ||
        nested_taken.sequence != nested_result.sequence) return 199;
    kadath_runtime_phase_request_completion_v1_t destroy_completion;
    memset(&destroy_completion, 0, sizeof(destroy_completion));
    destroy_completion.struct_size = (uint32_t)sizeof(destroy_completion);
    destroy_completion.status = KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED;
    destroy_completion.sequence = nested_taken.sequence;
    if (phase_interface->complete_structural(core, nested_flush.flush_token, &destroy_completion, 1U, 0U) != KADATH_OK) {
        return 200;
    }
    /* ACCEPTED实际完成hidden destroy并释放一个Object Authority slot；三个
     * authored Gameplay source占用后，其余125个slot必须全部可用。 */
    kadath_runtime_mutation_item_v1_t reserve_item;
    kadath_runtime_mutation_result_t reserve_result;
    memset(&reserve_item, 0, sizeof(reserve_item));
    reserve_item.struct_size = (uint32_t)sizeof(reserve_item);
    reserve_item.tag = KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
    reserve_item.payload.transient.struct_size = (uint32_t)sizeof(reserve_item.payload.transient);
    reserve_item.payload.transient.prototype_key = 47U;
    reserve_item.payload.transient.kind = KADATH_RUNTIME_OBJECT_KIND_SPRITE;
    reserve_item.payload.transient.sprite.struct_size = (uint32_t)sizeof(reserve_item.payload.transient.sprite);
    reserve_item.payload.transient.sprite.size[0] = 1.0F;
    reserve_item.payload.transient.sprite.size[1] = 1.0F;
    reserve_item.payload.transient.sprite.color[3] = 1.0F;
    reserve_item.payload.transient.sprite.texture_id = 1U;
    for (size_t index = 0; index < KADATH_RUNTIME_MAX_OBJECTS - 3U; ++index) {
        memset(&reserve_result, 0, sizeof(reserve_result));
        reserve_result.struct_size = (uint32_t)sizeof(reserve_result);
        if (mutate_one(object_interface, core, &reserve_item, &reserve_result) != KADATH_OK) {
            return 236;
        }
    }
    memset(&reserve_result, 0, sizeof(reserve_result));
    reserve_result.struct_size = (uint32_t)sizeof(reserve_result);
    if (mutate_one(object_interface, core, &reserve_item, &reserve_result) != KADATH_ERR_RUNTIME_OBJECT_CAPACITY ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, self_destroy_phase_sequence) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 200;
    return 0;
}

static int aborted_scene_discards_paired_phase_candidate(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_phase_interface_v1_t* phase_interface) {
    kadath_runtime_core_t* core = NULL;
    if (create_live_core(object_interface, &core) != 0) return 260;
    if (make_gameplay_terminal(core) != 0) return 260;

    kadath_runtime_source_object_desc_v1_t sources[3];
    kadath_runtime_scene_prepare_desc_t scene_desc;
    kadath_runtime_scene_candidate_info_t scene_info;
    fill_canonical_sources(sources);
    memset(&scene_desc, 0, sizeof(scene_desc));
    memset(&scene_info, 0, sizeof(scene_info));
    scene_desc.struct_size = (uint32_t)sizeof(scene_desc);
    scene_desc.mode = KADATH_RUNTIME_PREPARE_RESTART;
    scene_desc.bounds_max[0] = 100.0F;
    scene_desc.bounds_max[1] = 100.0F;
    scene_desc.source_objects = sources;
    scene_desc.source_object_count = 3U;
    scene_desc.source_object_stride = sizeof(sources[0]);
    scene_info.struct_size = (uint32_t)sizeof(scene_info);
    if (object_interface->prepare_scene(core, &scene_desc, &scene_info) != KADATH_OK) return 261;
    if (prepare_gameplay_candidate(object_interface, core) != 0) return 261;

    kadath_runtime_query_result_t candidate_player;
    if (query_candidate_id(object_interface, core, "player", &candidate_player) != KADATH_OK ||
        candidate_player.found != KADATH_RUNTIME_FOUND) return 262;

    kadath_runtime_phase_binding_desc_v1_t bindings[KADATH_RUNTIME_PHASE_MAX_BINDINGS / 4U];
    memset(bindings, 0, sizeof(bindings));
    for (size_t index = 0; index < sizeof(bindings) / sizeof(bindings[0]); ++index) {
        bindings[index].struct_size = (uint32_t)sizeof(bindings[index]);
        bindings[index].object_ref = candidate_player.payload.object.object_ref;
        bindings[index].behavior_count = KADATH_RUNTIME_PHASE_MAX_BEHAVIORS_PER_BINDING;
    }
    kadath_runtime_phase_state_prepare_desc_v1_t phase_desc;
    kadath_runtime_phase_state_candidate_info_v1_t phase_info;
    memset(&phase_desc, 0, sizeof(phase_desc));
    memset(&phase_info, 0, sizeof(phase_info));
    phase_desc.struct_size = (uint32_t)sizeof(phase_desc);
    phase_desc.target = KADATH_RUNTIME_TARGET_CANDIDATE;
    phase_desc.bindings = bindings;
    phase_desc.binding_count = sizeof(bindings) / sizeof(bindings[0]);
    phase_desc.binding_stride = sizeof(bindings[0]);
    phase_info.struct_size = (uint32_t)sizeof(phase_info);
    if (phase_interface->prepare_phase_state(core, &phase_desc, &phase_info) != KADATH_OK ||
        phase_interface->commit_phase_state(core) != KADATH_OK ||
        object_interface->abort_scene(core) != KADATH_OK) return 263;

    memset(&scene_info, 0, sizeof(scene_info));
    scene_info.struct_size = (uint32_t)sizeof(scene_info);
    if (object_interface->prepare_scene(core, &scene_desc, &scene_info) != KADATH_OK ||
        prepare_gameplay_candidate(object_interface, core) != 0 ||
        prepare_empty_phase_candidate(core) != 0 ||
        object_interface->commit_scene(core) != KADATH_OK) return 264;

    kadath_runtime_query_result_t live_player;
    if (query_id(object_interface, core, "player", &live_player) != KADATH_OK ||
        live_player.found != KADATH_RUNTIME_FOUND) return 265;
    kadath_runtime_phase_begin_desc_v1_t begin;
    kadath_runtime_phase_begin_result_v1_t begin_result;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK) return 266;
    const uint64_t phase_sequence = begin_result.phase_sequence;

    kadath_runtime_phase_structural_v1_t request;
    kadath_runtime_phase_request_completion_v1_t acceptance;
    kadath_runtime_phase_batch_result_v1_t batch_result;
    memset(&request, 0, sizeof(request));
    memset(&acceptance, 0, sizeof(acceptance));
    memset(&batch_result, 0, sizeof(batch_result));
    request.struct_size = (uint32_t)sizeof(request);
    request.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    request.behavior_count = 1U;
    request.prototype_key = 53U;
    request.origin = live_player.payload.object.object_ref;
    request.transient_sprite.struct_size = (uint32_t)sizeof(request.transient_sprite);
    request.transient_sprite.size[0] = 1.0F;
    request.transient_sprite.size[1] = 1.0F;
    request.transient_sprite.color[3] = 1.0F;
    request.transient_sprite.texture_id = 1U;
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    batch_result.struct_size = (uint32_t)sizeof(batch_result);
    if (phase_interface->submit_structural(core, &request, 1U, sizeof(request),
                                           &acceptance, 1U, &batch_result) != KADATH_OK) return 267;

    kadath_runtime_phase_structural_v1_t taken;
    kadath_runtime_phase_flush_info_v1_t flush;
    size_t taken_count = 0U;
    memset(&taken, 0, sizeof(taken));
    memset(&flush, 0, sizeof(flush));
    taken.struct_size = (uint32_t)sizeof(taken);
    flush.struct_size = (uint32_t)sizeof(flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence,
                                         &flush, &taken, 1U, &taken_count) != KADATH_OK ||
        taken_count != 1U ||
        phase_interface->abort_structural(core, flush.flush_token) != KADATH_OK ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 268;
    return 0;
}

static int activation_discard_path(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_phase_interface_v1_t* phase_interface) {
    kadath_runtime_core_t* core = NULL;
    if (create_live_core(object_interface, &core) != 0) return 210;
    kadath_runtime_query_result_t player_result;
    if (query_id(object_interface, core, "player", &player_result) != KADATH_OK ||
        player_result.found != KADATH_RUNTIME_FOUND) return 211;

    kadath_runtime_phase_begin_desc_v1_t begin;
    kadath_runtime_phase_begin_result_v1_t begin_result;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK) return 212;
    const uint64_t phase_sequence = begin_result.phase_sequence;

    kadath_runtime_phase_structural_v1_t root_request;
    kadath_runtime_phase_request_completion_v1_t root_acceptance;
    kadath_runtime_phase_batch_result_v1_t batch_result;
    memset(&root_request, 0, sizeof(root_request));
    memset(&root_acceptance, 0, sizeof(root_acceptance));
    memset(&batch_result, 0, sizeof(batch_result));
    root_request.struct_size = (uint32_t)sizeof(root_request);
    root_request.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    root_request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    root_request.behavior_count = 1U;
    root_request.prototype_key = 29U;
    root_request.origin = player_result.payload.object.object_ref;
    root_request.transient_sprite.struct_size = (uint32_t)sizeof(root_request.transient_sprite);
    root_request.transient_sprite.size[0] = 2.0F;
    root_request.transient_sprite.size[1] = 2.0F;
    root_request.transient_sprite.color[3] = 1.0F;
    root_request.transient_sprite.texture_id = 1U;
    root_acceptance.struct_size = (uint32_t)sizeof(root_acceptance);
    batch_result.struct_size = (uint32_t)sizeof(batch_result);
    if (phase_interface->submit_structural(core, &root_request, 1U, sizeof(root_request),
                                           &root_acceptance, 1U, &batch_result) != KADATH_OK) return 213;

    kadath_runtime_phase_structural_v1_t root_taken;
    kadath_runtime_phase_flush_info_v1_t root_flush;
    size_t root_count = 0U;
    memset(&root_taken, 0, sizeof(root_taken));
    memset(&root_flush, 0, sizeof(root_flush));
    root_taken.struct_size = (uint32_t)sizeof(root_taken);
    root_flush.struct_size = (uint32_t)sizeof(root_flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &root_flush,
                                         &root_taken, 1U, &root_count) != KADATH_OK || root_count != 1U) return 214;

    kadath_runtime_phase_transaction_info_v1_t transaction;
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, root_flush.flush_token, root_taken.sequence,
                                          &transaction) != KADATH_OK) return 215;

    kadath_runtime_phase_activation_batch_v1_t activation_batch;
    kadath_runtime_phase_structural_v1_t nested_request;
    kadath_runtime_phase_activation_structural_result_v1_t nested_result;
    memset(&activation_batch, 0, sizeof(activation_batch));
    memset(&nested_request, 0, sizeof(nested_request));
    memset(&nested_result, 0, sizeof(nested_result));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    nested_request.struct_size = (uint32_t)sizeof(nested_request);
    nested_request.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    nested_request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    nested_request.behavior_count = 1U;
    nested_request.prototype_key = 31U;
    nested_request.origin = player_result.payload.object.object_ref;
    nested_request.transient_sprite.struct_size = (uint32_t)sizeof(nested_request.transient_sprite);
    nested_request.transient_sprite.size[0] = 2.0F;
    nested_request.transient_sprite.size[1] = 2.0F;
    nested_request.transient_sprite.color[3] = 1.0F;
    nested_request.transient_sprite.texture_id = 1U;
    nested_result.struct_size = (uint32_t)sizeof(nested_result);
    activation_batch.structural = &nested_request;
    activation_batch.structural_count = 1U;
    activation_batch.structural_stride = sizeof(nested_request);
    activation_batch.structural_results = &nested_result;
    activation_batch.structural_result_capacity = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK ||
        nested_result.object_ref.object_id_length == 0U) return 216;

    kadath_runtime_phase_structural_v1_t discard_request;
    kadath_runtime_phase_activation_structural_result_v1_t discard_result;
    memset(&activation_batch, 0, sizeof(activation_batch));
    memset(&discard_request, 0, sizeof(discard_request));
    memset(&discard_result, 0, sizeof(discard_result));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    discard_request.struct_size = (uint32_t)sizeof(discard_request);
    discard_request.operation = KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION;
    discard_request.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    discard_request.script_id = 11U;
    discard_request.object_ref = nested_result.object_ref;
    discard_request.origin = player_result.payload.object.object_ref;
    discard_result.struct_size = (uint32_t)sizeof(discard_result);
    activation_batch.structural = &discard_request;
    activation_batch.structural_count = 1U;
    activation_batch.structural_stride = sizeof(discard_request);
    activation_batch.structural_results = &discard_result;
    activation_batch.structural_result_capacity = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK ||
        discard_result.destroy_disposition != KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN) return 217;

    kadath_runtime_phase_activation_result_v1_t activation_result;
    memset(&activation_result, 0, sizeof(activation_result));
    activation_result.struct_size = (uint32_t)sizeof(activation_result);
    if (phase_interface->commit_activation(core, transaction.transaction_id, &activation_result) != KADATH_OK ||
        activation_result.accepted_structural_count != 2U ||
        activation_result.cancelled_structural_count != 1U) return 218;

    kadath_runtime_phase_structural_v1_t pair[2];
    kadath_runtime_phase_flush_info_v1_t pair_flush;
    size_t pair_count = 0U;
    memset(pair, 0, sizeof(pair));
    memset(&pair_flush, 0, sizeof(pair_flush));
    pair[0].struct_size = (uint32_t)sizeof(pair[0]);
    pair[1].struct_size = (uint32_t)sizeof(pair[1]);
    pair_flush.struct_size = (uint32_t)sizeof(pair_flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence, &pair_flush,
                                         pair, 2U, &pair_count) != KADATH_OK || pair_count != 2U ||
        pair[0].operation != KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT ||
        pair[1].operation != KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION) return 219;
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, pair_flush.flush_token, pair[0].sequence,
                                          &transaction) != KADATH_OK) return 220;
    memset(&activation_batch, 0, sizeof(activation_batch));
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK) return 221;
    memset(&activation_result, 0, sizeof(activation_result));
    activation_result.struct_size = (uint32_t)sizeof(activation_result);
    if (phase_interface->commit_activation(core, transaction.transaction_id, &activation_result) != KADATH_OK ||
        activation_result.root_object.struct_size != 0U ||
        activation_result.cancelled_structural_count != 1U) return 222;

    kadath_runtime_phase_request_completion_v1_t discard_completion;
    memset(&discard_completion, 0, sizeof(discard_completion));
    discard_completion.struct_size = (uint32_t)sizeof(discard_completion);
    discard_completion.status = KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED;
    discard_completion.sequence = pair[1].sequence;
    if (phase_interface->complete_structural(core, pair_flush.flush_token, &discard_completion, 1U, 0U) != KADATH_OK ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 223;
    return 0;
}

static int activation_abort_preserves_identity_high_water(
    kadath_runtime_object_authority_interface_t* object_interface,
    kadath_runtime_phase_interface_v1_t* phase_interface) {
    kadath_runtime_core_t* core = NULL;
    if (create_live_core(object_interface, &core) != 0) return 240;
    kadath_runtime_query_result_t player_result;
    if (query_id(object_interface, core, "player", &player_result) != KADATH_OK) return 241;

    kadath_runtime_phase_begin_desc_v1_t begin;
    kadath_runtime_phase_begin_result_v1_t begin_result;
    memset(&begin, 0, sizeof(begin));
    memset(&begin_result, 0, sizeof(begin_result));
    begin.struct_size = (uint32_t)sizeof(begin);
    begin.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    begin_result.struct_size = (uint32_t)sizeof(begin_result);
    if (phase_interface->begin_phase(core, &begin, &begin_result) != KADATH_OK) return 242;
    const uint64_t phase_sequence = begin_result.phase_sequence;

    kadath_runtime_phase_structural_v1_t root;
    kadath_runtime_phase_request_completion_v1_t acceptance;
    kadath_runtime_phase_batch_result_v1_t batch_result;
    memset(&root, 0, sizeof(root));
    memset(&acceptance, 0, sizeof(acceptance));
    memset(&batch_result, 0, sizeof(batch_result));
    root.struct_size = (uint32_t)sizeof(root);
    root.operation = KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT;
    root.domain = KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    root.behavior_count = 1U;
    root.prototype_key = 41U;
    root.origin = player_result.payload.object.object_ref;
    root.transient_sprite.struct_size = (uint32_t)sizeof(root.transient_sprite);
    root.transient_sprite.size[0] = 2.0F;
    root.transient_sprite.size[1] = 2.0F;
    root.transient_sprite.color[3] = 1.0F;
    root.transient_sprite.texture_id = 1U;
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    batch_result.struct_size = (uint32_t)sizeof(batch_result);
    if (phase_interface->submit_structural(core, &root, 1U, sizeof(root),
                                           &acceptance, 1U, &batch_result) != KADATH_OK) return 243;

    kadath_runtime_phase_structural_v1_t taken;
    kadath_runtime_phase_flush_info_v1_t flush;
    size_t taken_count = 0U;
    memset(&taken, 0, sizeof(taken));
    memset(&flush, 0, sizeof(flush));
    taken.struct_size = (uint32_t)sizeof(taken);
    flush.struct_size = (uint32_t)sizeof(flush);
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence,
                                         &flush, &taken, 1U, &taken_count) != KADATH_OK ||
        taken_count != 1U) return 244;

    kadath_runtime_phase_transaction_info_v1_t transaction;
    memset(&transaction, 0, sizeof(transaction));
    transaction.struct_size = (uint32_t)sizeof(transaction);
    if (phase_interface->begin_activation(core, flush.flush_token, taken.sequence,
                                          &transaction) != KADATH_OK) return 245;

    kadath_runtime_phase_structural_v1_t nested = root;
    kadath_runtime_phase_activation_structural_result_v1_t nested_result;
    kadath_runtime_phase_activation_batch_v1_t activation_batch;
    memset(&nested_result, 0, sizeof(nested_result));
    memset(&activation_batch, 0, sizeof(activation_batch));
    nested.prototype_key = 43U;
    nested.sequence = 0U;
    memset(&nested.object_ref, 0, sizeof(nested.object_ref));
    nested_result.struct_size = (uint32_t)sizeof(nested_result);
    activation_batch.struct_size = (uint32_t)sizeof(activation_batch);
    activation_batch.transaction_id = transaction.transaction_id;
    activation_batch.active_binding_capacity = KADATH_RUNTIME_PHASE_MAX_BINDINGS;
    activation_batch.structural = &nested;
    activation_batch.structural_count = 1U;
    activation_batch.structural_stride = sizeof(nested);
    activation_batch.structural_results = &nested_result;
    activation_batch.structural_result_capacity = 1U;
    if (phase_interface->submit_activation(core, transaction.transaction_id, &activation_batch) != KADATH_OK ||
        nested_result.object_ref.object_id_length == 0U ||
        phase_interface->abort_activation(core, transaction.transaction_id) != KADATH_OK) return 246;

    memset(&acceptance, 0, sizeof(acceptance));
    memset(&batch_result, 0, sizeof(batch_result));
    acceptance.struct_size = (uint32_t)sizeof(acceptance);
    batch_result.struct_size = (uint32_t)sizeof(batch_result);
    if (phase_interface->submit_structural(core, &root, 1U, sizeof(root),
                                           &acceptance, 1U, &batch_result) != KADATH_OK ||
        memcmp(&acceptance.object.object_ref, &nested_result.object_ref,
               sizeof(nested_result.object_ref)) == 0) return 247;
    memset(&taken, 0, sizeof(taken));
    memset(&flush, 0, sizeof(flush));
    taken.struct_size = (uint32_t)sizeof(taken);
    flush.struct_size = (uint32_t)sizeof(flush);
    taken_count = 0U;
    if (phase_interface->take_structural(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence,
                                         &flush, &taken, 1U, &taken_count) != KADATH_OK ||
        taken_count != 1U ||
        phase_interface->abort_structural(core, flush.flush_token) != KADATH_OK ||
        phase_interface->end_phase(core, KADATH_RUNTIME_PHASE_DOMAIN_FIXED, phase_sequence) != KADATH_OK ||
        object_interface->destroy(&core) != KADATH_OK || core != NULL) return 248;
    return 0;
}

int main(void) {
    kadath_runtime_object_authority_interface_t interface_value = query_interface();
    if (interface_value.create == NULL || interface_value.destroy == NULL ||
        interface_value.prepare_scene == NULL || interface_value.commit_scene == NULL ||
        interface_value.abort_scene == NULL || interface_value.query == NULL ||
        interface_value.mutate == NULL) {
        return 1;
    }
    kadath_runtime_phase_interface_v1_t phase_interface = query_phase_interface();
    if (phase_interface.prepare_phase_state == NULL || phase_interface.begin_phase == NULL ||
        phase_interface.submit_events == NULL || phase_interface.submit_structural == NULL ||
        phase_interface.begin_activation == NULL || phase_interface.end_phase == NULL) {
        return 2;
    }
    kadath_runtime_gameplay_interface_v1_t gameplay_interface;
    memset(&gameplay_interface, 0, sizeof(gameplay_interface));
    gameplay_interface.struct_size = (uint32_t)sizeof(gameplay_interface);
    gameplay_interface.interface_version = KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1;
    if (kadath_runtime_core_query_gameplay_interface(&gameplay_interface) != KADATH_OK ||
        gameplay_interface.prepare_gameplay_state == NULL ||
        gameplay_interface.begin_fixed_step == NULL ||
        gameplay_interface.commit_fixed_step == NULL ||
        gameplay_interface.abort_fixed_step == NULL ||
        gameplay_interface.publish_snapshot == NULL) {
        return 3;
    }
    int normal_result = normal_path(&interface_value);
    if (normal_result != 0) {
        return normal_result;
    }
    int transient_result = transient_lifecycle(&interface_value);
    if (transient_result != 0) {
        return transient_result;
    }
    int restart_result = restart_and_reload(&interface_value);
    if (restart_result != 0) {
        return restart_result;
    }
    int world_result = world_and_position_batch(&interface_value);
    if (world_result != 0) return world_result;
    int activation_result = activation_batch_atomic(&interface_value);
    if (activation_result != 0) return activation_result;
    int query_result = query_batch_atomic(&interface_value);
    if (query_result != 0) return query_result;
    int gameplay_result = gameplay_contract_path(&interface_value, &phase_interface, &gameplay_interface);
    if (gameplay_result != 0) return gameplay_result;
    puts("PHASE3_PUBLIC_GAMEPLAY_PATH=PASS");
    int phase_result = phase_commit_path(&interface_value, &phase_interface);
    if (phase_result != 0) return phase_result;
    puts("PHASE3_PUBLIC_PHASE_COMMIT_PATH=PASS");
    int paired_abort_result = aborted_scene_discards_paired_phase_candidate(
        &interface_value, &phase_interface);
    if (paired_abort_result != 0) return paired_abort_result;
    puts("PHASE3_PUBLIC_PAIRED_ABORT=PASS");
    int discard_result = activation_discard_path(&interface_value, &phase_interface);
    if (discard_result != 0) return discard_result;
    puts("PHASE3_PUBLIC_ACTIVATION_DISCARD=PASS");
    int high_water_result = activation_abort_preserves_identity_high_water(&interface_value, &phase_interface);
    if (high_water_result != 0) return high_water_result;
    puts("PHASE3_PUBLIC_SERIAL_HIGH_WATER=PASS");
    int fault_result = fault_containment(&interface_value);
    if (fault_result != 0) return fault_result;
    puts("PHASE3_PUBLIC_FAULT_CONTAINMENT=PASS");
    int misuse_result = misuse_contract(&interface_value);
    if (misuse_result != 0) return misuse_result;
    puts("PHASE3_PUBLIC_MISUSE=PASS");
    return 0;
}
