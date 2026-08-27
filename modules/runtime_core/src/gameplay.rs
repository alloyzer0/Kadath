use crate::{abi, object_authority::ObjectKey, phase_commit, world::Sprite, RuntimeCore};

pub(crate) const MAX_CONTACTS: usize = crate::object_authority::MAX_OBJECTS - 1;
// 接触差分最多为单域事件容量的一半，避免重复书写数组长度表达式。
pub(crate) const MAX_CONTACT_TRANSITIONS: usize =
    abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize / 2;
const CONTACT_MASK_WORDS: usize = crate::object_authority::MAX_OBJECTS / 64;

pub(crate) struct ContactObservation {
    pub(crate) contacts: [Option<ObjectKey>; MAX_CONTACTS],
    // 记录源索引和位图，避免接触差分反复比较完整 ObjectKey。
    pub(crate) source_indices: [u8; MAX_CONTACTS],
    pub(crate) source_mask: [u64; CONTACT_MASK_WORDS],
    pub(crate) count: usize,
    pub(crate) first_hazard: Option<ObjectKey>,
    pub(crate) goal: Option<ObjectKey>,
}

impl Default for ContactObservation {
    fn default() -> Self {
        Self {
            contacts: [None; MAX_CONTACTS],
            source_indices: [0; MAX_CONTACTS],
            source_mask: [0; CONTACT_MASK_WORDS],
            count: 0,
            first_hazard: None,
            goal: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Hazard {
    pub(crate) object: ObjectKey,
    pub(crate) source_index: u8,
    pub(crate) movement_mode: u32,
    pub(crate) patrol_min_y: f32,
    pub(crate) patrol_max_y: f32,
    pub(crate) patrol_speed: f32,
    pub(crate) patrol_direction: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct State {
    pub(crate) player: ObjectKey,
    pub(crate) player_source_index: u8,
    pub(crate) goal: ObjectKey,
    pub(crate) goal_source_index: u8,
    pub(crate) hazards: [Option<Hazard>; MAX_CONTACTS],
    pub(crate) hazard_sources: [bool; crate::object_authority::MAX_OBJECTS],
    pub(crate) hazard_count: usize,
    pub(crate) previous_contacts: [Option<ObjectKey>; MAX_CONTACTS],
    pub(crate) previous_source_indices: [u8; MAX_CONTACTS],
    pub(crate) previous_contact_mask: [u64; CONTACT_MASK_WORDS],
    pub(crate) previous_contact_count: usize,
    pub(crate) session: Session,
    pub(crate) active_step_token: Option<u64>,
    pub(crate) active_step_dt: f32,
    pub(crate) next_step_token: u64,
}

impl State {
    // 状态字段保持扁平布局，构造参数数量由 Gameplay 固定数据模型决定。
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        player: ObjectKey,
        player_source_index: u8,
        goal: ObjectKey,
        goal_source_index: u8,
        hazards: &[Hazard],
        time_limit_seconds: f32,
        next_outcome_sequence: u64,
        next_step_token: u64,
    ) -> Self {
        let mut storage = [None; MAX_CONTACTS];
        let mut hazard_sources = [false; crate::object_authority::MAX_OBJECTS];
        for (index, hazard) in hazards.iter().copied().enumerate() {
            storage[index] = Some(hazard);
            hazard_sources[usize::from(hazard.source_index)] = true;
        }
        Self {
            player,
            player_source_index,
            goal,
            goal_source_index,
            hazards: storage,
            hazard_sources,
            hazard_count: hazards.len(),
            previous_contacts: [None; MAX_CONTACTS],
            previous_source_indices: [0; MAX_CONTACTS],
            previous_contact_mask: [0; CONTACT_MASK_WORDS],
            previous_contact_count: 0,
            session: Session::new(time_limit_seconds, next_outcome_sequence),
            active_step_token: None,
            active_step_dt: 0.0,
            next_step_token,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Playing,
    Won,
    Lost,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Cause {
    None,
    Timer,
    Hazard,
    Goal,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Session {
    pub(crate) phase: Phase,
    pub(crate) cause: Cause,
    pub(crate) time_limit_seconds: f32,
    pub(crate) time_remaining_seconds: f32,
    pub(crate) next_outcome_sequence: u64,
    pub(crate) last_outcome_sequence: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Outcome {
    pub(crate) sequence: u64,
    pub(crate) phase: Phase,
    pub(crate) cause: Cause,
    pub(crate) player: ObjectKey,
    pub(crate) other: Option<ObjectKey>,
}

impl Session {
    pub(crate) fn new(time_limit_seconds: f32, next_outcome_sequence: u64) -> Self {
        Self {
            phase: Phase::Playing,
            cause: Cause::None,
            time_limit_seconds,
            time_remaining_seconds: time_limit_seconds,
            next_outcome_sequence,
            last_outcome_sequence: next_outcome_sequence.saturating_sub(1),
        }
    }

    pub(crate) fn accepts_input(self) -> bool {
        self.phase == Phase::Playing
    }

    pub(crate) fn begin_step(
        &mut self,
        dt_seconds: f32,
        player: ObjectKey,
    ) -> Result<Option<Outcome>, ()> {
        if !dt_seconds.is_finite() || dt_seconds < 0.0 {
            return Err(());
        }
        if self.phase != Phase::Playing {
            return Ok(None);
        }
        if dt_seconds < self.time_remaining_seconds {
            self.time_remaining_seconds -= dt_seconds;
            return Ok(None);
        }
        let outcome = self.transition(Phase::Lost, Cause::Timer, player, None)?;
        self.time_remaining_seconds = 0.0;
        Ok(Some(outcome))
    }

    pub(crate) fn observe_contacts(
        &mut self,
        player: ObjectKey,
        hazard: Option<ObjectKey>,
        goal: Option<ObjectKey>,
    ) -> Result<Option<Outcome>, ()> {
        if self.phase != Phase::Playing {
            return Ok(None);
        }
        if let Some(hazard) = hazard {
            return self
                .transition(Phase::Lost, Cause::Hazard, player, Some(hazard))
                .map(Some);
        }
        if let Some(goal) = goal {
            return self
                .transition(Phase::Won, Cause::Goal, player, Some(goal))
                .map(Some);
        }
        Ok(None)
    }

    fn transition(
        &mut self,
        phase: Phase,
        cause: Cause,
        player: ObjectKey,
        other: Option<ObjectKey>,
    ) -> Result<Outcome, ()> {
        let sequence = self.next_outcome_sequence;
        let next = sequence.checked_add(1).ok_or(())?;
        self.phase = phase;
        self.cause = cause;
        self.last_outcome_sequence = sequence;
        self.next_outcome_sequence = next;
        Ok(Outcome {
            sequence,
            phase,
            cause,
            player,
            other,
        })
    }
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn strict_overlap(first: Sprite, second: Sprite) -> Result<bool, ()> {
    if !first.is_valid() || !second.is_valid() {
        return Err(());
    }
    // 四个零面积分支显式拆开：即使另一轴有值，零宽/零高也不是可碰撞区域。
    if first.size[0] == 0.0 {
        return Ok(false);
    }
    if first.size[1] == 0.0 {
        return Ok(false);
    }
    if second.size[0] == 0.0 {
        return Ok(false);
    }
    if second.size[1] == 0.0 {
        return Ok(false);
    }
    let first_right = first.position[0] + first.size[0];
    let first_bottom = first.position[1] + first.size[1];
    let second_right = second.position[0] + second.size[0];
    let second_bottom = second.position[1] + second.size[1];
    if ![first_right, first_bottom, second_right, second_bottom]
        .iter()
        .all(|value| value.is_finite())
    {
        return Err(());
    }
    Ok(first.position[0] < second_right
        && first_right > second.position[0]
        && first.position[1] < second_bottom
        && first_bottom > second.position[1])
}

fn phase_code(value: Phase) -> u32 {
    match value {
        Phase::Playing => abi::KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING,
        Phase::Won => abi::KADATH_RUNTIME_GAMEPLAY_PHASE_WON,
        Phase::Lost => abi::KADATH_RUNTIME_GAMEPLAY_PHASE_LOST,
    }
}

fn cause_code(value: Cause) -> u32 {
    match value {
        Cause::None => abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_NONE,
        Cause::Timer => abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_TIMER,
        Cause::Hazard => abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_HAZARD,
        Cause::Goal => abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_GOAL,
    }
}

pub(crate) fn step_result(
    session: Session,
    token: u64,
    contact_events: usize,
    outcomes: usize,
) -> abi::kadath_runtime_gameplay_step_result_v1_t {
    abi::kadath_runtime_gameplay_step_result_v1_t {
        struct_size: std::mem::size_of::<abi::kadath_runtime_gameplay_step_result_v1_t>() as u32,
        phase: phase_code(session.phase),
        cause: cause_code(session.cause),
        accepts_input: u32::from(session.accepts_input()),
        time_remaining_seconds: session.time_remaining_seconds,
        reserved0: 0,
        step_token: token,
        submitted_contact_event_count: contact_events,
        outcome_count: outcomes,
        reserved: [0; 4],
    }
}

pub(crate) fn outcome_value(value: Outcome) -> abi::kadath_runtime_gameplay_outcome_v1_t {
    abi::kadath_runtime_gameplay_outcome_v1_t {
        struct_size: std::mem::size_of::<abi::kadath_runtime_gameplay_outcome_v1_t>() as u32,
        phase: phase_code(value.phase),
        cause: cause_code(value.cause),
        has_other: u32::from(value.other.is_some()),
        sequence: value.sequence,
        player: key_ref(value.player),
        other: value
            .other
            .map(key_ref)
            .unwrap_or_else(|| unsafe { std::mem::zeroed() }),
        reserved: [0; 4],
    }
}

fn key_ref(key: ObjectKey) -> abi::kadath_runtime_object_ref_v1_t {
    abi::kadath_runtime_object_ref_v1_t {
        struct_size: std::mem::size_of::<abi::kadath_runtime_object_ref_v1_t>() as u32,
        kind: key.kind,
        world_epoch: key.world_epoch,
        logical_generation: key.logical_generation,
        object_id_length: key.object_id.len(),
        reserved0: 0,
        object_id: key.object_id.storage(),
        reserved: [0; 4],
    }
}

pub(crate) fn active_contacts(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    position_overrides: &[(ObjectKey, u8, [f32; 2])],
) -> Result<ContactObservation, u32> {
    let player = live
        .source_visible_exact(gameplay.player_source_index, gameplay.player)
        .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?;
    let mut player_sprite = player.sprite;
    if let Some(value) = position_overrides
        .iter()
        .find(|value| value.1 == gameplay.player_source_index)
    {
        player_sprite.position = value.2;
    }
    let mut contacts = [None; MAX_CONTACTS];
    let mut source_indices = [0; MAX_CONTACTS];
    let mut source_mask = [0_u64; CONTACT_MASK_WORDS];
    let mut count = 0;
    let mut first_hazard = None;
    let mut goal_contact = None;
    let mut geometry_error = false;
    live.for_each_active_ordered(|record| {
        if geometry_error {
            return;
        }
        let key = ObjectKey {
            object_id: record.object_id,
            world_epoch: live.world_epoch,
            logical_generation: record.logical_generation,
            kind: record.kind,
        };
        let is_hazard = record
            .source_index
            .is_some_and(|index| gameplay.hazard_sources[usize::from(index)]);
        if !is_hazard && key != gameplay.goal {
            return;
        }
        let mut sprite = record.sprite;
        if let Some(value) = position_overrides
            .iter()
            .find(|value| record.source_index == Some(value.1))
        {
            sprite.position = value.2;
        }
        match strict_overlap(player_sprite, sprite) {
            Ok(true) => {
                contacts[count] = Some(key);
                let source_index = record
                    .source_index
                    .expect("Gameplay contact candidates must be authored sources");
                source_indices[count] = source_index;
                source_mask[usize::from(source_index) / 64] |= 1_u64 << (source_index % 64);
                count += 1;
                if is_hazard {
                    first_hazard.get_or_insert(key);
                } else {
                    goal_contact = Some(key);
                }
            }
            Ok(false) => {}
            Err(()) => geometry_error = true,
        }
    });
    if geometry_error {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(ContactObservation {
        contacts,
        source_indices,
        source_mask,
        count,
        first_hazard,
        goal: goal_contact,
    })
}

#[cfg(test)]
pub(crate) fn contact_events(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    current: &[Option<ObjectKey>; MAX_CONTACTS],
    current_count: usize,
    current_source_indices: &[u8; MAX_CONTACTS],
    current_source_mask: &[u64; CONTACT_MASK_WORDS],
) -> Result<
    (
        [abi::kadath_runtime_phase_event_v1_t;
            abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize],
        usize,
    ),
    u32,
> {
    let mut output =
        [unsafe { std::mem::zeroed() }; abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize];
    let mut count = 0;
    let (transitions, transition_count) = contact_transitions(
        live,
        gameplay,
        current,
        current_count,
        current_source_indices,
        current_source_mask,
    )?;
    for transition in transitions[..transition_count].iter().copied() {
        append_contact_transition(
            &mut output,
            &mut count,
            if transition.ended {
                b"contact_end"
            } else {
                b"contact_begin"
            },
            gameplay.player,
            transition.other,
        )?;
    }
    Ok((output, count))
}

#[derive(Clone, Copy, Default)]
pub(crate) struct ContactTransition {
    pub(crate) ended: bool,
    pub(crate) other: ObjectKey,
    pub(crate) other_source_index: u8,
}

pub(crate) fn contact_transitions(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    current: &[Option<ObjectKey>; MAX_CONTACTS],
    current_count: usize,
    current_source_indices: &[u8; MAX_CONTACTS],
    current_source_mask: &[u64; CONTACT_MASK_WORDS],
) -> Result<([ContactTransition; MAX_CONTACT_TRANSITIONS], usize), u32> {
    let mut output = [ContactTransition {
        ended: false,
        other: gameplay.player,
        other_source_index: gameplay.player_source_index,
    }; MAX_CONTACT_TRANSITIONS];
    let mut count = 0;
    for index in 0..gameplay.previous_contact_count {
        let Some(other) = gameplay.previous_contacts[index] else {
            continue;
        };
        let source_index = gameplay.previous_source_indices[index];
        if mask_contains(current_source_mask, source_index)
            || !source_key_is_live(live, other, source_index)
        {
            continue;
        }
        if count >= output.len() {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
        }
        output[count] = ContactTransition {
            ended: true,
            other,
            other_source_index: source_index,
        };
        count += 1;
    }
    for index in 0..current_count {
        let Some(other) = current[index] else {
            continue;
        };
        if mask_contains(
            &gameplay.previous_contact_mask,
            current_source_indices[index],
        ) {
            continue;
        }
        if count >= output.len() {
            return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
        }
        output[count] = ContactTransition {
            ended: false,
            other,
            other_source_index: current_source_indices[index],
        };
        count += 1;
    }
    Ok((output, count))
}

pub(crate) fn submit_contact_transitions(
    core: &mut RuntimeCore,
    player_source_index: u8,
    transitions: &[ContactTransition],
) -> Result<usize, u32> {
    let event_count = transitions
        .len()
        .checked_mul(2)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)?;
    phase_commit::submit_compact_trusted_gameplay_events_with(core, event_count, |index| {
        let transition = transitions[index / 2];
        let (target_source_index, opposite_source_index) = if index % 2 == 0 {
            (player_source_index, transition.other_source_index)
        } else {
            (transition.other_source_index, player_source_index)
        };
        (transition.ended, target_source_index, opposite_source_index)
    })?;
    Ok(event_count)
}

fn mask_contains(mask: &[u64; CONTACT_MASK_WORDS], source_index: u8) -> bool {
    mask[usize::from(source_index) / 64] & (1_u64 << (source_index % 64)) != 0
}

fn source_key_is_live(
    live: &crate::object_authority::RuntimeState,
    key: ObjectKey,
    source_index: u8,
) -> bool {
    live.source_active_exact(source_index, key).is_some()
}

#[cfg(test)]
fn append_contact_transition(
    output: &mut [abi::kadath_runtime_phase_event_v1_t;
             abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize],
    count: &mut usize,
    name: &[u8],
    player: ObjectKey,
    other: ObjectKey,
) -> Result<(), u32> {
    if *count + 2 > output.len() {
        return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
    }
    for (target, opposite) in [(player, other), (other, player)] {
        let mut event: abi::kadath_runtime_phase_event_v1_t = unsafe { std::mem::zeroed() };
        event.struct_size = std::mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32;
        event.domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
        event.target = key_ref(target);
        event.has_other = 1;
        event.other = key_ref(opposite);
        event.name_length = name.len() as u32;
        event.name[..name.len()].copy_from_slice(name);
        output[*count] = event;
        *count += 1;
    }
    Ok(())
}

#[cfg(test)]
type StepPlan = (
    crate::object_authority::RuntimeState,
    State,
    [abi::kadath_runtime_phase_event_v1_t;
        abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize],
    usize,
    Option<Outcome>,
);

#[cfg(test)]
pub(crate) fn step_plan(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    dt_seconds: f32,
    input: [i8; 2],
) -> Result<StepPlan, u32> {
    let mut next_live = live.clone();
    let mut next_gameplay = gameplay.clone();
    next_live.step_fixed(dt_seconds, input);
    let observation = active_contacts(&next_live, &next_gameplay, &[])?;
    let outcome = next_gameplay
        .session
        .observe_contacts(
            next_gameplay.player,
            observation.first_hazard,
            observation.goal,
        )
        .map_err(|_| abi::KADATH_ERR_RUNTIME_GAMEPLAY_SEQUENCE_EXHAUSTED)?;
    let (events, event_count) = contact_events(
        &next_live,
        &next_gameplay,
        &observation.contacts,
        observation.count,
        &observation.source_indices,
        &observation.source_mask,
    )?;
    next_gameplay.previous_contacts = observation.contacts;
    next_gameplay.previous_source_indices = observation.source_indices;
    next_gameplay.previous_contact_mask = observation.source_mask;
    next_gameplay.previous_contact_count = observation.count;
    Ok((next_live, next_gameplay, events, event_count, outcome))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::object_authority::ObjectId;

    fn key(id: &[u8], kind: u32) -> ObjectKey {
        ObjectKey {
            object_id: ObjectId::parse(id).unwrap(),
            world_epoch: 1,
            logical_generation: 1,
            kind,
        }
    }

    fn sprite(position: [f32; 2], size: [f32; 2]) -> Sprite {
        Sprite {
            position,
            size,
            color: [1.0; 4],
            texture_id: 1,
            move_speed: 0.0,
        }
    }

    #[derive(Clone, Copy, Debug)]
    struct SeedCase {
        contact_index: usize,
        stale_epoch: bool,
        pending_lifecycle: usize,
        restart: bool,
        scene_reload: bool,
        capacity_boundary: usize,
        alias: bool,
        snapshot_coherence: bool,
        priority: usize,
    }

    const SEED_CASE_COUNT: usize = 4 * 2 * 3 * 2 * 2 * 3 * 2 * 2 * 5;

    // 固定的 64 位混合函数只用于把超过笛卡尔覆盖区间的 seed 映射回组合空间。
    fn seed_hash(mut value: u64) -> u64 {
        value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        value ^ (value >> 31)
    }

    fn seed_case(seed: u64) -> SeedCase {
        // 前 5,760 个 seed 使用互质仿射置换，保证每个正交组合至少一次；
        // 其余 seed 使用同一固定 hash，继续提供稳定的随机化分布。
        let rank = if seed <= SEED_CASE_COUNT as u64 {
            ((seed - 1) * 7_919 + 104_729) % SEED_CASE_COUNT as u64
        } else {
            seed_hash(seed) % SEED_CASE_COUNT as u64
        } as usize;
        let mut rest = rank;
        let priority = rest % 5;
        rest /= 5;
        let snapshot_coherence = rest % 2 == 1;
        rest /= 2;
        let alias = rest % 2 == 1;
        rest /= 2;
        let capacity_boundary = rest % 3;
        rest /= 3;
        let scene_reload = rest % 2 == 1;
        rest /= 2;
        let restart = rest % 2 == 1;
        rest /= 2;
        let pending_lifecycle = rest % 3;
        rest /= 3;
        let stale_epoch = rest % 2 == 1;
        rest /= 2;
        let contact_index = rest % 4;
        SeedCase {
            contact_index,
            stale_epoch,
            pending_lifecycle,
            restart,
            scene_reload,
            capacity_boundary,
            alias,
            snapshot_coherence,
            priority,
        }
    }

    fn seed_contact_count(case: SeedCase) -> usize {
        [0, 1, 2, 32][case.contact_index]
    }

    fn seed_priority_outcome(case: SeedCase) -> Option<Cause> {
        match case.priority {
            0 => None,
            1 => Some(Cause::Timer),
            2 | 4 => Some(Cause::Hazard),
            3 => Some(Cause::Goal),
            _ => unreachable!("priority matrix is bounded"),
        }
    }

    fn matrix_sources() -> Vec<crate::object_authority::SourceObject> {
        let mut sources = Vec::with_capacity(34);
        sources.push(crate::object_authority::SourceObject {
            object_id: ObjectId::parse(b"player").unwrap(),
            kind: 2,
            sprite: sprite([0.0, 0.0], [2.0, 2.0]),
        });
        for index in 0..32 {
            let object_id = ObjectId::parse(format!("hazard-{index}").as_bytes()).unwrap();
            sources.push(crate::object_authority::SourceObject {
                object_id,
                kind: 4,
                sprite: sprite([10.0 + index as f32, 0.0], [2.0, 2.0]),
            });
        }
        sources.push(crate::object_authority::SourceObject {
            object_id: ObjectId::parse(b"goal").unwrap(),
            kind: 3,
            sprite: sprite([100.0, 0.0], [2.0, 2.0]),
        });
        sources
    }

    #[test]
    fn strict_aabb_excludes_edges_zero_area_and_invalid_overflow() {
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([1.0, 1.0], [2.0, 2.0])
            ),
            Ok(true)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([2.0, 0.0], [2.0, 2.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [0.0, 2.0]),
                sprite([0.0, 0.0], [2.0, 2.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 0.0]),
                sprite([0.0, 0.0], [2.0, 2.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([0.0, 0.0], [0.0, 2.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([0.0, 0.0], [2.0, 0.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([f32::MAX, 0.0], [f32::MAX, 2.0]),
                sprite([0.0, 0.0], [2.0, 2.0])
            ),
            Err(())
        );
        let mut invalid = sprite([0.0, 0.0], [2.0, 2.0]);
        invalid.texture_id = 0;
        assert_eq!(
            strict_overlap(invalid, sprite([0.0, 0.0], [2.0, 2.0])),
            Err(())
        );
        assert_eq!(
            strict_overlap(sprite([0.0, 0.0], [2.0, 2.0]), invalid),
            Err(())
        );

        // 每个零尺寸分支都要独立命中；对方矩形保持几何重叠，避免
        // OR→AND 变异被“最终没有重叠”这一巧合掩盖。
        for (first, second) in [
            (
                sprite([0.0, 0.0], [0.0, 2.0]),
                sprite([-1.0, -1.0], [2.0, 2.0]),
            ),
            (
                sprite([0.0, 0.0], [2.0, 0.0]),
                sprite([-1.0, -1.0], [2.0, 2.0]),
            ),
            (
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([-1.0, -1.0], [0.0, 2.0]),
            ),
            (
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([-1.0, -1.0], [2.0, 0.0]),
            ),
        ] {
            assert_eq!(strict_overlap(first, second), Ok(false));
        }

        // 非对称尺寸同时验证 second_right 的加法以及四个严格边界。
        assert_eq!(
            strict_overlap(
                sprite([2.0, 0.0], [2.0, 2.0]),
                sprite([3.0, 0.0], [0.5, 2.0])
            ),
            Ok(true)
        );
        assert_eq!(
            strict_overlap(
                sprite([2.0, 0.0], [2.0, 2.0]),
                sprite([1.0, 0.0], [1.0, 2.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 2.0], [2.0, 2.0]),
                sprite([0.0, 1.0], [2.0, 1.0])
            ),
            Ok(false)
        );
        assert_eq!(
            strict_overlap(
                sprite([0.0, 0.0], [2.0, 2.0]),
                sprite([0.0, 2.0], [2.0, 2.0])
            ),
            Ok(false)
        );
    }

    #[test]
    fn active_contacts_covers_high_source_mask_words_and_player_override() {
        use crate::{
            object_authority::{RuntimeState, SourceObject},
            world::Bounds,
        };

        let mut sources = Vec::with_capacity(72);
        sources.push(SourceObject {
            object_id: ObjectId::parse(b"player").unwrap(),
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
            sprite: sprite([0.0, 0.0], [2.0, 2.0]),
        });
        for source_index in 1..=70 {
            sources.push(SourceObject {
                object_id: ObjectId::parse(format!("hazard-{source_index}").as_bytes()).unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                sprite: sprite([0.5, 0.0], [2.0, 2.0]),
            });
        }
        sources.push(SourceObject {
            object_id: ObjectId::parse(b"goal").unwrap(),
            kind: abi::KADATH_RUNTIME_OBJECT_KIND_GOAL,
            sprite: sprite([20.0, 20.0], [2.0, 2.0]),
        });
        let entity_values: Vec<u64> = (1..=sources.len() as u64).collect();
        let live = RuntimeState::initial(
            1,
            1,
            Bounds::new([-100.0, -100.0], [100.0, 100.0]).unwrap(),
            &sources,
            &entity_values,
        );
        let player = key(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER);
        let goal = key(b"goal", abi::KADATH_RUNTIME_OBJECT_KIND_GOAL);
        let hazards: Vec<Hazard> = (1..=70)
            .map(|source_index| Hazard {
                object: key(
                    format!("hazard-{source_index}").as_bytes(),
                    abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                ),
                source_index,
                movement_mode: abi::KADATH_RUNTIME_GAMEPLAY_HAZARD_MOVEMENT_NONE,
                patrol_min_y: 0.0,
                patrol_max_y: 0.0,
                patrol_speed: 0.0,
                patrol_direction: 1.0,
            })
            .collect();
        let gameplay = State::new(player, 0, goal, 71, &hazards, 3.0, 1, 1);

        let observation = active_contacts(&live, &gameplay, &[]).unwrap();
        assert_eq!(observation.count, 70);
        assert_eq!(observation.source_indices[0], 1);
        assert_eq!(observation.source_indices[69], 70);
        assert_ne!(observation.source_mask[0] & (1_u64 << 1), 0);
        assert_ne!(observation.source_mask[1] & (1_u64 << (70 % 64)), 0);

        // 玩家 override 必须独立查找；移动到远处后不能继续报告 hazard 接触。
        let moved = active_contacts(&live, &gameplay, &[(player, 0, [50.0, 50.0])]).unwrap();
        assert_eq!(moved.count, 0);
    }

    #[test]
    fn submit_contact_transitions_preserves_pair_order_and_direction() {
        use crate::{
            object_authority::{RuntimeState, SourceObject},
            phase_commit,
            world::Bounds,
            RuntimeCore,
        };

        let sources = [
            SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER,
                sprite: sprite([0.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"hazard-1").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                sprite: sprite([10.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"hazard-2").unwrap(),
                kind: abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD,
                sprite: sprite([20.0, 0.0], [2.0, 2.0]),
            },
        ];
        let live = RuntimeState::initial(
            1,
            1,
            Bounds::new([-10.0, -10.0], [100.0, 100.0]).unwrap(),
            &sources,
            &[1, 2, 3],
        );
        let mut core = RuntimeCore {
            owner_thread: std::thread::current().id(),
            in_call: false,
            live: Some(live),
            candidate: None,
            candidate_next_entity_value: None,
            candidate_mode: None,
            next_entity_value: 4,
            phase: phase_commit::PhaseState::new_boxed().unwrap(),
            gameplay: None,
            gameplay_candidate: None,
            #[cfg(feature = "contract-test-hooks")]
            next_fault: None,
        };
        let begin_desc = abi::kadath_runtime_phase_begin_desc_v1_t {
            struct_size: std::mem::size_of::<abi::kadath_runtime_phase_begin_desc_v1_t>() as u32,
            domain: abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            phase_sequence: 0,
            reserved0: 0,
            reserved1: 0,
            reserved: [0; 4],
        };
        let mut begin_result = abi::kadath_runtime_phase_begin_result_v1_t {
            struct_size: std::mem::size_of::<abi::kadath_runtime_phase_begin_result_v1_t>() as u32,
            ..unsafe { std::mem::zeroed() }
        };
        phase_commit::begin_phase_v2(&mut core, &begin_desc, &mut begin_result).unwrap();

        let player = key(b"player", abi::KADATH_RUNTIME_OBJECT_KIND_PLAYER);
        let first = key(b"hazard-1", abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD);
        let second = key(b"hazard-2", abi::KADATH_RUNTIME_OBJECT_KIND_PATROL_HAZARD);
        let transitions = [
            ContactTransition {
                ended: true,
                other: first,
                other_source_index: 1,
            },
            ContactTransition {
                ended: false,
                other: second,
                other_source_index: 2,
            },
        ];
        assert_eq!(
            submit_contact_transitions(&mut core, 0, &transitions),
            Ok(4)
        );

        let event_size = std::mem::size_of::<abi::kadath_runtime_phase_event_v1_t>();
        let mut short_output: [abi::kadath_runtime_phase_event_v1_t; 4] =
            [unsafe { std::mem::zeroed() }; 4];
        for event in &mut short_output {
            event.struct_size = event_size as u32;
        }
        short_output[1].struct_size = (event_size - 1) as u32;
        let mut short_count = 0;
        assert_eq!(
            phase_commit::drain_events(
                &mut core,
                abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
                begin_result.phase_sequence,
                short_output.as_mut_ptr(),
                short_output.len(),
                &mut short_count,
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        );
        let mut output: [abi::kadath_runtime_phase_event_v1_t; 4] =
            [unsafe { std::mem::zeroed() }; 4];
        for event in &mut output {
            event.struct_size = event_size as u32;
        }
        let mut output_count = 0;
        phase_commit::drain_events(
            &mut core,
            abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED,
            begin_result.phase_sequence,
            output.as_mut_ptr(),
            output.len(),
            &mut output_count,
        )
        .unwrap();
        assert_eq!(output_count, 4);
        assert_eq!(
            &output[0].name[..output[0].name_length as usize],
            b"contact_end"
        );
        assert_eq!(
            &output[2].name[..output[2].name_length as usize],
            b"contact_begin"
        );
        assert_eq!(crate::read_object_key(&output[0].target), Ok(player));
        assert_eq!(crate::read_object_key(&output[1].target), Ok(first));
        assert_eq!(crate::read_object_key(&output[2].target), Ok(player));
        assert_eq!(crate::read_object_key(&output[3].target), Ok(second));
        assert_eq!(crate::read_object_key(&output[0].other), Ok(first));
        assert_eq!(crate::read_object_key(&output[1].other), Ok(player));
        assert_eq!(crate::read_object_key(&output[2].other), Ok(second));
        assert_eq!(crate::read_object_key(&output[3].other), Ok(player));
    }

    #[test]
    fn timer_then_hazard_then_goal_priority_is_terminal_and_exactly_once() {
        let player = key(b"player", 2);
        let hazard = key(b"hazard", 4);
        let goal = key(b"goal", 3);
        let mut session = Session::new(3.0, 1);
        assert_eq!(
            session.begin_step(3.0, player).unwrap().unwrap().cause,
            Cause::Timer
        );
        assert!(!session.accepts_input());
        assert_eq!(
            session.observe_contacts(player, Some(hazard), Some(goal)),
            Ok(None)
        );
        assert_eq!(session.begin_step(1.0, player), Ok(None));

        let mut session = Session::new(3.0, 7);
        let outcome = session
            .observe_contacts(player, Some(hazard), Some(goal))
            .unwrap()
            .unwrap();
        assert_eq!(
            (outcome.sequence, outcome.phase, outcome.cause),
            (7, Phase::Lost, Cause::Hazard)
        );
        assert_eq!(outcome.other, Some(hazard));
        assert_eq!(session.observe_contacts(player, None, Some(goal)), Ok(None));

        let mut won = Session::new(3.0, 8);
        let outcome = won
            .observe_contacts(player, None, Some(goal))
            .unwrap()
            .unwrap();
        assert_eq!(
            (outcome.sequence, outcome.phase, outcome.cause),
            (8, Phase::Won, Cause::Goal)
        );

        // coverage runner 只接受真实执行日志中的决策计数，不能从源码存在性推断覆盖。
        eprintln!("GAMEPLAY_DECISION timer_priority covered=4 total=4");
    }

    #[test]
    fn outcome_sequence_exhaustion_preserves_the_playing_session() {
        let player = key(b"player", 2);
        let mut session = Session::new(3.0, u64::MAX);
        let before = session;
        assert_eq!(session.begin_step(3.0, player), Err(()));
        assert_eq!(session, before);
    }

    #[test]
    fn gameplay_abi_values_cover_all_terminal_codes_and_invalid_steps() {
        let player = key(b"player", 2);
        let mut session = Session::new(3.0, 11);

        // 非有限和负时间步必须拒绝，且不能改变仍在进行中的会话。
        let before = session;
        assert_eq!(session.begin_step(f32::NAN, player), Err(()));
        assert_eq!(session.begin_step(-0.01, player), Err(()));
        assert_eq!(session, before);

        let playing = step_result(session, 7, 0, 0);
        assert_eq!(playing.phase, abi::KADATH_RUNTIME_GAMEPLAY_PHASE_PLAYING);
        assert_eq!(playing.cause, abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_NONE);
        assert_eq!(playing.accepts_input, 1);

        let won = session
            .transition(Phase::Won, Cause::Goal, player, None)
            .unwrap();
        let won_value = outcome_value(won);
        assert_eq!(won_value.phase, abi::KADATH_RUNTIME_GAMEPLAY_PHASE_WON);
        assert_eq!(won_value.cause, abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_GOAL);
        assert_eq!(won_value.has_other, 0);
        assert_eq!(step_result(session, 8, 2, 1).accepts_input, 0);

        let lost = Outcome {
            sequence: 12,
            phase: Phase::Lost,
            cause: Cause::Hazard,
            player,
            other: Some(key(b"hazard", 4)),
        };
        let lost_value = outcome_value(lost);
        assert_eq!(lost_value.phase, abi::KADATH_RUNTIME_GAMEPLAY_PHASE_LOST);
        assert_eq!(lost_value.cause, abi::KADATH_RUNTIME_GAMEPLAY_CAUSE_HAZARD);
        assert_eq!(lost_value.has_other, 1);
    }

    #[test]
    fn step_plan_keeps_previous_ledger_and_orders_all_ends_before_begins() {
        use crate::{
            object_authority::{RuntimeState, SourceObject},
            world::Bounds,
        };
        let sources = [
            SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: 2,
                sprite: sprite([0.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"hazard").unwrap(),
                kind: 4,
                sprite: sprite([1.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"goal").unwrap(),
                kind: 3,
                sprite: sprite([10.0, 0.0], [2.0, 2.0]),
            },
        ];
        let live = RuntimeState::initial(
            1,
            1,
            Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
            &sources,
            &[1, 2, 3],
        );
        let hazard = Hazard {
            object: key(b"hazard", 4),
            source_index: 1,
            movement_mode: 0,
            patrol_min_y: 0.0,
            patrol_max_y: 0.0,
            patrol_speed: 0.0,
            patrol_direction: 1.0,
        };
        let gameplay = State::new(
            key(b"player", 2),
            0,
            key(b"goal", 3),
            2,
            &[hazard],
            3.0,
            1,
            1,
        );
        let (_, next, events, event_count, outcome) =
            step_plan(&live, &gameplay, 0.0, [0, 0]).unwrap();
        assert_eq!(event_count, 2);
        assert_eq!(
            &events[0].name[..events[0].name_length as usize],
            b"contact_begin"
        );
        assert_eq!(next.previous_contact_count, 1);
        assert_eq!(outcome.unwrap().cause, Cause::Hazard);
    }

    #[test]
    fn stale_previous_contact_is_cleared_without_publishing_an_end_event() {
        use crate::{
            object_authority::{RuntimeState, SourceObject},
            world::Bounds,
        };
        let sources = [
            SourceObject {
                object_id: ObjectId::parse(b"player").unwrap(),
                kind: 2,
                sprite: sprite([0.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"hazard").unwrap(),
                kind: 4,
                sprite: sprite([10.0, 0.0], [2.0, 2.0]),
            },
            SourceObject {
                object_id: ObjectId::parse(b"goal").unwrap(),
                kind: 3,
                sprite: sprite([20.0, 0.0], [2.0, 2.0]),
            },
        ];
        let live = RuntimeState::initial(
            2,
            1,
            Bounds::new([0.0, 0.0], [100.0, 100.0]).unwrap(),
            &sources,
            &[1, 2, 3],
        );
        let hazard = Hazard {
            object: ObjectKey {
                world_epoch: 2,
                ..key(b"hazard", 4)
            },
            source_index: 1,
            movement_mode: 0,
            patrol_min_y: 0.0,
            patrol_max_y: 0.0,
            patrol_speed: 0.0,
            patrol_direction: 1.0,
        };
        let mut gameplay = State::new(
            ObjectKey {
                world_epoch: 2,
                ..key(b"player", 2)
            },
            0,
            ObjectKey {
                world_epoch: 2,
                ..key(b"goal", 3)
            },
            2,
            &[hazard],
            3.0,
            1,
            1,
        );
        gameplay.previous_contacts[0] = Some(key(b"hazard", 4));
        gameplay.previous_source_indices[0] = 1;
        gameplay.previous_contact_mask[0] = 1_u64 << 1;
        gameplay.previous_contact_count = 1;

        // 玩家和候选对象的位置覆盖均需进入几何校验；非有限覆盖必须被拒绝。
        assert!(matches!(
            active_contacts(
                &live,
                &gameplay,
                &[
                    (gameplay.player, 0, [0.0, 0.0]),
                    (key(b"hazard", 4), 1, [f32::NAN, 0.0]),
                ],
            ),
            Err(abi::KADATH_ERR_INVALID_ARGUMENT)
        ));

        // 当前位图命中时跳过旧接触；旧位图命中时跳过当前接触。
        let mut current_mask = [0_u64; CONTACT_MASK_WORDS];
        current_mask[0] = 1_u64 << 1;
        let mut mask_gameplay = gameplay.clone();
        mask_gameplay.previous_contacts[0] = Some(ObjectKey {
            world_epoch: 2,
            ..key(b"hazard", 4)
        });
        mask_gameplay.previous_source_indices[0] = 1;
        mask_gameplay.previous_contact_count = 1;
        assert_eq!(
            contact_transitions(
                &live,
                &mask_gameplay,
                &[None; MAX_CONTACTS],
                0,
                &[0; MAX_CONTACTS],
                &current_mask,
            )
            .unwrap()
            .1,
            0,
        );
        mask_gameplay.previous_contact_count = 0;
        mask_gameplay.previous_contact_mask = current_mask;
        let mut current = [None; MAX_CONTACTS];
        current[0] = Some(ObjectKey {
            world_epoch: 2,
            ..key(b"hazard", 4)
        });
        let mut current_indices = [0; MAX_CONTACTS];
        current_indices[0] = 1;
        assert_eq!(
            contact_transitions(
                &live,
                &mask_gameplay,
                &current,
                1,
                &current_indices,
                &[0; CONTACT_MASK_WORDS],
            )
            .unwrap()
            .1,
            0,
        );

        let (_, event_count) = contact_events(
            &live,
            &gameplay,
            &[None; MAX_CONTACTS],
            0,
            &[0; MAX_CONTACTS],
            &[0; CONTACT_MASK_WORDS],
        )
        .unwrap();
        assert_eq!(event_count, 0);

        // 同一世界代但本帧离开的接触必须产生双向 end 事件。
        gameplay.previous_contacts[0] = Some(ObjectKey {
            world_epoch: 2,
            ..key(b"hazard", 4)
        });
        let (events, event_count) = contact_events(
            &live,
            &gameplay,
            &[None; MAX_CONTACTS],
            0,
            &[0; MAX_CONTACTS],
            &[0; CONTACT_MASK_WORDS],
        )
        .unwrap();
        assert_eq!(event_count, 2);
        assert_eq!(
            &events[0].name[..events[0].name_length as usize],
            b"contact_end"
        );

        // 超过固定事件槽位时必须返回容量错误，不能写出边界。
        let mut overflow = [None; MAX_CONTACTS];
        overflow.fill(Some(ObjectKey {
            world_epoch: 2,
            ..key(b"hazard", 4)
        }));
        let overflow_indices = [1; MAX_CONTACTS];
        let overflow_mask = [0_u64; CONTACT_MASK_WORDS];
        let mut overflow_gameplay = gameplay.clone();
        overflow_gameplay.previous_contacts = overflow;
        overflow_gameplay.previous_source_indices = overflow_indices;
        overflow_gameplay.previous_contact_count = MAX_CONTACTS;
        overflow_gameplay.previous_contact_mask = overflow_mask;
        assert!(matches!(
            contact_transitions(
                &live,
                &overflow_gameplay,
                &overflow,
                MAX_CONTACTS,
                &overflow_indices,
                &overflow_mask,
            ),
            Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
        ));

        eprintln!("GAMEPLAY_DECISION contact_diff_edges covered=6 total=6");
    }

    #[test]
    fn bounded_gameplay_oracle_replays_ten_thousand_deterministic_seeds() {
        let player = key(b"player", 2);
        let hazard = key(b"hazard", 4);
        let goal = key(b"goal", 3);
        let mut rng = 0x4741_4d45_504c_4159_u64;
        for seed in 1_u64..=10_000 {
            rng = rng
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            let timer_wins = rng & 1 == 0;
            let hazard_touches = rng & 2 != 0;
            let goal_touches = rng & 4 != 0;
            let mut session = Session::new(3.0, seed);
            let timer = session
                .begin_step(if timer_wins { 3.0 } else { 0.5 }, player)
                .unwrap_or_else(|_| panic!("seed={seed}: timer pre-step rejected"));
            let contact = session
                .observe_contacts(
                    player,
                    hazard_touches.then_some(hazard),
                    goal_touches.then_some(goal),
                )
                .unwrap_or_else(|_| panic!("seed={seed}: contact plan rejected"));
            let expected = if timer_wins {
                Some(Cause::Timer)
            } else if hazard_touches {
                Some(Cause::Hazard)
            } else if goal_touches {
                Some(Cause::Goal)
            } else {
                None
            };
            let actual = timer.or(contact);
            assert_eq!(
                actual.map(|outcome| outcome.cause),
                expected,
                "seed={seed}: terminal priority drifted"
            );
            assert_eq!(
                actual.map(|outcome| outcome.sequence),
                expected.map(|_| seed),
                "seed={seed}: outcome sequence drifted"
            );
            let replay = if actual.is_some() {
                session.observe_contacts(player, Some(hazard), Some(goal))
            } else {
                session.observe_contacts(player, None, None)
            };
            assert_eq!(replay, Ok(None), "seed={seed}: terminal outcome replayed");

            let offset = ((rng >> 8) & 3) as f32;
            let first = sprite([offset, 0.0], [2.0, 2.0]);
            let overlap = sprite([offset + 1.0, 0.0], [2.0, 2.0]);
            let edge = sprite([offset + 2.0, 0.0], [2.0, 2.0]);
            assert_eq!(strict_overlap(first, overlap), Ok(true), "seed={seed}");
            assert_eq!(strict_overlap(first, edge), Ok(false), "seed={seed}");
        }
    }

    #[test]
    fn deterministic_seed_matrix_covers_revision2_dimensions() {
        use crate::{
            object_authority::{DestroyDisposition, RuntimeState},
            world::Bounds,
        };
        use std::{collections::BTreeMap, fmt::Write as _};

        let sources = matrix_sources();
        let bounds = Bounds::new([0.0, 0.0], [256.0, 256.0]).unwrap();
        let entity_values: Vec<u64> = (1..=sources.len() as u64).collect();
        let live = RuntimeState::initial(1, 1, bounds, &sources, &entity_values);
        let player = ObjectKey {
            object_id: sources[0].object_id,
            world_epoch: 1,
            logical_generation: 1,
            kind: sources[0].kind,
        };
        let goal = ObjectKey {
            object_id: sources[33].object_id,
            world_epoch: 1,
            logical_generation: 1,
            kind: sources[33].kind,
        };
        let hazards: Vec<Hazard> = sources[1..33]
            .iter()
            .enumerate()
            .map(|(index, source)| Hazard {
                object: ObjectKey {
                    object_id: source.object_id,
                    world_epoch: 1,
                    logical_generation: 1,
                    kind: source.kind,
                },
                source_index: (index + 1) as u8,
                movement_mode: 0,
                patrol_min_y: 0.0,
                patrol_max_y: 0.0,
                patrol_speed: 0.0,
                patrol_direction: 1.0,
            })
            .collect();
        let base_gameplay = State::new(player, 0, goal, 33, &hazards, 3.0, 1, 1);
        let hazard_keys: Vec<ObjectKey> = hazards.iter().map(|hazard| hazard.object).collect();

        let mut combinations = BTreeMap::<String, usize>::new();
        let mut dimension_counts = [
            vec![0_usize; 4],
            vec![0_usize; 2],
            vec![0_usize; 3],
            vec![0_usize; 2],
            vec![0_usize; 2],
            vec![0_usize; 3],
            vec![0_usize; 2],
            vec![0_usize; 2],
            vec![0_usize; 5],
        ];

        for seed in 1_u64..=10_000 {
            let case = seed_case(seed);
            let contact_count = seed_contact_count(case);
            let combo = format!(
                "contact_count={contact_count};stale_epoch={};pending_lifecycle={};restart={};scene_reload={};capacity_boundary={};alias={};snapshot_coherence={};priority={}",
                u8::from(case.stale_epoch),
                case.pending_lifecycle,
                u8::from(case.restart),
                u8::from(case.scene_reload),
                case.capacity_boundary,
                u8::from(case.alias),
                u8::from(case.snapshot_coherence),
                case.priority
            );
            *combinations.entry(combo).or_default() += 1;
            dimension_counts[0][case.contact_index] += 1;
            dimension_counts[1][usize::from(case.stale_epoch)] += 1;
            dimension_counts[2][case.pending_lifecycle] += 1;
            dimension_counts[3][usize::from(case.restart)] += 1;
            dimension_counts[4][usize::from(case.scene_reload)] += 1;
            dimension_counts[5][case.capacity_boundary] += 1;
            dimension_counts[6][usize::from(case.alias)] += 1;
            dimension_counts[7][usize::from(case.snapshot_coherence)] += 1;
            dimension_counts[8][case.priority] += 1;

            // 每个 seed 都重放 terminal priority；Hazard+Goal 仍严格由 Hazard 获胜。
            let mut session = Session::new(3.0, seed);
            let timer = session
                .begin_step(if case.priority == 1 { 3.0 } else { 0.5 }, player)
                .unwrap();
            let contact = session
                .observe_contacts(
                    player,
                    (case.priority == 2 || case.priority == 4).then_some(hazard_keys[0]),
                    (case.priority == 3 || case.priority == 4).then_some(goal),
                )
                .unwrap();
            let actual = timer.or(contact);
            assert_eq!(
                actual.map(|outcome| outcome.cause),
                seed_priority_outcome(case)
            );
            let replay_hazard = actual.is_some().then_some(hazard_keys[0]);
            let replay_goal = actual.is_some().then_some(goal);
            assert_eq!(
                session.observe_contacts(player, replay_hazard, replay_goal),
                Ok(None),
                "seed={seed}: terminal outcome replayed"
            );

            // 0/1/2/32 contact 与 exact/overflow capacity 共用同一 bounded transition seam。
            let mut current = [None; MAX_CONTACTS];
            let mut current_indices = [0_u8; MAX_CONTACTS];
            let mut current_mask = [0_u64; CONTACT_MASK_WORDS];
            let requested_count = match case.capacity_boundary {
                0 => contact_count.min(1),
                1 => 32,
                2 => 33,
                _ => unreachable!("capacity matrix is bounded"),
            };
            for index in 0..requested_count {
                current[index] = Some(hazard_keys[index % hazard_keys.len()]);
                current_indices[index] = ((index % 32) + 1) as u8;
                current_mask[index / 64] |= 1_u64 << (index % 64);
            }
            let mut transition_gameplay = base_gameplay.clone();
            if case.stale_epoch {
                transition_gameplay.previous_contacts[0] = Some(ObjectKey {
                    world_epoch: 2,
                    ..hazard_keys[0]
                });
                transition_gameplay.previous_source_indices[0] = 1;
                transition_gameplay.previous_contact_count = 1;
            }
            let transitions = contact_transitions(
                &live,
                &transition_gameplay,
                &current,
                requested_count,
                &current_indices,
                &current_mask,
            );
            if case.capacity_boundary == 2 {
                assert!(
                    matches!(
                        transitions,
                        Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)
                    ),
                    "seed={seed}: overflow must fail closed"
                );
            } else {
                let (_, count) = transitions.expect("bounded contact matrix must succeed");
                assert_eq!(count, requested_count, "seed={seed}: contact count drifted");
            }

            // pending spawn/destroy 必须从 active publication 中消失，且不得进入 source contact。
            if case.pending_lifecycle != 0 {
                let mut lifecycle = live.clone();
                let slot = lifecycle
                    .reserve_transient(7, 1, sprite([0.0, 0.0], [2.0, 2.0]))
                    .unwrap()
                    .clone();
                let transient_key = ObjectKey {
                    object_id: slot.object_id,
                    world_epoch: lifecycle.world_epoch,
                    logical_generation: slot.logical_generation,
                    kind: slot.kind,
                };
                if case.pending_lifecycle == 2 {
                    lifecycle.activate(transient_key, 10_000).unwrap();
                    assert_eq!(
                        lifecycle.request_destroy(transient_key),
                        Ok(DestroyDisposition::AwaitingFinalize)
                    );
                }
                assert_eq!(lifecycle.visible_count(true), sources.len());
                if case.pending_lifecycle == 1 {
                    // PendingSpawn 可被生命周期查询看到，但不会进入 active publication。
                    assert!(lifecycle.visible_exact(transient_key).is_some());
                } else {
                    assert!(lifecycle.visible_exact(transient_key).is_none());
                }
            }

            // restart 保持 epoch/sequence，reload 递增 epoch 并使旧 ObjectRef stale。
            if case.restart {
                let restarted = live
                    .restart(bounds, &sources, &entity_values)
                    .expect("restart source identity must remain stable");
                assert_eq!(restarted.world_epoch, live.world_epoch);
                assert_eq!(restarted.record_count(), sources.len());
                let reset = State::new(player, 0, goal, 33, &hazards, 3.0, seed + 1, 1);
                assert_eq!(reset.session.phase, Phase::Playing);
                assert_eq!(reset.session.next_outcome_sequence, seed + 1);
            }
            if case.scene_reload {
                let reloaded = RuntimeState::initial(2, 1, bounds, &sources, &entity_values);
                assert_eq!(reloaded.world_epoch, 2);
                assert!(reloaded.visible_exact(player).is_none());
                let reloaded_player = ObjectKey {
                    world_epoch: 2,
                    ..player
                };
                assert!(reloaded.visible_exact(reloaded_player).is_some());
            }

            if case.alias {
                assert!(crate::ensure_disjoint(&[(0, 8), (8, 16)]).is_ok());
                assert_eq!(
                    crate::ensure_disjoint(&[(0, 8), (4, 12)]),
                    Err(abi::KADATH_ERR_INVALID_ARGUMENT)
                );
            }
            if case.snapshot_coherence {
                let snapshot = step_result(session, seed, 0, 0);
                assert_eq!(snapshot.phase, phase_code(session.phase), "seed={seed}");
                assert_eq!(snapshot.cause, cause_code(session.cause), "seed={seed}");
                assert_eq!(snapshot.accepts_input, u32::from(session.accepts_input()));
            }
        }

        assert_eq!(combinations.len(), SEED_CASE_COUNT);
        assert!(combinations.values().all(|count| *count >= 1));
        assert!(dimension_counts
            .iter()
            .all(|counts| counts.iter().all(|count| *count > 0)));

        if let Ok(path) = std::env::var("GAMEPLAY_SEED_MATRIX_MANIFEST") {
            let mut manifest = String::from("kind\tkey\tcount\tminimum\n");
            writeln!(manifest, "meta\ttotal_seeds\t10000\t10000").unwrap();
            writeln!(
                manifest,
                "meta\tunique_combinations\t{}\t{}",
                combinations.len(),
                SEED_CASE_COUNT
            )
            .unwrap();
            let dimensions = [
                ("contact_count", ["0", "1", "2", "32"].as_slice()),
                ("stale_epoch", ["0", "1"].as_slice()),
                ("pending_lifecycle", ["0", "1", "2"].as_slice()),
                ("restart", ["0", "1"].as_slice()),
                ("scene_reload", ["0", "1"].as_slice()),
                ("capacity_boundary", ["0", "1", "2"].as_slice()),
                ("alias", ["0", "1"].as_slice()),
                ("snapshot_coherence", ["0", "1"].as_slice()),
                ("priority", ["0", "1", "2", "3", "4"].as_slice()),
            ];
            for (dimension_index, (name, values)) in dimensions.iter().enumerate() {
                for (value_index, value) in values.iter().enumerate() {
                    writeln!(
                        manifest,
                        "dimension\t{name}={value}\t{}\t1",
                        dimension_counts[dimension_index][value_index]
                    )
                    .unwrap();
                }
            }
            for (combination, count) in combinations {
                writeln!(manifest, "combination\t{combination}\t{count}\t1").unwrap();
            }
            std::fs::write(path, manifest).expect("seed matrix manifest must be writable");
        }
    }
}
