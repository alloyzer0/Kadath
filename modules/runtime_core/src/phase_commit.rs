use crate::{
    abi, authority_error, enter_core, ffi_result, object_ref, object_view, ranges_overlap,
    read_object_key, read_struct_size, reserved_is_zero, strided_range, RuntimeCore,
};
use crate::{object_authority, world::Sprite};
use std::{
    alloc::{alloc, Layout},
    mem,
    ops::{Index, IndexMut},
    ptr,
};

const MAX_GENERATION: u32 = abi::KADATH_RUNTIME_PHASE_MAX_GENERATION;
const MAX_BINDINGS: u32 = abi::KADATH_RUNTIME_PHASE_MAX_BINDINGS;
const MAX_BEHAVIORS_PER_BINDING: u32 = abi::KADATH_RUNTIME_PHASE_MAX_BEHAVIORS_PER_BINDING;
const EVENT_CAPACITY: usize = abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize;
const STRUCTURAL_CAPACITY: usize = abi::KADATH_RUNTIME_PHASE_MAX_STRUCTURAL_PER_DOMAIN as usize;

/// A fixed-capacity staging buffer for the Phase contract's bounded resources.
///
/// All stored Phase values are POD/Copy. Keeping their storage inline makes the
/// public 64/256 limits the actual allocation boundary as well as the semantic
/// boundary: after `RuntimeCore::create`, event and structural traffic cannot
/// allocate merely because another bounded batch was submitted.
#[derive(Clone, Copy)]
struct BoundedVec<T: Copy, const CAPACITY: usize> {
    items: [mem::MaybeUninit<T>; CAPACITY],
    len: usize,
}

impl<T: Copy, const CAPACITY: usize> BoundedVec<T, CAPACITY> {
    fn new() -> Self {
        Self {
            items: [mem::MaybeUninit::uninit(); CAPACITY],
            len: 0,
        }
    }

    fn len(&self) -> usize {
        self.len
    }

    fn clear(&mut self) {
        self.len = 0;
    }

    fn as_slice(&self) -> &[T] {
        // SAFETY: `0..len` is initialized exclusively by `push`/`extend_from_slice`,
        // and `len` never exceeds the backing array's capacity.
        unsafe { std::slice::from_raw_parts(self.items.as_ptr().cast::<T>(), self.len) }
    }

    fn as_mut_slice(&mut self) -> &mut [T] {
        // SAFETY: same initialized-prefix invariant as `as_slice`; the mutable
        // borrow of `self` guarantees unique access to the returned prefix.
        unsafe { std::slice::from_raw_parts_mut(self.items.as_mut_ptr().cast::<T>(), self.len) }
    }

    fn iter(&self) -> std::slice::Iter<'_, T> {
        self.as_slice().iter()
    }

    fn push(&mut self, value: T) -> Result<(), u32> {
        if self.len == CAPACITY {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
        }
        self.items[self.len].write(value);
        self.len += 1;
        Ok(())
    }

    fn extend_from_slice(&mut self, values: &[T]) -> Result<(), u32> {
        if values.len() > CAPACITY - self.len {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
        }
        for value in values {
            self.items[self.len].write(*value);
            self.len += 1;
        }
        Ok(())
    }

    fn retain(&mut self, mut keep: impl FnMut(&T) -> bool) {
        let mut output = 0;
        for input in 0..self.len {
            let value = self.as_slice()[input];
            if keep(&value) {
                self.items[output].write(value);
                output += 1;
            }
        }
        self.len = output;
    }

    fn swap_remove(&mut self, index: usize) -> T {
        let value = self.as_slice()[index];
        let tail = self.as_slice()[self.len - 1];
        self.len -= 1;
        if index != self.len {
            self.items[index].write(tail);
        }
        value
    }
}

impl<T: Copy, const CAPACITY: usize> Index<usize> for BoundedVec<T, CAPACITY> {
    type Output = T;

    fn index(&self, index: usize) -> &Self::Output {
        &self.as_slice()[index]
    }
}

impl<T: Copy, const CAPACITY: usize> IndexMut<usize> for BoundedVec<T, CAPACITY> {
    fn index_mut(&mut self, index: usize) -> &mut Self::Output {
        &mut self.as_mut_slice()[index]
    }
}

impl<'a, T: Copy, const CAPACITY: usize> IntoIterator for &'a BoundedVec<T, CAPACITY> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

#[derive(Clone, Copy)]
struct Binding {
    object: object_authority::ObjectKey,
    behavior_count: u32,
}

#[derive(Clone, Copy)]
struct EventEntry {
    item: abi::kadath_runtime_phase_event_v1_t,
}

#[derive(Clone, Copy)]
struct StructuralEntry {
    item: abi::kadath_runtime_phase_structural_v1_t,
    slot_hint: u8,
    completed: bool,
}

#[derive(Clone, Copy)]
struct IndexedCompletion {
    entry_index: usize,
    value: abi::kadath_runtime_phase_request_completion_v1_t,
}

#[derive(Clone, Copy)]
struct Flush {
    token: u64,
    domain: u32,
    phase_sequence: u64,
    entries: BoundedVec<StructuralEntry, STRUCTURAL_CAPACITY>,
}

#[derive(Clone)]
struct Activation {
    transaction_id: u64,
    domain: u32,
    root_sequence: u64,
    root_key: object_authority::ObjectKey,
    root_self_destroyed: bool,
    positions: BoundedVec<abi::kadath_runtime_position_patch_v1_t, STRUCTURAL_CAPACITY>,
    events: BoundedVec<abi::kadath_runtime_phase_event_v1_t, EVENT_CAPACITY>,
    structural: BoundedVec<abi::kadath_runtime_phase_structural_v1_t, STRUCTURAL_CAPACITY>,
    staged_state: object_authority::RuntimeState,
    staged_bindings: BoundedVec<Binding, { MAX_BINDINGS as usize }>,
    staged_used: u32,
    cancelled_structural_count: u32,
}

#[derive(Clone, Copy)]
struct Candidate {
    target: u32,
    phase_epoch: u64,
    bindings: BoundedVec<Binding, { MAX_BINDINGS as usize }>,
    ready: bool,
}

#[derive(Clone, Copy)]
struct DomainState {
    phase_sequence: Option<u64>,
    event_queue: BoundedVec<EventEntry, EVENT_CAPACITY>,
    structural_queue: BoundedVec<StructuralEntry, STRUCTURAL_CAPACITY>,
    event_successor_generation: u32,
    structural_successor_generation: u32,
    event_has_drained: bool,
    structural_has_drained: bool,
    next_event_sequence: u64,
    next_structural_sequence: u64,
}

impl DomainState {
    fn new() -> Self {
        Self {
            phase_sequence: None,
            event_queue: BoundedVec::new(),
            structural_queue: BoundedVec::new(),
            event_successor_generation: 0,
            structural_successor_generation: 0,
            event_has_drained: false,
            structural_has_drained: false,
            next_event_sequence: 1,
            next_structural_sequence: 1,
        }
    }
}

pub(crate) struct PhaseState {
    candidate: Option<Candidate>,
    active_bindings: BoundedVec<Binding, { MAX_BINDINGS as usize }>,
    admission_used: u32,
    domains: [DomainState; 2],
    next_phase_sequence: u64,
    next_flush_token: u64,
    next_transaction_id: u64,
    flush: [Option<Flush>; 2],
    activation: Option<Activation>,
}

impl PhaseState {
    pub(crate) fn new_boxed() -> Result<Box<Self>, u32> {
        let pointer = unsafe { alloc(Layout::new::<Self>()) }.cast::<Self>();
        if pointer.is_null() {
            return Err(abi::KADATH_ERR_OUT_OF_MEMORY);
        }
        // Build the large bounded arena directly in its final heap allocation.
        // This allocation occurs once at Core creation; Phase traffic only reuses
        // the initialized inline capacities below.
        unsafe {
            ptr::addr_of_mut!((*pointer).candidate).write(None);
            ptr::addr_of_mut!((*pointer).active_bindings).write(BoundedVec::new());
            ptr::addr_of_mut!((*pointer).admission_used).write(0);
            ptr::addr_of_mut!((*pointer).domains[0]).write(DomainState::new());
            ptr::addr_of_mut!((*pointer).domains[1]).write(DomainState::new());
            ptr::addr_of_mut!((*pointer).next_phase_sequence).write(1);
            ptr::addr_of_mut!((*pointer).next_flush_token).write(1);
            ptr::addr_of_mut!((*pointer).next_transaction_id).write(1);
            ptr::addr_of_mut!((*pointer).flush).write([None, None]);
            ptr::addr_of_mut!((*pointer).activation).write(None);
            Ok(Box::from_raw(pointer))
        }
    }

    pub(crate) fn ensure_scene_commit_allowed(&self) -> Result<(), u32> {
        if self
            .domains
            .iter()
            .any(|domain| domain.phase_sequence.is_some())
            || self.flush.iter().any(Option::is_some)
            || self.activation.is_some()
        {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
        }
        if !self.candidate.is_some_and(|candidate| {
            candidate.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE && candidate.ready
        }) {
            return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
        }
        Ok(())
    }

    pub(crate) fn has_candidate(&self) -> bool {
        self.candidate.is_some()
    }

    pub(crate) fn ensure_gameplay_begin_allowed(&self) -> Result<(), u32> {
        if !self.is_fully_idle() || self.candidate.is_some() {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
        }
        Ok(())
    }

    pub(crate) fn ensure_gameplay_commit_allowed(&self) -> Result<(), u32> {
        if self.candidate.is_some()
            || self.flush.iter().any(Option::is_some)
            || self.activation.is_some()
        {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
        }
        if self.domains[0].phase_sequence.is_none() {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED);
        }
        Ok(())
    }

    pub(crate) fn is_fully_idle(&self) -> bool {
        self.domains
            .iter()
            .all(|domain| domain.phase_sequence.is_none())
            && self.flush.iter().all(Option::is_none)
            && self.activation.is_none()
    }

    pub(crate) fn commit_after_scene(&mut self) {
        self.active_bindings.clear();
        self.admission_used = 0;
        for domain in &mut self.domains {
            domain.phase_sequence = None;
            domain.event_queue.clear();
            domain.structural_queue.clear();
            domain.event_successor_generation = 0;
            domain.structural_successor_generation = 0;
            domain.event_has_drained = false;
            domain.structural_has_drained = false;
        }
        self.flush = [None, None];
        self.activation = None;
        let candidate = self
            .candidate
            .take()
            .expect("paired ready candidate was preflighted");
        debug_assert_eq!(candidate.target, abi::KADATH_RUNTIME_TARGET_CANDIDATE);
        debug_assert!(candidate.ready);
        self.active_bindings = candidate.bindings;
        self.admission_used = self
            .active_bindings
            .iter()
            .map(|binding| binding.behavior_count)
            .sum();
    }

    pub(crate) fn abort_with_scene_candidate(&mut self) {
        if self
            .candidate
            .is_some_and(|candidate| candidate.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE)
        {
            self.candidate = None;
        }
    }

    fn domain_index(domain: u32) -> Result<usize, u32> {
        match domain {
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED => Ok(0),
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME => Ok(1),
            _ => Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_DOMAIN),
        }
    }

    fn domain(&self, domain: u32) -> Result<&DomainState, u32> {
        Ok(&self.domains[Self::domain_index(domain)?])
    }

    fn domain_mut(&mut self, domain: u32) -> Result<&mut DomainState, u32> {
        let index = Self::domain_index(domain)?;
        Ok(&mut self.domains[index])
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
        if self.domain(domain)?.phase_sequence == Some(phase_sequence) {
            Ok(())
        } else {
            Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)
        }
    }

    fn admission_add(
        used: &mut u32,
        bindings: &mut BoundedVec<Binding, { MAX_BINDINGS as usize }>,
        binding: Binding,
    ) -> Result<(), u32> {
        if binding.behavior_count == 0 {
            return Ok(());
        }
        let next = used
            .checked_add(binding.behavior_count)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)?;
        if next > MAX_BINDINGS {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY);
        }
        *used = next;
        bindings
            .push(binding)
            .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)?;
        Ok(())
    }

    fn admission_remove(
        used: &mut u32,
        bindings: &mut BoundedVec<Binding, { MAX_BINDINGS as usize }>,
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
    if pointer.is_null() {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if (pointer as usize) % mem::align_of::<T>() != 0 {
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

fn valid_activation_structural_results(
    pointer: *mut abi::kadath_runtime_phase_activation_structural_result_v1_t,
    count: usize,
) -> Result<(), u32> {
    valid_output_array(pointer, count)?;
    for index in 0..count {
        let value = unsafe { &*pointer.add(index) };
        if value.status != 0
            || value.sequence != 0
            || value.error_code != 0
            || value.destroy_disposition != 0
            || !zero_object_ref(&value.object_ref)
            || !reserved_is_zero(&value.reserved)
        {
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

fn event_objects_live(
    event: &abi::kadath_runtime_phase_event_v1_t,
    state: &object_authority::RuntimeState,
) -> bool {
    let is_live = |object: &abi::kadath_runtime_object_ref_v1_t| {
        read_object_key(object)
            .ok()
            .and_then(|key| state.visible_exact(key))
            .is_some_and(|record| record.lifecycle == object_authority::Lifecycle::Active)
    };
    if !is_live(&event.target) {
        return false;
    }
    if event.has_sender != 0 && !is_live(&event.sender) {
        return false;
    }
    if event.has_other != 0 && !is_live(&event.other) {
        return false;
    }
    event.fields[..event.field_count as usize]
        .iter()
        .filter(|field| field.value_kind == abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_OBJECT)
        .all(|field| is_live(unsafe { &field.value.object_value }))
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
            let origin = read_object_key(&item.origin)
                .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
            if state.visible_exact(origin).is_none()
                || item.script_id == 0
                || item.prototype_key != 0
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
    if desc.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE && core.gameplay_candidate.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
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
    let mut bindings = BoundedVec::new();
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
        bindings
            .push(Binding {
                object: key,
                behavior_count: value.behavior_count,
            })
            .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)?;
    }
    let candidate = Candidate {
        target: desc.target,
        phase_epoch: state.world_epoch,
        bindings,
        ready: false,
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
    if core
        .phase
        .domains
        .iter()
        .any(|domain| domain.phase_sequence.is_some())
        || core.phase.flush.iter().any(Option::is_some)
        || core.phase.activation.is_some()
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    let candidate = core
        .phase
        .candidate
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    if candidate.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE && core.candidate.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
    }
    if candidate.target == abi::KADATH_RUNTIME_TARGET_CANDIDATE {
        core.phase
            .candidate
            .as_mut()
            .expect("candidate exists")
            .ready = true;
    } else {
        let candidate = core.phase.candidate.take().expect("candidate exists");
        core.phase.active_bindings = candidate.bindings;
        core.phase.admission_used = core
            .phase
            .active_bindings
            .iter()
            .map(|binding| binding.behavior_count)
            .sum();
    }
    Ok(())
}

pub(crate) fn abort_phase_state(core: &mut RuntimeCore) -> Result<(), u32> {
    core.phase.candidate = None;
    Ok(())
}

fn begin_phase_impl(
    core: &mut RuntimeCore,
    desc_ptr: *const abi::kadath_runtime_phase_begin_desc_v1_t,
    out_ptr: *mut abi::kadath_runtime_phase_begin_result_v1_t,
    core_generates_sequence: bool,
) -> Result<(), u32> {
    // 两个外部指针分别校验，保证单侧为空时不会落入后续结构体读取。
    if desc_ptr.is_null() {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if out_ptr.is_null() {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_size = unsafe { read_struct_size(desc_ptr) }?;
    let out_size = unsafe { read_struct_size(out_ptr) }?;
    if desc_size < mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32
        || out_size < mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc_range = strided_range(
        desc_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let output_range = strided_range(
        out_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(desc_range, output_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let desc = unsafe { &*desc_ptr };
    if !matches!(
        desc.domain,
        abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED | abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME
    ) {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_DOMAIN);
    }
    if (core_generates_sequence && desc.phase_sequence != 0)
        || (!core_generates_sequence && desc.phase_sequence == 0)
        || desc.reserved0 != 0
        || desc.reserved1 != 0
        || !reserved_is_zero(&desc.reserved)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.live.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE);
    }
    if core
        .phase
        .domains
        .iter()
        .any(|domain| domain.phase_sequence.is_some())
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    // V1保留Host提供的兼容身份；V2才由Rust Core生成唯一sequence。
    let phase_sequence = if core_generates_sequence {
        PhaseState::next_sequence(&mut core.phase.next_phase_sequence)?
    } else {
        desc.phase_sequence
    };
    let domain = core.phase.domain_mut(desc.domain)?;
    domain.phase_sequence = Some(phase_sequence);
    domain.event_queue.clear();
    domain.structural_queue.clear();
    domain.event_successor_generation = 0;
    domain.structural_successor_generation = 0;
    domain.event_has_drained = false;
    domain.structural_has_drained = false;
    let result = abi::kadath_runtime_phase_begin_result_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
        domain: desc.domain,
        phase_sequence,
        reserved: [0; 4],
    };
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

pub(crate) fn begin_phase_v1(
    core: &mut RuntimeCore,
    desc_ptr: *const abi::kadath_runtime_phase_begin_desc_v1_t,
    out_ptr: *mut abi::kadath_runtime_phase_begin_result_v1_t,
) -> Result<(), u32> {
    begin_phase_impl(core, desc_ptr, out_ptr, false)
}

pub(crate) fn begin_phase_v2(
    core: &mut RuntimeCore,
    desc_ptr: *const abi::kadath_runtime_phase_begin_desc_v1_t,
    out_ptr: *mut abi::kadath_runtime_phase_begin_result_v1_t,
) -> Result<(), u32> {
    begin_phase_impl(core, desc_ptr, out_ptr, true)
}

pub(crate) fn submit_events(
    core: &mut RuntimeCore,
    events_ptr: *const abi::kadath_runtime_phase_event_v1_t,
    item_count: usize,
    item_stride: usize,
    out_ptr: *mut abi::kadath_runtime_phase_batch_result_v1_t,
) -> Result<(), u32> {
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
    let domain = unsafe { (*events_ptr).domain };
    let domain_state = core.phase.domain(domain)?;
    if domain_state.phase_sequence.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED);
    }
    if domain_state.event_queue.len() + item_count > EVENT_CAPACITY {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut sequence = domain_state.next_event_sequence;
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
            domain_state.event_successor_generation,
            domain_state.event_has_drained,
        )?;
        sequence = sequence
            .checked_add(1)
            .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
        let _ = generation;
    }
    let first_sequence = domain_state.next_event_sequence;
    let result = write_batch_result(item_count, first_sequence, sequence - 1);
    let domain_state = core.phase.domain_mut(domain)?;
    domain_state.next_event_sequence = sequence;
    for index in 0..item_count {
        let pointer = unsafe {
            events_ptr
                .cast::<u8>()
                .add(index * item_stride)
                .cast::<abi::kadath_runtime_phase_event_v1_t>()
        };
        let mut copied = unsafe { *pointer };
        copied.sequence = first_sequence + index as u64;
        copied.generation = PhaseState::normalize_generation(
            copied.generation,
            domain_state.event_successor_generation,
            domain_state.event_has_drained,
        )?;
        domain_state.event_queue.push(EventEntry { item: copied })?;
    }
    unsafe { ptr::write(out_ptr, result) };
    Ok(())
}

/// 将 Rust Gameplay 已生成的接触事件直接写入 Phase 队列。
///
/// 该入口不属于 C ABI；调用者只能传入 `contact_events` 构造的固定事件，
/// 因此跳过面向外部脚本的 ObjectRef/字段重复校验，同时保留队列容量、
/// Phase 活跃状态、序列号和 generation 的不变量。
pub(crate) fn submit_trusted_gameplay_events_with(
    core: &mut RuntimeCore,
    event_count: usize,
    mut build_event: impl FnMut(usize) -> abi::kadath_runtime_phase_event_v1_t,
) -> Result<(), u32> {
    if event_count == 0 {
        return Ok(());
    }
    if event_count > EVENT_CAPACITY {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    let domain_state = core.phase.domain(domain)?;
    if domain_state.phase_sequence.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED);
    }
    if domain_state.event_queue.len() + event_count > EVENT_CAPACITY {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let first_sequence = domain_state.next_event_sequence;
    // 与公开 submit_events 一致，先预留完整的 [first, next) 区间；
    // next 必须指向批次后的首个空闲序列，不能停在已使用的 last 上。
    let next_sequence = first_sequence
        .checked_add(event_count as u64)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
    let generation = PhaseState::normalize_generation(
        0,
        domain_state.event_successor_generation,
        domain_state.event_has_drained,
    )?;
    let domain_state = core.phase.domain_mut(domain)?;
    for index in 0..event_count {
        let event = build_event(index);
        if event.domain != domain {
            return Err(abi::KADATH_ERR_INTERNAL);
        }
        let mut copied = event;
        copied.sequence = first_sequence + index as u64;
        copied.generation = generation;
        domain_state.event_queue.push(EventEntry { item: copied })?;
    }
    domain_state.next_event_sequence = next_sequence;
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
    if output_ptr.is_null()
        || out_count.is_null()
        || (out_count as usize) % mem::align_of::<usize>() != 0
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    core.phase.check_phase(domain, phase_sequence)?;
    let domain_state = core.phase.domain(domain)?;
    if output_capacity == 0 {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    if (output_ptr as usize) % mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() != 0 {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let output_range = strided_range(
        output_ptr as usize,
        output_capacity,
        mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
        mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let count_range = strided_range(out_count as usize, 1, 1, mem::size_of::<usize>())
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(output_range, count_range) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let generation = domain_state
        .event_queue
        .iter()
        .map(|entry| entry.item.generation)
        .min();
    let Some(generation) = generation else {
        unsafe { ptr::write(out_count, 0) };
        return Ok(());
    };
    let count = domain_state
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
    for entry in domain_state
        .event_queue
        .iter()
        .filter(|entry| entry.item.generation == generation)
    {
        // Gameplay 事件只跳过提交时的外部 ABI 重复校验；投递时仍重新解析
        // target/sender/other，防止 structural settle 后把幽灵引用交给 Zig。
        if event_objects_live(&entry.item, state) {
            unsafe { ptr::write(output_ptr.add(output_index), entry.item) };
            output_index += 1;
        }
    }
    let domain_state = core.phase.domain_mut(domain)?;
    if count == domain_state.event_queue.len() {
        domain_state.event_queue.clear();
    } else {
        domain_state
            .event_queue
            .retain(|entry| entry.item.generation != generation);
    }
    domain_state.event_has_drained = true;
    domain_state.event_successor_generation = generation.saturating_add(1);
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
    let domain = unsafe { (*items_ptr).domain };
    let domain_index = PhaseState::domain_index(domain)?;
    let domain_state = core.phase.domain(domain)?;
    if domain_state.phase_sequence.is_none() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED);
    }
    if domain_state.structural_queue.len() + item_count > STRUCTURAL_CAPACITY
        || core.phase.flush[domain_index].is_some()
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    valid_output_array(acceptance_ptr, item_count)?;
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut staged_state = state.clone();
    let mut staged_bindings = core.phase.active_bindings;
    let mut staged_used = core.phase.admission_used;
    let mut staged_queue = BoundedVec::<StructuralEntry, STRUCTURAL_CAPACITY>::new();
    let mut completions =
        BoundedVec::<abi::kadath_runtime_phase_request_completion_v1_t, STRUCTURAL_CAPACITY>::new();
    let mut next_sequence = domain_state.next_structural_sequence;
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
            domain_state.structural_successor_generation,
            domain_state.structural_has_drained,
        )?;
        let mut copied = *item;
        copied.sequence = PhaseState::next_sequence(&mut next_sequence)?;
        copied.generation = generation;
        let slot_hint;
        let mut disposition = abi::KADATH_RUNTIME_DESTROY_DISPOSITION_NONE;
        let mut view = unsafe { mem::zeroed::<abi::kadath_runtime_object_view_v1_t>() };
        match item.operation {
            abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
                let sprite = read_sprite(&item.transient_sprite)?;
                read_object_key(&item.origin)
                    .map_err(|_| abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
                let slot_index = staged_state
                    .reserve_transient_slot(
                        item.prototype_key,
                        abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE,
                        sprite,
                    )
                    .map_err(authority_error)?;
                slot_hint = slot_index as u8;
                let record = staged_state.slots[slot_index]
                    .record
                    .as_ref()
                    .expect("reserved record exists")
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
                    },
                )?;
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY => {
                let key = read_object_key(&item.object_ref)?;
                slot_hint = staged_state
                    .exact_index(key, true)
                    .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?
                    as u8;
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
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST);
            }
            _ => unreachable!(),
        }
        completions.push(write_completion(
            abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED,
            copied.sequence,
            0,
            disposition,
            view,
        ))?;
        staged_queue.push(StructuralEntry {
            item: copied,
            slot_hint,
            completed: false,
        })?;
    }
    let result = write_batch_result(
        item_count,
        staged_queue[0].item.sequence,
        staged_queue[item_count - 1].item.sequence,
    );
    core.live = Some(staged_state);
    core.phase.active_bindings = staged_bindings;
    core.phase.admission_used = staged_used;
    let domain_state = core.phase.domain_mut(domain)?;
    domain_state.next_structural_sequence = next_sequence;
    domain_state
        .structural_queue
        .extend_from_slice(staged_queue.as_slice())?;
    for (index, completion) in completions.iter().copied().enumerate() {
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
    let domain_index = PhaseState::domain_index(domain)?;
    if flush_ptr.is_null()
        || output_ptr.is_null()
        || out_count.is_null()
        || (out_count as usize) % mem::align_of::<usize>() != 0
        || output_capacity == 0
    {
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
    let count_range = strided_range(out_count as usize, 1, 1, mem::size_of::<usize>())
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    if ranges_overlap(flush_range, output_range)
        || ranges_overlap(flush_range, count_range)
        || ranges_overlap(output_range, count_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    if core.phase.flush[domain_index].is_some() || core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY);
    }
    let domain_state = core.phase.domain(domain)?;
    let generation = domain_state
        .structural_queue
        .iter()
        .map(|entry| entry.item.generation)
        .min();
    let Some(generation) = generation else {
        unsafe { ptr::write(out_count, 0) };
        return Ok(());
    };
    let count = domain_state
        .structural_queue
        .iter()
        .filter(|entry| entry.item.generation == generation)
        .count();
    if output_capacity < count {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    valid_output_array(output_ptr, count)?;
    let token = core.phase.next_flush_token;
    let next_token = token
        .checked_add(1)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
    let mut entries = BoundedVec::<StructuralEntry, STRUCTURAL_CAPACITY>::new();
    let mut remaining = BoundedVec::<StructuralEntry, STRUCTURAL_CAPACITY>::new();
    let domain_state = core.phase.domain_mut(domain)?;
    for entry in domain_state.structural_queue.iter().copied() {
        if entry.item.generation == generation {
            entries.push(entry)?;
        } else {
            remaining.push(entry)?;
        }
    }
    domain_state.structural_queue = remaining;
    domain_state.structural_has_drained = true;
    domain_state.structural_successor_generation = generation.saturating_add(1);
    for (index, entry) in entries.iter().enumerate() {
        unsafe { ptr::write(output_ptr.add(index), entry.item) };
    }
    let info = abi::kadath_runtime_phase_flush_info_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_flush_info_v1_t>() as u32,
        domain,
        flush_token: token,
        phase_sequence,
        request_count: entries.len(),
        reserved: [0; 4],
    };
    core.phase.next_flush_token = next_token;
    core.phase.flush[domain_index] = Some(Flush {
        token,
        domain,
        phase_sequence,
        entries,
    });
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
    let domain_state = core.phase.domain(domain)?;
    if core.phase.flush[PhaseState::domain_index(domain)?].is_some()
        || core.phase.activation.is_some()
        || domain_state
            .event_queue
            .iter()
            .any(|entry| entry.item.domain == domain)
        || domain_state
            .structural_queue
            .iter()
            .any(|entry| entry.item.domain == domain)
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_NOT_DRAINED);
    }
    core.phase.domain_mut(domain)?.phase_sequence = None;
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
    let flush_index = core
        .phase
        .flush
        .iter()
        .position(|flush| {
            flush
                .as_ref()
                .is_some_and(|value| value.token == flush_token)
        })
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let flush = core.phase.flush[flush_index]
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
    let root_cancelled = state.visible_exact(key).is_none()
        && flush.entries.iter().any(|entry| {
            matches!(
                entry.item.operation,
                abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY
                    | abi::KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION
            ) && read_object_key(&entry.item.object_ref).ok() == Some(key)
        });
    if state.visible_exact(key).is_none() && !root_cancelled {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let transaction_id = PhaseState::next_sequence(&mut core.phase.next_transaction_id)?;
    core.phase.activation = Some(Activation {
        transaction_id,
        domain: flush.domain,
        root_sequence,
        root_key: key,
        root_self_destroyed: false,
        positions: BoundedVec::new(),
        events: BoundedVec::new(),
        structural: BoundedVec::new(),
        staged_state: state.clone(),
        staged_bindings: core.phase.active_bindings,
        staged_used: core.phase.admission_used,
        cancelled_structural_count: 0,
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
    let domain = active.domain;
    let root_key = active.root_key;
    let mut root_self_destroyed = active.root_self_destroyed;
    let mut staged_state = active.staged_state.clone();
    let mut staged_bindings = active.staged_bindings;
    let mut staged_used = active.staged_used;
    let existing_event_count = active.events.len();
    let existing_structural_count = active.structural.len();
    let domain_state = *core.phase.domain(domain)?;

    if batch.position_count > abi::KADATH_RUNTIME_MAX_OBJECTS as usize
        || batch.event_count > EVENT_CAPACITY
        || batch.structural_count > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    if active
        .positions
        .len()
        .checked_add(batch.position_count)
        .is_none_or(|count| count > STRUCTURAL_CAPACITY)
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let batch_range = strided_range(
        batch_ptr as usize,
        1,
        1,
        mem::size_of::<abi::kadath_runtime_phase_activation_batch_v1_t>(),
    )
    .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    let range_for = |pointer: usize, count: usize, stride: usize, size: usize| {
        if count == 0 {
            Ok((pointer, pointer))
        } else {
            strided_range(pointer, count, stride, size).ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)
        }
    };
    let position_range = range_for(
        batch.positions as usize,
        batch.position_count,
        batch.position_stride,
        mem::size_of::<abi::kadath_runtime_position_patch_v1_t>(),
    )?;
    let event_range = range_for(
        batch.events as usize,
        batch.event_count,
        batch.event_stride,
        mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
    )?;
    let structural_range = range_for(
        batch.structural as usize,
        batch.structural_count,
        batch.structural_stride,
        mem::size_of::<abi::kadath_runtime_phase_structural_v1_t>(),
    )?;
    let structural_result_range = if batch.structural_result_capacity == 0 {
        if !batch.structural_results.is_null() {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        (
            batch.structural_results as usize,
            batch.structural_results as usize,
        )
    } else {
        if batch.structural_results.is_null()
            || (batch.structural_results as usize)
                % mem::align_of::<abi::kadath_runtime_phase_activation_structural_result_v1_t>()
                != 0
        {
            return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
        }
        strided_range(
            batch.structural_results as usize,
            batch.structural_result_capacity,
            mem::size_of::<abi::kadath_runtime_phase_activation_structural_result_v1_t>(),
            mem::size_of::<abi::kadath_runtime_phase_activation_structural_result_v1_t>(),
        )
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?
    };
    if batch.structural_count > batch.structural_result_capacity {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    if batch.structural_count != 0 {
        valid_activation_structural_results(batch.structural_results, batch.structural_count)?;
    }
    if ranges_overlap(batch_range, position_range)
        || ranges_overlap(batch_range, event_range)
        || ranges_overlap(batch_range, structural_range)
        || ranges_overlap(batch_range, structural_result_range)
        || ranges_overlap(position_range, event_range)
        || ranges_overlap(position_range, structural_range)
        || ranges_overlap(event_range, structural_range)
        || ranges_overlap(position_range, structural_result_range)
        || ranges_overlap(event_range, structural_result_range)
        || ranges_overlap(structural_range, structural_result_range)
    {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }

    let mut positions =
        BoundedVec::<abi::kadath_runtime_position_patch_v1_t, STRUCTURAL_CAPACITY>::new();
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
            if staged_state.visible_exact(key).is_none() {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
            }
            staged_state
                .set_position(key, value.position)
                .map_err(authority_error)?;
            positions.push(*value)?;
        }
    }

    let mut events = BoundedVec::<abi::kadath_runtime_phase_event_v1_t, EVENT_CAPACITY>::new();
    let mut next_event_sequence = domain_state.next_event_sequence;
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
        for index in 0..batch.event_count {
            let pointer = unsafe {
                batch
                    .events
                    .cast::<u8>()
                    .add(index * batch.event_stride)
                    .cast::<abi::kadath_runtime_phase_event_v1_t>()
            };
            let value = unsafe { &*pointer };
            let generation = validate_event(
                value,
                &staged_state,
                domain,
                domain_state.event_successor_generation,
                domain_state.event_has_drained,
            )?;
            let mut copied = *value;
            copied.sequence = PhaseState::next_sequence(&mut next_event_sequence)?;
            copied.generation = generation;
            events.push(copied)?;
        }
    }

    let mut structural =
        BoundedVec::<abi::kadath_runtime_phase_structural_v1_t, STRUCTURAL_CAPACITY>::new();
    let mut structural_results = BoundedVec::<
        abi::kadath_runtime_phase_activation_structural_result_v1_t,
        STRUCTURAL_CAPACITY,
    >::new();
    let mut next_structural_sequence = domain_state.next_structural_sequence;
    let mut cancelled_structural_count = 0_u32;
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
        for index in 0..batch.structural_count {
            let pointer = unsafe {
                batch
                    .structural
                    .cast::<u8>()
                    .add(index * batch.structural_stride)
                    .cast::<abi::kadath_runtime_phase_structural_v1_t>()
            };
            let value = unsafe { &*pointer };
            let generation = validate_structural(
                value,
                &staged_state,
                domain,
                domain_state.structural_successor_generation,
                domain_state.structural_has_drained,
            )?;
            let mut copied = *value;
            copied.sequence = PhaseState::next_sequence(&mut next_structural_sequence)?;
            copied.generation = generation;
            let mut destroy_disposition = abi::KADATH_RUNTIME_DESTROY_DISPOSITION_NONE;
            match copied.operation {
                abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
                    let sprite = read_sprite(&copied.transient_sprite)?;
                    let record = staged_state
                        .reserve_transient(
                            copied.prototype_key,
                            abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE,
                            sprite,
                        )
                        .map_err(authority_error)?
                        .clone();
                    let key = object_authority::ObjectKey {
                        object_id: record.object_id,
                        world_epoch: staged_state.world_epoch,
                        logical_generation: record.logical_generation,
                        kind: record.kind,
                    };
                    copied.object_ref = object_ref(&record, staged_state.world_epoch);
                    PhaseState::admission_add(
                        &mut staged_used,
                        &mut staged_bindings,
                        Binding {
                            object: key,
                            behavior_count: copied.behavior_count,
                        },
                    )?;
                }
                abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY => {
                    let key = read_object_key(&copied.object_ref)?;
                    if key == root_key {
                        if root_self_destroyed || staged_state.visible_exact(key).is_none() {
                            return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
                        }
                        root_self_destroyed = true;
                        PhaseState::admission_remove(&mut staged_used, &mut staged_bindings, key);
                        destroy_disposition = abi::KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE;
                    } else {
                        let disposition =
                            staged_state.request_destroy(key).map_err(authority_error)?;
                        destroy_disposition = match disposition {
                            object_authority::DestroyDisposition::CancelledPendingSpawn => {
                                cancelled_structural_count += 1;
                                PhaseState::admission_remove(
                                    &mut staged_used,
                                    &mut staged_bindings,
                                    key,
                                );
                                abi::KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN
                            }
                            object_authority::DestroyDisposition::AwaitingFinalize => {
                                abi::KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE
                            }
                        };
                    }
                }
                abi::KADATH_RUNTIME_PHASE_OPERATION_DISCARD_RESERVATION => {
                    let key = read_object_key(&copied.object_ref)?;
                    staged_state.discard(key).map_err(authority_error)?;
                    PhaseState::admission_remove(&mut staged_used, &mut staged_bindings, key);
                    cancelled_structural_count += 1;
                    destroy_disposition = abi::KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN;
                }
                _ => return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST),
            }
            structural_results.push(
                abi::kadath_runtime_phase_activation_structural_result_v1_t {
                    struct_size: mem::size_of::<
                        abi::kadath_runtime_phase_activation_structural_result_v1_t,
                    >() as u32,
                    status: abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED,
                    sequence: copied.sequence,
                    error_code: 0,
                    destroy_disposition,
                    object_ref: copied.object_ref,
                    reserved: [0; 4],
                },
            )?;
            structural.push(copied)?;
        }
    }
    if domain_state.event_queue.len() + existing_event_count + events.len() > EVENT_CAPACITY
        || domain_state.structural_queue.len() + existing_structural_count + structural.len()
            > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    if staged_used as usize > batch.active_binding_capacity {
        return Err(abi::KADATH_ERR_BUFFER_TOO_SMALL);
    }
    {
        let domain_state = core.phase.domain_mut(domain)?;
        domain_state.next_event_sequence = next_event_sequence;
        domain_state.next_structural_sequence = next_structural_sequence;
    }
    let serial_high_water = staged_state.next_spawn_serial;
    let live = core
        .live
        .as_mut()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    // The transaction plan remains private; only Object Authority's monotonic serial
    // high-water is observable before commit so abort/failure can never reuse an ID.
    live.next_spawn_serial = live.next_spawn_serial.max(serial_high_water);
    let active = core
        .phase
        .activation
        .as_mut()
        .expect("transaction remains active");
    active.positions.extend_from_slice(positions.as_slice())?;
    active.events.extend_from_slice(events.as_slice())?;
    active.structural.extend_from_slice(structural.as_slice())?;
    active.staged_state = staged_state;
    active.staged_bindings = staged_bindings;
    active.staged_used = staged_used;
    active.root_self_destroyed = root_self_destroyed;
    active.cancelled_structural_count = active
        .cancelled_structural_count
        .checked_add(cancelled_structural_count)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)?;
    for (index, result) in structural_results.iter().copied().enumerate() {
        unsafe { ptr::write(batch.structural_results.add(index), result) };
    }
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
    let domain = activation.domain;
    let domain_index = PhaseState::domain_index(domain)?;
    let flush =
        core.phase.flush[domain_index].ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root_index = flush
        .entries
        .iter()
        .position(|entry| entry.item.sequence == activation.root_sequence && !entry.completed)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root_item = flush.entries[root_index].item;
    let root_key = read_object_key(&root_item.object_ref)?;
    let mut state = activation.staged_state.clone();
    let bindings = activation.staged_bindings;
    let used = activation.staged_used;
    let domain_state = *core.phase.domain(domain)?;
    let mut event_queue = domain_state.event_queue;
    let mut structural_queue = domain_state.structural_queue;
    if event_queue.len() + activation.events.len() > EVENT_CAPACITY
        || structural_queue.len() + activation.structural.len() > STRUCTURAL_CAPACITY
    {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    let root_cancelled = state.visible_exact(root_key).is_none();
    if root_cancelled {
        let mut bindings = core.phase.active_bindings;
        let mut used = core.phase.admission_used;
        PhaseState::admission_remove(&mut used, &mut bindings, root_key);
        let mut entries = flush.entries;
        entries[root_index].completed = true;
        core.phase.flush[domain_index] = if entries.iter().all(|entry| entry.completed) {
            None
        } else {
            Some(Flush {
                token: flush.token,
                domain: flush.domain,
                phase_sequence: flush.phase_sequence,
                entries,
            })
        };
        core.phase.activation = None;
        let result = abi::kadath_runtime_phase_activation_result_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_phase_activation_result_v1_t>() as u32,
            reserved0: 0,
            accepted_event_count: 0,
            accepted_structural_count: 0,
            cancelled_structural_count: activation.cancelled_structural_count.saturating_add(1),
            active_binding_count: used,
            root_object: unsafe { mem::zeroed() },
            reserved: [0; 4],
        };
        core.phase.active_bindings = bindings;
        core.phase.admission_used = used;
        unsafe { ptr::write(out_ptr, result) };
        return Ok(());
    }
    let entity = core.next_entity_value;
    let next_entity = entity.checked_add(1).ok_or(abi::KADATH_ERR_INTERNAL)?;
    state.activate(root_key, entity).map_err(authority_error)?;
    if activation.root_self_destroyed {
        let disposition = state.request_destroy(root_key).map_err(authority_error)?;
        if disposition != object_authority::DestroyDisposition::AwaitingFinalize {
            return Err(abi::KADATH_ERR_INTERNAL);
        }
    }
    let world_epoch = state.world_epoch;
    let accepted_event_count = activation.events.len() as u32;
    for event in activation.events.iter().copied() {
        event_queue.push(EventEntry { item: event })?;
    }
    let accepted_structural_count = activation.structural.len() as u32;
    for item in activation.structural.iter().copied() {
        structural_queue.push(StructuralEntry {
            item,
            slot_hint: read_object_key(&item.object_ref)
                .ok()
                .and_then(|key| state.exact_index(key, true))
                .map_or(u8::MAX, |index| index as u8),
            completed: false,
        })?;
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
        Some(Flush {
            token: flush.token,
            domain: flush.domain,
            phase_sequence: flush.phase_sequence,
            entries,
        })
    };
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    {
        let domain_state = core.phase.domain_mut(domain)?;
        domain_state.event_queue = event_queue;
        domain_state.structural_queue = structural_queue;
    }
    core.phase.flush[domain_index] = flush;
    core.phase.activation = None;
    core.next_entity_value = next_entity;
    let result = abi::kadath_runtime_phase_activation_result_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_activation_result_v1_t>() as u32,
        reserved0: 0,
        accepted_event_count,
        accepted_structural_count,
        cancelled_structural_count: activation.cancelled_structural_count,
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
    let domain_index = PhaseState::domain_index(activation.domain)?;
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let flush =
        core.phase.flush[domain_index].ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let root = flush
        .entries
        .iter()
        .find(|entry| entry.item.sequence == activation.root_sequence && !entry.completed)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let key = read_object_key(&root.item.object_ref)?;
    state.discard(key).map_err(authority_error)?;
    let mut bindings = core.phase.active_bindings;
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
    core.phase.flush[domain_index] = if entries.iter().all(|entry| entry.completed) {
        None
    } else {
        Some(Flush {
            token: flush.token,
            domain: flush.domain,
            phase_sequence: flush.phase_sequence,
            entries,
        })
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
    let flush_index = core
        .phase
        .flush
        .iter()
        .position(|flush| {
            flush
                .as_ref()
                .is_some_and(|value| value.token == flush_token)
        })
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let flush = core.phase.flush[flush_index].ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    if flush.token != flush_token {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST);
    }
    let remaining_count = flush
        .entries
        .iter()
        .filter(|entry| !entry.completed)
        .count();
    if completion_count != remaining_count {
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
    if completion_count > 0 {
        strided_range(
            completions_ptr as usize,
            completion_count,
            mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>(),
            mem::size_of::<abi::kadath_runtime_phase_request_completion_v1_t>(),
        )
        .ok_or(abi::KADATH_ERR_INVALID_ARGUMENT)?;
    }
    let mut seen = [false; STRUCTURAL_CAPACITY];
    let mut values = BoundedVec::<IndexedCompletion, STRUCTURAL_CAPACITY>::new();
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
        values.push(IndexedCompletion {
            entry_index,
            value: *value,
        })?;
    }
    let mut state = core
        .live
        .clone()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    let mut bindings = core.phase.active_bindings;
    let mut used = core.phase.admission_used;
    for indexed in &values {
        let item = &flush.entries[indexed.entry_index].item;
        let key = read_object_key(&item.object_ref)?;
        if item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT {
            if indexed.value.status != abi::KADATH_RUNTIME_PHASE_COMPLETION_CANCELLED {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
            }
            continue;
        }
        if item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY
            && indexed.value.status == abi::KADATH_RUNTIME_PHASE_COMPLETION_ACCEPTED
        {
            match state
                .finalize_destroy_index(flush.entries[indexed.entry_index].slot_hint as usize, key)
            {
                Ok(()) | Err(object_authority::AuthorityError::Stale) => {}
                Err(other) => return Err(authority_error(other)),
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        }
    }
    let mut entries = flush.entries;
    for indexed in &values {
        entries[indexed.entry_index].completed = true;
    }
    core.live = Some(state);
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.flush[flush_index] = if entries.iter().all(|entry| entry.completed) {
        None
    } else {
        Some(Flush {
            token: flush.token,
            domain: flush.domain,
            phase_sequence: flush.phase_sequence,
            entries,
        })
    };
    Ok(())
}

pub(crate) fn abort_structural(core: &mut RuntimeCore, flush_token: u64) -> Result<(), u32> {
    if core.phase.activation.is_some() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_TRANSACTION_BUSY);
    }
    let flush_index = core
        .phase
        .flush
        .iter()
        .position(|flush| {
            flush
                .as_ref()
                .is_some_and(|value| value.token == flush_token)
        })
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?;
    let entries = core.phase.flush[flush_index]
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)?
        .entries;
    let state = core
        .live
        .as_ref()
        .ok_or(abi::KADATH_ERR_RUNTIME_INVALID_STATE)?;
    // Complete preflight before changing Object Authority or admission state.
    for entry in &entries {
        if entry.completed {
            continue;
        }
        let key = read_object_key(&entry.item.object_ref)?;
        let record = state
            .exact_index_hint(entry.slot_hint as usize, key, true)
            .and_then(|index| state.slots[index].record.as_ref());
        match entry.item.operation {
            abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT => {
                if record.is_some_and(|value| {
                    value.source_index.is_some()
                        || value.lifecycle != object_authority::Lifecycle::PendingSpawn
                }) {
                    return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
                }
            }
            abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY => {
                if record.is_some_and(|value| {
                    value.source_index.is_some()
                        || value.lifecycle != object_authority::Lifecycle::PendingDestroy
                }) {
                    return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_COMMIT);
                }
            }
            _ => return Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST),
        }
    }
    let state = core.live.as_mut().expect("live state passed preflight");
    let mut bindings = core.phase.active_bindings;
    let mut used = core.phase.admission_used;
    for entry in &entries {
        if entry.completed {
            continue;
        }
        if entry.item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_RESERVE_TRANSIENT {
            let key = read_object_key(&entry.item.object_ref)?;
            if state
                .exact_index_hint(entry.slot_hint as usize, key, false)
                .is_some()
            {
                state
                    .discard_index(entry.slot_hint as usize, key)
                    .expect("reservation passed abort preflight");
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        } else if entry.item.operation == abi::KADATH_RUNTIME_PHASE_OPERATION_REQUEST_DESTROY {
            let key = read_object_key(&entry.item.object_ref)?;
            match state.finalize_destroy_index(entry.slot_hint as usize, key) {
                Ok(()) | Err(object_authority::AuthorityError::Stale) => {}
                Err(_) => unreachable!("destroy passed abort preflight"),
            }
            PhaseState::admission_remove(&mut used, &mut bindings, key);
        }
    }
    core.phase.active_bindings = bindings;
    core.phase.admission_used = used;
    core.phase.flush[flush_index] = None;
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
phase_entry!(begin_phase_v1_entry, begin_phase_v1, (core: *mut abi::kadath_runtime_core_t, desc: *const abi::kadath_runtime_phase_begin_desc_v1_t, out: *mut abi::kadath_runtime_phase_begin_result_v1_t));
phase_entry!(begin_phase_v2_entry, begin_phase_v2, (core: *mut abi::kadath_runtime_core_t, desc: *const abi::kadath_runtime_phase_begin_desc_v1_t, out: *mut abi::kadath_runtime_phase_begin_result_v1_t));
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
    if requested.interface_version != abi::KADATH_RUNTIME_PHASE_INTERFACE_V1
        && requested.interface_version != abi::KADATH_RUNTIME_PHASE_INTERFACE_V2
    {
        return Err(abi::KADATH_ERR_NOT_SUPPORTED);
    }
    if !reserved_is_zero(&requested.reserved) {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    let begin_phase: Option<
        unsafe extern "C" fn(
            *mut abi::kadath_runtime_core_t,
            *const abi::kadath_runtime_phase_begin_desc_v1_t,
            *mut abi::kadath_runtime_phase_begin_result_v1_t,
        ) -> i32,
    > = if requested.interface_version == abi::KADATH_RUNTIME_PHASE_INTERFACE_V2 {
        Some(begin_phase_v2_entry)
    } else {
        Some(begin_phase_v1_entry)
    };
    let value = abi::kadath_runtime_phase_interface_v1_t {
        struct_size: mem::size_of::<abi::kadath_runtime_phase_interface_v1_t>() as u32,
        interface_version: requested.interface_version,
        prepare_phase_state: Some(prepare_entry),
        commit_phase_state: Some(commit_state_entry),
        abort_phase_state: Some(abort_state_entry),
        begin_phase,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_vec_preserves_order_and_capacity() {
        let mut values = BoundedVec::<u32, 3>::new();
        assert_eq!(values.len(), 0);
        values.push(10).expect("first value");
        values
            .extend_from_slice(&[20, 30])
            .expect("remaining capacity");
        assert_eq!(values.as_slice(), &[10, 20, 30]);
        assert_eq!(
            values.push(40),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
        );
        assert_eq!(
            values.extend_from_slice(&[40]),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
        );
        values.retain(|value| *value != 20);
        assert_eq!(values.as_slice(), &[10, 30]);
        assert_eq!(values.swap_remove(0), 10);
        assert_eq!(values.as_slice(), &[30]);
        values.clear();
        assert_eq!(values.len(), 0);
    }

    #[test]
    fn domains_generations_and_admission_are_bounded() {
        assert_eq!(
            PhaseState::domain_index(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED),
            Ok(0)
        );
        assert_eq!(
            PhaseState::domain_index(abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME),
            Ok(1)
        );
        assert_eq!(
            PhaseState::domain_index(0),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_DOMAIN)
        );

        assert_eq!(PhaseState::normalize_generation(0, 0, false), Ok(0));
        assert_eq!(PhaseState::normalize_generation(0, 4, true), Ok(4));
        assert_eq!(PhaseState::normalize_generation(4, 4, true), Ok(4));
        assert_eq!(
            PhaseState::normalize_generation(3, 4, true),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST)
        );
        assert_eq!(
            PhaseState::normalize_generation(MAX_GENERATION + 1, 0, false),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_GENERATION_EXHAUSTED)
        );
        assert_eq!(
            PhaseState::normalize_generation(0, MAX_GENERATION + 1, true),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_GENERATION_EXHAUSTED)
        );

        let mut used = MAX_BINDINGS - 1;
        let mut bindings = BoundedVec::<Binding, { MAX_BINDINGS as usize }>::new();
        let key = object_authority::ObjectKey {
            object_id: object_authority::ObjectId::runtime(1),
            world_epoch: 1,
            logical_generation: 1,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_SPRITE,
        };
        PhaseState::admission_add(
            &mut used,
            &mut bindings,
            Binding {
                object: key,
                behavior_count: 1,
            },
        )
        .expect("last admission");
        assert_eq!(used, MAX_BINDINGS);
        assert_eq!(
            PhaseState::admission_add(
                &mut used,
                &mut bindings,
                Binding {
                    object: key,
                    behavior_count: 1,
                },
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_ADMISSION_CAPACITY)
        );
        PhaseState::admission_remove(&mut used, &mut bindings, key);
        assert_eq!(used, MAX_BINDINGS - 1);
        assert_eq!(bindings.len(), 0);
    }

    #[test]
    fn output_and_union_helpers_reject_nonzero_sentinels() {
        let mut result: abi::kadath_runtime_phase_activation_structural_result_v1_t =
            unsafe { mem::zeroed() };
        result.struct_size = mem::size_of_val(&result) as u32;
        assert_eq!(valid_activation_structural_results(&mut result, 1), Ok(()));
        result.status = 1;
        assert_eq!(
            valid_activation_structural_results(&mut result, 1),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );

        let bytes = [0_u8; 8];
        assert!(union_tail_zero(&bytes, 4));
        let bytes = [0_u8, 0, 0, 0, 1, 0, 0, 0];
        assert!(!union_tail_zero(&bytes, 4));
        assert!(!union_tail_zero(&bytes, bytes.len() + 1));
    }

    #[test]
    fn validate_event_covers_header_object_liveness_and_generation_contract() {
        use crate::{
            object_authority::{ObjectId, RuntimeState, SourceObject},
            world::Bounds,
        };

        fn object_ref(id: &[u8], kind: u32) -> abi::kadath_runtime_object_ref_v1_t {
            let object_id = ObjectId::parse(id).unwrap();
            abi::kadath_runtime_object_ref_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
                kind,
                world_epoch: 1,
                logical_generation: 1,
                object_id_length: object_id.len(),
                reserved0: 0,
                object_id: object_id.storage(),
                reserved: [0; 4],
            }
        }

        let sources = [
            SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                sprite: Sprite {
                    position: [0.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 0.0,
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
        ];
        let state = RuntimeState::initial(
            1,
            1,
            Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
            &sources,
            &[1, 2],
        );
        let mut event: abi::kadath_runtime_phase_event_v1_t = unsafe { mem::zeroed() };
        event.struct_size = mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32;
        event.domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
        event.target = object_ref(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER);

        assert_eq!(
            validate_event(
                &event,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Ok(0)
        );

        // header 条件必须逐一拒绝，避免把多个 guard 合并后让 OR→AND 变异逃逸。
        for mutate in [
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.struct_size = 0,
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.sequence = 1,
            |value: &mut abi::kadath_runtime_phase_event_v1_t| {
                value.domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME
            },
            |value: &mut abi::kadath_runtime_phase_event_v1_t| {
                value.generation = MAX_GENERATION + 1
            },
            |value: &mut abi::kadath_runtime_phase_event_v1_t| {
                value.field_count = abi::KADATH_RUNTIME_PHASE_MAX_EVENT_FIELDS + 1
            },
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.has_sender = 2,
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.has_other = 2,
            |value: &mut abi::kadath_runtime_phase_event_v1_t| {
                value.name_length = abi::KADATH_RUNTIME_PHASE_MAX_EVENT_NAME_BYTES + 1
            },
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.name[0] = 1,
            |value: &mut abi::kadath_runtime_phase_event_v1_t| value.reserved[0] = 1,
        ] {
            let mut invalid = event;
            mutate(&mut invalid);
            assert_eq!(
                validate_event(
                    &invalid,
                    &state,
                    abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                    0,
                    false
                ),
                Err(abi::KADATH_ERR_INVALID_ARGUMENT)
            );
        }

        // has_sender > 1 的 guard 必须在 sender 本身合法时仍拒绝，
        // 这样 OR→AND 变异不会被后续 sender 活性检查掩盖。
        let mut invalid_sender_flag = event;
        invalid_sender_flag.has_sender = 2;
        invalid_sender_flag.sender = object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        assert_eq!(
            validate_event(
                &invalid_sender_flag,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );

        // 阈值等于最大值时仍然是合法输入（字段/名称/generation 均走边界契约）。
        let mut max_event = event;
        max_event.generation = MAX_GENERATION;
        max_event.name_length = abi::KADATH_RUNTIME_PHASE_MAX_EVENT_NAME_BYTES;
        max_event.field_count = abi::KADATH_RUNTIME_PHASE_MAX_EVENT_FIELDS;
        for field in &mut max_event.fields {
            *field = abi::kadath_runtime_phase_event_field_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_event_field_v1_t>() as u32,
                value_kind: abi::KADATH_RUNTIME_PHASE_EVENT_VALUE_BOOLEAN,
                ..unsafe { mem::zeroed() }
            };
        }
        assert_eq!(
            validate_event(
                &max_event,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                MAX_GENERATION,
                true
            ),
            Ok(MAX_GENERATION)
        );

        // sender/other 显式存在时需要验证 active object；未声明时则必须是全零 sentinel。
        let mut with_sender = event;
        with_sender.has_sender = 1;
        with_sender.sender = object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        assert_eq!(
            validate_event(
                &with_sender,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Ok(0)
        );
        let mut sender_mismatch = event;
        sender_mismatch.sender = object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        assert_eq!(
            validate_event(
                &sender_mismatch,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut stale_sender = with_sender;
        stale_sender.sender.world_epoch = 2;
        assert_eq!(
            validate_event(
                &stale_sender,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)
        );
        let mut with_other = event;
        with_other.has_other = 1;
        with_other.other = object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        assert_eq!(
            validate_event(
                &with_other,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Ok(0)
        );
        let mut other_mismatch = event;
        other_mismatch.other = object_ref(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        assert_eq!(
            validate_event(
                &other_mismatch,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut stale_other = with_other;
        stale_other.other.world_epoch = 2;
        assert_eq!(
            validate_event(
                &stale_other,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)
        );

        let mut stale_target = event;
        stale_target.target.world_epoch = 2;
        assert_eq!(
            validate_event(
                &stale_target,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_STALE_REQUEST)
        );
        let mut invalid_generation = event;
        invalid_generation.generation = 1;
        assert_eq!(
            validate_event(
                &invalid_generation,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST)
        );
        invalid_generation.generation = 0;
        assert_eq!(
            validate_event(
                &invalid_generation,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                4,
                true
            ),
            Ok(4)
        );
        invalid_generation.generation = MAX_GENERATION + 1;
        assert_eq!(
            validate_event(
                &invalid_generation,
                &state,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                0,
                false
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
    }

    #[test]
    fn submit_events_covers_pointer_queue_sequence_and_generation_contract() {
        use crate::{
            object_authority::{ObjectId, RuntimeState, SourceObject},
            world::{Bounds, Sprite},
        };

        fn test_core() -> RuntimeCore {
            let sources = [
                SourceObject {
                    object_id: ObjectId::parse(b"player").unwrap(),
                    kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                    sprite: Sprite {
                        position: [0.0, 0.0],
                        size: [2.0, 2.0],
                        color: [1.0; 4],
                        texture_id: 1,
                        move_speed: 0.0,
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
            ];
            let live = RuntimeState::initial(
                1,
                1,
                Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
                &sources,
                &[1, 2],
            );
            RuntimeCore {
                owner_thread: std::thread::current().id(),
                in_call: false,
                live: Some(live),
                candidate: None,
                candidate_next_entity_value: None,
                candidate_mode: None,
                next_entity_value: 3,
                phase: PhaseState::new_boxed().unwrap(),
                gameplay: None,
                gameplay_candidate: None,
                #[cfg(feature = "contract-test-hooks")]
                next_fault: None,
            }
        }

        fn event() -> abi::kadath_runtime_phase_event_v1_t {
            let object_id = ObjectId::parse(b"player").unwrap();
            abi::kadath_runtime_phase_event_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32,
                domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                target: abi::kadath_runtime_object_ref_v1_t {
                    struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
                    kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                    world_epoch: 1,
                    logical_generation: 1,
                    object_id_length: object_id.len(),
                    reserved0: 0,
                    object_id: object_id.storage(),
                    reserved: [0; 4],
                },
                ..unsafe { mem::zeroed() }
            }
        }

        fn begin(core: &mut RuntimeCore) -> u64 {
            let desc = abi::kadath_runtime_phase_begin_desc_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32,
                domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                phase_sequence: 0,
                reserved0: 0,
                reserved1: 0,
                reserved: [0; 4],
            };
            let mut result = abi::kadath_runtime_phase_begin_result_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
                ..unsafe { mem::zeroed() }
            };
            begin_phase_v2(core, &desc, &mut result).unwrap();
            result.phase_sequence
        }

        fn batch_result() -> abi::kadath_runtime_phase_batch_result_v1_t {
            abi::kadath_runtime_phase_batch_result_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>() as u32,
                ..unsafe { mem::zeroed() }
            }
        }

        let stride = mem::size_of::<abi::kadath_runtime_phase_event_v1_t>();
        let mut core = test_core();
        begin(&mut core);
        let event = event();
        let mut events = [event; 2];
        // 两个事件必须有可观察差异，才能捕获第二项地址计算中的乘法变异。
        let goal_id = ObjectId::parse(b"goal").unwrap();
        events[1].target = abi::kadath_runtime_object_ref_v1_t {
            struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_GOAL,
            world_epoch: 1,
            logical_generation: 1,
            object_id_length: goal_id.len(),
            reserved0: 0,
            object_id: goal_id.storage(),
            reserved: [0; 4],
        };
        let mut result = batch_result();
        assert_eq!(
            submit_events(
                &mut core,
                events.as_ptr(),
                events.len(),
                stride,
                &mut result
            ),
            Ok(())
        );
        assert_eq!(result.accepted_count, 2);
        assert_eq!((result.first_sequence, result.last_sequence), (1, 2));
        let domain = core
            .phase
            .domain(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED)
            .unwrap();
        assert_eq!(domain.next_event_sequence, 3);
        assert_eq!(domain.event_queue.len(), 2);
        assert_eq!(domain.event_queue[0].item.sequence, 1);
        assert_eq!(domain.event_queue[1].item.sequence, 2);
        assert_eq!(
            domain.event_queue[1].item.target.kind,
            abi::KADATH_RUNTIME_OBJECT_KIND_GOAL
        );

        // 每个指针/长度/步长 guard 都单独命中，确保边界变异不会被短路条件掩盖。
        let mut fresh = test_core();
        let mut fresh_result = batch_result();
        assert_eq!(
            submit_events(&mut fresh, std::ptr::null(), 1, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 0, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(
                &mut fresh,
                events.as_ptr(),
                EVENT_CAPACITY + 1,
                stride,
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 1, stride, std::ptr::null_mut()),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut short_result = batch_result();
        short_result.struct_size = 0;
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 1, stride, &mut short_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut misaligned_result_storage = [0_u8; 256];
        let misaligned_result = unsafe {
            misaligned_result_storage
                .as_mut_ptr()
                .add(1)
                .cast::<abi::kadath_runtime_phase_batch_result_v1_t>()
        };
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 1, stride, misaligned_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut misaligned_events_storage = [0_u8; 512];
        let misaligned_events = unsafe {
            misaligned_events_storage
                .as_mut_ptr()
                .add(1)
                .cast::<abi::kadath_runtime_phase_event_v1_t>()
        };
        assert_eq!(
            submit_events(&mut fresh, misaligned_events, 1, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(
                &mut fresh,
                events.as_ptr(),
                1,
                stride - 1,
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(
                &mut fresh,
                events.as_ptr(),
                1,
                stride - mem::align_of::<abi::kadath_runtime_phase_event_v1_t>(),
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            submit_events(
                &mut fresh,
                events.as_ptr(),
                1,
                stride + 1,
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let overflow_start =
            usize::MAX - (mem::align_of::<abi::kadath_runtime_phase_event_v1_t>() - 1);
        assert_eq!(
            submit_events(
                &mut fresh,
                overflow_start as *const abi::kadath_runtime_phase_event_v1_t,
                2,
                stride,
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let overlap_result = events
            .as_mut_ptr()
            .cast::<abi::kadath_runtime_phase_batch_result_v1_t>();
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 1, stride, overlap_result),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );

        // Phase 必须先激活；合法事件随后还要经过 object/generation 校验。
        assert_eq!(
            submit_events(&mut fresh, events.as_ptr(), 1, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_ACTIVE_REQUIRED)
        );
        begin(&mut fresh);
        let mut invalid_generation = event;
        invalid_generation.generation = 1;
        assert_eq!(
            submit_events(
                &mut fresh,
                &invalid_generation,
                1,
                stride,
                &mut fresh_result
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST)
        );

        let mut no_live = test_core();
        begin(&mut no_live);
        no_live.live = None;
        assert_eq!(
            submit_events(&mut no_live, &event, 1, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE)
        );

        let mut full = test_core();
        begin(&mut full);
        let full_events = vec![event; EVENT_CAPACITY].into_boxed_slice();
        let mut full_result = batch_result();
        submit_events(
            &mut full,
            full_events.as_ptr(),
            full_events.len(),
            stride,
            &mut full_result,
        )
        .unwrap();
        assert_eq!(
            submit_events(&mut full, &event, 1, stride, &mut full_result),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
        );

        // 队列恰好剩余一个槽位时提交两个，覆盖 len + count 的边界。
        let mut queue_boundary = test_core();
        begin(&mut queue_boundary);
        let boundary_events = vec![event; EVENT_CAPACITY].into_boxed_slice();
        submit_events(
            &mut queue_boundary,
            boundary_events.as_ptr(),
            EVENT_CAPACITY - 1,
            stride,
            &mut full_result,
        )
        .unwrap();
        assert_eq!(
            submit_events(
                &mut queue_boundary,
                boundary_events.as_ptr(),
                2,
                stride,
                &mut full_result
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
        );

        let mut exhausted = test_core();
        begin(&mut exhausted);
        exhausted
            .phase
            .domain_mut(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED)
            .unwrap()
            .next_event_sequence = u64::MAX;
        assert_eq!(
            submit_events(&mut exhausted, &event, 1, stride, &mut fresh_result),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)
        );
    }

    #[test]
    fn submit_events_arithmetic_boundaries_have_observable_side_effects() {
        use crate::{
            object_authority::{ObjectId, RuntimeState, SourceObject},
            world::{Bounds, Sprite},
        };

        fn test_core() -> RuntimeCore {
            let sources = [SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                sprite: Sprite {
                    position: [0.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 0.0,
                },
            }];
            let live = RuntimeState::initial(
                1,
                1,
                Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
                &sources,
                &[1],
            );
            RuntimeCore {
                owner_thread: std::thread::current().id(),
                in_call: false,
                live: Some(live),
                candidate: None,
                candidate_next_entity_value: None,
                candidate_mode: None,
                next_entity_value: 2,
                phase: PhaseState::new_boxed().unwrap(),
                gameplay: None,
                gameplay_candidate: None,
                #[cfg(feature = "contract-test-hooks")]
                next_fault: None,
            }
        }

        fn event() -> abi::kadath_runtime_phase_event_v1_t {
            let object_id = ObjectId::parse(b"player").unwrap();
            abi::kadath_runtime_phase_event_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32,
                domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                target: abi::kadath_runtime_object_ref_v1_t {
                    struct_size: mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
                    kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                    world_epoch: 1,
                    logical_generation: 1,
                    object_id_length: object_id.len(),
                    reserved0: 0,
                    object_id: object_id.storage(),
                    reserved: [0; 4],
                },
                ..unsafe { mem::zeroed() }
            }
        }

        fn begin(core: &mut RuntimeCore) {
            let desc = abi::kadath_runtime_phase_begin_desc_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32,
                domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                phase_sequence: 0,
                reserved0: 0,
                reserved1: 0,
                reserved: [0; 4],
            };
            let mut result = abi::kadath_runtime_phase_begin_result_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
                ..unsafe { mem::zeroed() }
            };
            begin_phase_v2(core, &desc, &mut result).unwrap();
        }

        fn result() -> abi::kadath_runtime_phase_batch_result_v1_t {
            abi::kadath_runtime_phase_batch_result_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>() as u32,
                ..unsafe { mem::zeroed() }
            }
        }

        let stride = mem::size_of::<abi::kadath_runtime_phase_event_v1_t>();
        {
            // item_count=64 且队列已有 1 个元素时，原始 len + count 会拒绝，
            // +→* 变异若放行将部分写入，故同时断言队列和 sequence 保持不变。
            let mut core = test_core();
            begin(&mut core);
            let one = [event()];
            let mut output = result();
            submit_events(&mut core, one.as_ptr(), 1, stride, &mut output).unwrap();
            let batch = vec![event(); EVENT_CAPACITY].into_boxed_slice();
            assert_eq!(
                submit_events(
                    &mut core,
                    batch.as_ptr(),
                    EVENT_CAPACITY,
                    stride,
                    &mut output,
                ),
                Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
            );
            let domain = core
                .phase
                .domain(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED)
                .unwrap();
            assert_eq!(domain.event_queue.len(), 1);
            assert_eq!(domain.next_event_sequence, 2);
        }

        {
            // 第一项合法、第二项 generation 非法，确保 index * stride 的
            // *→/ 变异不会把第二项再次读取为第一项。
            let mut core = test_core();
            begin(&mut core);
            let first = event();
            let mut second = first;
            second.generation = 1;
            let events = [first, second];
            let mut output = result();
            assert_eq!(
                submit_events(
                    &mut core,
                    events.as_ptr(),
                    events.len(),
                    stride,
                    &mut output
                ),
                Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_REQUEST)
            );
            assert_eq!(
                core.phase
                    .domain(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED)
                    .unwrap()
                    .event_queue
                    .len(),
                0
            );
        }
    }

    #[test]
    fn begin_phase_v1_v2_cover_preflight_domain_busy_and_sequence_contract() {
        use crate::{
            object_authority::{ObjectId, RuntimeState, SourceObject},
            world::{Bounds, Sprite},
        };

        fn test_core() -> RuntimeCore {
            let sources = [SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                sprite: Sprite {
                    position: [0.0, 0.0],
                    size: [2.0, 2.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed: 0.0,
                },
            }];
            let live = RuntimeState::initial(
                1,
                1,
                Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
                &sources,
                &[1],
            );
            RuntimeCore {
                owner_thread: std::thread::current().id(),
                in_call: false,
                live: Some(live),
                candidate: None,
                candidate_next_entity_value: None,
                candidate_mode: None,
                next_entity_value: 2,
                phase: PhaseState::new_boxed().unwrap(),
                gameplay: None,
                gameplay_candidate: None,
                #[cfg(feature = "contract-test-hooks")]
                next_fault: None,
            }
        }

        fn desc(domain: u32, sequence: u64) -> abi::kadath_runtime_phase_begin_desc_v1_t {
            abi::kadath_runtime_phase_begin_desc_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32,
                domain,
                phase_sequence: sequence,
                reserved0: 0,
                reserved1: 0,
                reserved: [0; 4],
            }
        }

        fn result() -> abi::kadath_runtime_phase_begin_result_v1_t {
            abi::kadath_runtime_phase_begin_result_v1_t {
                struct_size: mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
                ..unsafe { mem::zeroed() }
            }
        }

        let mut core = test_core();
        let valid_v2 = desc(abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED, 0);
        let mut output = result();
        begin_phase_v2(&mut core, &valid_v2, &mut output).unwrap();
        assert_eq!(output.phase_sequence, 1);
        end_phase(
            &mut core,
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            output.phase_sequence,
        )
        .unwrap();

        let valid_v1 = desc(abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME, 41);
        output = result();
        begin_phase_v1(&mut core, &valid_v1, &mut output).unwrap();
        assert_eq!(output.phase_sequence, 41);
        end_phase(
            &mut core,
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FRAME,
            output.phase_sequence,
        )
        .unwrap();

        // desc/out 的空指针、短结构体与 alias 都必须在任何解引用前失败。
        assert_eq!(
            begin_phase_v2(&mut core, std::ptr::null(), &mut output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        assert_eq!(
            begin_phase_v2(&mut core, &valid_v2, std::ptr::null_mut()),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut short_desc = valid_v2;
        short_desc.struct_size = 0;
        assert_eq!(
            begin_phase_v2(&mut core, &short_desc, &mut output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut short_output = result();
        short_output.struct_size = 0;
        assert_eq!(
            begin_phase_v2(&mut core, &valid_v2, &mut short_output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let alias_output = (&valid_v2 as *const abi::kadath_runtime_phase_begin_desc_v1_t)
            .cast_mut()
            .cast::<abi::kadath_runtime_phase_begin_result_v1_t>();
        assert_eq!(
            begin_phase_v2(&mut core, &valid_v2, alias_output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );

        let mut invalid = valid_v2;
        invalid.domain = 99;
        assert_eq!(
            begin_phase_v2(&mut core, &invalid, &mut output),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_INVALID_DOMAIN)
        );
        invalid = valid_v2;
        invalid.phase_sequence = 7;
        assert_eq!(
            begin_phase_v2(&mut core, &invalid, &mut output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut invalid_v1 = valid_v1;
        invalid_v1.phase_sequence = 0;
        assert_eq!(
            begin_phase_v1(&mut core, &invalid_v1, &mut output),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        for mutate in [
            |value: &mut abi::kadath_runtime_phase_begin_desc_v1_t| value.reserved0 = 1,
            |value: &mut abi::kadath_runtime_phase_begin_desc_v1_t| value.reserved1 = 1,
            |value: &mut abi::kadath_runtime_phase_begin_desc_v1_t| value.reserved[0] = 1,
        ] {
            let mut invalid = valid_v2;
            mutate(&mut invalid);
            assert_eq!(
                begin_phase_v2(&mut core, &invalid, &mut output),
                Err(abi::KADATH_ERR_INVALID_ARGUMENT)
            );
        }

        let mut no_live = test_core();
        no_live.live = None;
        assert_eq!(
            begin_phase_v2(&mut no_live, &valid_v2, &mut output),
            Err(abi::KADATH_ERR_RUNTIME_INVALID_STATE)
        );

        let mut busy = test_core();
        let mut busy_output = result();
        begin_phase_v2(&mut busy, &valid_v2, &mut busy_output).unwrap();
        assert_eq!(
            begin_phase_v2(&mut busy, &valid_v2, &mut output),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_BUSY)
        );

        let mut exhausted = test_core();
        exhausted.phase.next_phase_sequence = u64::MAX;
        assert_eq!(
            begin_phase_v2(&mut exhausted, &valid_v2, &mut output),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_SEQUENCE_EXHAUSTED)
        );
    }
}
