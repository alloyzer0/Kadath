use crate::world::{Bounds, Sprite};

pub(crate) const MAX_OBJECTS: usize = 128;
pub(crate) const MAX_OBJECT_ID_BYTES: usize = 63;
pub(crate) const MAX_LOGICAL_GENERATION: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ObjectId {
    bytes: [u8; 64],
    len: u8,
}

impl ObjectId {
    pub(crate) fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty()
            || bytes.len() > MAX_OBJECT_ID_BYTES
            || !bytes[0].is_ascii_lowercase()
            || !bytes[1..].iter().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_' || *byte == b'-'
            })
        {
            return None;
        }
        let mut storage = [0; 64];
        storage[..bytes.len()].copy_from_slice(bytes);
        Some(Self {
            bytes: storage,
            len: bytes.len() as u8,
        })
    }

    pub(crate) fn runtime(serial: u64) -> Self {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        let mut storage = [0; 64];
        storage[..8].copy_from_slice(b"runtime-");
        for digit in 0..16 {
            let shift = (15 - digit) * 4;
            storage[8 + digit] = HEX[((serial >> shift) & 0xF) as usize];
        }
        Self {
            bytes: storage,
            len: 24,
        }
    }

    pub(crate) fn len(&self) -> u32 {
        u32::from(self.len)
    }

    pub(crate) fn storage(&self) -> [u8; 64] {
        self.bytes
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Lifecycle {
    PendingSpawn,
    Active,
    PendingDestroy,
}

#[derive(Clone, Debug)]
pub(crate) struct Record {
    pub(crate) object_id: ObjectId,
    pub(crate) logical_generation: u64,
    pub(crate) lifecycle: Lifecycle,
    pub(crate) source_index: Option<u8>,
    pub(crate) prototype_key: Option<u32>,
    pub(crate) kind: u32,
    pub(crate) sprite: Sprite,
    pub(crate) entity_value: u64,
    pub(crate) spawn_serial: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct Slot {
    pub(crate) logical_generation: u64,
    pub(crate) record: Option<Record>,
}

impl Default for Slot {
    fn default() -> Self {
        Self {
            logical_generation: 1,
            record: None,
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct SourceObject {
    pub(crate) object_id: ObjectId,
    pub(crate) kind: u32,
    pub(crate) sprite: Sprite,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ObjectKey {
    pub(crate) object_id: ObjectId,
    pub(crate) world_epoch: u64,
    pub(crate) logical_generation: u64,
    pub(crate) kind: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AuthorityError {
    Capacity,
    InvalidLifecycle,
    SerialExhausted,
    SourceDestroy,
    Stale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DestroyDisposition {
    CancelledPendingSpawn,
    AwaitingFinalize,
}

#[derive(Clone, Debug)]
pub(crate) struct RuntimeState {
    pub(crate) world_epoch: u64,
    pub(crate) next_spawn_serial: u64,
    pub(crate) bounds: Bounds,
    pub(crate) slots: [Slot; MAX_OBJECTS],
    record_count: usize,
    next_available_slot: usize,
    authored_source_count: u8,
    authored_sources: [Option<SourceObject>; MAX_OBJECTS],
}

impl RuntimeState {
    pub(crate) fn initial(
        world_epoch: u64,
        next_spawn_serial: u64,
        bounds: Bounds,
        sources: &[SourceObject],
        entity_values: &[u64],
    ) -> Self {
        let mut state = Self {
            world_epoch,
            next_spawn_serial,
            bounds,
            slots: std::array::from_fn(|_| Slot::default()),
            record_count: sources.len(),
            next_available_slot: sources.len(),
            authored_source_count: sources.len() as u8,
            authored_sources: std::array::from_fn(|_| None),
        };
        for (index, (source, entity_value)) in sources
            .iter()
            .zip(entity_values.iter().copied())
            .enumerate()
        {
            state.authored_sources[index] = Some(source.clone());
            let mut sprite = source.sprite;
            sprite.constrain(bounds);
            state.slots[index].record = Some(Record {
                object_id: source.object_id,
                logical_generation: 1,
                lifecycle: Lifecycle::Active,
                source_index: Some(index as u8),
                prototype_key: None,
                kind: source.kind,
                sprite,
                entity_value,
                spawn_serial: 0,
            });
        }
        state
    }

    pub(crate) fn record_count(&self) -> usize {
        self.record_count
    }

    pub(crate) fn visible_count(&self, active_only: bool) -> usize {
        self.slots
            .iter()
            .filter_map(|slot| slot.record.as_ref())
            .filter(|record| match record.lifecycle {
                Lifecycle::PendingSpawn => !active_only,
                Lifecycle::Active => true,
                Lifecycle::PendingDestroy => false,
            })
            .count()
    }

    pub(crate) fn restart(
        &self,
        bounds: Bounds,
        sources: &[SourceObject],
        entity_values: &[u64],
    ) -> Option<Self> {
        let current_records = self.ordered_records(false).ok()?;
        let mut current_sources = Vec::new();
        current_sources
            .try_reserve_exact(current_records.len())
            .ok()?;
        current_sources.extend(
            current_records
                .into_iter()
                .filter(|record| record.source_index.is_some()),
        );
        if self.authored_source_count as usize != sources.len()
            || sources.iter().enumerate().any(|(index, source)| {
                self.authored_sources[index]
                    .as_ref()
                    .is_none_or(|authored| {
                        authored.object_id != source.object_id
                            || authored.kind != source.kind
                            || authored.sprite != source.sprite
                    })
            })
            || current_sources.len() != sources.len()
        {
            return None;
        }

        let mut next = self.clone();
        next.bounds = bounds;
        for slot in &mut next.slots {
            if slot
                .record
                .as_ref()
                .is_some_and(|record| record.source_index.is_none())
            {
                slot.record = None;
                slot.logical_generation = (slot.logical_generation + 1).min(MAX_LOGICAL_GENERATION);
            }
        }
        next.record_count = sources.len();
        next.next_available_slot = next
            .slots
            .iter()
            .position(|slot| {
                slot.record.is_none() && slot.logical_generation < MAX_LOGICAL_GENERATION
            })
            .unwrap_or(MAX_OBJECTS);
        for (index, ((source, entity_value), current)) in sources
            .iter()
            .zip(entity_values.iter().copied())
            .zip(current_sources)
            .enumerate()
        {
            let mut sprite = source.sprite;
            sprite.constrain(bounds);
            let slot_index = usize::from(current.source_index.expect("source index exists"));
            next.slots[slot_index].record = Some(Record {
                object_id: source.object_id,
                logical_generation: current.logical_generation,
                lifecycle: Lifecycle::Active,
                source_index: Some(index as u8),
                prototype_key: None,
                kind: source.kind,
                sprite,
                entity_value,
                spawn_serial: 0,
            });
        }
        Some(next)
    }

    pub(crate) fn ordered_records(&self, active_only: bool) -> Result<Vec<&Record>, ()> {
        let capacity = self.record_count();
        let mut source = Vec::new();
        source.try_reserve_exact(capacity).map_err(|_| ())?;
        let mut transient = Vec::new();
        transient.try_reserve_exact(capacity).map_err(|_| ())?;
        for record in self.slots.iter().filter_map(|slot| slot.record.as_ref()) {
            let visible = match record.lifecycle {
                Lifecycle::PendingSpawn => !active_only,
                Lifecycle::Active => true,
                Lifecycle::PendingDestroy => false,
            };
            if !visible {
                continue;
            }
            if record.source_index.is_some() {
                source.push(record);
            } else {
                transient.push(record);
            }
        }
        source.sort_by_key(|record| record.source_index);
        transient.sort_by_key(|record| record.spawn_serial);
        source.extend(transient);
        Ok(source)
    }

    pub(crate) fn for_each_active_ordered(&self, mut visit: impl FnMut(&Record)) {
        for source_index in 0..self.authored_source_count {
            if let Some(record) = self.slots[usize::from(source_index)]
                .record
                .as_ref()
                .filter(|record| {
                    record.lifecycle == Lifecycle::Active
                        && record.source_index == Some(source_index)
                })
            {
                visit(record);
            }
        }
        // 没有 transient 时无需再次扫描全部 slots 寻找 spawn serial。
        if self.record_count == usize::from(self.authored_source_count) {
            return;
        }
        let mut last_serial = 0;
        loop {
            let next = self
                .slots
                .iter()
                .filter_map(|slot| slot.record.as_ref())
                .filter(|record| {
                    record.lifecycle == Lifecycle::Active
                        && record.source_index.is_none()
                        && record.spawn_serial > last_serial
                })
                .min_by_key(|record| record.spawn_serial);
            let Some(record) = next else { break };
            visit(record);
            last_serial = record.spawn_serial;
        }
    }

    pub(crate) fn visible_exact(&self, key: ObjectKey) -> Option<&Record> {
        if key.world_epoch != self.world_epoch {
            return None;
        }
        self.slots
            .iter()
            .filter_map(|slot| slot.record.as_ref())
            .find(|record| {
                record.lifecycle != Lifecycle::PendingDestroy
                    && record.object_id == key.object_id
                    && record.logical_generation == key.logical_generation
                    && record.kind == key.kind
            })
    }

    pub(crate) fn source_visible_exact(&self, source_index: u8, key: ObjectKey) -> Option<&Record> {
        if key.world_epoch != self.world_epoch {
            return None;
        }
        self.slots[usize::from(source_index)]
            .record
            .as_ref()
            .filter(|record| {
                record.lifecycle != Lifecycle::PendingDestroy
                    && record.source_index == Some(source_index)
                    && record.object_id == key.object_id
                    && record.logical_generation == key.logical_generation
                    && record.kind == key.kind
            })
    }

    pub(crate) fn visible_by_id(&self, object_id: ObjectId) -> Option<&Record> {
        self.slots
            .iter()
            .filter_map(|slot| slot.record.as_ref())
            .find(|record| {
                record.lifecycle != Lifecycle::PendingDestroy && record.object_id == object_id
            })
    }

    pub(crate) fn active_by_entity(&self, entity_value: u64) -> Option<&Record> {
        self.slots
            .iter()
            .filter_map(|slot| slot.record.as_ref())
            .find(|record| {
                record.lifecycle == Lifecycle::Active && record.entity_value == entity_value
            })
    }

    pub(crate) fn set_bounds(&mut self, bounds: Bounds) {
        self.bounds = bounds;
        for record in self
            .slots
            .iter_mut()
            .filter_map(|slot| slot.record.as_mut())
        {
            record.sprite.constrain(bounds);
        }
    }

    pub(crate) fn step_fixed(&mut self, dt_seconds: f32, input: [i8; 2]) {
        let bounds = self.bounds;
        for record in self
            .slots
            .iter_mut()
            .filter_map(|slot| slot.record.as_mut())
            .filter(|record| record.lifecycle == Lifecycle::Active)
        {
            record.sprite.step_fixed(bounds, dt_seconds, input);
        }
    }

    pub(crate) fn planned_step_position_at_source(
        &self,
        source_index: u8,
        key: ObjectKey,
        dt_seconds: f32,
        input: [i8; 2],
    ) -> Option<[f32; 2]> {
        let mut sprite = self.source_visible_exact(source_index, key)?.sprite;
        sprite.step_fixed(self.bounds, dt_seconds, input);
        Some(sprite.position)
    }

    pub(crate) fn planned_absolute_position_at_source(
        &self,
        source_index: u8,
        key: ObjectKey,
        position: [f32; 2],
    ) -> Option<[f32; 2]> {
        let mut sprite = self.source_visible_exact(source_index, key)?.sprite;
        sprite.position = position;
        sprite.constrain(self.bounds);
        Some(sprite.position)
    }

    pub(crate) fn apply_planned_positions(&mut self, updates: &[(ObjectKey, u8, [f32; 2])]) {
        for (key, source_index, position) in updates {
            let index = usize::from(*source_index);
            debug_assert!(self.source_visible_exact(*source_index, *key).is_some());
            self.slots[index]
                .record
                .as_mut()
                .expect("planned Gameplay record remains present")
                .sprite
                .position = *position;
        }
    }

    pub(crate) fn set_position(
        &mut self,
        key: ObjectKey,
        position: [f32; 2],
    ) -> Result<(), AuthorityError> {
        let index = self.exact_index(key, false).ok_or(AuthorityError::Stale)?;
        let record = self.slots[index]
            .record
            .as_mut()
            .expect("resolved record exists");
        if !matches!(
            record.lifecycle,
            Lifecycle::PendingSpawn | Lifecycle::Active
        ) {
            return Err(AuthorityError::InvalidLifecycle);
        }
        record.sprite.position = position;
        record.sprite.constrain(self.bounds);
        Ok(())
    }

    pub(crate) fn exact_index(
        &self,
        key: ObjectKey,
        include_pending_destroy: bool,
    ) -> Option<usize> {
        if key.world_epoch != self.world_epoch {
            return None;
        }
        self.slots.iter().position(|slot| {
            slot.record.as_ref().is_some_and(|record| {
                (include_pending_destroy || record.lifecycle != Lifecycle::PendingDestroy)
                    && record.object_id == key.object_id
                    && record.logical_generation == key.logical_generation
                    && record.kind == key.kind
            })
        })
    }

    pub(crate) fn exact_index_hint(
        &self,
        index: usize,
        key: ObjectKey,
        include_pending_destroy: bool,
    ) -> Option<usize> {
        if key.world_epoch != self.world_epoch {
            return None;
        }
        self.slots.get(index)?.record.as_ref().and_then(|record| {
            ((include_pending_destroy || record.lifecycle != Lifecycle::PendingDestroy)
                && record.object_id == key.object_id
                && record.logical_generation == key.logical_generation
                && record.kind == key.kind)
                .then_some(index)
        })
    }

    pub(crate) fn reserve_transient(
        &mut self,
        prototype_key: u32,
        kind: u32,
        sprite: Sprite,
    ) -> Result<&Record, AuthorityError> {
        let slot_index = self.reserve_transient_slot(prototype_key, kind, sprite)?;
        Ok(self.slots[slot_index]
            .record
            .as_ref()
            .expect("reserved record exists"))
    }

    pub(crate) fn reserve_transient_slot(
        &mut self,
        prototype_key: u32,
        kind: u32,
        mut sprite: Sprite,
    ) -> Result<usize, AuthorityError> {
        if self.record_count() >= MAX_OBJECTS {
            return Err(AuthorityError::Capacity);
        }
        let slot_index = self.next_available_slot;
        if slot_index == MAX_OBJECTS {
            return Err(AuthorityError::Capacity);
        }
        let mut serial = self.next_spawn_serial;
        let object_id = loop {
            if serial == u64::MAX {
                return Err(AuthorityError::SerialExhausted);
            }
            let candidate = ObjectId::runtime(serial);
            // `next_spawn_serial` is a persistent high-water mark, so a
            // previously issued transient can never own this or any later ID.
            // Only authored IDs can collide with the generated namespace.
            if self.authored_sources[..self.authored_source_count as usize]
                .iter()
                .flatten()
                .all(|source| source.object_id != candidate)
            {
                break candidate;
            }
            serial += 1;
        };
        self.next_spawn_serial = serial + 1;
        sprite.constrain(self.bounds);
        let generation = self.slots[slot_index].logical_generation;
        self.slots[slot_index].record = Some(Record {
            object_id,
            logical_generation: generation,
            lifecycle: Lifecycle::PendingSpawn,
            source_index: None,
            prototype_key: Some(prototype_key),
            kind,
            sprite,
            entity_value: 0,
            spawn_serial: serial,
        });
        self.record_count += 1;
        self.next_available_slot = self.slots[slot_index + 1..]
            .iter()
            .position(|slot| {
                slot.record.is_none() && slot.logical_generation < MAX_LOGICAL_GENERATION
            })
            .map_or(MAX_OBJECTS, |offset| slot_index + 1 + offset);
        Ok(slot_index)
    }

    pub(crate) fn activate(
        &mut self,
        key: ObjectKey,
        entity_value: u64,
    ) -> Result<(), AuthorityError> {
        let index = self.exact_index(key, true).ok_or(AuthorityError::Stale)?;
        let record = self.slots[index]
            .record
            .as_mut()
            .expect("resolved record exists");
        if record.source_index.is_some() || record.lifecycle != Lifecycle::PendingSpawn {
            return Err(AuthorityError::InvalidLifecycle);
        }
        record.entity_value = entity_value;
        record.lifecycle = Lifecycle::Active;
        Ok(())
    }

    pub(crate) fn discard(&mut self, key: ObjectKey) -> Result<(), AuthorityError> {
        let index = self.exact_index(key, true).ok_or(AuthorityError::Stale)?;
        self.discard_index(index, key)
    }

    pub(crate) fn discard_index(
        &mut self,
        index: usize,
        key: ObjectKey,
    ) -> Result<(), AuthorityError> {
        let index = self
            .exact_index_hint(index, key, true)
            .ok_or(AuthorityError::Stale)?;
        let record = self.slots[index]
            .record
            .as_ref()
            .expect("resolved record exists");
        if record.source_index.is_some() {
            return Err(AuthorityError::SourceDestroy);
        }
        if record.lifecycle != Lifecycle::PendingSpawn {
            return Err(AuthorityError::InvalidLifecycle);
        }
        self.release(index);
        Ok(())
    }

    pub(crate) fn request_destroy(
        &mut self,
        key: ObjectKey,
    ) -> Result<DestroyDisposition, AuthorityError> {
        let index = self.exact_index(key, true).ok_or(AuthorityError::Stale)?;
        let record = self.slots[index]
            .record
            .as_mut()
            .expect("resolved record exists");
        if record.source_index.is_some() {
            return Err(AuthorityError::SourceDestroy);
        }
        match record.lifecycle {
            Lifecycle::PendingSpawn => {
                self.release(index);
                Ok(DestroyDisposition::CancelledPendingSpawn)
            }
            Lifecycle::Active => {
                record.lifecycle = Lifecycle::PendingDestroy;
                Ok(DestroyDisposition::AwaitingFinalize)
            }
            Lifecycle::PendingDestroy => Err(AuthorityError::Stale),
        }
    }

    pub(crate) fn finalize_destroy(&mut self, key: ObjectKey) -> Result<(), AuthorityError> {
        let index = self.exact_index(key, true).ok_or(AuthorityError::Stale)?;
        self.finalize_destroy_index(index, key)
    }

    pub(crate) fn finalize_destroy_index(
        &mut self,
        index: usize,
        key: ObjectKey,
    ) -> Result<(), AuthorityError> {
        let index = self
            .exact_index_hint(index, key, true)
            .ok_or(AuthorityError::Stale)?;
        let record = self.slots[index]
            .record
            .as_ref()
            .expect("resolved record exists");
        if record.source_index.is_some() {
            return Err(AuthorityError::SourceDestroy);
        }
        if record.lifecycle != Lifecycle::PendingDestroy {
            return Err(AuthorityError::InvalidLifecycle);
        }
        self.release(index);
        Ok(())
    }

    fn release(&mut self, index: usize) {
        self.slots[index].record = None;
        self.record_count -= 1;
        self.slots[index].logical_generation =
            (self.slots[index].logical_generation + 1).min(MAX_LOGICAL_GENERATION);
        if self.slots[index].logical_generation < MAX_LOGICAL_GENERATION {
            self.next_available_slot = self.next_available_slot.min(index);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds() -> Bounds {
        Bounds::new([0.0, 0.0], [100.0, 100.0]).expect("valid bounds")
    }

    fn sprite() -> Sprite {
        Sprite {
            position: [1.0, 2.0],
            size: [3.0, 4.0],
            color: [1.0; 4],
            texture_id: 1,
            move_speed: 0.0,
        }
    }

    fn source(id: &[u8], kind: u32) -> SourceObject {
        SourceObject {
            object_id: ObjectId::parse(id).expect("test ObjectId is valid"),
            kind,
            sprite: sprite(),
        }
    }

    fn key(record: &Record, epoch: u64) -> ObjectKey {
        ObjectKey {
            object_id: record.object_id,
            world_epoch: epoch,
            logical_generation: record.logical_generation,
            kind: record.kind,
        }
    }

    #[test]
    fn transient_ids_are_monotonic_and_stale_refs_never_revive() {
        let sources = [source(b"player", 2), source(b"goal", 3)];
        let mut state = RuntimeState::initial(1, 1, bounds(), &sources, &[1, 2]);
        for expected_serial in 1..=64_u64 {
            let first = state
                .reserve_transient(7, 1, sprite())
                .expect("reservation fits")
                .clone();
            assert_eq!(first.object_id, ObjectId::runtime(expected_serial));
            let stale_key = key(&first, 1);
            state
                .activate(stale_key, 100 + expected_serial)
                .expect("activation succeeds");
            assert_eq!(
                state.request_destroy(stale_key),
                Ok(DestroyDisposition::AwaitingFinalize)
            );
            state
                .finalize_destroy(stale_key)
                .expect("finalize succeeds");
            assert!(state.visible_exact(stale_key).is_none());
        }
        let replacement = state
            .reserve_transient(7, 1, sprite())
            .expect("released slot is reusable");
        assert_eq!(replacement.object_id, ObjectId::runtime(65));
        assert!(replacement.logical_generation > 1);
    }

    #[test]
    fn ordering_is_source_first_then_transient_serial() {
        let sources = [source(b"z_source", 1), source(b"a_source", 1)];
        let mut state = RuntimeState::initial(1, 1, bounds(), &sources, &[1, 2]);
        let first_key = {
            let record = state
                .reserve_transient(0, 1, sprite())
                .expect("reserve first");
            key(record, 1)
        };
        let second_key = {
            let record = state
                .reserve_transient(0, 1, sprite())
                .expect("reserve second");
            key(record, 1)
        };
        state.activate(second_key, 4).expect("activate second");
        state.activate(first_key, 3).expect("activate first");
        let ordered = state.ordered_records(true).expect("ordering succeeds");
        assert_eq!(ordered[0].object_id, ObjectId::parse(b"z_source").unwrap());
        assert_eq!(ordered[1].object_id, ObjectId::parse(b"a_source").unwrap());
        assert_eq!(ordered[2].object_id, ObjectId::runtime(1));
        assert_eq!(ordered[3].object_id, ObjectId::runtime(2));
    }

    #[test]
    fn restart_keeps_source_refs_and_serial_high_water_but_stales_transients() {
        let sources = [source(b"player", 2), source(b"goal", 3)];
        let mut state = RuntimeState::initial(9, 1, bounds(), &sources, &[1, 2]);
        let transient_key = {
            let record = state.reserve_transient(0, 1, sprite()).expect("reserve");
            key(record, 9)
        };
        let restarted = state
            .restart(bounds(), &sources, &[11, 12])
            .expect("same source contract restarts");
        assert!(restarted.visible_exact(transient_key).is_none());
        assert_eq!(restarted.world_epoch, 9);
        assert_eq!(restarted.next_spawn_serial, 2);
        assert_eq!(
            restarted.ordered_records(true).unwrap()[0].logical_generation,
            1
        );
        assert_eq!(restarted.ordered_records(true).unwrap()[0].entity_value, 11);
    }

    #[test]
    fn restart_rejects_authored_source_changes() {
        let sources = [source(b"player", 2), source(b"goal", 3)];
        let state = RuntimeState::initial(1, 1, bounds(), &sources, &[1, 2]);
        let mut changed = sources;
        changed[0].sprite.texture_id = 2;
        assert!(state.restart(bounds(), &changed, &[3, 4]).is_none());
    }
}
