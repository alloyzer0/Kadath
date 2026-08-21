#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Bounds {
    pub(crate) min: [f32; 2],
    pub(crate) max: [f32; 2],
}

impl Bounds {
    pub(crate) fn new(min: [f32; 2], max: [f32; 2]) -> Option<Self> {
        if min.iter().chain(max.iter()).all(|value| value.is_finite())
            && (0..2).all(|axis| min[axis] < max[axis])
        {
            Some(Self { min, max })
        } else {
            None
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Sprite {
    pub(crate) position: [f32; 2],
    pub(crate) size: [f32; 2],
    pub(crate) color: [f32; 4],
    pub(crate) texture_id: u32,
    pub(crate) move_speed: f32,
}

impl Sprite {
    pub(crate) fn is_valid(self) -> bool {
        self.texture_id != 0
            && self.move_speed.is_finite()
            && self.move_speed >= 0.0
            && self.position.iter().all(|value| value.is_finite())
            && self
                .size
                .iter()
                .all(|value| value.is_finite() && *value >= 0.0)
            && self.color.iter().all(|value| value.is_finite())
    }

    pub(crate) fn constrain(&mut self, bounds: Bounds) {
        for axis in 0..2 {
            let max_position = (bounds.max[axis] - self.size[axis]).max(bounds.min[axis]);
            self.position[axis] = self.position[axis].clamp(bounds.min[axis], max_position);
        }
    }

    pub(crate) fn step_fixed(&mut self, bounds: Bounds, dt_seconds: f32, input: [i8; 2]) {
        self.position[0] += f32::from(input[0]) * self.move_speed * dt_seconds;
        self.position[1] += f32::from(input[1]) * self.move_speed * dt_seconds;
        self.constrain(bounds);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_step_is_deterministic_and_always_constrained() {
        let bounds = Bounds::new([0.0, 0.0], [100.0, 80.0]).expect("valid bounds");
        for move_speed in [0.0, 1.0, 25.0, 500.0] {
            for dt_seconds in [0.0, 1.0 / 60.0, 0.5, 100.0] {
                let mut first = Sprite {
                    position: [10.0, 15.0],
                    size: [8.0, 9.0],
                    color: [1.0; 4],
                    texture_id: 1,
                    move_speed,
                };
                let mut second = first;
                first.step_fixed(bounds, dt_seconds, [1, -1]);
                second.step_fixed(bounds, dt_seconds, [1, -1]);
                assert_eq!(first, second);
                assert!((0.0..=92.0).contains(&first.position[0]));
                assert!((0.0..=71.0).contains(&first.position[1]));
            }
        }
    }

    #[test]
    fn descriptor_validation_rejects_non_finite_and_zero_texture() {
        let valid = Sprite {
            position: [0.0; 2],
            size: [1.0; 2],
            color: [1.0; 4],
            texture_id: 1,
            move_speed: 0.0,
        };
        assert!(valid.is_valid());
        assert!(!Sprite {
            texture_id: 0,
            ..valid
        }
        .is_valid());
        assert!(!Sprite {
            position: [f32::NAN, 0.0],
            ..valid
        }
        .is_valid());
    }
}
