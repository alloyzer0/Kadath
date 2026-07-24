#ifndef KADATH_WORLD_H
#define KADATH_WORLD_H

#include <stddef.h>
#include <stdint.h>

#include "kadath_errors.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kadath_world_opaque_t kadath_world_opaque_t;
typedef kadath_world_opaque_t* kadath_world_t;
typedef uint64_t kadath_entity_id_t;
typedef uint32_t kadath_resource_id_t;

#define KADATH_ENTITY_INVALID 0ULL
#define KADATH_RESOURCE_INVALID 0U

typedef struct kadath_world_input_snapshot_t {
    int8_t move_x;
    int8_t move_y;
} kadath_world_input_snapshot_t;

typedef struct kadath_world_bounds_t {
    float min[2];
    float max[2];
} kadath_world_bounds_t;

typedef struct kadath_world_position_t {
    float value[2];
} kadath_world_position_t;

typedef struct kadath_world_sprite_spawn_desc_t {
    float position[2];
    float size[2];
    float color[4];
    kadath_resource_id_t texture_id;
    float move_speed;
} kadath_world_sprite_spawn_desc_t;

typedef struct kadath_world_render_sprite_t {
    kadath_entity_id_t entity_id;
    float position[2];
    float size[2];
    float color[4];
    kadath_resource_id_t texture_id;
} kadath_world_render_sprite_t;

// Thread-compatible: different worlds may be used concurrently; the same world may not.
// Ownership: on success, the caller owns out_world and must call kadath_world_destroy.
int32_t kadath_world_create(kadath_world_t* out_world);

// Thread-compatible. Ownership: consumes the world handle exactly once.
int32_t kadath_world_destroy(kadath_world_t world);

// Thread-compatible. Bounds are copied during this call and immediately constrain live sprites.
int32_t kadath_world_set_bounds(
    kadath_world_t world,
    const kadath_world_bounds_t* bounds
);

// Thread-compatible. Position is copied during this call and bounds are applied.
int32_t kadath_world_set_sprite_position(
    kadath_world_t world,
    kadath_entity_id_t entity,
    const kadath_world_position_t* position
);

// Thread-compatible. The descriptor is borrowed for the duration of this call.
int32_t kadath_world_spawn_sprite(
    kadath_world_t world,
    const kadath_world_sprite_spawn_desc_t* desc,
    kadath_entity_id_t* out_entity
);

// Thread-compatible. The descriptor is borrowed for this call and out_replacement
// is caller-owned. Success atomically invalidates old_entity and writes one new ID;
// every failure leaves the old entity and out_replacement unchanged.
int32_t kadath_world_replace_sprite(
    kadath_world_t world,
    kadath_entity_id_t old_entity,
    const kadath_world_sprite_spawn_desc_t* replacement_desc,
    kadath_entity_id_t* out_replacement
);

// Thread-compatible. The input POD is borrowed for the duration of this call.
int32_t kadath_world_step_fixed(
    kadath_world_t world,
    float dt_seconds,
    const kadath_world_input_snapshot_t* input
);

// Thread-compatible. Invalid or stale generation IDs return KADATH_ERR_WORLD_INVALID_ENTITY.
int32_t kadath_world_despawn(kadath_world_t world, kadath_entity_id_t entity);

// Thread-compatible. out_sprites is caller-owned and written only during this call.
int32_t kadath_world_extract_sprites(
    kadath_world_t world,
    kadath_world_render_sprite_t* out_sprites,
    size_t capacity,
    size_t* out_count
);

#ifdef __cplusplus
}
#endif

#endif
