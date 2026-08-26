use crate::{abi, object_authority::ObjectKey, phase_commit, world::Sprite, RuntimeCore};

pub(crate) const MAX_CONTACTS: usize = crate::object_authority::MAX_OBJECTS - 1;
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
    if first.size[0] == 0.0
        || first.size[1] == 0.0
        || second.size[0] == 0.0
        || second.size[1] == 0.0
    {
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

#[derive(Clone, Copy)]
pub(crate) struct ContactTransition {
    pub(crate) ended: bool,
    pub(crate) other: ObjectKey,
}

pub(crate) fn contact_transitions(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    current: &[Option<ObjectKey>; MAX_CONTACTS],
    current_count: usize,
    current_source_indices: &[u8; MAX_CONTACTS],
    current_source_mask: &[u64; CONTACT_MASK_WORDS],
) -> Result<
    (
        [ContactTransition; (abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize) / 2],
        usize,
    ),
    u32,
> {
    let mut output = [ContactTransition {
        ended: false,
        other: gameplay.player,
    }; (abi::KADATH_RUNTIME_PHASE_MAX_EVENTS_PER_DOMAIN as usize) / 2];
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
        output[count] = ContactTransition { ended: true, other };
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
        };
        count += 1;
    }
    Ok((output, count))
}

pub(crate) fn submit_contact_transitions(
    core: &mut RuntimeCore,
    player: ObjectKey,
    transitions: &[ContactTransition],
) -> Result<usize, u32> {
    let event_count = transitions
        .len()
        .checked_mul(2)
        .ok_or(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY)?;
    phase_commit::submit_trusted_gameplay_events_with(core, event_count, |index| {
        let transition = transitions[index / 2];
        let name = if transition.ended {
            b"contact_end".as_slice()
        } else {
            b"contact_begin".as_slice()
        };
        let (target, opposite) = if index % 2 == 0 {
            (player, transition.other)
        } else {
            (transition.other, player)
        };
        let mut event: abi::kadath_runtime_phase_event_v1_t = unsafe { std::mem::zeroed() };
        event.struct_size = std::mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32;
        event.domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
        event.target = key_ref(target);
        event.has_other = 1;
        event.other = key_ref(opposite);
        event.name_length = name.len() as u32;
        event.name[..name.len()].copy_from_slice(name);
        event
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
}
