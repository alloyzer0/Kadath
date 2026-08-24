#![allow(clippy::not_unsafe_ptr_arg_deref)]

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
    pub extern "C" fn kadath_runtime_core_phase_quality_begin_allocation_count() {
        ALLOCATIONS.store(0, Ordering::SeqCst);
        ENABLED.store(true, Ordering::SeqCst);
    }

    #[no_mangle]
    pub extern "C" fn kadath_runtime_core_phase_quality_end_allocation_count() -> u64 {
        ENABLED.store(false, Ordering::SeqCst);
        ALLOCATIONS.load(Ordering::SeqCst)
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
    next_entity_value: u64,
    phase: Box<phase_commit::PhaseState>,
    #[cfg(feature = "contract-test-hooks")]
    next_fault: Option<TestFault>,
}

#[cfg(feature = "contract-test-hooks")]
#[derive(Clone, Copy)]
struct TestFault {
    entry: u32,
    fault: u32,
}

#[cfg(feature = "contract-test-hooks")]
const TEST_ENTRY_PREPARE: u32 = 1;
#[cfg(feature = "contract-test-hooks")]
const TEST_ENTRY_QUERY: u32 = 2;
#[cfg(feature = "contract-test-hooks")]
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
        next_entity_value: 1,
        phase: phase_commit::PhaseState::new_boxed()?,
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
    unsafe { ptr::write(out_info, info) };
    Ok(())
}

fn commit_scene(core_pointer: *mut abi::kadath_runtime_core_t) -> Result<(), u32> {
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    core.phase.ensure_scene_commit_allowed()?;
    let candidate = core
        .candidate
        .take()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let next_entity_value = core
        .candidate_next_entity_value
        .take()
        .expect("candidate entity high-water accompanies candidate");
    core.live = Some(candidate);
    core.next_entity_value = next_entity_value;
    core.phase.reset_after_scene_commit();
    Ok(())
}

fn abort_scene(core_pointer: *mut abi::kadath_runtime_core_t) -> Result<(), u32> {
    let (core, _guard) = unsafe { enter_core(core_pointer) }?;
    core.candidate = None;
    core.candidate_next_entity_value = None;
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
    let mut parsed = Vec::new();
    parsed
        .try_reserve_exact(value.patch_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
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
        if parsed
            .iter()
            .any(|(existing, _): &(ObjectKey, [f32; 2])| *existing == key)
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        parsed.push((key, patch.position));
    }
    for (key, position) in parsed {
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
                || borrowed_ranges
                    .iter()
                    .any(|previous| ranges_overlap(*previous, patch_range))
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            borrowed_ranges.push(patch_range);
        }
    }
    let live_target = match batch.target {
        abi::KADATH_RUNTIME_TARGET_LIVE => true,
        abi::KADATH_RUNTIME_TARGET_CANDIDATE => false,
        _ => return Err(abi::KADATH_ERR_INVALID_ARGUMENT),
    };
    let mut state = if live_target {
        core.live.as_ref()
    } else {
        core.candidate.as_ref()
    }
    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?
    .clone();
    let mut next_entity = core.next_entity_value;
    let mut planned_results = Vec::new();
    planned_results
        .try_reserve_exact(batch.item_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    let mut lifecycle_refs: Vec<(ObjectKey, u32)> = Vec::new();
    lifecycle_refs
        .try_reserve_exact(batch.item_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
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
                if let Some((_, previous_tag)) = lifecycle_refs
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
                lifecycle_refs.push((key, item.tag));
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
        planned_results.push(result);
    }
    trigger_test_fault(core, 3)?;
    core.next_entity_value = next_entity;
    if live_target {
        core.live = Some(state);
    } else {
        core.candidate = Some(state);
    }
    for (index, result) in planned_results.into_iter().enumerate() {
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
            next_entity_value: 1,
            phase: phase_commit::PhaseState::new_boxed().expect("phase arena allocation"),
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
}
