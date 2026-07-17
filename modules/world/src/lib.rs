use std::panic::{catch_unwind, AssertUnwindSafe};

#[allow(non_camel_case_types, non_upper_case_globals, dead_code)]
mod abi {
    include!(concat!(env!("OUT_DIR"), "/kadath_world_bindings.rs"));
}

const INDEX_MASK: u64 = u32::MAX as u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorldError {
    InvalidArgument,
    InvalidEntity,
    OutOfMemory,
}

#[derive(Clone, Copy)]
struct SpriteRecord {
    position: [f32; 2],
    size: [f32; 2],
    color: [f32; 4],
    texture_id: abi::kadath_resource_id_t,
    move_speed: f32,
}

struct EntitySlot {
    generation: u32,
    sprite: Option<SpriteRecord>,
}

#[derive(Default)]
struct WorldState {
    slots: Vec<EntitySlot>,
    free_indices: Vec<u32>,
}

impl WorldState {
    fn spawn_sprite(
        &mut self,
        desc: &abi::kadath_world_sprite_spawn_desc_t,
    ) -> Result<abi::kadath_entity_id_t, WorldError> {
        if desc.texture_id == abi::KADATH_RESOURCE_INVALID
            || !desc.move_speed.is_finite()
            || desc.move_speed < 0.0
        {
            return Err(WorldError::InvalidArgument);
        }

        let record = SpriteRecord {
            position: desc.position,
            size: desc.size,
            color: desc.color,
            texture_id: desc.texture_id,
            move_speed: desc.move_speed,
        };

        if let Some(index) = self.free_indices.pop() {
            let slot = &mut self.slots[index as usize];
            slot.sprite = Some(record);
            return Ok(encode_entity(index, slot.generation));
        }

        self.slots
            .try_reserve(1)
            .map_err(|_| WorldError::OutOfMemory)?;
        let index = u32::try_from(self.slots.len()).map_err(|_| WorldError::OutOfMemory)?;
        self.slots.push(EntitySlot {
            generation: 1,
            sprite: Some(record),
        });
        Ok(encode_entity(index, 1))
    }

    fn step_fixed(
        &mut self,
        dt_seconds: f32,
        input: &abi::kadath_world_input_snapshot_t,
    ) -> Result<(), WorldError> {
        if !dt_seconds.is_finite()
            || dt_seconds < 0.0
            || !(-1..=1).contains(&input.move_x)
            || !(-1..=1).contains(&input.move_y)
        {
            return Err(WorldError::InvalidArgument);
        }
        for slot in &mut self.slots {
            let Some(sprite) = slot.sprite.as_mut() else {
                continue;
            };
            sprite.position[0] += f32::from(input.move_x) * sprite.move_speed * dt_seconds;
            sprite.position[1] += f32::from(input.move_y) * sprite.move_speed * dt_seconds;
        }
        Ok(())
    }
    fn despawn(&mut self, entity: abi::kadath_entity_id_t) -> Result<(), WorldError> {
        let (index, generation) = decode_entity(entity).ok_or(WorldError::InvalidEntity)?;
        self.free_indices
            .try_reserve(1)
            .map_err(|_| WorldError::OutOfMemory)?;
        let slot = self
            .slots
            .get_mut(index as usize)
            .filter(|slot| slot.generation == generation && slot.sprite.is_some())
            .ok_or(WorldError::InvalidEntity)?;

        slot.sprite = None;
        slot.generation = slot.generation.wrapping_add(1).max(1);
        self.free_indices.push(index);
        Ok(())
    }

    fn extract_sprites(
        &self,
        output: &mut [abi::kadath_world_render_sprite_t],
    ) -> Result<usize, i32> {
        let count = self
            .slots
            .iter()
            .filter(|slot| slot.sprite.is_some())
            .count();
        if output.len() < count {
            return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL as i32);
        }

        let mut written = 0;
        for (index, slot) in self.slots.iter().enumerate() {
            let Some(sprite) = slot.sprite else {
                continue;
            };
            output[written] = abi::kadath_world_render_sprite_t {
                entity_id: encode_entity(index as u32, slot.generation),
                position: sprite.position,
                size: sprite.size,
                color: sprite.color,
                texture_id: sprite.texture_id,
            };
            written += 1;
        }
        Ok(written)
    }
}

fn encode_entity(index: u32, generation: u32) -> abi::kadath_entity_id_t {
    ((generation as u64) << 32) | index as u64
}

fn decode_entity(entity: abi::kadath_entity_id_t) -> Option<(u32, u32)> {
    if entity == abi::KADATH_ENTITY_INVALID as abi::kadath_entity_id_t {
        return None;
    }
    let index = (entity & INDEX_MASK) as u32;
    let generation = (entity >> 32) as u32;
    (generation != 0).then_some((index, generation))
}

fn error_code(error: WorldError) -> i32 {
    match error {
        WorldError::InvalidArgument => abi::KADATH_ERR_INVALID_ARGUMENT as i32,
        WorldError::InvalidEntity => abi::KADATH_ERR_WORLD_INVALID_ENTITY as i32,
        WorldError::OutOfMemory => abi::KADATH_ERR_OUT_OF_MEMORY as i32,
    }
}

fn ffi_boundary(operation: impl FnOnce() -> i32) -> i32 {
    // Rust panic 绝不能越过 C ABI；所有导出入口统一在这里收敛为稳定错误码。
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(abi::KADATH_ERR_INTERNAL as i32)
}

#[no_mangle]
pub extern "C" fn kadath_world_create(out_world: *mut abi::kadath_world_t) -> i32 {
    ffi_boundary(|| {
        let Some(out_world) = (unsafe { out_world.as_mut() }) else {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        };
        let world = Box::new(WorldState::default());
        *out_world = Box::into_raw(world).cast::<abi::kadath_world_opaque_t>();
        abi::KADATH_OK as i32
    })
}

#[no_mangle]
pub extern "C" fn kadath_world_destroy(world: abi::kadath_world_t) -> i32 {
    ffi_boundary(|| {
        if world.is_null() {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        }
        // create 转移给调用方的唯一所有权在此收回；同一 handle 只能 destroy 一次。
        unsafe { drop(Box::from_raw(world.cast::<WorldState>())) };
        abi::KADATH_OK as i32
    })
}

#[no_mangle]
pub extern "C" fn kadath_world_spawn_sprite(
    world: abi::kadath_world_t,
    desc: *const abi::kadath_world_sprite_spawn_desc_t,
    out_entity: *mut abi::kadath_entity_id_t,
) -> i32 {
    ffi_boundary(|| {
        let (Some(world), Some(desc), Some(out_entity)) = (
            unsafe { world.cast::<WorldState>().as_mut() },
            unsafe { desc.as_ref() },
            unsafe { out_entity.as_mut() },
        ) else {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        };
        match world.spawn_sprite(desc) {
            Ok(entity) => {
                *out_entity = entity;
                abi::KADATH_OK as i32
            }
            Err(error) => error_code(error),
        }
    })
}

#[no_mangle]
pub extern "C" fn kadath_world_step_fixed(
    world: abi::kadath_world_t,
    dt_seconds: f32,
    input: *const abi::kadath_world_input_snapshot_t,
) -> i32 {
    ffi_boundary(|| {
        let (Some(world), Some(input)) = (unsafe { world.cast::<WorldState>().as_mut() }, unsafe {
            input.as_ref()
        }) else {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        };
        world
            .step_fixed(dt_seconds, input)
            .map(|()| abi::KADATH_OK as i32)
            .unwrap_or_else(error_code)
    })
}
#[no_mangle]
pub extern "C" fn kadath_world_despawn(
    world: abi::kadath_world_t,
    entity: abi::kadath_entity_id_t,
) -> i32 {
    ffi_boundary(|| {
        let Some(world) = (unsafe { world.cast::<WorldState>().as_mut() }) else {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        };
        world
            .despawn(entity)
            .map(|()| abi::KADATH_OK as i32)
            .unwrap_or_else(error_code)
    })
}

#[no_mangle]
pub extern "C" fn kadath_world_extract_sprites(
    world: abi::kadath_world_t,
    out_sprites: *mut abi::kadath_world_render_sprite_t,
    capacity: usize,
    out_count: *mut usize,
) -> i32 {
    ffi_boundary(|| {
        let (Some(world), Some(out_count)) =
            (unsafe { world.cast::<WorldState>().as_ref() }, unsafe {
                out_count.as_mut()
            })
        else {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        };
        if capacity > 0 && out_sprites.is_null() {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        }

        let output = if capacity == 0 {
            &mut []
        } else {
            // 指针仅在本次调用内借用，长度由 caller 提供并受 C ABI 契约约束。
            unsafe { std::slice::from_raw_parts_mut(out_sprites, capacity) }
        };
        match world.extract_sprites(output) {
            Ok(count) => {
                *out_count = count;
                abi::KADATH_OK as i32
            }
            Err(code) => code,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sprite_desc(texture_id: u32) -> abi::kadath_world_sprite_spawn_desc_t {
        abi::kadath_world_sprite_spawn_desc_t {
            position: [10.0, 20.0],
            size: [32.0, 48.0],
            color: [1.0, 0.5, 0.25, 1.0],
            texture_id,
            move_speed: 100.0,
        }
    }

    #[test]
    fn spawn_and_extract_sprite_snapshot() {
        let mut world = WorldState::default();
        let entity = world.spawn_sprite(&sprite_desc(7)).unwrap();
        let mut output = [abi::kadath_world_render_sprite_t::default(); 1];
        assert_eq!(world.extract_sprites(&mut output), Ok(1));
        assert_eq!(output[0].entity_id, entity);
        assert_eq!(output[0].position, [10.0, 20.0]);
        assert_eq!(output[0].texture_id, 7);
    }

    #[test]
    fn generation_rejects_stale_entity_id() {
        let mut world = WorldState::default();
        let stale = world.spawn_sprite(&sprite_desc(1)).unwrap();
        world.despawn(stale).unwrap();
        assert_eq!(world.despawn(stale), Err(WorldError::InvalidEntity));

        let replacement = world.spawn_sprite(&sprite_desc(1)).unwrap();
        assert_ne!(replacement, stale);
        assert_eq!(replacement as u32, stale as u32);
    }

    #[test]
    fn fixed_step_is_deterministic_and_zero_input_is_stable() {
        let mut first = WorldState::default();
        let mut second = WorldState::default();
        first.spawn_sprite(&sprite_desc(1)).unwrap();
        second.spawn_sprite(&sprite_desc(1)).unwrap();
        let input = abi::kadath_world_input_snapshot_t {
            move_x: -1,
            move_y: 0,
        };
        for _ in 0..10 {
            first.step_fixed(1.0 / 60.0, &input).unwrap();
            second.step_fixed(1.0 / 60.0, &input).unwrap();
        }

        let zero = abi::kadath_world_input_snapshot_t {
            move_x: 0,
            move_y: 0,
        };
        first.step_fixed(1.0, &zero).unwrap();
        second.step_fixed(1.0, &zero).unwrap();
        let mut first_output = [abi::kadath_world_render_sprite_t::default(); 1];
        let mut second_output = [abi::kadath_world_render_sprite_t::default(); 1];
        first.extract_sprites(&mut first_output).unwrap();
        second.extract_sprites(&mut second_output).unwrap();
        assert_eq!(first_output[0].position, second_output[0].position);
    }
    #[test]
    fn fixed_step_moves_sprite_from_input_snapshot() {
        let mut world = WorldState::default();
        let entity = world.spawn_sprite(&sprite_desc(1)).unwrap();
        let input = abi::kadath_world_input_snapshot_t {
            move_x: 1,
            move_y: -1,
        };
        world.step_fixed(0.5, &input).unwrap();

        let mut output = [abi::kadath_world_render_sprite_t::default(); 1];
        world.extract_sprites(&mut output).unwrap();
        assert_eq!(output[0].entity_id, entity);
        assert_eq!(output[0].position, [60.0, -30.0]);
    }
    #[test]
    fn extract_reports_small_caller_buffer() {
        let mut world = WorldState::default();
        world.spawn_sprite(&sprite_desc(1)).unwrap();
        assert_eq!(
            world.extract_sprites(&mut []),
            Err(abi::KADATH_ERR_BUFFER_TOO_SMALL as i32)
        );
    }
}
