use crate::{
    abi, authority_error, enter_core, ffi_result, object_ref, object_view, ranges_overlap,
    read_object_key, read_struct_size, reserved_is_zero, strided_range, RuntimeCore,
};
use crate::{object_authority, world::Sprite};
use std::{mem, ptr};

const MAX_GENERATION: u32 = 8;
const MAX_BINDINGS: u32 = 256;
const MAX_BEHAVIORS_PER_BINDING: u32 = 4;
const EVENT_CAPACITY: usize = 64;
const STRUCTURAL_CAPACITY: usize = 64;

#[derive(Clone)]
struct Binding {
    object: object_authority::ObjectKey,
    behavior_count: u32,
    script_id: u32,
}

#[derive(Clone)]
struct EventEntry {
    item: abi::kadath_runtime_phase_event_v1_t,
}

#[derive(Clone)]
struct StructuralEntry {
    item: abi::kadath_runtime_phase_structural_v1_t,
    completed: bool,
}

#[derive(Clone)]
struct Flush {
    token: u64,
    domain: u32,
    phase_sequence: u64,
    entries: Vec<StructuralEntry>,
}

#[derive(Clone)]
struct Activation {
    transaction_id: u64,
    root_sequence: u64,
    positions: Vec<abi::kadath_runtime_position_patch_v1_t>,
    events: Vec<abi::kadath_runtime_phase_event_v1_t>,
    structural: Vec<abi::kadath_runtime_phase_structural_v1_t>,
}

#[derive(Clone)]
struct Candidate {
    target: u32,
    phase_epoch: u64,
    bindings: Vec<Binding>,
}

pub(crate) struct PhaseState {
    candidate: Option<Candidate>,
    active_bindings: Vec<Binding>,
    admission_used: u32,
    active_phase: Option<(u32, u64)>,
    event_queue: Vec<EventEntry>,
    structural_queue: Vec<StructuralEntry>,
    event_successor_generation: u32,
    structural_successor_generation: u32,
    event_has_drained: bool,
    structural_has_drained: bool,
    next_event_sequence: u64,
    next_structural_sequence: u64,
    next_flush_token: u64,
    next_transaction_id: u64,
    flush: Option<Flush>,
    activation: Option<Activation>,
}

impl PhaseState {
    pub(crate) fn new() -> Self {
        Self {
            candidate: None,
            active_bindings: Vec::new(),
            admission_used: 0,
            active_phase: None,
            event_queue: Vec::new(),
            structural_queue: Vec::new(),
            event_successor_generation: 0,
            structural_successor_generation: 0,
            event_has_drained: false,
            structural_has_drained: false,
            next_event_sequence: 1,
            next_structural_sequence: 1,
            next_flush_token: 1,
            next_transaction_id: 1,
            flush: None,
            activation: None,
        }
    }

    fn active_domain(&self) -> Result<(u32, u64), u32> {
        self.active_phase
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED)
    }

    fn next_sequence(value: &mut u64) -> Result<u64, u32> {
        let current = *value;
        *value = value
            .checked_add(1)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
        Ok(current)
    }

    fn normalize_generation(input: u32, expected: u32, has_drained: bool) -> Result<u32, u32> {
        if expected > MAX_GENERATION {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_GENERATION_EXHAUSTED);
        }
        if input == 0 {
            return Ok(if has_drained { expected } else { 0 });
        }
        if input > MAX_GENERATION {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_GENERATION_EXHAUSTED);
        }
        if input != expected {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST);
        }
        Ok(input)
    }

    fn check_phase(&self, domain: u32, phase_sequence: u64) -> Result<(), u32> {
        if self.active_phase == Some((domain, phase_sequence)) {
            Ok(())
        } else {
            Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)
        }
    }

    fn admission_add(
        used: &mut u32,
        bindings: &mut Vec<Binding>,
        binding: Binding,
    ) -> Result<(), u32> {
        let next = used
            .checked_add(binding.behavior_count)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)?;
        if next > MAX_BINDINGS {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY);
        }
        *used = next;
        bindings.push(binding);
        Ok(())
    }

    fn admission_remove(
        used: &mut u32,
        bindings: &mut Vec<Binding>,
        key: object_authority::ObjectKey,
    ) {
        if let Some(index) = bindings.iter().position(|binding| binding.object == key) {
            *used = used.saturating_sub(bindings[index].behavior_count);
            bindings.swap_remove(index);
        }
    }
}

fn zero_object_ref(value: &abi::kadath_runtime_object_ref_v1_t) -> bool {
    value.struct_size == 0
        && value.kind == 0
        && value.world_epoch == 0
        && value.logical_generation == 0
        && value.object_id_length == 0
        && value.reserved0 == 0
        && value.object_id.iter().all(|byte| *byte == 0)
        && reserved_is_zero(&value.reserved)
}

fn valid_phase_output<T>(pointer: *mut T) -> Result<(), u32> {
    if pointer.is_null() || (pointer as usize) % mem::align_of::<T>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let size = unsafe { read_struct_size(pointer) }?;
    if size < mem::size_of::<T>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(())
}

fn valid_output_array<T>(pointer: *mut T, count: usize) -> Result<(), u32> {
    if pointer.is_null() || (pointer as usize) % mem::align_of::<T>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    for index in 0..count {
        let value = unsafe { pointer.add(index) };
        if unsafe { read_struct_size(value) }? < mem::size_of::<T>() as u32 {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
    }
    Ok(())
}

fn valid_event_field(field: &abi::kadath_runtime_phase_event_field_v1_t) -> Result<(), u32> {
    if field.struct_size < mem::size_of::<abi::kadath_runtime_phase_event_field_v1_t>() as u32
        || field.key_length > abi::KADATH_RUNTIME_PHASE_MAX_EVENT_KEY_BYTES
        || field.key[field.key_length as usize..]
            .iter()
            .any(|byte| *byte != 0)
        || !reserved_is_zero(&field.reserved)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let active = match field.value_kind {
        abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_BOOLEAN => mem::size_of::<i32>(),
        abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_NUMBER => mem::size_of::<f64>(),
        abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_STRING => mem::size_of::<u32>() + 128,
        abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_OBJECT => {
            mem::size_of::<abi::kadath_runtime_object_ref_v1_t>()
        }
        _ => return Err(abi::KADATH_ERR_INVALID_ARGUMENT),
    };
    if !union_tail_zero(&field.value, active) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    unsafe {
        match field.value_kind {
            abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_BOOLEAN => {
                if !matches!(field.value.boolean_value, 0 | 1) {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
            }
            abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_NUMBER => {
                if !field.value.number_value.is_finite() {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
            }
            abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_STRING => {
                let value = field.value.string_value;
                if value.length > abi::KADATH_RUNTIME_PHASE_MAX_EVENT_STRING_BYTES
                    || value.bytes[value.length as usize..]
                        .iter()
                        .any(|byte| *byte != 0)
                {
                    return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
                }
            }
            abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_OBJECT => {
                read_object_key(&field.value.object_value)?;
            }
            _ => unreachable!(),
        }
    }
    Ok(())
}

fn union_tail_zero<T>(value: *const T, active_size: usize) -> bool {
    if active_size > mem::size_of::<T>() {
        return false;
    }
    let bytes = unsafe { std::slice::from_raw_parts(value.cast::<u8>(), mem::size_of::<T>()) };
    bytes[active_size..].iter().all(|byte| *byte == 0)
}

fn validate_event(
    event: &abi::kadath_runtime_phase_event_v1_t,
    state: &object_authority::RuntimeState,
    domain: u32,
    expected_generation: u32,
    has_drained: bool,
) -> Result<u32, u32> {
    if event.struct_size < mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32
        || event.sequence != 0
        || event.domain != domain
        || event.generation > MAX_GENERATION
        || event.field_count > abi::KADATH_RUNTIME_PHASE_MAX_EVENT_FIELDS
        || event.has_sender > 1
        || event.has_other > 1
        || event.name_length > abi::KADATH_RUNTIME_PHASE_MAX_EVENT_NAME_BYTES
        || event.name[event.name_length as usize..]
            .iter()
            .any(|byte| *byte != 0)
        || !reserved_is_zero(&event.reserved)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let target =
        read_object_key(&event.target).map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    if state
        .visible_exact(target)
        .is_none_or(|record| record.lifecycle != object_authority::Lifecycle::Active)
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    {
        if event.has_sender == 0 {
            if !zero_object_ref(&event.sender) {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
        } else {
            let sender = read_object_key(&event.sender)?;
            if state
                .visible_exact(sender)
                .is_none_or(|record| record.lifecycle != object_authority::Lifecycle::Active)
            {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
        }
        if event.has_other == 0 {
            if !zero_object_ref(&event.other) {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
        } else {
            let other = read_object_key(&event.other)?;
            if state
                .visible_exact(other)
                .is_none_or(|record| record.lifecycle != object_authority::Lifecycle::Active)
            {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
        }
    }
    for field in &event.fields[..event.field_count as usize] {
        valid_event_field(field)?;
    }
    PhaseState::normalize_generation(event.generation, expected_generation, has_drained)
}

fn read_sprite(value: &abi::kadath_runtime_sprite_desc_v1_t) -> Result<Sprite, u32> {
    if value.struct_size < mem::size_of::<abi::kadath_runtime_sprite_desc_v1_t>() as u32
        || value.reserved0 != 0
        || !value.reserved.iter().all(|reserved| *reserved == 0)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let sprite = Sprite {
        position: value.position,
        size: value.size,
        color: value.color,
        texture_id: value.texture_id,
        move_speed: value.move_speed,
    };
    if !sprite.is_valid() || sprite.move_speed != 0.0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(sprite)
}

fn validate_structural(
    item: &abi::kadath_runtime_phase_structural_v1_t,
    state: &object_authority::RuntimeState,
    domain: u32,
    expected_generation: u32,
    has_drained: bool,
) -> Result<u32, u32> {
    if item.struct_size < mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>() as u32
        || item.sequence != 0
        || item.domain != domain
        || item.behavior_count > MAX_BEHAVIORS_PER_BINDING
        || !reserved_is_zero(&item.reserved)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let generation =
        PhaseState::normalize_generation(item.generation, expected_generation, has_drained)?;
    match item.operation {
        abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
            if !zero_object_ref(&item.object_ref) {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            let origin = read_object_key(&item.origin)
                .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
            if state.visible_exact(origin).is_none() {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
            read_sprite(&item.transient_sprite)?;
        }
        abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY
        | abi::KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION => {
            let key = read_object_key(&item.object_ref)
                .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
            if state.visible_exact(key).is_none() {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
            if !zero_object_ref(&item.origin)
                || item.prototype_key != 0
                || item.script_id != 0
                || item.behavior_count != 0
                || item.transient_sprite.struct_size != 0
                || item.transient_sprite.position != [0.0; 2]
                || item.transient_sprite.size != [0.0; 2]
                || item.transient_sprite.color != [0.0; 4]
                || item.transient_sprite.texture_id != 0
                || item.transient_sprite.move_speed != 0.0
                || item.transient_sprite.reserved0 != 0
                || !item
                    .transient_sprite
                    .reserved
                    .iter()
                    .all(|reserved| *reserved == 0)
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
        }
        _ => return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST),
    }
    Ok(generation)
}

fn write_batch_result(
    accepted_count: usize,
    first_sequence: u64,
    last_sequence: u64,
) -> abi::kadath_runtime_phase_batch_result_v1_t {
    abi::kadath_runtime_phase_batch_result_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>() as u32,
        reserved0: 0,
        accepted_count,
        first_sequence,
        last_sequence,
        reserved: [0; 4],
    }
}

fn write_completion(
    status: u32,
    sequence: u64,
    error_code: u32,
    disposition: u32,
    object: abi::kadath_runtime_object_view_v1_t,
) -> abi::kadath_runtime_phase_request_completion_v1_t {
    abi::kadath_runtime_phase_request_completion_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>() as u32,
        status,
        sequence,
        error_code,
        destroy_disposition: disposition,
        object,
        reserved: [0; 4],
    }
}

pub(crate) fn prepare_phase_state(
    core: &mut RuntimeCore,
    desc_ptr: *const abi::kadath_runtime_phase_state_prepare_desc_v1_t,
    out_ptr: *mut abi::kadath_runtime_phase_state_candidate_info_v1_t,
) -> Result<(), u32> {
    if desc_ptr.is_null()
        || out_ptr.is_null()
        || (desc_ptr as usize)
            % mem::align_of::<abi::kadath_runtime_phase_state_prepare_desc_v1_t>()
            != 0
        || (out_ptr as usize)
            % mem::align_of::<abi::kadath_runtime_phase_state_candidate_info_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_size = unsafe { read_struct_size(desc_ptr) }?;
    let out_size = unsafe { read_struct_size(out_ptr) }?;
    if desc_size < mem::size_of::<abi::kadath_runtime_phase_state_prepare_desc_v1_t>() as u32
        || out_size < mem::size_of::<abi::kadath_runtime_phase_state_candidate_info_v1_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc_ptr };
    if !reserved_is_zero(&desc.reserved)
        || !matches!(
            desc.target,
            abi::KADATH_RUNTIME_TARGET_LIVE | abi::KADATH_RUNTIME_TARGET_CANDIDATE
        )
        || desc.binding_count > MAX_BINDINGS as usize
        || (desc.binding_count != 0 && desc.bindings.is_null())
        || desc.binding_stride < mem::size_of::<abi::kadath_runtime_phase_binding_desc_v1_t>()
        || desc.binding_stride % mem::align_of::<abi::kadath_runtime_phase_binding_desc_v1_t>() != 0
        || strided_range(
            desc.bindings as usize,
            desc.binding_count,
            desc.binding_stride,
            mem::size_of::<abi::kadath_runtime_phase_binding_desc_v1_t>(),
        )
        .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.candidate.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_CANDIDATE_BUSY);
    }
    let desc_range = strided_range(
        desc_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_state_prepare_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_state_candidate_info_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let binding_range = if desc.binding_count == 0 {
        (desc.bindings as usize, desc.bindings as usize)
    } else {
        strided_range(
            desc.bindings as usize,
            desc.binding_count,
            desc.binding_stride,
            mem::size_of::<abi::kadath_runtime_phase_binding_desc_v1_t>(),
        )
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?
    };
    if ranges_overlap(desc_range, output_range)
        || ranges_overlap(binding_range, desc_range)
        || ranges_overlap(binding_range, output_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let state = match desc.target {
        abi::KADATH_RUNTIME_TARGET_LIVE => core.live.as_ref(),
        abi::KADATH_RUNTIME_TARGET_CANDIDATE => core.candidate.as_ref(),
        _ => unreachable!(),
    }
    .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut bindings = Vec::new();
    bindings
        .try_reserve_exact(desc.binding_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    let mut used = 0_u32;
    for index in 0..desc.binding_count {
        let pointer = unsafe {
            desc.bindings
                .cast::<u8>()
                .add(index * desc.binding_stride)
                .cast::<abi::kadath_runtime_phase_binding_desc_v1_t>()
        };
        let value = unsafe { &*pointer };
        if value.struct_size < mem::size_of::<abi::kadath_runtime_phase_binding_desc_v1_t>() as u32
            || value.behavior_count > MAX_BEHAVIORS_PER_BINDING
            || value.reserved0 != 0
            || !reserved_is_zero(&value.reserved)
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let key = read_object_key(&value.object_ref)?;
        if state.visible_exact(key).is_none() {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
        }
        used = used
            .checked_add(value.behavior_count)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)?;
        if used > MAX_BINDINGS {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY);
        }
        bindings.push(Binding {
            object: key,
            behavior_count: value.behavior_count,
            script_id: value.script_id,
        });
    }
    let candidate = Candidate {
        target: desc.target,
        phase_epoch: state.world_epoch,
        bindings,
    };
    let info = abi::kadath_runtime_phase_state_candidate_info_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_state_candidate_info_v1_t>() as u32,
        target: desc.target,
        binding_count: candidate.bindings.len() as u32,
        reserved0: 0,
        phase_epoch: candidate.phase_epoch,
        reserved: [0; 4],
    };
    core.phase.candidate = Some(candidate);
    unsafe { ptr::write(out_ptr, info) };
    Ok(())
}

pub(crate) fn commit_phase_state(core: &mut RuntimeCore) -> Result<(), u32> {
    let candidate = core
        .phase
        .candidate
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    if candidate.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE && core.candidate.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
    }
    let candidate = core.phase.candidate.take().expect("candidate exists");
    let _diagnostic_script_id_sum = candidate
        .bindings
        .iter()
        .fold(0_u32, |sum, binding| sum.wrapping_add(binding.script_id));
    core.phase.active_bindings = candidate.bindings;
    core.phase.admission_used = core
        .phase
        .active_bindings
        .iter()
        .map(|binding| binding.behavior_count)
        .sum();
    Ok(())
}

pub(crate) fn abort_phase_state(core: &mut RuntimeCore) -> Result<(), u32> {
    core.phase.candidate = None;
    Ok(())
}

pub(crate) fn begin_phase(
    core: &mut RuntimeCore,
    desc_ptr: *const abi::kadath_runtime_phase_begin_desc_v1_t,
    out_ptr: *mut abi::kadath_runtime_phase_begin_result_v1_t,
) -> Result<(), u32> {
    if desc_ptr.is_null() || out_ptr.is_null() {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_size = unsafe { read_struct_size(desc_ptr) }?;
    let out_size = unsafe { read_struct_size(out_ptr) }?;
    if desc_size < mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32
        || out_size < mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc_ptr };
    if !matches!(
        desc.domain,
        abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED | abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME
    ) {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_DOMAIN);
    }
    if desc.phase_sequence == 0
        || desc.reserved0 != 0
        || desc.reserved1 != 0
        || !reserved_is_zero(&desc.reserved)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.live.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
    }
    if core.phase.active_phase.is_some()
        || core.phase.flush.is_some()
        || core.phase.activation.is_some()
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    core.phase.active_phase = Some((desc.domain, desc.phase_sequence));
    core.phase.event_queue.clear();
    core.phase.structural_queue.clear();
    core.phase.event_successor_generation = 0;
    core.phase.structural_successor_generation = 0;
    core.phase.event_has_drained = false;
    core.phase.structural_has_drained = false;
    let result = abi::kadath_runtime_phase_begin_result_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
        domain: desc.domain,
        phase_sequence: desc.phase_sequence,
        reserved: [0; 4],
    };
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

pub(crate) fn submit_events(
    core: &mut RuntimeCore,
    events_ptr: *const abi::kadath_runtime_phase_event_v1_t,
    item_count: usize,
    item_stride: usize,
    out_ptr: *mut abi::kadath_runtime_phase_batch_result_v1_t,
) -> Result<(), u32> {
    let (domain, _phase_sequence) = core.phase.active_domain()?;
    if events_ptr.is_null() || out_ptr.is_null() || item_count == 0 || item_count > EVENT_CAPACITY {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    valid_phase_output(out_ptr)?;
    if (events_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() != 0
        || item_stride < mem::size_of::<abi::kadath_runtime_phase_event_v1_t>()
        || item_stride % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() != 0
        || strided_range(
            events_ptr as usize,
            item_count,
            item_stride,
            mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
        )
        .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let input_range = strided_range(
        events_ptr as usize,
        item_count,
        item_stride,
        mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(input_range, output_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.event_queue.len() + item_count > EVENT_CAPACITY {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut parsed = Vec::new();
    parsed
        .try_reserve_exact(item_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    let mut sequence = core.phase.next_event_sequence;
    for index in 0..item_count {
        let pointer = unsafe {
            events_ptr
                .cast::<u8>()
                .add(index * item_stride)
                .cast::<abi::kadath_runtime_phase_event_v1_t>()
        };
        let event = unsafe { &*pointer };
        let generation = validate_event(
            event,
            state,
            domain,
            core.phase.event_successor_generation,
            core.phase.event_has_drained,
        )?;
        sequence = sequence
            .checked_add(1)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
        let mut copied = *event;
        copied.sequence = sequence - 1;
        copied.generation = generation;
        parsed.push(EventEntry { item: copied });
    }
    let result = write_batch_result(
        item_count,
        parsed[0].item.sequence,
        parsed[item_count - 1].item.sequence,
    );
    core.phase.next_event_sequence = sequence;
    core.phase.event_queue.extend(parsed);
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

pub(crate) fn drain_events(
    core: &mut RuntimeCore,
    domain: u32,
    phase_sequence: u64,
    output_ptr: *mut abi::kadath_runtime_phase_event_v1_t,
    output_capacity: usize,
    out_count: *mut usize,
) -> Result<(), u32> {
    let (active_domain, active_sequence) = core.phase.active_domain()?;
    if output_ptr.is_null()
        || out_count.is_null()
        || (out_count as usize) % mem::align_of::<usize>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    core.phase.check_phase(domain, phase_sequence)?;
    if domain != active_domain || phase_sequence != active_sequence {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    if output_capacity == 0 {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    if (output_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let generation = core
        .phase
        .event_queue
        .iter()
        .map(|entry| entry.item.generation)
        .min();
    let Some(generation) = generation else {
        unsafe { ptr::write(out_count, 0) };
        return Ok(());
    };
    let count = core
        .phase
        .event_queue
        .iter()
        .filter(|entry| entry.item.generation == generation)
        .count();
    if output_capacity < count {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    valid_output_array(output_ptr, count)?;
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut output_index = 0;
    for entry in core
        .phase
        .event_queue
        .iter()
        .filter(|entry| entry.item.generation == generation)
    {
        let target = read_object_key(&entry.item.target);
        if target
            .ok()
            .is_some_and(|key| state.visible_exact(key).is_some())
        {
            unsafe { ptr::write(output_ptr.add(output_index), entry.item) };
            output_index += 1;
        }
    }
    core.phase
        .event_queue
        .retain(|entry| entry.item.generation != generation);
    core.phase.event_has_drained = true;
    core.phase.event_successor_generation = generation.saturating_add(1);
    unsafe { ptr::write(out_count, output_index) };
    Ok(())
}

pub(crate) fn submit_structural(
    core: &mut RuntimeCore,
    items_ptr: *const abi::kadath_runtime_phase_structural_v1_t,
    item_count: usize,
    item_stride: usize,
    acceptance_ptr: *mut abi::kadath_runtime_phase_request_completion_v1_t,
    acceptance_capacity: usize,
    out_ptr: *mut abi::kadath_runtime_phase_batch_result_v1_t,
) -> Result<(), u32> {
    let (domain, _phase_sequence) = core.phase.active_domain()?;
    if items_ptr.is_null()
        || acceptance_ptr.is_null()
        || out_ptr.is_null()
        || item_count == 0
        || item_count > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    valid_phase_output(out_ptr)?;
    if acceptance_capacity < item_count {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    if (items_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_structural_v1_t>() != 0
        || (acceptance_ptr as usize)
            % mem::align_of::<abi::kadath_runtime_phase_request_completion_v1_t>()
            != 0
        || item_stride < mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>()
        || item_stride % mem::align_of::<abi::kadath_runtime_phase_structural_v1_t>() != 0
        || strided_range(
            items_ptr as usize,
            item_count,
            item_stride,
            mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
        )
        .is_none()
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let item_range = strided_range(
        items_ptr as usize,
        item_count,
        item_stride,
        mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let acceptance_range = strided_range(
        acceptance_ptr as usize,
        item_count,
        mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>(),
        mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let result_range = strided_range(
        out_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(item_range, acceptance_range)
        || ranges_overlap(item_range, result_range)
        || ranges_overlap(acceptance_range, result_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.structural_queue.len() + item_count > STRUCTURAL_CAPACITY
        || core.phase.flush.is_some()
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    valid_output_array(acceptance_ptr, item_count)?;
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut staged_state = state.clone();
    let mut staged_bindings = core.phase.active_bindings.clone();
    let mut staged_used = core.phase.admission_used;
    let mut staged_queue = Vec::new();
    let mut completions = Vec::new();
    let mut next_sequence = core.phase.next_structural_sequence;
    for index in 0..item_count {
        let pointer = unsafe {
            items_ptr
                .cast::<u8>()
                .add(index * item_stride)
                .cast::<abi::kadath_runtime_phase_structural_v1_t>()
        };
        let item = unsafe { &*pointer };
        let generation = validate_structural(
            item,
            &staged_state,
            domain,
            core.phase.structural_successor_generation,
            core.phase.structural_has_drained,
        )?;
        let mut copied = *item;
        copied.sequence = PhaseState::next_sequence(&mut next_sequence)?;
        copied.generation = generation;
        let mut disposition = abi::KADATH_RUNTIME_DESTROY_DISPOSITION_NONE;
        let mut view = unsafe { mem::zeroed::<abi::kadath_runtime_object_view_v1_t>() };
        match item.operation {
            abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
                let sprite = read_sprite(&item.transient_sprite)?;
                read_object_key(&item.origin)
                    .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
                let record = staged_state
                    .reserve_transient(
                        item.prototype_key,
                        abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE,
                        sprite,
                    )
                    .map_err(authority_error)?
                    .clone();
                let object_key = object_authority::ObjectKey {
                    object_id: record.object_id,
                    world_epoch: staged_state.world_epoch,
                    logical_generation: record.logical_generation,
                    kind: record.kind,
                };
                copied.object_ref = object_ref(&record, staged_state.world_epoch);
                view = object_view(&record, staged_state.world_epoch);
                PhaseState::admission_add(
                    &mut staged_used,
                    &mut staged_bindings,
                    Binding {
                        object: object_key,
                        behavior_count: item.behavior_count,
                        script_id: item.script_id,
                    },
                )?;
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY => {
                let key = read_object_key(&item.object_ref)?;
                let before = staged_state.visible_exact(key).cloned();
                let result = staged_state.request_destroy(key).map_err(authority_error)?;
                disposition = match result {
                    object_authority::DestroyDisposition::CancelledPendingSpawn => {
                        abi::KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN
                    }
                    object_authority::DestroyDisposition::AwaitingFinalize => {
                        abi::KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE
                    }
                };
                if let Some(record) = before.as_ref() {
                    view = object_view(record, staged_state.world_epoch);
                    if disposition == abi::KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN {
                        PhaseState::admission_remove(&mut staged_used, &mut staged_bindings, key);
                    }
                }
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION => {
                let key = read_object_key(&item.object_ref)?;
                staged_state.discard(key).map_err(authority_error)?;
                PhaseState::admission_remove(&mut staged_used, &mut staged_bindings, key);
            }
            _ => unreachable!(),
        }
        completions.push(write_completion(
            abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED,
            copied.sequence,
            0,
            disposition,
            view,
        ));
        staged_queue.push(StructuralEntry {
            item: copied,
            completed: false,
        });
    }
    let result = write_batch_result(
        item_count,
        staged_queue[0].item.sequence,
        staged_queue[item_count - 1].item.sequence,
    );
    core.live = Some(staged_state);
    core.phase.active_bindings = staged_bindings;
    core.phase.admission_used = staged_used;
    core.phase.next_structural_sequence = next_sequence;
    core.phase.structural_queue.extend(staged_queue);
    for (index, completion) in completions.into_iter().enumerate() {
        unsafe { ptr::write(acceptance_ptr.add(index), completion) };
    }
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

pub(crate) fn take_structural(
    core: &mut RuntimeCore,
    domain: u32,
    phase_sequence: u64,
    flush_ptr: *mut abi::kadath_runtime_phase_flush_info_v1_t,
    output_ptr: *mut abi::kadath_runtime_phase_structural_v1_t,
    output_capacity: usize,
    out_count: *mut usize,
) -> Result<(), u32> {
    core.phase.check_phase(domain, phase_sequence)?;
    if flush_ptr.is_null() || output_ptr.is_null() || out_count.is_null() || output_capacity == 0 {
        return Err(if output_capacity == 0 {
            abi::KADATH_ERR_BUFFER_TOO_SMALL
        } else {
            abi::KADATH_ERR_INVALID_ARGUMENT
        });
    }
    valid_phase_output(flush_ptr)?;
    if (output_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_structural_v1_t>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let flush_range = strided_range(
        flush_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_flush_info_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        output_ptr as usize,
        output_capacity,
        mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
        mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(flush_range, output_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.flush.is_some() || core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    let generation = core
        .phase
        .structural_queue
        .iter()
        .map(|entry| entry.item.generation)
        .min();
    let Some(generation) = generation else {
        unsafe { ptr::write(out_count, 0) };
        return Ok(());
    };
    let count = core
        .phase
        .structural_queue
        .iter()
        .filter(|entry| entry.item.generation == generation)
        .count();
    if output_capacity < count {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    valid_output_array(output_ptr, count)?;
    let mut entries = Vec::new();
    let mut remaining = Vec::with_capacity(core.phase.structural_queue.len());
    for entry in core.phase.structural_queue.drain(..) {
        if entry.item.generation == generation {
            entries.push(entry);
        } else {
            remaining.push(entry);
        }
    }
    core.phase.structural_queue = remaining;
    for (index, entry) in entries.iter().enumerate() {
        unsafe { ptr::write(output_ptr.add(index), entry.item) };
    }
    let token = PhaseState::next_sequence(&mut core.phase.next_flush_token)?;
    let info = abi::kadath_runtime_phase_flush_info_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_flush_info_v1_t>() as u32,
        domain,
        flush_token: token,
        phase_sequence,
        request_count: entries.len(),
        reserved: [0; 4],
    };
    core.phase.flush = Some(Flush {
        token,
        domain,
        phase_sequence,
        entries,
    });
    core.phase.structural_has_drained = true;
    core.phase.structural_successor_generation = generation.saturating_add(1);
    unsafe {
        ptr::write(flush_ptr, info);
        ptr::write(out_count, count);
    }
    Ok(())
}

pub(crate) fn end_phase(
    core: &mut RuntimeCore,
    domain: u32,
    phase_sequence: u64,
) -> Result<(), u32> {
    core.phase.check_phase(domain, phase_sequence)?;
    if core.phase.flush.is_some()
        || core.phase.activation.is_some()
        || core
            .phase
            .event_queue
            .iter()
            .any(|entry| entry.item.domain == domain)
        || core
            .phase
            .structural_queue
            .iter()
            .any(|entry| entry.item.domain == domain)
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_NOT_DRAINED);
    }
    core.phase.active_phase = None;
    Ok(())
}

pub(crate) fn begin_activation(
    core: &mut RuntimeCore,
    flush_token: u64,
    root_sequence: u64,
    out_ptr: *mut abi::kadath_runtime_phase_transaction_info_v1_t,
) -> Result<(), u32> {
    valid_phase_output(out_ptr)?;
    if core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY);
    }
    let flush = core
        .phase
        .flush
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    core.phase.check_phase(flush.domain, flush.phase_sequence)?;
    if flush.token != flush_token || root_sequence == 0 {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let root = flush
        .entries
        .iter()
        .find(|entry| entry.item.sequence == root_sequence && !entry.completed)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    if root.item.operation != abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
    }
    let key = read_object_key(&root.item.object_ref)?;
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    if state.visible_exact(key).is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let transaction_id = PhaseState::next_sequence(&mut core.phase.next_transaction_id)?;
    core.phase.activation = Some(Activation {
        transaction_id,
        root_sequence,
        positions: Vec::new(),
        events: Vec::new(),
        structural: Vec::new(),
    });
    let info = abi::kadath_runtime_phase_transaction_info_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_transaction_info_v1_t>() as u32,
        reserved0: 0,
        transaction_id,
        root_sequence,
        reserved: [0; 4],
    };
    unsafe { ptr::write(out_ptr, info) };
    Ok(())
}

pub(crate) fn submit_activation(
    core: &mut RuntimeCore,
    transaction_id: u64,
    batch_ptr: *const abi::kadath_runtime_phase_activation_batch_v1_t,
) -> Result<(), u32> {
    if batch_ptr.is_null()
        || (batch_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_activation_batch_v1_t>()
            != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let batch_size = unsafe { read_struct_size(batch_ptr) }?;
    if batch_size < mem::size_of::<abi::kadath_runtime_phase_activation_batch_v1_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let batch = unsafe { &*batch_ptr };
    if batch.transaction_id != transaction_id
        || batch.reserved0 != 0
        || !reserved_is_zero(&batch.reserved)
        || batch.active_binding_capacity > MAX_BINDINGS as usize
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let active = core
        .phase
        .activation
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY)?;
    if active.transaction_id != transaction_id {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let (domain, _) = core.phase.active_domain()?;

    let mut positions = Vec::new();
    if batch.position_count != 0 {
        if batch.positions.is_null()
            || (batch.positions as usize)
                % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
                != 0
            || batch.position_stride < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>()
            || batch.position_stride % mem::align_of::<abi::kadath_runtime_position_patch_v1_t>()
                != 0
            || strided_range(
                batch.positions as usize,
                batch.position_count,
                batch.position_stride,
                mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
            )
            .is_none()
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        positions
            .try_reserve_exact(batch.position_count)
            .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
        for index in 0..batch.position_count {
            let pointer = unsafe {
                batch
                    .positions
                    .cast::<u8>()
                    .add(index * batch.position_stride)
                    .cast::<abi::kadath_runtime_position_patch_v1_t>()
            };
            let value = unsafe { &*pointer };
            if value.struct_size < mem::size_of::<abi::kadath_runtime_position_patch_v1_t>() as u32
                || value.reserved0 != 0
                || !reserved_is_zero(&value.reserved)
                || !value.position.iter().all(|position| position.is_finite())
            {
                return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
            }
            let key = read_object_key(&value.object_ref)?;
            if state.visible_exact(key).is_none() {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
            positions.push(*value);
        }
    }

    let mut events = Vec::new();
    if batch.event_count != 0 {
        if batch.events.is_null()
            || (batch.events as usize) % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>()
                != 0
            || batch.event_stride < mem::size_of::<abi::kadath_runtime_phase_event_v1_t>()
            || batch.event_stride % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() != 0
            || strided_range(
                batch.events as usize,
                batch.event_count,
                batch.event_stride,
                mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
            )
            .is_none()
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        events
            .try_reserve_exact(batch.event_count)
            .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
        for index in 0..batch.event_count {
            let pointer = unsafe {
                batch
                    .events
                    .cast::<u8>()
                    .add(index * batch.event_stride)
                    .cast::<abi::kadath_runtime_phase_event_v1_t>()
            };
            let value = unsafe { &*pointer };
            validate_event(
                value,
                state,
                domain,
                core.phase.event_successor_generation,
                core.phase.event_has_drained,
            )?;
            events.push(*value);
        }
    }

    let mut structural = Vec::new();
    if batch.structural_count != 0 {
        if batch.structural.is_null()
            || (batch.structural as usize)
                % mem::align_of::<abi::kadath_runtime_phase_structural_v1_t>()
                != 0
            || batch.structural_stride < mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>()
            || batch.structural_stride
                % mem::align_of::<abi::kadath_runtime_phase_structural_v1_t>()
                != 0
            || batch.structural_count > STRUCTURAL_CAPACITY
            || strided_range(
                batch.structural as usize,
                batch.structural_count,
                batch.structural_stride,
                mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
            )
            .is_none()
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        structural
            .try_reserve_exact(batch.structural_count)
            .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
        for index in 0..batch.structural_count {
            let pointer = unsafe {
                batch
                    .structural
                    .cast::<u8>()
                    .add(index * batch.structural_stride)
                    .cast::<abi::kadath_runtime_phase_structural_v1_t>()
            };
            let value = unsafe { &*pointer };
            validate_structural(
                value,
                state,
                domain,
                core.phase.structural_successor_generation,
                core.phase.structural_has_drained,
            )?;
            structural.push(*value);
        }
    }
    if core.phase.event_queue.len() + events.len() > EVENT_CAPACITY
        || core.phase.structural_queue.len() + structural.len() > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let active = core
        .phase
        .activation
        .as_mut()
        .expect("transaction remains active");
    active.positions.extend(positions);
    active.events.extend(events);
    active.structural.extend(structural);
    Ok(())
}

pub(crate) fn commit_activation(
    core: &mut RuntimeCore,
    transaction_id: u64,
    out_ptr: *mut abi::kadath_runtime_phase_activation_result_v1_t,
) -> Result<(), u32> {
    valid_phase_output(out_ptr)?;
    let activation = core
        .phase
        .activation
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY)?;
    if activation.transaction_id != transaction_id {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let flush = core
        .phase
        .flush
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root_index = flush
        .entries
        .iter()
        .position(|entry| entry.item.sequence == activation.root_sequence && !entry.completed)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root_item = flush.entries[root_index].item;
    let root_key = read_object_key(&root_item.object_ref)?;
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut bindings = core.phase.active_bindings.clone();
    let mut used = core.phase.admission_used;
    let mut event_queue = core.phase.event_queue.clone();
    let mut structural_queue = core.phase.structural_queue.clone();
    if event_queue.len() + activation.events.len() > EVENT_CAPACITY
        || structural_queue.len() + activation.structural.len() > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let entity = core.next_entity_value;
    let next_entity = entity.checked_add(1).ok_or(abi::KADATH_ERR_INTERNAL)?;
    state.activate(root_key, entity).map_err(authority_error)?;
    let world_epoch = state.world_epoch;
    for patch in &activation.positions {
        state
            .set_position(read_object_key(&patch.object_ref)?, patch.position)
            .map_err(authority_error)?;
    }
    let successor_event_generation = core.phase.event_successor_generation;
    let successor_structural_generation = core.phase.structural_successor_generation;
    if successor_event_generation > MAX_GENERATION
        || successor_structural_generation > MAX_GENERATION
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_GENERATION_EXHAUSTED);
    }
    let mut next_event_sequence = core.phase.next_event_sequence;
    let accepted_event_count = activation.events.len() as u32;
    for input in activation.events {
        let mut event = input;
        validate_event(
            &event,
            &state,
            flush.domain,
            successor_event_generation,
            true,
        )?;
        event.sequence = PhaseState::next_sequence(&mut next_event_sequence)?;
        event.generation = successor_event_generation;
        event_queue.push(EventEntry { item: event });
    }
    let mut next_structural_sequence = core.phase.next_structural_sequence;
    let mut accepted_structural_count = 0_u32;
    let mut cancelled_structural_count = 0_u32;
    for input in activation.structural {
        let mut item = input;
        validate_structural(
            &item,
            &state,
            flush.domain,
            successor_structural_generation,
            true,
        )?;
        item.sequence = PhaseState::next_sequence(&mut next_structural_sequence)?;
        item.generation = successor_structural_generation;
        match item.operation {
            abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
                let sprite = read_sprite(&item.transient_sprite)?;
                let record = state
                    .reserve_transient(
                        item.prototype_key,
                        abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE,
                        sprite,
                    )
                    .map_err(authority_error)?
                    .clone();
                let key = object_authority::ObjectKey {
                    object_id: record.object_id,
                    world_epoch,
                    logical_generation: record.logical_generation,
                    kind: record.kind,
                };
                item.object_ref = object_ref(&record, world_epoch);
                PhaseState::admission_add(
                    &mut used,
                    &mut bindings,
                    Binding {
                        object: key,
                        behavior_count: item.behavior_count,
                        script_id: item.script_id,
                    },
                )?;
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY => {
                let key = read_object_key(&item.object_ref)?;
                let disposition = state.request_destroy(key).map_err(authority_error)?;
                if matches!(
                    disposition,
                    object_authority::DestroyDisposition::CancelledPendingSpawn
                ) {
                    PhaseState::admission_remove(&mut used, &mut bindings, key);
                    cancelled_structural_count += 1;
                }
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION => {
                let key = read_object_key(&item.object_ref)?;
                state.discard(key).map_err(authority_error)?;
                PhaseState::admission_remove(&mut used, &mut bindings, key);
                cancelled_structural_count += 1;
            }
            _ => return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST),
        }
        structural_queue.push(StructuralEntry {
            item,
            completed: false,
        });
        accepted_structural_count += 1;
    }
    let root_object = state
        .visible_exact(root_key)
        .map(|record| object_view(record, world_epoch))
        .unwrap_or_else(|| unsafe { mem::zeroed() });
    let mut entries = flush.entries;
    entries[root_index].completed = true;
    let flush = if entries.iter().all(|entry| entry.completed) {
        None
    } else {
        Some(Flush { entries, ..flush })
    };
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.event_queue = event_queue;
    core.phase.structural_queue = structural_queue;
    core.phase.next_event_sequence = next_event_sequence;
    core.phase.next_structural_sequence = next_structural_sequence;
    core.phase.flush = flush;
    core.phase.activation = None;
    core.next_entity_value = next_entity;
    let result = abi::kadath_runtime_phase_activation_result_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_activation_result_v1_t>() as u32,
        reserved0: 0,
        accepted_event_count,
        accepted_structural_count,
        cancelled_structural_count,
        active_binding_count: used,
        root_object,
        reserved: [0; 4],
    };
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

pub(crate) fn abort_activation(core: &mut RuntimeCore, transaction_id: u64) -> Result<(), u32> {
    let activation = core
        .phase
        .activation
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY)?;
    if activation.transaction_id != transaction_id {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let flush = core
        .phase
        .flush
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root = flush
        .entries
        .iter()
        .find(|entry| entry.item.sequence == activation.root_sequence && !entry.completed)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let key = read_object_key(&root.item.object_ref)?;
    state.discard(key).map_err(authority_error)?;
    let mut bindings = core.phase.active_bindings.clone();
    let mut used = core.phase.admission_used;
    PhaseState::admission_remove(&mut used, &mut bindings, key);
    let mut entries = flush.entries;
    let index = entries
        .iter()
        .position(|entry| entry.item.sequence == activation.root_sequence)
        .expect("root exists");
    entries[index].completed = true;
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.flush = if entries.iter().all(|entry| entry.completed) {
        None
    } else {
        Some(Flush { entries, ..flush })
    };
    core.phase.activation = None;
    Ok(())
}

pub(crate) fn complete_structural(
    core: &mut RuntimeCore,
    flush_token: u64,
    completions_ptr: *const abi::kadath_runtime_phase_request_completion_v1_t,
    completion_count: usize,
    reserved_size: usize,
) -> Result<(), u32> {
    if reserved_size != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY);
    }
    let flush = core
        .phase
        .flush
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    if flush.token != flush_token {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let remaining: Vec<_> = flush
        .entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| !entry.completed)
        .collect();
    if completion_count != remaining.len() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
    }
    if completion_count > 0
        && (completions_ptr.is_null()
            || (completions_ptr as usize)
                % mem::align_of::<abi::kadath_runtime_phase_request_completion_v1_t>()
                != 0)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let mut seen = vec![false; flush.entries.len()];
    let mut values = Vec::new();
    values
        .try_reserve_exact(completion_count)
        .map_err(|_| abi::KADATH_ERR_OUT_OF_MEMORY)?;
    for index in 0..completion_count {
        let pointer = unsafe { completions_ptr.add(index) };
        let value = unsafe { &*pointer };
        if value.struct_size
            < mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>() as u32
            || !reserved_is_zero(&value.reserved)
            || !matches!(
                value.status,
                abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED
                    | abi::KADATH_RUNTIME_PHASE_COMPLETION_REJECTED
                    | abi::KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED
            )
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        let entry_index = flush
            .entries
            .iter()
            .position(|entry| entry.item.sequence == value.sequence && !entry.completed)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
        if seen[entry_index] {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
        }
        seen[entry_index] = true;
        values.push((entry_index, *value));
    }
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut bindings = core.phase.active_bindings.clone();
    let mut used = core.phase.admission_used;
    for (entry_index, completion) in &values {
        let item = &flush.entries[*entry_index].item;
        let key = read_object_key(&item.object_ref)?;
        if item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT {
            if completion.status != abi::KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
            }
            continue;
        }
        if item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY
            && completion.status == abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED
        {
            match state.finalize_destroy(key) {
                Ok(()) | Err(object_authority::AuthorityError::Stale) => {}
                Err(other) => return Err(authority_error(other)),
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        }
    }
    let mut entries = flush.entries;
    for (entry_index, _) in values {
        entries[entry_index].completed = true;
    }
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.flush = if entries.iter().all(|entry| entry.completed) {
        None
    } else {
        Some(Flush { entries, ..flush })
    };
    Ok(())
}

pub(crate) fn abort_structural(core: &mut RuntimeCore, flush_token: u64) -> Result<(), u32> {
    if core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY);
    }
    let flush = core
        .phase
        .flush
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    if flush.token != flush_token {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut bindings = core.phase.active_bindings.clone();
    let mut used = core.phase.admission_used;
    for entry in &flush.entries {
        if entry.completed {
            continue;
        }
        if entry.item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT {
            let key = read_object_key(&entry.item.object_ref)?;
            if state.visible_exact(key).is_some() {
                state.discard(key).map_err(authority_error)?;
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        } else if entry.item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY {
            let key = read_object_key(&entry.item.object_ref)?;
            match state.finalize_destroy(key) {
                Ok(()) | Err(object_authority::AuthorityError::Stale) => {}
                Err(other) => return Err(authority_error(other)),
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        }
    }
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.flush = None;
    Ok(())
}

macro_rules! phase_entry {
    ($name:ident, $function:ident, ($core:ident : *mut abi::kadath_runtime_core_t $(, $arg:ident : $ty:ty)* $(,)?)) => {
        extern "C" fn $name($core: *mut abi::kadath_runtime_core_t $(, $arg : $ty)*) -> i32 {
            ffi_result(|| {
                let (core_ref, _guard) = unsafe { enter_core($core) }?;
                $function(core_ref $(, $arg)*)
            })
        }
    };
}

phase_entry!(prepare_entry, prepare_phase_state, (core: *mut abi::kadath_runtime_core_t, desc: *const abi::kadath_runtime_phase_state_prepare_desc_v1_t, out: *mut abi::kadath_runtime_phase_state_candidate_info_v1_t));
phase_entry!(commit_state_entry, commit_phase_state, (core: *mut abi::kadath_runtime_core_t));
phase_entry!(abort_state_entry, abort_phase_state, (core: *mut abi::kadath_runtime_core_t));
phase_entry!(begin_phase_entry, begin_phase, (core: *mut abi::kadath_runtime_core_t, desc: *const abi::kadath_runtime_phase_begin_desc_v1_t, out: *mut abi::kadath_runtime_phase_begin_result_v1_t));
phase_entry!(submit_events_entry, submit_events, (core: *mut abi::kadath_runtime_core_t, events: *const abi::kadath_runtime_phase_event_v1_t, count: usize, stride: usize, out: *mut abi::kadath_runtime_phase_batch_result_v1_t));
phase_entry!(drain_events_entry, drain_events, (core: *mut abi::kadath_runtime_core_t, domain: u32, sequence: u64, output: *mut abi::kadath_runtime_phase_event_v1_t, capacity: usize, count: *mut usize));
phase_entry!(submit_structural_entry, submit_structural, (core: *mut abi::kadath_runtime_core_t, items: *const abi::kadath_runtime_phase_structural_v1_t, count: usize, stride: usize, results: *mut abi::kadath_runtime_phase_request_completion_v1_t, capacity: usize, out: *mut abi::kadath_runtime_phase_batch_result_v1_t));
phase_entry!(take_structural_entry, take_structural, (core: *mut abi::kadath_runtime_core_t, domain: u32, sequence: u64, flush: *mut abi::kadath_runtime_phase_flush_info_v1_t, output: *mut abi::kadath_runtime_phase_structural_v1_t, capacity: usize, count: *mut usize));
phase_entry!(begin_activation_entry, begin_activation, (core: *mut abi::kadath_runtime_core_t, flush: u64, root: u64, out: *mut abi::kadath_runtime_phase_transaction_info_v1_t));
phase_entry!(submit_activation_entry, submit_activation, (core: *mut abi::kadath_runtime_core_t, id: u64, batch: *const abi::kadath_runtime_phase_activation_batch_v1_t));
phase_entry!(commit_activation_entry, commit_activation, (core: *mut abi::kadath_runtime_core_t, id: u64, out: *mut abi::kadath_runtime_phase_activation_result_v1_t));
phase_entry!(abort_activation_entry, abort_activation, (core: *mut abi::kadath_runtime_core_t, id: u64));
phase_entry!(complete_structural_entry, complete_structural, (core: *mut abi::kadath_runtime_core_t, token: u64, items: *const abi::kadath_runtime_phase_request_completion_v1_t, count: usize, reserved: usize));
phase_entry!(abort_structural_entry, abort_structural, (core: *mut abi::kadath_runtime_core_t, token: u64));
phase_entry!(end_phase_entry, end_phase, (core: *mut abi::kadath_runtime_core_t, domain: u32, sequence: u64));

pub(crate) fn query_interface(
    in_out: *mut abi::kadath_runtime_phase_interface_v1_t,
) -> Result<(), u32> {
    if in_out.is_null()
        || (in_out as usize) % mem::align_of::<abi::kadath_runtime_phase_interface_v1_t>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let size = unsafe { read_struct_size(in_out) }?;
    if size < mem::size_of::<abi::kadath_runtime_phase_interface_v1_t>() as u32 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let requested = unsafe { ptr::read(in_out) };
    if requested.interface_version != abi::KADATH_RUNTIME_PHASE_INTERFACE_V1 {
        return Err(abi::KADATH_ERR_NOT_SUPPORTED);
    }
    if !reserved_is_zero(&requested.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let value = abi::kadath_runtime_phase_interface_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_interface_v1_t>() as u32,
        interface_version: abi::KADATH_RUNTIME_PHASE_INTERFACE_V1,
        prepare_phase_state: Some(prepare_entry),
        commit_phase_state: Some(commit_state_entry),
        abort_phase_state: Some(abort_state_entry),
        begin_phase: Some(begin_phase_entry),
        submit_events: Some(submit_events_entry),
        drain_events: Some(drain_events_entry),
        submit_structural: Some(submit_structural_entry),
        take_structural: Some(take_structural_entry),
        begin_activation: Some(begin_activation_entry),
        submit_activation: Some(submit_activation_entry),
        commit_activation: Some(commit_activation_entry),
        abort_activation: Some(abort_activation_entry),
        complete_structural: Some(complete_structural_entry),
        abort_structural: Some(abort_structural_entry),
        end_phase: Some(end_phase_entry),
        reserved: [0; 8],
    };
    unsafe { ptr::write(in_out, value) };
    Ok(())
}
