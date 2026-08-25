use crate::{abi, object_authority::ObjectKey, phase_commit, world::Sprite, RuntimeCore};

pub(crate) const MAX_CONTACTS: usize = crate::object_authority::MAX_OBJECTS - 1;

pub(crate) struct ContactObservation {
    pub(crate) contacts: [Option<ObjectKey>; MAX_CONTACTS],
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
    pub(crate) goal: ObjectKey,
    pub(crate) hazards: [Option<Hazard>; MAX_CONTACTS],
    pub(crate) hazard_sources: [bool; crate::object_authority::MAX_OBJECTS],
    pub(crate) hazard_count: usize,
    pub(crate) previous_contacts: [Option<ObjectKey>; MAX_CONTACTS],
    pub(crate) previous_contact_count: usize,
    pub(crate) session: Session,
    pub(crate) active_step_token: Option<u64>,
    pub(crate) active_step_dt: f32,
    pub(crate) next_step_token: u64,
}

impl State {
    pub(crate) fn new(
        player: ObjectKey,
        goal: ObjectKey,
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
            goal,
            hazards: storage,
            hazard_sources,
            hazard_count: hazards.len(),
            previous_contacts: [None; MAX_CONTACTS],
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
    position_overrides: &[(ObjectKey, [f32; 2])],
) -> Result<ContactObservation, u32> {
    let player = live
        .visible_exact(gameplay.player)
        .ok_or(abi::KADATH_ERR_RUNTIME_STALE_OBJECT)?;
    let mut player_sprite = player.sprite;
    if let Some(value) = position_overrides
        .iter()
        .find(|value| value.0 == gameplay.player)
    {
        player_sprite.position = value.1;
    }
    let mut contacts = [None; MAX_CONTACTS];
    let mut count = 0;
    let mut first_hazard = None;
    let mut goal_contact = None;
    let mut invalid_geometry = false;
    live.for_each_active_ordered(|record| {
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
        if let Some(value) = position_overrides.iter().find(|value| value.0 == key) {
            sprite.position = value.1;
        }
        match strict_overlap(player_sprite, sprite) {
            Ok(true) => {
                contacts[count] = Some(key);
                count += 1;
                if is_hazard {
                    first_hazard.get_or_insert(key);
                } else {
                    goal_contact = Some(key);
                }
            }
            Ok(false) => {}
            Err(()) => invalid_geometry = true,
        }
    });
    if invalid_geometry {
        return Err(abi::KADATH_ERR_INVALID_ARGUMENT);
    }
    Ok(ContactObservation {
        contacts,
        count,
        first_hazard,
        goal: goal_contact,
    })
}

fn contains(values: &[Option<ObjectKey>], count: usize, key: ObjectKey) -> bool {
    values[..count].contains(&Some(key))
}

pub(crate) fn contact_events(
    live: &crate::object_authority::RuntimeState,
    gameplay: &State,
    current: &[Option<ObjectKey>; MAX_CONTACTS],
    current_count: usize,
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
    for name in [b"contact_end".as_slice(), b"contact_begin".as_slice()] {
        let values = if name == b"contact_end" {
            &gameplay.previous_contacts
        } else {
            current
        };
        let value_count = if name == b"contact_end" {
            gameplay.previous_contact_count
        } else {
            current_count
        };
        for other in values[..value_count].iter().flatten().copied() {
            let transitioned = if name == b"contact_end" {
                !contains(current, current_count, other)
            } else {
                !contains(
                    &gameplay.previous_contacts,
                    gameplay.previous_contact_count,
                    other,
                )
            };
            if !transitioned {
                continue;
            }
            // A previous pair whose peer has since become stale is forgotten
            // silently. Phase events may only carry fully live ObjectRefs.
            if name == b"contact_end" && live.visible_exact(other).is_none() {
                continue;
            }
            if count + 2 > output.len() {
                return Err(abi::KADATH_ERR_RUNTIME_PHASE_QUEUE_CAPACITY);
            }
            for (target, opposite) in [(gameplay.player, other), (other, gameplay.player)] {
                let mut event: abi::kadath_runtime_phase_event_v1_t = unsafe { std::mem::zeroed() };
                event.struct_size =
                    std::mem::size_of::<abi::kadath_runtime_phase_event_v1_t>() as u32;
                event.domain = abi::KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
                event.target = key_ref(target);
                event.has_other = 1;
                event.other = key_ref(opposite);
                event.name_length = name.len() as u32;
                event.name[..name.len()].copy_from_slice(name);
                output[count] = event;
                count += 1;
            }
        }
    }
    Ok((output, count))
}

pub(crate) fn submit_contact_events(
    core: &mut RuntimeCore,
    events: &[abi::kadath_runtime_phase_event_v1_t],
) -> Result<(), u32> {
    if events.is_empty() {
        return Ok(());
    }
    let mut result: abi::kadath_runtime_phase_batch_result_v1_t = unsafe { std::mem::zeroed() };
    result.struct_size = std::mem::size_of::<abi::kadath_runtime_phase_batch_result_v1_t>() as u32;
    phase_commit::submit_events(
        core,
        events.as_ptr(),
        events.len(),
        std::mem::size_of::<abi::kadath_runtime_phase_event_v1_t>(),
        &mut result,
    )
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
    )?;
    next_gameplay.previous_contacts = observation.contacts;
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
        let gameplay = State::new(key(b"player", 2), key(b"goal", 3), &[hazard], 3.0, 1, 1);
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
            ObjectKey {
                world_epoch: 2,
                ..key(b"goal", 3)
            },
            &[hazard],
            3.0,
            1,
            1,
        );
        gameplay.previous_contacts[0] = Some(key(b"hazard", 4));
        gameplay.previous_contact_count = 1;

        let (_, event_count) = contact_events(&live, &gameplay, &[None; MAX_CONTACTS], 0).unwrap();
        assert_eq!(event_count, 0);
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
