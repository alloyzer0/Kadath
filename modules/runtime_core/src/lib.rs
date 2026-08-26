#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod gameplay;
mod object_authority;
mod phase_commit;
mod world;

use object_authority::{
    AuthorityError, DestroyDisposition, ObjectId, ObjectKey, RuntimeState, SourceObject,
    MAX_OBJECTS,
};
use std::{
    alloc::{alloc, Layout},
    mem,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    thread::{self, ThreadId},
};
use world::{Bounds, Sprite};

#[cfg(feature = "phase-quality-evidence")]
mod quality_evidence {
    use crate::abi;
    use std::{
        alloc::{GlobalAlloc, Layout, System},
        sync::atomic::{AtomicBool, AtomicU64, Ordering},
    };

    pub(crate) struct CountingAllocator;
    static ENABLED: AtomicBool = AtomicBool::new(false);
    static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

    unsafe impl GlobalAlloc for CountingAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if ENABLED.load(Ordering::Relaxed) {
                ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
            }
            unsafe { System.alloc(layout) }
        }

        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            if ENABLED.load(Ordering::Relaxed) {
                ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
            }
            unsafe { System.alloc_zeroed(layout) }
        }

        unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
            unsafe { System.dealloc(pointer, layout) };
        }

        unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            if ENABLED.load(Ordering::Relaxed) {
                ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
            }
            unsafe { System.realloc(pointer, layout, new_size) }
        }
    }

    #[no_mangle]
    pub extern "C" fn kadath_runtime_core_phase_quality_begin_allocation_count() -> i32 {
        ALLOCATIONS.store(0, Ordering::SeqCst);
        ENABLED.store(true, Ordering::SeqCst);
        0
    }

    #[no_mangle]
    pub extern "C" fn kadath_runtime_core_phase_quality_end_allocation_count(
        out_allocation_count: *mut u64,
    ) -> i32 {
        if out_allocation_count.is_null()
            || (out_allocation_count as usize) % std::mem::align_of::<u64>() != 0
        {
            return abi::KADATH_ERR_INVALID_ARGUMENT as i32;
        }
        ENABLED.store(false, Ordering::SeqCst);
        unsafe { out_allocation_count.write(ALLOCATIONS.load(Ordering::SeqCst)) };
        0
    }
}

#[cfg(feature = "phase-quality-evidence")]
#[global_allocator]
static PHASE_QUALITY_ALLOCATOR: quality_evidence::CountingAllocator =
    quality_evidence::CountingAllocator;

#[allow(non_camel_case_types, non_upper_case_globals, dead_code)]
mod abi {
    include!(concat!(env!("OUT_DIR"), "/kadath_runtime_core_bindings.rs"));
}

struct RuntimeCore {
    owner_thread: ThreadId,
    in_call: bool,
    live: Option<RuntimeState>,
    candidate: Option<RuntimeState>,
    candidate_next_entity_value: Option<u64>,
    candidate_mode: Option<u32>,
    next_entity_value: u64,
    phase: Box<phase_commit::PhaseState>,
    gameplay: Option<gameplay::State>,
    gameplay_candidate: Option<gameplay::State>,
    #[cfg(feature = "contract-test-hooks")]
    next_fault: Option<TestFault>,
}

#[cfg(feature = "contract-test-hooks")]
#[derive(Clone, Copy)]
struct TestFault {
    entry: u32,
    fault: u32,
}

const TEST_ENTRY_PREPARE: u32 = 1;
const TEST_ENTRY_QUERY: u32 = 2;
const TEST_ENTRY_MUTATE: u32 = 3;
#[cfg(feature = "contract-test-hooks")]
const TEST_FAULT_PANIC_BEFORE_PUBLICATION: u32 = 1;
#[cfg(feature = "contract-test-hooks")]
const TEST_FAULT_ALLOCATION_FAILURE: u32 = 2;

struct CallGuard(*mut RuntimeCore);

impl Drop for CallGuard {
    fn drop(&mut self) {
        unsafe { (*self.0).in_call = false };
    }
}

fn error(code: u32) -> i32 {
    code as i32
}

fn reserved_is_zero(values: &[u64]) -> bool {
    values.iter().all(|value| *value == 0)
}

unsafe fn read_struct_size<T>(pointer: *const T) -> Result<u32, u32> {
    if pointer.is_null() || (pointer as usize) % mem::align_of::<T>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(ptr::read(pointer.cast::<u32>()))
}

#[cfg(feature = "contract-test-hooks")]
fn trigger_test_fault(core: &mut RuntimeCore, entry: u32) -> Result<(), u32> {
    if core.next_fault.is_none_or(|fault| fault.entry != entry) {
        return Ok(());
    }
    let fault = core.next_fault.take().expect("matching test fault exists");
    match fault.fault {
        TEST_FAULT_PANIC_BEFORE_PUBLICATION => panic!("contract-test panic before publication"),
        TEST_FAULT_ALLOCATION_FAILURE => Err(abi::KADATH_ERR_OUT_OF_MEMORY),
        _ => unreachable!("test fault was validated when armed"),
    }
}

#[cfg(not(feature = "contract-test-hooks"))]
fn trigger_test_fault(_core: &mut RuntimeCore, _entry: u32) -> Result<(), u32> {
    Ok(())
}

unsafe fn enter_core(
    core: *mut abi::kadath_runtime_core_t,
) -> Result<(&'static mut RuntimeCore, CallGuard), u32> {
    if core.is_null() || (core as usize) % mem::align_of::<RuntimeCore>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let core = core
        .cast::<RuntimeCore>()
        .as_mut()
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if core.owner_thread != thread::current().id() {
        return Err(abi::KADATH_ERR_RUNTIME_WRONG_THREAD);
    }
    if core.in_call {
        return Err(abi::KADATH_ERR_RUNTIME_REENTRANT);
    }
    core.in_call = true;
    let pointer = core as *mut RuntimeCore;
    Ok((core, CallGuard(pointer)))
}

fn create(
    desc: *const abi::kadath_runtime_core_create_desc_t,
    out_core: *mut *mut abi::kadath_runtime_core_t,
) -> Result<(), u32> {
    if desc.is_null()
        || out_core.is_null()
        || (desc as usize) % mem::align_of::<abi::kadath_runtime_core_create_desc_t>() != 0
        || (out_core as usize) % mem::align_of::<*mut abi::kadath_runtime_core_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_size = unsafe { read_struct_size(desc) }?;
    if desc_size < mem::size_of::<abi::kadath_runtime_core_create_desc_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_core_create_desc_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_core as usize,
        1,
        1,
        mem::size_of::<*mut abi::kadath_runtime_core_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(desc_range, output_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc };
    if desc.reserved0 != 0 || !reserved_is_zero(&desc.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let core = RuntimeCore {
        owner_thread: thread::current().id(),
        in_call: false,
        live: None,
        candidate: None,
        candidate_next_entity_value: None,
        candidate_mode: None,
        next_entity_value: 1,
        phase: phase_commit::PhaseState::new_boxed()?,
        gameplay: None,
        gameplay_candidate: None,
        #[cfg(feature = "contract-test-hooks")]
        next_fault: None,
    };
    let allocation = unsafe { alloc(Layout::new::<RuntimeCore>()) }.cast::<RuntimeCore>();
    if allocation.is_null() {
        return Err(abi::KADATH_ERR_OUT_OF_MEMORY);
    }
    unsafe { ptr::write(allocation, core) };
    unsafe { ptr::write(out_core, allocation.cast()) };
    Ok(())
}

fn destroy(in_out_core: *mut *mut abi::kadath_runtime_core_t) -> Result<(), u32> {
    if in_out_core.is_null()
        || (in_out_core as usize) % mem::align_of::<*mut abi::kadath_runtime_core_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let pointer = unsafe { ptr::read(in_out_core) };
    if pointer.is_null() {
        return Ok(());
    }
    if (pointer as usize) % mem::align_of::<RuntimeCore>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let core = unsafe { pointer.cast::<RuntimeCore>().as_mut() }
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if core.owner_thread != thread::current().id() {
        return Err(abi::KADATH_ERR_RUNTIME_WRONG_THREAD);
    }
    if core.in_call {
        return Err(abi::KADATH_ERR_RUNTIME_REENTRANT);
    }
    unsafe { drop(Box::from_raw(pointer.cast::<RuntimeCore>())) };
    unsafe { ptr::write(in_out_core, ptr::null_mut()) };
    Ok(())
}

fn read_source_objects(
    desc: &abi::kadath_runtime_scene_prepare_desc_t,
) -> Result<Vec<SourceObject>, u32> {
    if desc.source_object_count == 0
        || desc.source_object_count > MAX_OBJECTS
        || desc.source_objects.is_null()
        || (desc.source_objects as usize)
            % mem::align_of::<abi::kadath_runtime_source_object_desc_v1_t>()
            != 0
        || desc.source_object_stride < mem::size_of::<abi::kadath_runtime_source_object_desc_v1_t>()
        || desc.source_object_stride
            % mem::align_of::<abi::kadath_runtime_source_object_desc_v1_t>()
            != 0
        || strided_range(
            desc.source_objects as usize,
            desc.source_object_count,
            desc.source_object_stride,
            mem::size_of::<abi::kadath_runtime_source_object_desc_v1_t>(),
        )
        .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let mut sources = Vec::new();
    sources
        .try_reserve_exact(desc.source_object_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    for index in 0..desc.source_object_count {
        let offset = index
            .checked_mul(desc.source_object_stride)
            .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
        let source_pointer = unsafe {
            desc.source_objects
                .cast::<u8>()
                .add(offset)
                .cast::<abi::kadath_runtime_source_object_desc_v1_t>()
        };
        let source_size = unsafe { read_struct_size(source_pointer) }?;
        if source_size < mem::size_of::<abi::kadath_runtime_source_object_desc_v1_t>() as u32 {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let source = unsafe { &*source_pointer };
        if source.sprite.struct_size < mem::size_of::<abi::kadath_runtime_sprite_desc_v1_t>() as u32
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let descriptor_invalid = source.reserved0 != 0
            || !reserved_is_zero(&source.reserved)
            || source.object_id_length == 0
            || source.object_id_length as usize > object_authority::MAX_OBJECT_ID_BYTES
            || source.object_id[source.object_id_length as usize..]
                .iter()
                .any(|byte| *byte != 0)
            || source.sprite.reserved0 != 0
            || source.sprite.reserved.iter().any(|value| *value != 0)
            || !(abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE
                ..=abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD)
                .contains(&source.kind);
        if descriptor_invalid {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let object_id = ObjectId::parse(&source.object_id[..source.object_id_length as usize])
            .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
        if sources
            .iter()
            .any(|existing: &SourceObject| existing.object_id == object_id)
        {
            return Err(abi::KADATH_ERR_RUNTIME_DUPLICATE_OBJECT_ID);
        }
        let sprite = Sprite {
            position: source.sprite.position,
            size: source.sprite.size,
            color: source.sprite.color,
            texture_id: source.sprite.texture_id,
            move_speed: source.sprite.move_speed,
        };
        if !sprite.is_valid()
            || (source.kind == abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER && sprite.move_speed < 0.0)
            || (source.kind != abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER && sprite.move_speed != 0.0)
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        sources.push(SourceObject {
            object_id,
            kind: source.kind,
            sprite,
        });
    }
    Ok(sources)
}

fn prepare_scene(
    core_pointer: *mut abi::kadath_runtime_core_t,
    desc: *const abi::kadath_runtime_scene_prepare_desc_t,
    out_info: *mut abi::kadath_runtime_scene_candidate_info_t,
) -> Result<(), u32> {
    if core_pointer.is_null()
        || desc.is_null()
        || out_info.is_null()
        || (desc as usize) % mem::align_of::<abi::kadath_runtime_scene_prepare_desc_t>() != 0
        || (out_info as usize) % mem::align_of::<abi::kadath_runtime_scene_candidate_info_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let desc_size = unsafe { read_struct_size(desc) }?;
    let output_size = unsafe { read_struct_size(out_info) }?;
    if desc_size < mem::size_of::<abi::kadath_runtime_scene_prepare_desc_t>() as u32
        || output_size < mem::size_of::<abi::kadath_runtime_scene_candidate_info_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc };
    if !reserved_is_zero(&desc.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if !matches!(
        desc.mode,
        abi::KADATH_RUNTIME_PREPARE_INITIAL
            | abi::KADATH_RUNTIME_PREPARE_RESTART
            | abi::KADATH_RUNTIME_PREPARE_SCENE_RELOAD
    ) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if desc.source_objects.is_null()
        || desc.source_object_count == 0
        || desc.source_object_count > MAX_OBJECTS
        || (desc.source_objects as usize)
            % mem::align_of::<abi::kadath_runtime_source_object_desc_v1_t>()
            != 0
        || desc.source_object_stride < mem::size_of::<abi::kadath_runtime_source_object_desc_v1_t>()
        || desc.source_object_stride
            % mem::align_of::<abi::kadath_runtime_source_object_desc_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc as *const _ as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_scene_prepare_desc_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let source_range = strided_range(
        desc.source_objects as usize,
        desc.source_object_count,
        desc.source_object_stride,
        mem::size_of::<abi::kadath_runtime_source_object_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_info as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_scene_candidate_info_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(source_range, desc_range)
        || ranges_overlap(source_range, output_range)
        || ranges_overlap(desc_range, output_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let bounds =
        Bounds::new(desc.bounds_min, desc.bounds_max).ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let sources = read_source_objects(desc)?;
    if core.candidate.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_CANDIDATE_BUSY);
    }
    let first_entity = core.next_entity_value;
    let count = sources.len() as u64;
    let next_entity = first_entity
        .checked_add(count)
        .ok_or(abi::KADATH_ERR_INTERNAL)?;
    let entity_values: Vec<u64> = (first_entity..next_entity).collect();
    let candidate = match desc.mode {
        abi::KADATH_RUNTIME_PREPARE_INITIAL if core.live.is_none() => {
            RuntimeState::initial(1, 1, bounds, &sources, &entity_values)
        }
        abi::KADATH_RUNTIME_PREPARE_RESTART => {
            let live = core
                .live
                .as_ref()
                .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
            live.restart(bounds, &sources, &entity_values)
                .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?
        }
        abi::KADATH_RUNTIME_PREPARE_SCENE_RELOAD => {
            let live = core
                .live
                .as_ref()
                .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
            let epoch = live
                .world_epoch
                .checked_add(1)
                .filter(|value| *value <= object_authority::MAX_LOGICAL_GENERATION)
                .ok_or(abi::KADATH_ERR_RUNTIME_EPOCH_EXHAUSTED)?;
            RuntimeState::initial(epoch, 1, bounds, &sources, &entity_values)
        }
        abi::KADATH_RUNTIME_PREPARE_INITIAL => return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE),
        _ => return Err(abi::KADATH_ERR_INVALID_ARGUMENT),
    };
    let candidate_epoch = candidate.world_epoch;
    let info = abi::kadath_runtime_scene_candidate_info_t {
        struct_size: mem::size_of::<abi::kadath_runtime_scene_candidate_info_t>() as u32,
        mode: desc.mode,
        world_epoch: candidate_epoch,
        source_object_count: sources.len(),
        reserved: [0; 6],
    };
    trigger_test_fault(core, 1)?;
    core.candidate = Some(candidate);
    core.candidate_next_entity_value = Some(next_entity);
    core.candidate_mode = Some(desc.mode);
    unsafe { ptr::write(out_info, info) };
    Ok(())
}

fn commit_scene(core_pointer: *mut abi::kadath_runtime_core_t) -> Result<(), u32> {
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    core.phase.ensure_scene_commit_allowed()?;
    if core.candidate.is_none() || core.gameplay_candidate.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
    }
    if core
        .gameplay
        .as_ref()
        .is_some_and(|state| state.active_step_token.is_some())
    {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STEP_BUSY);
    }
    let candidate = core
        .candidate
        .take()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let next_entity_value = core
        .candidate_next_entity_value
        .take()
        .expect("candidate entity high-water accompanies candidate");
    core.live = Some(candidate);
    core.gameplay = core.gameplay_candidate.take();
    core.next_entity_value = next_entity_value;
    core.candidate_mode = None;
    core.phase.commit_after_scene();
    Ok(())
}

fn abort_scene(core_pointer: *mut abi::kadath_runtime_core_t) -> Result<(), u32> {
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    core.candidate = None;
    core.candidate_next_entity_value = None;
    core.candidate_mode = None;
    core.gameplay_candidate = None;
    core.phase.abort_with_scene_candidate();
    Ok(())
}

fn object_ref(
    record: &object_authority::Record,
    world_epoch: u64,
) -> abi::kadath_runtime_object_ref_v1_t {
    abi::kadath_runtime_object_ref_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
        kind: record.kind,
        world_epoch,
        logical_generation: record.logical_generation,
        object_id_length: record.object_id.len(),
        reserved0: 0,
        object_id: record.object_id.storage(),
        reserved: [0; 4],
    }
}

fn read_object_key(value: &abi::kadath_runtime_object_ref_v1_t) -> Result<ObjectKey, u32> {
    if value.struct_size < mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if value.reserved0 != 0
        || !reserved_is_zero(&value.reserved)
        || value.object_id_length == 0
        || value.object_id_length as usize > object_authority::MAX_OBJECT_ID_BYTES
        || value.object_id[value.object_id_length as usize..]
            .iter()
            .any(|byte| *byte != 0)
        || !(abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE..=abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD)
            .contains(&value.kind)
        || value.world_epoch == 0
        || value.logical_generation == 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let object_id = ObjectId::parse(&value.object_id[..value.object_id_length as usize])
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    Ok(ObjectKey {
        object_id,
        world_epoch: value.world_epoch,
        logical_generation: value.logical_generation,
        kind: value.kind,
    })
}

fn object_view(
    record: &object_authority::Record,
    world_epoch: u64,
) -> abi::kadath_runtime_object_view_v1_t {
    abi::kadath_runtime_object_view_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_object_view_v1_t>() as u32,
        lifecycle: match record.lifecycle {
            object_authority::Lifecycle::PendingSpawn => {
                abi::KADATH_RUNTIME_LIFECYCLE_PENDING_SPAWN
            }
            object_authority::Lifecycle::Active => abi::KADATH_RUNTIME_LIFECYCLE_ACTIVE,
            object_authority::Lifecycle::PendingDestroy => unreachable!(),
        },
        origin: if record.source_index.is_some() {
            abi::KADATH_RUNTIME_ORIGIN_SOURCE
        } else {
            abi::KADATH_RUNTIME_ORIGIN_TRANSIENT
        },
        origin_key: record
            .source_index
            .map(u32::from)
            .or(record.prototype_key)
            .unwrap_or(0),
        object_ref: object_ref(record, world_epoch),
        entity_value: record.entity_value,
        position: record.sprite.position,
        size: record.sprite.size,
        color: record.sprite.color,
        texture_id: record.sprite.texture_id,
        reserved0: 0,
        reserved: [0; 4],
    }
}

fn strided_range(
    start: usize,
    count: usize,
    stride: usize,
    item_size: usize,
) -> Option<(usize, usize)> {
    if count == 0 {
        return Some((start, start));
    }
    let bytes = (count - 1).checked_mul(stride)?.checked_add(item_size)?;
    Some((start, start.checked_add(bytes)?))
}

fn ranges_overlap(left: (usize, usize), right: (usize, usize)) -> bool {
    left.0 < right.1 && right.0 < left.1
}

fn union_tail_is_zero<T>(payload: *const T, active_size: usize) -> bool {
    let total_size = mem::size_of::<T>();
    if active_size > total_size {
        return false;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload.cast::<u8>(), total_size) };
    bytes[active_size..].iter().all(|byte| *byte == 0)
}

fn query_payload_is_well_formed(item: &abi::kadath_runtime_query_item_v1_t) -> Result<usize, u32> {
    let active_size = match item.tag {
        abi::KADATH_RUNTIME_QUERY_STATE_INFO => 0,
        abi::KADATH_RUNTIME_QUERY_FIND_BY_ID => mem::size_of::<abi::kadath_runtime_string_view_t>(),
        abi::KADATH_RUNTIME_QUERY_RESOLVE_EXACT_REF => {
            mem::size_of::<abi::kadath_runtime_object_ref_v1_t>()
        }
        abi::KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS | abi::KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS => {
            mem::size_of::<abi::kadath_runtime_object_buffer_t>()
        }
        abi::KADATH_RUNTIME_QUERY_FIND_BY_ENTITY => mem::size_of::<u64>(),
        _ => return Err(abi::KADATH_ERR_NOT_SUPPORTED),
    };
    if !union_tail_is_zero(&item.payload, active_size) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(active_size)
}

fn mutation_payload_is_well_formed(
    item: &abi::kadath_runtime_mutation_item_v1_t,
) -> Result<usize, u32> {
    let active_size = match item.tag {
        abi::KADATH_RUNTIME_MUTATION_SET_BOUNDS => {
            mem::size_of::<abi::kadath_runtime_bounds_desc_v1_t>()
        }
        abi::KADATH_RUNTIME_MUTATION_STEP_FIXED => {
            mem::size_of::<abi::kadath_runtime_fixed_step_desc_v1_t>()
        }
        abi::KADATH_RUNTIME_MUTATION_APPLY_POSITIONS => {
            mem::size_of::<abi::kadath_runtime_position_batch_v1_t>()
        }
        abi::KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT => {
            mem::size_of::<abi::kadath_runtime_transient_desc_v1_t>()
        }
        abi::KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT
        | abi::KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION
        | abi::KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY
        | abi::KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY => {
            mem::size_of::<abi::kadath_runtime_object_ref_v1_t>()
        }
        _ => return Err(abi::KADATH_ERR_NOT_SUPPORTED),
    };
    if !union_tail_is_zero(&item.payload, active_size) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(active_size)
}

struct PlannedQuery {
    result: abi::kadath_runtime_query_result_t,
    object_output: Option<(*mut u8, usize, Vec<abi::kadath_runtime_object_view_v1_t>)>,
}

fn query(
    core_pointer: *mut abi::kadath_runtime_core_t,
    batch: *const abi::kadath_runtime_query_batch_t,
    results: *mut abi::kadath_runtime_query_result_t,
    result_capacity: usize,
) -> Result<(), u32> {
    if core_pointer.is_null()
        || batch.is_null()
        || results.is_null()
        || (batch as usize) % mem::align_of::<abi::kadath_runtime_query_batch_t>() != 0
        || (results as usize) % mem::align_of::<abi::kadath_runtime_query_result_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let batch_size = unsafe { read_struct_size(batch) }?;
    if batch_size < mem::size_of::<abi::kadath_runtime_query_batch_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let batch = unsafe { &*batch };
    if !reserved_is_zero(&batch.reserved)
        || batch.item_count == 0
        || batch.item_count > MAX_OBJECTS
        || result_capacity < batch.item_count
        || batch.items.is_null()
        || batch.item_stride < mem::size_of::<abi::kadath_runtime_query_item_v1_t>()
        || batch.item_stride % mem::align_of::<abi::kadath_runtime_query_item_v1_t>() != 0
        || (batch.items as usize) % mem::align_of::<abi::kadath_runtime_query_item_v1_t>() != 0
        || (results as usize) % mem::align_of::<abi::kadath_runtime_query_result_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if !matches!(
        batch.target,
        abi::KADATH_RUNTIME_TARGET_LIVE | abi::KADATH_RUNTIME_TARGET_CANDIDATE
    ) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let item_range = strided_range(
        batch.items as usize,
        batch.item_count,
        batch.item_stride,
        mem::size_of::<abi::kadath_runtime_query_item_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let batch_range = strided_range(
        batch as *const _ as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_query_batch_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let result_range = strided_range(
        results as usize,
        batch.item_count,
        mem::size_of::<abi::kadath_runtime_query_result_t>(),
        mem::size_of::<abi::kadath_runtime_query_result_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(item_range, result_range)
        || ranges_overlap(batch_range, item_range)
        || ranges_overlap(batch_range, result_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let state = match batch.target {
        abi::KADATH_RUNTIME_TARGET_LIVE => core.live.as_ref(),
        abi::KADATH_RUNTIME_TARGET_CANDIDATE => core.candidate.as_ref(),
        _ => return Err(abi::KADATH_ERR_INVALID_ARGUMENT),
    }
    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut borrowed_ranges: Vec<(usize, usize)> = Vec::new();
    borrowed_ranges
        .try_reserve_exact(batch.item_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    for index in 0..batch.item_count {
        let item_pointer = unsafe {
            batch
                .items
                .cast::<u8>()
                .add(index * batch.item_stride)
                .cast::<abi::kadath_runtime_query_item_v1_t>()
        };
        let item_size = unsafe { read_struct_size(item_pointer) }?;
        let result_pointer = unsafe { results.add(index) };
        let result_size = unsafe { read_struct_size(result_pointer) }?;
        if item_size < mem::size_of::<abi::kadath_runtime_query_item_v1_t>() as u32
            || result_size < mem::size_of::<abi::kadath_runtime_query_result_t>() as u32
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let item = unsafe { &*item_pointer };
        if !reserved_is_zero(&item.reserved) {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        query_payload_is_well_formed(item)?;
        let borrowed_range = match item.tag {
            abi::KADATH_RUNTIME_QUERY_FIND_BY_ID => {
                let input = unsafe { item.payload.object_id };
                if input.data.is_null()
                    || input.length == 0
                    || input.length > object_authority::MAX_OBJECT_ID_BYTES
                {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
                Some(
                    strided_range(input.data as usize, input.length, 1, 1)
                        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?,
                )
            }
            abi::KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS
            | abi::KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS => {
                let object_buffer = unsafe { item.payload.object_buffer };
                let active_only = item.tag == abi::KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS;
                if object_buffer.objects.is_null()
                    || object_buffer.object_capacity < state.visible_count(active_only)
                    || object_buffer.object_stride
                        < mem::size_of::<abi::kadath_runtime_object_view_v1_t>()
                    || object_buffer.object_stride
                        % mem::align_of::<abi::kadath_runtime_object_view_v1_t>()
                        != 0
                    || (object_buffer.objects as usize)
                        % mem::align_of::<abi::kadath_runtime_object_view_v1_t>()
                        != 0
                {
                    return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
                }
                Some(
                    strided_range(
                        object_buffer.objects as usize,
                        object_buffer.object_capacity,
                        object_buffer.object_stride,
                        mem::size_of::<abi::kadath_runtime_object_view_v1_t>(),
                    )
                    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?,
                )
            }
            _ => None,
        };
        if let Some(range) = borrowed_range {
            if ranges_overlap(range, batch_range)
                || ranges_overlap(range, item_range)
                || ranges_overlap(range, result_range)
                || borrowed_ranges
                    .iter()
                    .any(|previous| ranges_overlap(*previous, range))
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            borrowed_ranges.push(range);
        }
    }
    let mut plans = Vec::new();
    plans
        .try_reserve_exact(batch.item_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    for index in 0..batch.item_count {
        let item = unsafe {
            &*batch
                .items
                .cast::<u8>()
                .add(index * batch.item_stride)
                .cast::<abi::kadath_runtime_query_item_v1_t>()
        };
        let mut result: abi::kadath_runtime_query_result_t = unsafe { mem::zeroed() };
        result.struct_size = mem::size_of::<abi::kadath_runtime_query_result_t>() as u32;
        result.tag = item.tag;
        result.found = abi::KADATH_RUNTIME_FOUND;
        let mut object_output = None;
        match item.tag {
            abi::KADATH_RUNTIME_QUERY_STATE_INFO => {
                result.payload = abi::kadath_runtime_query_result_payload_v1_t {
                    state_info: abi::kadath_runtime_state_info_v1_t {
                        world_epoch: state.world_epoch,
                        object_count: state.record_count(),
                        reserved: [0; 4],
                    },
                };
            }
            abi::KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS
            | abi::KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS => {
                let object_buffer = unsafe { item.payload.object_buffer };
                let active_only = item.tag == abi::KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS;
                let records = state
                    .ordered_records(active_only)
                    .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
                if object_buffer.objects.is_null()
                    || object_buffer.object_capacity < records.len()
                    || object_buffer.object_stride
                        < mem::size_of::<abi::kadath_runtime_object_view_v1_t>()
                    || object_buffer.object_stride
                        % mem::align_of::<abi::kadath_runtime_object_view_v1_t>()
                        != 0
                    || (object_buffer.objects as usize)
                        % mem::align_of::<abi::kadath_runtime_object_view_v1_t>()
                        != 0
                {
                    return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
                }
                let mut views = Vec::new();
                views
                    .try_reserve_exact(records.len())
                    .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
                views.extend(
                    records
                        .into_iter()
                        .map(|record| object_view(record, state.world_epoch)),
                );
                result.payload = abi::kadath_runtime_query_result_payload_v1_t {
                    snapshot: abi::kadath_runtime_snapshot_result_v1_t {
                        world_epoch: state.world_epoch,
                        object_count: views.len(),
                        reserved: [0; 4],
                    },
                };
                object_output = Some((
                    object_buffer.objects.cast::<u8>(),
                    object_buffer.object_stride,
                    views,
                ));
            }
            abi::KADATH_RUNTIME_QUERY_RESOLVE_EXACT_REF => {
                let key = read_object_key(unsafe { &item.payload.object_ref })?;
                if let Some(record) = state.visible_exact(key) {
                    result.payload = abi::kadath_runtime_query_result_payload_v1_t {
                        object: object_view(record, state.world_epoch),
                    };
                } else {
                    result.found = abi::KADATH_RUNTIME_NOT_FOUND;
                }
            }
            abi::KADATH_RUNTIME_QUERY_FIND_BY_ID => {
                let input = unsafe { item.payload.object_id };
                if input.data.is_null()
                    || input.length == 0
                    || input.length > object_authority::MAX_OBJECT_ID_BYTES
                    || (input.data as usize).checked_add(input.length).is_none()
                {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
                let object_id = ObjectId::parse(unsafe {
                    std::slice::from_raw_parts(input.data, input.length)
                })
                .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
                if let Some(record) = state.visible_by_id(object_id) {
                    result.payload = abi::kadath_runtime_query_result_payload_v1_t {
                        object: object_view(record, state.world_epoch),
                    };
                } else {
                    result.found = abi::KADATH_RUNTIME_NOT_FOUND;
                }
            }
            abi::KADATH_RUNTIME_QUERY_FIND_BY_ENTITY => {
                let entity_value = unsafe { item.payload.entity_value };
                if entity_value == 0 {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
                if let Some(record) = state.active_by_entity(entity_value) {
                    result.payload = abi::kadath_runtime_query_result_payload_v1_t {
                        object: object_view(record, state.world_epoch),
                    };
                } else {
                    result.found = abi::KADATH_RUNTIME_NOT_FOUND;
                }
            }
            _ => return Err(abi::KADATH_ERR_NOT_SUPPORTED),
        }
        plans.push(PlannedQuery {
            result,
            object_output,
        });
    }
    trigger_test_fault(core, 2)?;
    for plan in &plans {
        if let Some((output, stride, views)) = &plan.object_output {
            for (index, view) in views.iter().enumerate() {
                let destination = unsafe {
                    output
                        .add(index * *stride)
                        .cast::<abi::kadath_runtime_object_view_v1_t>()
                };
                unsafe { ptr::write(destination, *view) };
            }
        }
    }
    for (index, plan) in plans.into_iter().enumerate() {
        unsafe { ptr::write(results.add(index), plan.result) };
    }
    Ok(())
}

extern "C" fn create_entry(
    desc: *const abi::kadath_runtime_core_create_desc_t,
    out_core: *mut *mut abi::kadath_runtime_core_t,
) -> i32 {
    ffi_result(|| create(desc, out_core))
}

extern "C" fn destroy_entry(in_out_core: *mut *mut abi::kadath_runtime_core_t) -> i32 {
    ffi_result(|| destroy(in_out_core))
}

extern "C" fn prepare_scene_entry(
    core: *mut abi::kadath_runtime_core_t,
    desc: *const abi::kadath_runtime_scene_prepare_desc_t,
    out_info: *mut abi::kadath_runtime_scene_candidate_info_t,
) -> i32 {
    ffi_result(|| prepare_scene(core, desc, out_info))
}

extern "C" fn commit_scene_entry(core: *mut abi::kadath_runtime_core_t) -> i32 {
    ffi_result(|| commit_scene(core))
}

extern "C" fn abort_scene_entry(core: *mut abi::kadath_runtime_core_t) -> i32 {
    ffi_result(|| abort_scene(core))
}

extern "C" fn query_entry(
    core: *mut abi::kadath_runtime_core_t,
    batch: *const abi::kadath_runtime_query_batch_t,
    results: *mut abi::kadath_runtime_query_result_t,
    result_capacity: usize,
) -> i32 {
    ffi_result(|| query(core, batch, results, result_capacity))
}

fn authority_error(value: AuthorityError) -> u32 {
    match value {
        AuthorityError::Capacity => abi::KADATH_ERR_RUNTIME_OBJECT_CAPACITY,
        AuthorityError::InvalidLifecycle => abi::KADATH_ERR_RUNTIME_INVALID_LIFECYCLE,
        AuthorityError::SerialExhausted => abi::KADATH_ERR_RUNTIME_TRANSIENT_ID_EXHAUSTED,
        AuthorityError::SourceDestroy => abi::KADATH_ERR_RUNTIME_SOURCE_DESTROY_REJECTED,
        AuthorityError::Stale => abi::KADATH_ERR_RUNTIME_STALE_OBJECT,
    }
}

fn read_transient(
    value: &abi::kadath_runtime_transient_desc_v1_t,
) -> Result<(u32, u32, Sprite), u32> {
    if value.struct_size < mem::size_of::<abi::kadath_runtime_transient_desc_v1_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if value.reserved0 != 0
        || !reserved_is_zero(&value.reserved)
        || value.kind != abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE
        || value.sprite.struct_size < mem::size_of::<abi::kadath_runtime_sprite_desc_v1_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if value.sprite.reserved0 != 0 || value.sprite.reserved.iter().any(|reserved| *reserved != 0) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let sprite = Sprite {
        position: value.sprite.position,
        size: value.sprite.size,
        color: value.sprite.color,
        texture_id: value.sprite.texture_id,
        move_speed: value.sprite.move_speed,
    };
    if !sprite.is_valid() || sprite.move_speed != 0.0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok((value.prototype_key, value.kind, sprite))
}

fn read_bounds(value: &abi::kadath_runtime_bounds_desc_v1_t) -> Result<Bounds, u32> {
    if value.struct_size < mem::size_of::<abi::kadath_runtime_bounds_desc_v1_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if value.reserved0 != 0 || !reserved_is_zero(&value.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Bounds::new(value.min, value.max).ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)
}

fn apply_positions(
    state: &mut RuntimeState,
    value: &abi::kadath_runtime_position_batch_v1_t,
    item_range: (usize, usize),
    result_range: (usize, usize),
) -> Result<(), u32> {
    if value.patches.is_null()
        || value.patch_count == 0
        || value.patch_count > MAX_OBJECTS
        || (value.patches as usize) % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
            != 0
        || value.patch_stride < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>()
        || value.patch_stride % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>() != 0
        || strided_range(
            value.patches as usize,
            value.patch_count,
            value.patch_stride,
            mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
        )
        .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let patch_range = strided_range(
        value.patches as usize,
        value.patch_count,
        value.patch_stride,
        mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(patch_range, item_range) || ranges_overlap(patch_range, result_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    // Gameplay 热路径的补丁数量有固定上限，使用栈上固定容量避免每步堆分配。
    let mut parsed = [(unsafe { mem::zeroed() }, [0.0; 2]); MAX_OBJECTS];
    let mut parsed_count = 0;
    for index in 0..value.patch_count {
        let offset = index
            .checked_mul(value.patch_stride)
            .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
        let patch = unsafe {
            &*value
                .patches
                .cast::<u8>()
                .add(offset)
                .cast::<abi::kadath_runtime_position_patch_v1_t>()
        };
        if patch.struct_size < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() as u32 {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        if patch.reserved0 != 0
            || !reserved_is_zero(&patch.reserved)
            || !patch.position.iter().all(|position| position.is_finite())
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let key = read_object_key(&patch.object_ref)?;
        if parsed[..parsed_count]
            .iter()
            .any(|(existing, _): &(ObjectKey, [f32; 2])| *existing == key)
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        parsed[parsed_count] = (key, patch.position);
        parsed_count += 1;
    }
    for (key, position) in parsed[..parsed_count].iter().copied() {
        state.set_position(key, position).map_err(authority_error)?;
    }
    Ok(())
}

#[cfg(not(feature = "contract-test-hooks"))]
fn apply_single_position_batch_in_place(
    state: &mut RuntimeState,
    value: &abi::kadath_runtime_position_batch_v1_t,
    item_range: (usize, usize),
    result_range: (usize, usize),
) -> Result<(), u32> {
    // 单一位置批次先完整验证，再一次性发布；跳过整份 RuntimeState 克隆。
    if value.patches.is_null()
        || value.patch_count == 0
        || value.patch_count > MAX_OBJECTS
        || (value.patches as usize) % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
            != 0
        || value.patch_stride < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let patch_range = strided_range(
        value.patches as usize,
        value.patch_count,
        value.patch_stride,
        mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(patch_range, item_range) || ranges_overlap(patch_range, result_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let mut parsed = [(unsafe { mem::zeroed() }, [0.0; 2], [0.0; 2]); MAX_OBJECTS];
    for index in 0..value.patch_count {
        let patch = unsafe {
            &*value
                .patches
                .cast::<u8>()
                .add(index * value.patch_stride)
                .cast::<abi::kadath_runtime_position_patch_v1_t>()
        };
        if patch.struct_size < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() as u32
            || patch.reserved0 != 0
            || !reserved_is_zero(&patch.reserved)
            || !patch.position.iter().all(|position| position.is_finite())
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let key = read_object_key(&patch.object_ref)?;
        if parsed[..index]
            .iter()
            .any(|(existing, _, _): &(ObjectKey, [f32; 2], [f32; 2])| *existing == key)
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let old_position = state
            .visible_exact(key)
            .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?
            .sprite
            .position;
        parsed[index] = (key, patch.position, old_position);
    }
    for (key, position, _) in parsed[..value.patch_count].iter().copied() {
        state.set_position(key, position).map_err(authority_error)?;
    }
    Ok(())
}

fn mutate(
    core_pointer: *mut abi::kadath_runtime_core_t,
    batch: *const abi::kadath_runtime_mutation_batch_t,
    results: *mut abi::kadath_runtime_mutation_result_t,
    result_capacity: usize,
) -> Result<(), u32> {
    if core_pointer.is_null()
        || batch.is_null()
        || results.is_null()
        || (batch as usize) % mem::align_of::<abi::kadath_runtime_mutation_batch_t>() != 0
        || (results as usize) % mem::align_of::<abi::kadath_runtime_mutation_result_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let batch_size = unsafe { read_struct_size(batch) }?;
    if batch_size < mem::size_of::<abi::kadath_runtime_mutation_batch_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let batch = unsafe { &*batch };
    if !reserved_is_zero(&batch.reserved)
        || batch.item_count == 0
        || batch.item_count > MAX_OBJECTS
        || result_capacity < batch.item_count
        || batch.items.is_null()
        || batch.item_stride < mem::size_of::<abi::kadath_runtime_mutation_item_v1_t>()
        || batch.item_stride % mem::align_of::<abi::kadath_runtime_mutation_item_v1_t>() != 0
        || (batch.items as usize) % mem::align_of::<abi::kadath_runtime_mutation_item_v1_t>() != 0
        || batch
            .item_count
            .checked_sub(1)
            .and_then(|last| last.checked_mul(batch.item_stride))
            .and_then(|offset| {
                offset.checked_add(mem::size_of::<abi::kadath_runtime_mutation_item_v1_t>())
            })
            .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if !matches!(
        batch.target,
        abi::KADATH_RUNTIME_TARGET_LIVE | abi::KADATH_RUNTIME_TARGET_CANDIDATE
    ) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let item_range = strided_range(
        batch.items as usize,
        batch.item_count,
        batch.item_stride,
        mem::size_of::<abi::kadath_runtime_mutation_item_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let batch_range = strided_range(
        batch as *const _ as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_mutation_batch_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let result_range = strided_range(
        results as usize,
        batch.item_count,
        mem::size_of::<abi::kadath_runtime_mutation_result_t>(),
        mem::size_of::<abi::kadath_runtime_mutation_result_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(item_range, result_range)
        || ranges_overlap(batch_range, item_range)
        || ranges_overlap(batch_range, result_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let live_target = batch.target == abi::KADATH_RUNTIME_TARGET_LIVE;
    #[cfg(not(feature = "contract-test-hooks"))]
    if batch.item_count == 1 {
        let item_pointer = batch.items.cast::<abi::kadath_runtime_mutation_item_v1_t>();
        let item_size = unsafe { read_struct_size(item_pointer) }?;
        let result_size = unsafe { read_struct_size(results) }?;
        if item_size < mem::size_of::<abi::kadath_runtime_mutation_item_v1_t>() as u32
            || result_size < mem::size_of::<abi::kadath_runtime_mutation_result_t>() as u32
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let item = unsafe { &*item_pointer };
        if item.tag == abi::KADATH_RUNTIME_MUTATION_APPLY_POSITIONS {
            if !reserved_is_zero(&item.reserved) {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            mutation_payload_is_well_formed(item)?;
            let state = if live_target {
                core.live
                    .as_mut()
                    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?
            } else {
                core.candidate
                    .as_mut()
                    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?
            };
            apply_single_position_batch_in_place(
                state,
                unsafe { &item.payload.positions },
                item_range,
                result_range,
            )?;
            let mut result: abi::kadath_runtime_mutation_result_t = unsafe { mem::zeroed() };
            result.struct_size = mem::size_of::<abi::kadath_runtime_mutation_result_t>() as u32;
            result.tag = item.tag;
            unsafe { ptr::write(results, result) };
            return Ok(());
        }
    }
    // 输入借用范围也受 MAX_OBJECTS 限制，固定数组可保持 mutate 无分配。
    let mut borrowed_ranges = [(0usize, 0usize); MAX_OBJECTS];
    let mut borrowed_range_count = 0;
    for index in 0..batch.item_count {
        let item_pointer = unsafe {
            batch
                .items
                .cast::<u8>()
                .add(index * batch.item_stride)
                .cast::<abi::kadath_runtime_mutation_item_v1_t>()
        };
        let item_size = unsafe { read_struct_size(item_pointer) }?;
        let result_pointer = unsafe { results.add(index) };
        let result_size = unsafe { read_struct_size(result_pointer) }?;
        if item_size < mem::size_of::<abi::kadath_runtime_mutation_item_v1_t>() as u32
            || result_size < mem::size_of::<abi::kadath_runtime_mutation_result_t>() as u32
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let item = unsafe { &*item_pointer };
        if !reserved_is_zero(&item.reserved) {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        mutation_payload_is_well_formed(item)?;
        if item.tag == abi::KADATH_RUNTIME_MUTATION_APPLY_POSITIONS {
            let positions = unsafe { &item.payload.positions };
            if positions.patches.is_null()
                || positions.patch_count == 0
                || positions.patch_count > MAX_OBJECTS
                || (positions.patches as usize)
                    % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
                    != 0
                || positions.patch_stride
                    < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>()
                || positions.patch_stride
                    % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
                    != 0
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            let patch_range = strided_range(
                positions.patches as usize,
                positions.patch_count,
                positions.patch_stride,
                mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
            )
            .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
            if ranges_overlap(patch_range, batch_range)
                || ranges_overlap(patch_range, item_range)
                || ranges_overlap(patch_range, result_range)
                || borrowed_ranges[..borrowed_range_count]
                    .iter()
                    .any(|previous| ranges_overlap(*previous, patch_range))
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            borrowed_ranges[borrowed_range_count] = patch_range;
            borrowed_range_count += 1;
        }
    }
    let mut state = if live_target {
        core.live.as_ref()
    } else {
        core.candidate.as_ref()
    }
    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?
    .clone();
    let mut next_entity = core.next_entity_value;
    // 事务结果和同批次生命周期引用均有固定批次上限，避免在提交循环中分配。
    let mut planned_results = [unsafe { mem::zeroed() }; MAX_OBJECTS];
    let mut planned_result_count = 0;
    let mut lifecycle_refs = [(unsafe { mem::zeroed() }, 0_u32); MAX_OBJECTS];
    let mut lifecycle_ref_count = 0;
    for index in 0..batch.item_count {
        let item = unsafe {
            &*batch
                .items
                .cast::<u8>()
                .add(index * batch.item_stride)
                .cast::<abi::kadath_runtime_mutation_item_v1_t>()
        };
        let mut result: abi::kadath_runtime_mutation_result_t = unsafe { mem::zeroed() };
        result.struct_size = mem::size_of::<abi::kadath_runtime_mutation_result_t>() as u32;
        result.tag = item.tag;
        match item.tag {
            abi::KADATH_RUNTIME_MUTATION_SET_BOUNDS => {
                let bounds = read_bounds(unsafe { &item.payload.bounds })?;
                state.set_bounds(bounds);
            }
            abi::KADATH_RUNTIME_MUTATION_STEP_FIXED => {
                if !live_target {
                    return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
                }
                let value = unsafe { &item.payload.fixed_step };
                if value.struct_size
                    < mem::size_of::<abi::kadath_runtime_fixed_step_desc_v1_t>() as u32
                {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
                if value.reserved0 != 0
                    || value.reserved_input.iter().any(|reserved| *reserved != 0)
                    || !reserved_is_zero(&value.reserved)
                    || !value.dt_seconds.is_finite()
                    || value.dt_seconds < 0.0
                    || !(-1..=1).contains(&value.move_x)
                    || !(-1..=1).contains(&value.move_y)
                {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
                state.step_fixed(value.dt_seconds, [value.move_x, value.move_y]);
            }
            abi::KADATH_RUNTIME_MUTATION_APPLY_POSITIONS => {
                apply_positions(
                    &mut state,
                    unsafe { &item.payload.positions },
                    item_range,
                    result_range,
                )?;
            }
            abi::KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT => {
                if !live_target {
                    return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
                }
                let (prototype_key, kind, sprite) =
                    read_transient(unsafe { &item.payload.transient })?;
                let world_epoch = state.world_epoch;
                let record = state
                    .reserve_transient(prototype_key, kind, sprite)
                    .map_err(authority_error)?;
                result.object = object_view(record, world_epoch);
            }
            abi::KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT
            | abi::KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION
            | abi::KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY
            | abi::KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY => {
                if !live_target {
                    return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
                }
                let key = read_object_key(unsafe { &item.payload.object_ref })?;
                if let Some((_, previous_tag)) = lifecycle_refs[..lifecycle_ref_count]
                    .iter()
                    .rev()
                    .find(|(previous_key, _)| *previous_key == key)
                {
                    let allowed_activation_destroy = *previous_tag
                        == abi::KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT
                        && item.tag == abi::KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
                    if !allowed_activation_destroy {
                        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                    }
                }
                lifecycle_refs[lifecycle_ref_count] = (key, item.tag);
                lifecycle_ref_count += 1;
                match item.tag {
                    abi::KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT => {
                        let entity_value = next_entity;
                        next_entity = next_entity.checked_add(1).ok_or(abi::KADATH_ERR_INTERNAL)?;
                        state.activate(key, entity_value).map_err(authority_error)?;
                    }
                    abi::KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION => {
                        state.discard(key).map_err(authority_error)?;
                    }
                    abi::KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY => {
                        result.destroy_disposition =
                            match state.request_destroy(key).map_err(authority_error)? {
                                DestroyDisposition::CancelledPendingSpawn => {
                                    abi::KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN
                                }
                                DestroyDisposition::AwaitingFinalize => {
                                    abi::KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE
                                }
                            };
                    }
                    abi::KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY => {
                        state.finalize_destroy(key).map_err(authority_error)?;
                    }
                    _ => unreachable!(),
                }
            }
            _ => return Err(abi::KADATH_ERR_NOT_SUPPORTED),
        }
        planned_results[planned_result_count] = result;
        planned_result_count += 1;
    }
    trigger_test_fault(core, 3)?;
    core.next_entity_value = next_entity;
    if live_target {
        core.live = Some(state);
    } else {
        core.candidate = Some(state);
    }
    for (index, result) in planned_results[..planned_result_count]
        .iter()
        .copied()
        .enumerate()
    {
        unsafe { ptr::write(results.add(index), result) };
    }
    Ok(())
}

extern "C" fn mutate_entry(
    core: *mut abi::kadath_runtime_core_t,
    batch: *const abi::kadath_runtime_mutation_batch_t,
    results: *mut abi::kadath_runtime_mutation_result_t,
    result_capacity: usize,
) -> i32 {
    ffi_result(|| mutate(core, batch, results, result_capacity))
}

fn ffi_result(operation: impl FnOnce() -> Result<(), u32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => abi::KADATH_OK as i32,
        Ok(Err(code)) => error(code),
        Err(_) => error(abi::KADATH_ERR_INTERNAL),
    }
}

fn query_interface(
    in_out_interface: *mut abi::kadath_runtime_object_authority_interface_t,
) -> Result<(), u32> {
    if in_out_interface.is_null()
        || (in_out_interface as usize)
            % mem::align_of::<abi::kadath_runtime_object_authority_interface_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let requested_size = unsafe { read_struct_size(in_out_interface) }?;
    if requested_size < mem::size_of::<abi::kadath_runtime_object_authority_interface_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let requested_version = unsafe {
        ptr::read(
            in_out_interface
                .cast::<u8>()
                .add(mem::size_of::<u32>())
                .cast::<u32>(),
        )
    };
    let requested = unsafe { ptr::read(in_out_interface) };
    if !reserved_is_zero(&requested.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if requested_version != abi::KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1 {
        return Err(abi::KADATH_ERR_NOT_SUPPORTED);
    }
    let value = abi::kadath_runtime_object_authority_interface_t {
        struct_size: mem::size_of::<abi::kadath_runtime_object_authority_interface_t>() as u32,
        interface_version: abi::KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1,
        create: Some(create_entry),
        destroy: Some(destroy_entry),
        prepare_scene: Some(prepare_scene_entry),
        commit_scene: Some(commit_scene_entry),
        abort_scene: Some(abort_scene_entry),
        query: Some(query_entry),
        mutate: Some(mutate_entry),
        reserved: [0; 8],
    };
    unsafe { ptr::write(in_out_interface, value) };
    Ok(())
}

#[no_mangle]
pub extern "C" fn kadath_runtime_core_query_object_authority_interface(
    in_out_interface: *mut abi::kadath_runtime_object_authority_interface_t,
) -> i32 {
    ffi_result(|| query_interface(in_out_interface))
}

#[no_mangle]
pub extern "C" fn kadath_runtime_core_query_phase_interface(
    in_out_interface: *mut abi::kadath_runtime_phase_interface_v1_t,
) -> i32 {
    ffi_result(|| phase_commit::query_interface(in_out_interface))
}

fn valid_output<T>(pointer: *mut T) -> Result<(), u32> {
    if pointer.is_null() || (pointer as usize) % mem::align_of::<T>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if unsafe { read_struct_size(pointer) }? < mem::size_of::<T>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(())
}

fn ensure_disjoint(ranges: &[(usize, usize)]) -> Result<(), u32> {
    for (index, range) in ranges.iter().enumerate() {
        if ranges[index + 1..]
            .iter()
            .any(|other| ranges_overlap(*range, *other))
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
    }
    Ok(())
}

fn validate_outcome_buffer(
    buffer_pointer: *mut abi::kadath_runtime_gameplay_outcome_buffer_v1_t,
) -> Result<abi::kadath_runtime_gameplay_outcome_buffer_v1_t, u32> {
    valid_output(buffer_pointer)?;
    // 验证潜在重叠范围前先复制caller metadata，避免对不可信内存建立独占Rust引用。
    let buffer = unsafe { ptr::read(buffer_pointer) };
    if buffer.reserved0 != 0
        || !reserved_is_zero(&buffer.reserved)
        || buffer.outcomes.is_null()
        || buffer.outcome_capacity < 1
        || buffer.outcome_stride < mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>()
        || buffer.outcome_stride % mem::align_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() != 0
        || (buffer.outcomes as usize) % mem::align_of::<abi::kadath_runtime_gameplay_outcome_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if unsafe { read_struct_size(buffer.outcomes) }?
        < mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let buffer_range = strided_range(
        buffer_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_buffer_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let outcome_range = strided_range(
        buffer.outcomes as usize,
        buffer.outcome_capacity,
        buffer.outcome_stride,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    ensure_disjoint(&[buffer_range, outcome_range])?;
    Ok(buffer)
}

fn prepare_gameplay_state(
    core_pointer: *mut abi::kadath_runtime_core_t,
    desc_pointer: *const abi::kadath_runtime_gameplay_desc_v1_t,
    out_pointer: *mut abi::kadath_runtime_gameplay_candidate_info_v1_t,
) -> Result<(), u32> {
    if desc_pointer.is_null()
        || (desc_pointer as usize) % mem::align_of::<abi::kadath_runtime_gameplay_desc_v1_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    valid_output(out_pointer)?;
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let desc = unsafe { &*desc_pointer };
    if desc.struct_size < mem::size_of::<abi::kadath_runtime_gameplay_desc_v1_t>() as u32
        || desc.reserved0 != 0
        || !reserved_is_zero(&desc.reserved)
        || !desc.time_limit_seconds.is_finite()
        || desc.time_limit_seconds <= 0.0
        || desc.hazard_count == 0
        || desc.hazard_count as usize > gameplay::MAX_CONTACTS - 1
        || desc.hazards.is_null()
        || desc.hazard_stride < mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>()
        || desc.hazard_stride % mem::align_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>()
            != 0
        || (desc.hazards as usize)
            % mem::align_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let hazard_range = strided_range(
        desc.hazards as usize,
        desc.hazard_count as usize,
        desc.hazard_stride,
        mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_candidate_info_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    ensure_disjoint(&[desc_range, hazard_range, output_range])?;
    if core.gameplay_candidate.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_CANDIDATE_BUSY);
    }
    if core.phase.has_candidate() {
        return Err(abi::KADATH_ERR_RUNTIME_CANDIDATE_BUSY);
    }
    let candidate = core
        .candidate
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let player = read_object_key(&desc.player)?;
    let goal = read_object_key(&desc.goal)?;
    let player_record = candidate.visible_exact(player);
    let goal_record = candidate.visible_exact(goal);
    if player.kind != abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER
        || goal.kind != abi::KADATH_RUNTIME_OBJECT_KIND_GOAL
        || player == goal
        || player_record
            .and_then(|record| record.source_index)
            .is_none()
        || goal_record.and_then(|record| record.source_index).is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let mut hazards = Vec::new();
    hazards
        .try_reserve_exact(desc.hazard_count as usize)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    let mut previous_source = None;
    for index in 0..desc.hazard_count as usize {
        let pointer = unsafe {
            desc.hazards
                .cast::<u8>()
                .add(index * desc.hazard_stride)
                .cast::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>()
        };
        let hazard = unsafe { &*pointer };
        if hazard.struct_size
            < mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>() as u32
            || hazard.reserved0 != 0
            || !reserved_is_zero(&hazard.reserved)
            || !matches!(
                hazard.movement_mode,
                abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE
                    | abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL
            )
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let key = read_object_key(&hazard.object_ref)?;
        let record = candidate
            .visible_exact(key)
            .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?;
        if key.kind != abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD || key == player || key == goal
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let source = record
            .source_index
            .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
        if previous_source.is_some_and(|value| source <= value) {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        previous_source = Some(source);
        let legacy =
            hazard.movement_mode == abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL;
        if (!legacy
            && (hazard.patrol_min_y != 0.0
                || hazard.patrol_max_y != 0.0
                || hazard.patrol_speed != 0.0))
            || (legacy
                && (!hazard.patrol_min_y.is_finite()
                    || !hazard.patrol_max_y.is_finite()
                    || !hazard.patrol_speed.is_finite()
                    || hazard.patrol_min_y >= hazard.patrol_max_y
                    || hazard.patrol_speed < 0.0))
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        hazards.push(gameplay::Hazard {
            object: key,
            source_index: source,
            movement_mode: hazard.movement_mode,
            patrol_min_y: hazard.patrol_min_y,
            patrol_max_y: hazard.patrol_max_y,
            patrol_speed: hazard.patrol_speed,
            patrol_direction: 1.0,
        });
    }
    if core.candidate_mode == Some(abi::KADATH_RUNTIME_PREPARE_RESTART)
        && core
            .gameplay
            .as_ref()
            .is_some_and(|state| state.session.phase == gameplay::Phase::Playing)
    {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE);
    }
    let (next_sequence, next_step_token) = core.gameplay.as_ref().map_or((1, 1), |value| {
        (value.session.next_outcome_sequence, value.next_step_token)
    });
    let state = gameplay::State::new(
        player,
        player_record
            .and_then(|record| record.source_index)
            .expect("validated player source index"),
        goal,
        goal_record
            .and_then(|record| record.source_index)
            .expect("validated goal source index"),
        &hazards,
        desc.time_limit_seconds,
        next_sequence,
        next_step_token,
    );
    let output = abi::kadath_runtime_gameplay_candidate_info_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_gameplay_candidate_info_v1_t>() as u32,
        hazard_count: desc.hazard_count,
        world_epoch: candidate.world_epoch,
        reserved: [0; 4],
    };
    trigger_test_fault(core, TEST_ENTRY_PREPARE)?;
    core.gameplay_candidate = Some(state);
    unsafe { ptr::write(out_pointer, output) };
    Ok(())
}

fn begin_gameplay_fixed(
    core_pointer: *mut abi::kadath_runtime_core_t,
    desc_pointer: *const abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t,
    buffer_pointer: *mut abi::kadath_runtime_gameplay_outcome_buffer_v1_t,
    out_pointer: *mut abi::kadath_runtime_gameplay_step_result_v1_t,
) -> Result<(), u32> {
    if desc_pointer.is_null()
        || (desc_pointer as usize)
            % mem::align_of::<abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    valid_output(out_pointer)?;
    let buffer = validate_outcome_buffer(buffer_pointer)?;
    let desc = unsafe { &*desc_pointer };
    if desc.struct_size
        < mem::size_of::<abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t>() as u32
        || desc.reserved0 != 0
        || desc.reserved1 != 0
        || !reserved_is_zero(&desc.reserved)
        || !desc.dt_seconds.is_finite()
        || desc.dt_seconds < 0.0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let buffer_range = strided_range(
        buffer_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_buffer_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let outcome_range = strided_range(
        buffer.outcomes as usize,
        buffer.outcome_capacity,
        buffer.outcome_stride,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let result_range = strided_range(
        out_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    ensure_disjoint(&[desc_range, buffer_range, outcome_range, result_range])?;
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    if core.candidate.is_some() || core.gameplay_candidate.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE);
    }
    core.phase.ensure_gameplay_begin_allowed()?;
    let state = core
        .gameplay
        .as_mut()
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)?;
    if state.active_step_token.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STEP_BUSY);
    }
    trigger_test_fault(core, TEST_ENTRY_QUERY)?;
    let state = core
        .gameplay
        .as_mut()
        .expect("Gameplay state was preflighted");
    let token = state.next_step_token;
    let next_token = token
        .checked_add(1)
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_SEQUENCE_EXHAUSTED)?;
    let mut session = state.session;
    let outcome = session
        .begin_step(desc.dt_seconds, state.player)
        .map_err(|_| abi::KADATH_ERR_RUNTIME_GAMEPLAY_SEQUENCE_EXHAUSTED)?;
    let result = gameplay::step_result(session, token, 0, usize::from(outcome.is_some()));
    if let Some(outcome) = outcome {
        unsafe { ptr::write(buffer.outcomes, gameplay::outcome_value(outcome)) };
    }
    unsafe { ptr::write(out_pointer, result) };
    state.session = session;
    state.active_step_token = Some(token);
    state.active_step_dt = desc.dt_seconds;
    state.next_step_token = next_token;
    Ok(())
}

struct GameplayPositionPlan {
    updates: [(ObjectKey, u8, [f32; 2]); MAX_OBJECTS],
    update_count: usize,
    hazard_directions: [f32; gameplay::MAX_CONTACTS],
}

fn plan_gameplay_positions(
    state: &RuntimeState,
    gameplay: &gameplay::State,
    dt_seconds: f32,
    input: [i8; 2],
) -> Result<GameplayPositionPlan, u32> {
    let mut updates = [(gameplay.player, gameplay.player_source_index, [0.0; 2]); MAX_OBJECTS];
    let mut hazard_directions = [1.0; gameplay::MAX_CONTACTS];
    let mut count = 0;
    updates[count] = (
        gameplay.player,
        gameplay.player_source_index,
        state
            .planned_step_position_at_source(
                gameplay.player_source_index,
                gameplay.player,
                dt_seconds,
                input,
            )
            .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?,
    );
    count += 1;
    for (index, hazard) in gameplay.hazards[..gameplay.hazard_count].iter().enumerate() {
        let hazard = hazard.as_ref().expect("descriptor hazards are dense");
        hazard_directions[index] = hazard.patrol_direction;
        if hazard.movement_mode != abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL
            || hazard.patrol_speed == 0.0
            || dt_seconds == 0.0
        {
            continue;
        }
        let record = state
            .source_visible_exact(hazard.source_index, hazard.object)
            .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?;
        let span = f64::from(hazard.patrol_max_y - hazard.patrol_min_y);
        let period = span * 2.0;
        let phase = (f64::from(record.sprite.position[1] - hazard.patrol_min_y)
            + f64::from(hazard.patrol_speed)
                * f64::from(dt_seconds)
                * f64::from(hazard.patrol_direction))
        .rem_euclid(period);
        let (y, direction) = if phase < span {
            (f64::from(hazard.patrol_min_y) + phase, 1.0)
        } else {
            (f64::from(hazard.patrol_max_y) - (phase - span), -1.0)
        };
        let position = state
            .planned_absolute_position_at_source(
                hazard.source_index,
                hazard.object,
                [record.sprite.position[0], y as f32],
            )
            .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?;
        updates[count] = (hazard.object, hazard.source_index, position);
        count += 1;
        hazard_directions[index] = direction;
    }
    Ok(GameplayPositionPlan {
        updates,
        update_count: count,
        hazard_directions,
    })
}

fn commit_gameplay_fixed(
    core_pointer: *mut abi::kadath_runtime_core_t,
    desc_pointer: *const abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t,
    buffer_pointer: *mut abi::kadath_runtime_gameplay_outcome_buffer_v1_t,
    out_pointer: *mut abi::kadath_runtime_gameplay_step_result_v1_t,
) -> Result<(), u32> {
    if desc_pointer.is_null()
        || (desc_pointer as usize)
            % mem::align_of::<abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    valid_output(out_pointer)?;
    let buffer = validate_outcome_buffer(buffer_pointer)?;
    let desc = unsafe { &*desc_pointer };
    if desc.struct_size
        < mem::size_of::<abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t>() as u32
        || desc.reserved_input != [0; 2]
        || desc.reserved0 != 0
        || desc.reserved1 != 0
        || !reserved_is_zero(&desc.reserved)
        || !(-1..=1).contains(&desc.move_x)
        || !(-1..=1).contains(&desc.move_y)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let buffer_range = strided_range(
        buffer_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_buffer_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let outcome_range = strided_range(
        buffer.outcomes as usize,
        buffer.outcome_capacity,
        buffer.outcome_stride,
        mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let result_range = strided_range(
        out_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    ensure_disjoint(&[desc_range, buffer_range, outcome_range, result_range])?;
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    core.phase.ensure_gameplay_commit_allowed()?;
    let gameplay = core
        .gameplay
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)?;
    if gameplay.active_step_token != Some(desc.step_token) {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STALE_TOKEN);
    }
    trigger_test_fault(core, TEST_ENTRY_MUTATE)?;
    let gameplay = core
        .gameplay
        .as_ref()
        .expect("Gameplay state was preflighted");
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)?;
    let actual_dt = gameplay.active_step_dt;
    let movement_input = if gameplay.session.accepts_input() {
        [desc.move_x, desc.move_y]
    } else {
        [0, 0]
    };
    let position_plan = plan_gameplay_positions(state, gameplay, actual_dt, movement_input)?;
    let observation = gameplay::active_contacts(
        state,
        gameplay,
        &position_plan.updates[..position_plan.update_count],
    )?;
    let mut session = gameplay.session;
    let outcome = session
        .observe_contacts(gameplay.player, observation.first_hazard, observation.goal)
        .map_err(|_| abi::KADATH_ERR_RUNTIME_GAMEPLAY_SEQUENCE_EXHAUSTED)?;
    let (transitions, transition_count) = gameplay::contact_transitions(
        state,
        gameplay,
        &observation.contacts,
        observation.count,
        &observation.source_indices,
        &observation.source_mask,
    )?;
    // 先通过 Phase authority 提交，再发布 Gameplay 状态；事件在队列边界直接构造。
    let event_count = gameplay::submit_contact_transitions(
        core,
        gameplay.player,
        &transitions[..transition_count],
    )?;
    core.live
        .as_mut()
        .expect("live state was preflighted")
        .apply_planned_positions(&position_plan.updates[..position_plan.update_count]);
    let gameplay = core
        .gameplay
        .as_mut()
        .expect("Gameplay state was preflighted");
    for (index, hazard) in gameplay.hazards[..gameplay.hazard_count]
        .iter_mut()
        .enumerate()
    {
        hazard
            .as_mut()
            .expect("descriptor hazards are dense")
            .patrol_direction = position_plan.hazard_directions[index];
    }
    gameplay.session = session;
    gameplay.previous_contacts = observation.contacts;
    gameplay.previous_source_indices = observation.source_indices;
    gameplay.previous_contact_mask = observation.source_mask;
    gameplay.previous_contact_count = observation.count;
    gameplay.active_step_token = None;
    gameplay.active_step_dt = 0.0;
    let result = gameplay::step_result(
        gameplay.session,
        desc.step_token,
        event_count,
        usize::from(outcome.is_some()),
    );
    if let Some(outcome) = outcome {
        unsafe { ptr::write(buffer.outcomes, gameplay::outcome_value(outcome)) };
    }
    unsafe { ptr::write(out_pointer, result) };
    Ok(())
}

fn abort_gameplay_fixed(
    core_pointer: *mut abi::kadath_runtime_core_t,
    token: u64,
) -> Result<(), u32> {
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let state = core
        .gameplay
        .as_mut()
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)?;
    if state.active_step_token != Some(token) {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STALE_TOKEN);
    }
    state.active_step_token = None;
    state.active_step_dt = 0.0;
    Ok(())
}

fn publish_gameplay_snapshot(
    core_pointer: *mut abi::kadath_runtime_core_t,
    buffer_pointer: *mut abi::kadath_runtime_render_buffer_v1_t,
    out_pointer: *mut abi::kadath_runtime_gameplay_snapshot_v1_t,
) -> Result<(), u32> {
    valid_output(buffer_pointer)?;
    valid_output(out_pointer)?;
    // 完整建立alias/range契约前，只把descriptor视为本次调用复制的字节。
    let buffer = unsafe { ptr::read(buffer_pointer) };
    if buffer.reserved0 != 0
        || !reserved_is_zero(&buffer.reserved)
        || buffer.items.is_null()
        || buffer.item_capacity == 0
        || buffer.item_capacity > MAX_OBJECTS
        || buffer.item_stride < mem::size_of::<abi::kadath_runtime_render_item_v1_t>()
        || buffer.item_stride % mem::align_of::<abi::kadath_runtime_render_item_v1_t>() != 0
        || (buffer.items as usize) % mem::align_of::<abi::kadath_runtime_render_item_v1_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let buffer_range = strided_range(
        buffer_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_render_buffer_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let item_range = strided_range(
        buffer.items as usize,
        buffer.item_capacity,
        buffer.item_stride,
        mem::size_of::<abi::kadath_runtime_render_item_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let snapshot_range = strided_range(
        out_pointer as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_gameplay_snapshot_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    ensure_disjoint(&[buffer_range, item_range, snapshot_range])?;
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    if !core.phase.is_fully_idle() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    let gameplay = core
        .gameplay
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)?;
    if gameplay.active_step_token.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STEP_BUSY);
    }
    if core.live.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE);
    }
    trigger_test_fault(core, TEST_ENTRY_QUERY)?;
    let gameplay = core
        .gameplay
        .as_ref()
        .expect("Gameplay state was preflighted");
    let live = core.live.as_ref().expect("live state was preflighted");
    let count = live.visible_count(true);
    if buffer.item_capacity < count {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    for index in 0..count {
        let pointer = unsafe {
            buffer
                .items
                .cast::<u8>()
                .add(index * buffer.item_stride)
                .cast::<abi::kadath_runtime_render_item_v1_t>()
        };
        if unsafe { read_struct_size(pointer) }?
            < mem::size_of::<abi::kadath_runtime_render_item_v1_t>() as u32
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
    }
    let mut index = 0;
    live.for_each_active_ordered(|record| {
        let mut color = record.sprite.color;
        if record.source_index == Some(gameplay.player_source_index) {
            color = match gameplay.session.phase {
                gameplay::Phase::Won => [0.20, 0.95, 0.35, 1.0],
                gameplay::Phase::Lost => [0.95, 0.20, 0.20, 1.0],
                gameplay::Phase::Playing => color,
            };
        }
        let item = abi::kadath_runtime_render_item_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_render_item_v1_t>() as u32,
            reserved0: 0,
            object_ref: object_ref(record, live.world_epoch),
            entity_value: record.entity_value,
            position: record.sprite.position,
            size: record.sprite.size,
            final_color: color,
            texture_id: record.sprite.texture_id,
            reserved1: 0,
            reserved: [0; 4],
        };
        unsafe {
            ptr::write(
                buffer
                    .items
                    .cast::<u8>()
                    .add(index * buffer.item_stride)
                    .cast(),
                item,
            )
        };
        index += 1;
    });
    let session_result = gameplay::step_result(gameplay.session, 0, 0, 0);
    let snapshot = abi::kadath_runtime_gameplay_snapshot_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_gameplay_snapshot_v1_t>() as u32,
        phase: session_result.phase,
        cause: session_result.cause,
        accepts_input: u32::from(gameplay.session.accepts_input()),
        world_epoch: live.world_epoch,
        last_outcome_sequence: gameplay.session.last_outcome_sequence,
        time_remaining_seconds: gameplay.session.time_remaining_seconds,
        reserved0: 0,
        render_count: count,
        reserved: [0; 4],
    };
    unsafe { ptr::write(out_pointer, snapshot) };
    Ok(())
}

extern "C" fn prepare_gameplay_state_entry(
    core: *mut abi::kadath_runtime_core_t,
    desc: *const abi::kadath_runtime_gameplay_desc_v1_t,
    out: *mut abi::kadath_runtime_gameplay_candidate_info_v1_t,
) -> i32 {
    ffi_result(|| prepare_gameplay_state(core, desc, out))
}
extern "C" fn begin_gameplay_fixed_entry(
    core: *mut abi::kadath_runtime_core_t,
    desc: *const abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t,
    buffer: *mut abi::kadath_runtime_gameplay_outcome_buffer_v1_t,
    out: *mut abi::kadath_runtime_gameplay_step_result_v1_t,
) -> i32 {
    ffi_result(|| begin_gameplay_fixed(core, desc, buffer, out))
}
extern "C" fn commit_gameplay_fixed_entry(
    core: *mut abi::kadath_runtime_core_t,
    desc: *const abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t,
    buffer: *mut abi::kadath_runtime_gameplay_outcome_buffer_v1_t,
    out: *mut abi::kadath_runtime_gameplay_step_result_v1_t,
) -> i32 {
    ffi_result(|| commit_gameplay_fixed(core, desc, buffer, out))
}
extern "C" fn abort_gameplay_fixed_entry(core: *mut abi::kadath_runtime_core_t, token: u64) -> i32 {
    ffi_result(|| abort_gameplay_fixed(core, token))
}
extern "C" fn publish_gameplay_snapshot_entry(
    core: *mut abi::kadath_runtime_core_t,
    buffer: *mut abi::kadath_runtime_render_buffer_v1_t,
    out: *mut abi::kadath_runtime_gameplay_snapshot_v1_t,
) -> i32 {
    ffi_result(|| publish_gameplay_snapshot(core, buffer, out))
}

fn query_gameplay_interface(
    pointer: *mut abi::kadath_runtime_gameplay_interface_v1_t,
) -> Result<(), u32> {
    valid_output(pointer)?;
    let requested = unsafe { ptr::read(pointer) };
    if !reserved_is_zero(&requested.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if requested.interface_version != abi::KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1 {
        return Err(abi::KADATH_ERR_NOT_SUPPORTED);
    }
    unsafe {
        ptr::write(
            pointer,
            abi::kadath_runtime_gameplay_interface_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_gameplay_interface_v1_t>() as u32,
                interface_version: abi::KADATH_RUNTIME_GAMEPLAY_INTERFACE_V1,
                prepare_gameplay_state: Some(prepare_gameplay_state_entry),
                begin_fixed_step: Some(begin_gameplay_fixed_entry),
                commit_fixed_step: Some(commit_gameplay_fixed_entry),
                abort_fixed_step: Some(abort_gameplay_fixed_entry),
                publish_snapshot: Some(publish_gameplay_snapshot_entry),
                reserved: [0; 8],
            },
        )
    };
    Ok(())
}

#[no_mangle]
pub extern "C" fn kadath_runtime_core_query_gameplay_interface(
    pointer: *mut abi::kadath_runtime_gameplay_interface_v1_t,
) -> i32 {
    ffi_result(|| query_gameplay_interface(pointer))
}

#[cfg(feature = "contract-test-hooks")]
#[repr(C)]
pub struct TestFaultDesc {
    struct_size: u32,
    entry: u32,
    fault: u32,
    reserved0: u32,
    reserved: [u64; 4],
}

#[cfg(feature = "contract-test-hooks")]
fn arm_next_fault(
    core_pointer: *mut abi::kadath_runtime_core_t,
    desc: *const TestFaultDesc,
) -> Result<(), u32> {
    if core_pointer.is_null()
        || desc.is_null()
        || (desc as usize) % mem::align_of::<TestFaultDesc>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    let desc_size = unsafe { read_struct_size(desc) }?;
    if desc_size < mem::size_of::<TestFaultDesc>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc };
    if desc.reserved0 != 0
        || !reserved_is_zero(&desc.reserved)
        || !matches!(
            desc.entry,
            TEST_ENTRY_PREPARE | TEST_ENTRY_QUERY | TEST_ENTRY_MUTATE
        )
        || !(TEST_FAULT_PANIC_BEFORE_PUBLICATION..=TEST_FAULT_ALLOCATION_FAILURE)
            .contains(&desc.fault)
        || core.next_fault.is_some()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    core.next_fault = Some(TestFault {
        entry: desc.entry,
        fault: desc.fault,
    });
    Ok(())
}

#[cfg(feature = "contract-test-hooks")]
#[no_mangle]
pub extern "C" fn kadath_runtime_core_test_arm_next_fault(
    core: *mut abi::kadath_runtime_core_t,
    desc: *const TestFaultDesc,
) -> i32 {
    ffi_result(|| arm_next_fault(core, desc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reentrant_entry_is_rejected_without_clearing_outer_call_state() {
        let mut core = RuntimeCore {
            owner_thread: thread::current().id(),
            in_call: true,
            live: None,
            candidate: None,
            candidate_next_entity_value: None,
            candidate_mode: None,
            next_entity_value: 1,
            phase: phase_commit::PhaseState::new_boxed().expect("phase arena allocation"),
            gameplay: None,
            gameplay_candidate: None,
            #[cfg(feature = "contract-test-hooks")]
            next_fault: None,
        };
        let pointer = (&mut core as *mut RuntimeCore).cast::<abi::kadath_runtime_core_t>();
        assert_eq!(
            abort_scene_entry(pointer),
            error(abi::KADATH_ERR_RUNTIME_REENTRANT)
        );
        assert!(core.in_call);
        assert!(core.live.is_none());
        assert!(core.candidate.is_none());
    }

    #[test]
    fn gameplay_outcome_buffer_validation_covers_pointer_stride_capacity_and_reserved_fields() {
        let mut outcome = abi::kadath_runtime_gameplay_outcome_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        let mut buffer = abi::kadath_runtime_gameplay_outcome_buffer_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_outcome_buffer_v1_t>() as u32,
            outcomes: &mut outcome,
            outcome_capacity: 1,
            outcome_stride: mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>(),
            ..unsafe { mem::zeroed() }
        };

        // 有效 caller-owned buffer 必须完整通过；后续每个字段单独覆盖一个 preflight 分支。
        assert!(validate_outcome_buffer(&mut buffer).is_ok());
        let valid = buffer;
        buffer.reserved0 = 1;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.reserved[0] = 1;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.reserved0 = 1;
        buffer.reserved[0] = 1;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.outcomes = std::ptr::null_mut();
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.outcome_capacity = 0;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.outcome_stride = mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() - 1;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        buffer.outcome_stride = mem::align_of::<abi::kadath_runtime_gameplay_outcome_v1_t>();
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        // stride 足够大但不自然对齐时，必须由独立 alignment 分支拒绝，
        // 不能让 OR→AND 变异被前面的长度校验掩盖。
        buffer.outcome_stride = mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() + 1;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        let mut misaligned_storage = [0_u8; 256];
        let alignment = mem::align_of::<abi::kadath_runtime_gameplay_outcome_v1_t>();
        assert!(
            alignment > 1,
            "ABI outcome alignment must expose an alignment preflight branch"
        );
        let misaligned_address =
            ((misaligned_storage.as_mut_ptr() as usize + alignment - 1) & !(alignment - 1)) + 1;
        // 先写入合法 struct_size，避免对齐 mutant 被后续读取失败掩盖。
        unsafe {
            std::ptr::write_unaligned(
                misaligned_address as *mut u32,
                mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() as u32,
            );
        }
        buffer.outcomes = misaligned_address as *mut abi::kadath_runtime_gameplay_outcome_v1_t;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        buffer = valid;
        let mut short_outcome = outcome;
        short_outcome.struct_size = 0;
        buffer.outcomes = &mut short_outcome;
        assert!(matches!(
            validate_outcome_buffer(&mut buffer),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn gameplay_output_preflight_rejects_null_misaligned_and_short_structs() {
        let mut value = abi::kadath_runtime_gameplay_step_result_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        assert!(valid_output(&mut value).is_ok());
        assert!(matches!(
            valid_output::<abi::kadath_runtime_gameplay_step_result_v1_t>(std::ptr::null_mut()),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
        value.struct_size = 0;
        assert!(matches!(
            valid_output(&mut value),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));
    }

    fn gameplay_test_object_ref(
        id: &[u8],
        kind: u32,
        epoch: u64,
    ) -> abi::kadath_runtime_object_ref_v1_t {
        let object_id = ObjectId::parse(id).expect("test object id is valid");
        abi::kadath_runtime_object_ref_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
            kind,
            world_epoch: epoch,
            logical_generation: 1,
            object_id_length: object_id.len(),
            reserved0: 0,
            object_id: object_id.storage(),
            reserved: [0; 4],
        }
    }

    fn gameplay_test_core(mode: u32) -> Box<RuntimeCore> {
        let sources = [
            SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                sprite: Sprite {
                    position: [0.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 1.0,
                },
            },
            SourceObject {
                object_id: ObjectId::parse(b"goal").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_GOAL,
                sprite: Sprite {
                    position: [10.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 0.0,
                },
            },
            SourceObject {
                object_id: ObjectId::parse(b"hazard").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                sprite: Sprite {
                    position: [20.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 0.0,
                },
            },
        ];
        let live = RuntimeState::initial(
            1,
            1,
            Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
            &sources,
            &[1, 2, 3],
        );
        Box::new(RuntimeCore {
            owner_thread: thread::current().id(),
            in_call: false,
            live: Some(live.clone()),
            candidate: Some(live),
            candidate_next_entity_value: Some(4),
            candidate_mode: Some(mode),
            next_entity_value: 4,
            phase: phase_commit::PhaseState::new_boxed().expect("phase arena allocation"),
            gameplay: None,
            gameplay_candidate: None,
            #[cfg(feature = "contract-test-hooks")]
            next_fault: None,
        })
    }

    fn gameplay_test_hazard() -> abi::kadath_runtime_gameplay_hazard_desc_v1_t {
        abi::kadath_runtime_gameplay_hazard_desc_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>() as u32,
            movement_mode: abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE,
            object_ref: gameplay_test_object_ref(
                b"hazard",
                abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                1,
            ),
            patrol_min_y: 0.0,
            patrol_max_y: 0.0,
            patrol_speed: 0.0,
            reserved0: 0,
            reserved: [0; 4],
        }
    }

    fn gameplay_test_desc(
        hazards: *const abi::kadath_runtime_gameplay_hazard_desc_v1_t,
    ) -> abi::kadath_runtime_gameplay_desc_v1_t {
        abi::kadath_runtime_gameplay_desc_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_desc_v1_t>() as u32,
            reserved0: 0,
            time_limit_seconds: 3.0,
            hazard_count: 1,
            player: gameplay_test_object_ref(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER, 1),
            goal: gameplay_test_object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL, 1),
            hazards,
            hazard_stride: mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>(),
            reserved: [0; 6],
        }
    }

    fn run_gameplay_prepare(
        desc: abi::kadath_runtime_gameplay_desc_v1_t,
        _hazards: &mut [abi::kadath_runtime_gameplay_hazard_desc_v1_t; 2],
    ) -> (
        i32,
        Box<RuntimeCore>,
        abi::kadath_runtime_gameplay_candidate_info_v1_t,
    ) {
        let mut output = abi::kadath_runtime_gameplay_candidate_info_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_candidate_info_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        let mut core = gameplay_test_core(abi::KADATH_RUNTIME_PREPARE_INITIAL);
        let pointer = (&mut *core as *mut RuntimeCore).cast::<abi::kadath_runtime_core_t>();
        let status = prepare_gameplay_state_entry(pointer, &desc, &mut output);
        (status, core, output)
    }

    #[test]
    fn gameplay_prepare_preflight_covers_descriptor_and_hazard_validation() {
        let mut hazards = [gameplay_test_hazard(), gameplay_test_hazard()];
        let valid = gameplay_test_desc(hazards.as_ptr());
        let (status, core, output) = run_gameplay_prepare(valid, &mut hazards);
        assert_eq!(status, abi::KADATH_OK as i32);
        assert_eq!(output.hazard_count, 1);
        assert_eq!(output.world_epoch, 1);
        assert!(core.gameplay_candidate.is_some());

        let invalid = [
            {
                let mut value = valid;
                value.struct_size = 0;
                value
            },
            {
                let mut value = valid;
                value.reserved0 = 1;
                value
            },
            {
                let mut value = valid;
                value.reserved[0] = 1;
                value
            },
            {
                let mut value = valid;
                value.time_limit_seconds = f32::NAN;
                value
            },
            {
                let mut value = valid;
                value.time_limit_seconds = 0.0;
                value
            },
            {
                let mut value = valid;
                value.hazard_count = 0;
                value
            },
            {
                let mut value = valid;
                value.hazard_count = (gameplay::MAX_CONTACTS - 1 + 1) as u32;
                value
            },
            {
                let mut value = valid;
                value.hazards = std::ptr::null();
                value
            },
            {
                let mut value = valid;
                value.hazard_stride =
                    mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>() - 1;
                value
            },
            {
                let mut value = valid;
                value.hazard_stride =
                    mem::size_of::<abi::kadath_runtime_gameplay_hazard_desc_v1_t>() + 1;
                value
            },
            {
                let mut value = valid;
                value.player.kind = abi::KADATH_RUNTIME_OBJECT_KIND_GOAL;
                value
            },
            {
                let mut value = valid;
                value.goal.kind = abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER;
                value
            },
            {
                let mut value = valid;
                value.goal = value.player;
                value
            },
        ];
        for (index, desc) in invalid.into_iter().enumerate() {
            let (status, core, _) = run_gameplay_prepare(desc, &mut hazards);
            assert_ne!(status, abi::KADATH_OK as i32, "descriptor case {index}");
            assert!(core.gameplay_candidate.is_none());
        }

        let hazard_invalid = [
            {
                let mut value = hazards[0];
                value.struct_size = 0;
                value
            },
            {
                let mut value = hazards[0];
                value.reserved0 = 1;
                value
            },
            {
                let mut value = hazards[0];
                value.reserved[0] = 1;
                value
            },
            {
                let mut value = hazards[0];
                value.movement_mode = 99;
                value
            },
            {
                let mut value = hazards[0];
                value.object_ref.world_epoch = 2;
                value
            },
            {
                let mut value = hazards[0];
                value.object_ref.kind = abi::KADATH_RUNTIME_OBJECT_KIND_GOAL;
                value
            },
            {
                let mut value = hazards[0];
                value.patrol_min_y = 1.0;
                value
            },
            {
                let mut value = hazards[0];
                value.movement_mode = abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL;
                value.patrol_min_y = 2.0;
                value.patrol_max_y = 1.0;
                value
            },
            {
                let mut value = hazards[0];
                value.movement_mode = abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL;
                value.patrol_min_y = 0.0;
                value.patrol_max_y = 2.0;
                value.patrol_speed = f32::NAN;
                value
            },
        ];
        for (index, hazard) in hazard_invalid.into_iter().enumerate() {
            hazards[0] = hazard;
            let (status, core, _) = run_gameplay_prepare(valid, &mut hazards);
            assert_ne!(status, abi::KADATH_OK as i32, "hazard case {index}");
            assert!(core.gameplay_candidate.is_none());
            hazards[0] = gameplay_test_hazard();
        }
    }

    #[test]
    fn gameplay_position_plan_covers_player_and_legacy_patrol_paths() {
        let core = gameplay_test_core(abi::KADATH_RUNTIME_PREPARE_INITIAL);
        let state = core.live.as_ref().expect("test live state");
        let player = ObjectKey {
            object_id: ObjectId::parse(b"player").unwrap(),
            world_epoch: 1,
            logical_generation: 1,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
        };
        let goal = ObjectKey {
            object_id: ObjectId::parse(b"goal").unwrap(),
            world_epoch: 1,
            logical_generation: 1,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_GOAL,
        };
        let hazard_key = ObjectKey {
            object_id: ObjectId::parse(b"hazard").unwrap(),
            world_epoch: 1,
            logical_generation: 1,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
        };
        let patrol = gameplay::Hazard {
            object: hazard_key,
            source_index: 2,
            movement_mode: abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL,
            patrol_min_y: 0.0,
            patrol_max_y: 10.0,
            patrol_speed: 2.0,
            patrol_direction: 1.0,
        };
        let gameplay = gameplay::State::new(player, 0, goal, 1, &[patrol], 3.0, 1, 1);

        // 玩家位移与巡逻 hazard 同时规划；dt=5 将 phase 推到 span 边界，
        // 独立命中正向和反向 patrol 分支以及两个 update_count 增量。
        let plan = plan_gameplay_positions(state, &gameplay, 5.0, [1, 0]).unwrap();
        assert_eq!(plan.update_count, 2);
        assert_eq!(plan.updates[0].0, player);
        assert_eq!(plan.updates[0].2, [5.0, 0.0]);
        assert_eq!(plan.updates[1].0, hazard_key);
        assert_eq!(plan.updates[1].2, [20.0, 10.0]);
        assert_eq!(plan.hazard_directions[0], -1.0);

        // phase 位于 span 内时必须沿正方向前进，覆盖加法和 rem_euclid 输入。
        let plan = plan_gameplay_positions(state, &gameplay, 1.0, [0, 0]).unwrap();
        assert_eq!(plan.updates[1].2, [20.0, 2.0]);
        assert_eq!(plan.hazard_directions[0], 1.0);

        // 三个 continue 条件各自独立验证，避免 OR→AND 变异漏过。
        for (movement_mode, patrol_speed, dt_seconds) in [
            (abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE, 2.0, 1.0),
            (
                abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL,
                0.0,
                1.0,
            ),
            (
                abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_LEGACY_PATROL,
                2.0,
                0.0,
            ),
        ] {
            let mut hazard = patrol;
            hazard.movement_mode = movement_mode;
            hazard.patrol_speed = patrol_speed;
            let gameplay = gameplay::State::new(player, 0, goal, 1, &[hazard], 3.0, 1, 1);
            let plan = plan_gameplay_positions(state, &gameplay, dt_seconds, [0, 0]).unwrap();
            assert_eq!(plan.update_count, 1);
            assert_eq!(plan.hazard_directions[0], 1.0);
        }
    }

    #[test]
    fn gameplay_apply_positions_validates_batch_and_publishes_clamped_updates() {
        let core = gameplay_test_core(abi::KADATH_RUNTIME_PREPARE_INITIAL);
        let initial = core.live.as_ref().expect("test live state").clone();
        let player = gameplay_test_object_ref(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER, 1);
        let mut patches = [abi::kadath_runtime_position_patch_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() as u32,
            reserved0: 0,
            object_ref: player,
            position: [200.0, 200.0],
            reserved: [0; 4],
        }];
        let base = abi::kadath_runtime_position_batch_v1_t {
            patches: patches.as_ptr(),
            patch_count: 1,
            patch_stride: mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
        };
        let empty_range = (0, 0);

        // 合法批次必须一次性验证后发布，并由 Object Authority 做 bounds clamp。
        let mut state = initial.clone();
        assert_eq!(
            apply_positions(&mut state, &base, empty_range, empty_range),
            Ok(())
        );
        let player_key = read_object_key(&player).unwrap();
        assert_eq!(
            state.visible_exact(player_key).unwrap().sprite.position,
            [98.0, 98.0]
        );

        // 顶层 batch preflight 的每个条件都独立命中，避免 OR→AND 变异漏过。
        let mut invalid = base;
        invalid.patches = std::ptr::null();
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        invalid = base;
        invalid.patch_count = 0;
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        invalid = base;
        invalid.patch_count = MAX_OBJECTS + 1;
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        let alignment = mem::align_of::<abi::kadath_runtime_position_patch_v1_t>();
        let mut misaligned = [0_u8; 256];
        let misaligned_address =
            ((misaligned.as_mut_ptr() as usize + alignment - 1) & !(alignment - 1)) + 1;
        invalid = base;
        invalid.patches = misaligned_address as *const _;
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        invalid = base;
        invalid.patch_stride = mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() - 1;
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        invalid = base;
        invalid.patch_stride = mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() + 1;
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());
        invalid = base;
        invalid.patch_count = MAX_OBJECTS;
        invalid.patch_stride = usize::MAX - (alignment - 1);
        assert!(apply_positions(&mut initial.clone(), &invalid, empty_range, empty_range).is_err());

        let patch_range = (
            patches.as_ptr() as usize,
            patches.as_ptr() as usize + mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
        );
        assert!(apply_positions(&mut initial.clone(), &base, patch_range, empty_range).is_err());
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, patch_range).is_err());

        // patch 级别的 struct/reserved/finite/key/duplicate 校验也必须拒绝且不改状态。
        patches[0].struct_size = 0;
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, empty_range).is_err());
        patches[0].struct_size = mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() as u32;
        patches[0].reserved0 = 1;
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, empty_range).is_err());
        patches[0].reserved0 = 0;
        patches[0].reserved[0] = 1;
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, empty_range).is_err());
        patches[0].reserved[0] = 0;
        patches[0].position = [f32::NAN, 0.0];
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, empty_range).is_err());
        patches[0].position = [200.0, 200.0];
        patches[0].object_ref.world_epoch = 2;
        assert!(apply_positions(&mut initial.clone(), &base, empty_range, empty_range).is_err());
        patches[0].object_ref = player;

        let duplicate = [patches[0], patches[0]];
        let duplicate_batch = abi::kadath_runtime_position_batch_v1_t {
            patches: duplicate.as_ptr(),
            patch_count: 2,
            patch_stride: mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
        };
        assert!(apply_positions(
            &mut initial.clone(),
            &duplicate_batch,
            empty_range,
            empty_range
        )
        .is_err());
    }

    #[test]
    fn gameplay_snapshot_validates_caller_buffer_and_publishes_terminal_tint() {
        let mut core = gameplay_test_core(abi::KADATH_RUNTIME_PREPARE_INITIAL);
        let player = gameplay_test_object_ref(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER, 1);
        let goal = gameplay_test_object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL, 1);
        let player_key = read_object_key(&player).unwrap();
        let goal_key = read_object_key(&goal).unwrap();
        let hazard_key = ObjectKey {
            object_id: ObjectId::parse(b"hazard").unwrap(),
            world_epoch: 1,
            logical_generation: 1,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
        };
        let hazard = gameplay::Hazard {
            object: hazard_key,
            source_index: 2,
            movement_mode: abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE,
            patrol_min_y: 0.0,
            patrol_max_y: 0.0,
            patrol_speed: 0.0,
            patrol_direction: 1.0,
        };
        core.gameplay = Some(gameplay::State::new(
            player_key,
            0,
            goal_key,
            1,
            &[hazard],
            3.0,
            1,
            1,
        ));
        let pointer = (&mut *core as *mut RuntimeCore).cast::<abi::kadath_runtime_core_t>();
        let render_size = mem::size_of::<abi::kadath_runtime_render_item_v1_t>();
        let mut items = [abi::kadath_runtime_render_item_v1_t {
            struct_size: render_size as u32,
            ..unsafe { mem::zeroed() }
        }; 3];
        let mut buffer = abi::kadath_runtime_render_buffer_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_render_buffer_v1_t>() as u32,
            reserved0: 0,
            items: items.as_mut_ptr(),
            item_capacity: items.len(),
            item_stride: render_size,
            reserved: [0; 4],
        };
        let mut snapshot = abi::kadath_runtime_gameplay_snapshot_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_snapshot_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };

        // Playing/Won/Lost 三态都必须写出稳定的 phase、cause、input 与玩家颜色。
        for (phase, expected_color) in [
            (gameplay::Phase::Playing, [1.0, 1.0, 1.0, 1.0]),
            (gameplay::Phase::Won, [0.20, 0.95, 0.35, 1.0]),
            (gameplay::Phase::Lost, [0.95, 0.20, 0.20, 1.0]),
        ] {
            let state = core.gameplay.as_mut().unwrap();
            state.session.phase = phase;
            state.session.cause = match phase {
                gameplay::Phase::Playing => gameplay::Cause::None,
                gameplay::Phase::Won => gameplay::Cause::Goal,
                gameplay::Phase::Lost => gameplay::Cause::Hazard,
            };
            assert_eq!(
                publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot),
                Ok(())
            );
            assert_eq!(snapshot.render_count, 3);
            assert_eq!(
                snapshot.accepts_input,
                u32::from(phase == gameplay::Phase::Playing)
            );
            assert_eq!(items[0].final_color, expected_color);
        }

        // buffer/output 的 descriptor、reserved、容量、stride、指针对齐和结构体大小
        // 各自独立拒绝；每个失败都发生在写入 caller storage 之前。
        let valid_buffer = buffer;
        let valid_snapshot = snapshot;
        buffer.reserved0 = 1;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.reserved[0] = 1;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.items = std::ptr::null_mut();
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.item_capacity = 0;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.item_capacity = MAX_OBJECTS + 1;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.item_stride = render_size - 1;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.item_stride = render_size + 1;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        let alignment = mem::align_of::<abi::kadath_runtime_render_item_v1_t>();
        let mut misaligned = [0_u8; 256];
        let misaligned_address =
            ((misaligned.as_mut_ptr() as usize + alignment - 1) & !(alignment - 1)) + 1;
        buffer = valid_buffer;
        buffer.items = misaligned_address as *mut _;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.item_capacity = 2;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        items[0].struct_size = 0;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        assert_eq!(items[0].struct_size, 0);

        buffer = valid_buffer;
        buffer.items = (&mut buffer as *mut abi::kadath_runtime_render_buffer_v1_t).cast();
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.items = (&mut snapshot as *mut abi::kadath_runtime_gameplay_snapshot_v1_t).cast();
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        buffer.struct_size = 0;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
        buffer = valid_buffer;
        snapshot = valid_snapshot;
        snapshot.struct_size = 0;
        assert!(publish_gameplay_snapshot(pointer, &mut buffer, &mut snapshot).is_err());
    }

    #[test]
    fn gameplay_begin_and_commit_entries_validate_descriptors_and_tokens() {
        let mut core = gameplay_test_core(abi::KADATH_RUNTIME_PREPARE_INITIAL);
        let player = read_object_key(&gameplay_test_object_ref(
            b"player",
            abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
            1,
        ))
        .unwrap();
        let goal = read_object_key(&gameplay_test_object_ref(
            b"goal",
            abi::KADATH_RUNTIME_OBJECT_KIND_GOAL,
            1,
        ))
        .unwrap();
        // 直接准备一个无 hazard 的 Gameplay state，使 begin/commit 可以独立验证
        // descriptor、step token 与 Phase 活跃边界，不依赖外层 Zig 编排。
        core.candidate = None;
        core.candidate_next_entity_value = None;
        core.candidate_mode = None;
        core.gameplay = Some(gameplay::State::new(player, 0, goal, 1, &[], 3.0, 1, 1));
        let pointer = (&mut *core as *mut RuntimeCore).cast::<abi::kadath_runtime_core_t>();
        let begin_size = mem::size_of::<abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t>();
        let mut begin_desc = abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t {
            struct_size: begin_size as u32,
            dt_seconds: 0.0,
            reserved0: 0,
            reserved1: 0,
            reserved: [0; 4],
        };
        let mut outcome = abi::kadath_runtime_gameplay_outcome_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        let mut outcome_buffer = abi::kadath_runtime_gameplay_outcome_buffer_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_outcome_buffer_v1_t>() as u32,
            reserved0: 0,
            outcomes: &mut outcome,
            outcome_capacity: 1,
            outcome_stride: mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>(),
            reserved: [0; 4],
        };
        let mut begin_result = abi::kadath_runtime_gameplay_step_result_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };

        // begin 的 null/alignment/size/reserved/finite/range 分支逐一验证。
        assert_eq!(
            begin_gameplay_fixed(
                pointer,
                std::ptr::null(),
                &mut outcome_buffer,
                &mut begin_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            begin_gameplay_fixed(
                pointer,
                &begin_desc,
                &mut outcome_buffer,
                std::ptr::null_mut()
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let alignment = mem::align_of::<abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t>();
        let mut misaligned = [0_u8; 128];
        let misaligned_address =
            ((misaligned.as_mut_ptr() as usize + alignment - 1) & !(alignment - 1)) + 1;
        assert_eq!(
            begin_gameplay_fixed(
                pointer,
                misaligned_address as *const _,
                &mut outcome_buffer,
                &mut begin_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        for mutate in [
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| value.struct_size = 0,
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| value.reserved0 = 1,
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| value.reserved1 = 1,
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| value.reserved[0] = 1,
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| {
                value.dt_seconds = f32::NAN
            },
            |value: &mut abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t| {
                value.dt_seconds = -0.01
            },
        ] {
            begin_desc = abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t {
                struct_size: begin_size as u32,
                ..begin_desc
            };
            mutate(&mut begin_desc);
            assert_eq!(
                begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
                Err(abi::KADATH_ERR_INVALID_ARGUMENT)
            );
        }
        begin_desc = abi::kadath_runtime_gameplay_begin_fixed_desc_v1_t {
            struct_size: begin_size as u32,
            dt_seconds: 0.0,
            reserved0: 0,
            reserved1: 0,
            reserved: [0; 4],
        };

        // candidate/gameplay candidate、无Gameplay状态和Phase busy 都必须阻止 begin。
        let live_candidate = core.live.clone();
        core.candidate = live_candidate;
        assert!(matches!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)
        ));
        core.candidate = None;
        core.gameplay_candidate = Some(core.gameplay.as_ref().unwrap().clone());
        assert!(matches!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)
        ));
        core.gameplay_candidate = None;
        let saved_gameplay = core.gameplay.take().unwrap();
        assert!(matches!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_INVALID_STATE)
        ));
        core.gameplay = Some(saved_gameplay);

        let mut phase_desc = abi::kadath_runtime_phase_begin_desc_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32,
            domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            phase_sequence: 0,
            reserved0: 0,
            reserved1: 0,
            reserved: [0; 4],
        };
        let mut phase_result = abi::kadath_runtime_phase_begin_result_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        phase_commit::begin_phase_v2(&mut core, &phase_desc, &mut phase_result).unwrap();
        assert_eq!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY)
        );
        phase_commit::end_phase(
            &mut core,
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            phase_result.phase_sequence,
        )
        .unwrap();

        // 合法 begin 必须打开且只打开一个 step；重复 begin 命中 STEP_BUSY，
        // abort 后再进入 commit，验证 Rust 生成的 step token 贯穿整条路径。
        assert_eq!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Ok(())
        );
        let token = begin_result.step_token;
        assert_ne!(token, 0);
        assert_eq!(
            begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result),
            Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STEP_BUSY)
        );
        abort_gameplay_fixed(pointer.cast(), token).unwrap();

        // commit 前重新 begin，并打开固定 Phase；先验证 stale token，再验证合法提交。
        begin_gameplay_fixed(pointer, &begin_desc, &mut outcome_buffer, &mut begin_result).unwrap();
        let token = begin_result.step_token;
        phase_desc.phase_sequence = 0;
        phase_commit::begin_phase_v2(&mut core, &phase_desc, &mut phase_result).unwrap();
        let commit_size = mem::size_of::<abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t>();
        let mut commit_desc = abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t {
            struct_size: commit_size as u32,
            move_x: 0,
            move_y: 0,
            reserved_input: [0; 2],
            reserved0: 0,
            reserved1: 0,
            step_token: token + 1,
            reserved: [0; 4],
        };
        let mut commit_result = abi::kadath_runtime_gameplay_step_result_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>() as u32,
            ..unsafe { mem::zeroed() }
        };
        assert_eq!(
            commit_gameplay_fixed(
                pointer,
                &commit_desc,
                &mut outcome_buffer,
                &mut commit_result
            ),
            Err(abi::KADATH_ERR_RUNTIME_GAMEPLAY_STALE_TOKEN)
        );
        for mutate in [
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.struct_size = 0,
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| {
                value.reserved_input = [1, 0]
            },
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.reserved0 = 1,
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.reserved1 = 1,
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.reserved[0] = 1,
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.move_x = 2,
            |value: &mut abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t| value.move_y = -2,
        ] {
            commit_desc = abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t {
                struct_size: commit_size as u32,
                move_x: 0,
                move_y: 0,
                reserved_input: [0; 2],
                reserved0: 0,
                reserved1: 0,
                step_token: token,
                reserved: [0; 4],
            };
            mutate(&mut commit_desc);
            assert_eq!(
                commit_gameplay_fixed(
                    pointer,
                    &commit_desc,
                    &mut outcome_buffer,
                    &mut commit_result
                ),
                Err(abi::KADATH_ERR_INVALID_ARGUMENT)
            );
        }
        commit_desc = abi::kadath_runtime_gameplay_commit_fixed_desc_v1_t {
            struct_size: commit_size as u32,
            move_x: 0,
            move_y: 0,
            reserved_input: [0; 2],
            reserved0: 0,
            reserved1: 0,
            step_token: token,
            reserved: [0; 4],
        };
        assert_eq!(
            commit_gameplay_fixed(
                pointer,
                &commit_desc,
                &mut outcome_buffer,
                &mut commit_result
            ),
            Ok(())
        );
        assert_eq!(commit_result.step_token, token);
        assert_eq!(commit_result.submitted_contact_event_count, 0);
        assert_eq!(commit_result.outcome_count, 0);
        phase_commit::end_phase(
            &mut core,
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            phase_result.phase_sequence,
        )
        .unwrap();
    }
}
