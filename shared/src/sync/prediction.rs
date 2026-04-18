use serde::{Deserialize, Serialize};
use crate::vehicle::Transform;

/// Dead-reckoning prediction state for a single vehicle/body
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictionState {
    /// Vehicle/body ID this prediction tracks
    pub id: u32,
    /// Last known transform from wire (authoritative snapshot)
    pub base_transform: Transform,
    /// Timestamp of last authoritative snapshot (seconds since epoch)
    pub base_timestamp: f64,
    /// Current predicted transform (extrapolated from base)
    pub predicted_transform: Transform,
    /// Generation/tick of last snapshot
    pub generation: u64,
}

impl PredictionState {
    pub fn new(id: u32, transform: &Transform, timestamp: f64, generation: u64) -> Self {
        Self {
            id,
            base_transform: transform.clone(),
            base_timestamp: timestamp,
            predicted_transform: transform.clone(),
            generation,
        }
    }

    /// Extrapolate state forward by delta_time using dead-reckoning
    ///
    /// Position: x(t+Δt) = x(t) + v(t)·Δt (world frame)
    /// Rotation: q(t+Δt) = q(t) ⊗ Δq(ω·Δt) (quaternion integration)
    ///
    /// # Arguments
    /// * `current_time` - Current timestamp (seconds since epoch)
    ///
    /// # Returns
    /// Predicted transform at current_time
    pub fn extrapolate(&mut self, current_time: f64) -> Transform {
        self.predicted_transform = extrapolate_transform(
            &self.base_transform,
            self.base_timestamp,
            current_time,
        );
        self.predicted_transform.clone()
    }

    /// Update base state from new authoritative snapshot
    ///
    /// # Arguments
    /// * `transform` - New authoritative transform from wire
    /// * `timestamp` - Timestamp of the snapshot
    /// * `generation` - Generation/tick number
    pub fn update_base(&mut self, transform: &Transform, timestamp: f64, generation: u64) {
        self.base_transform = transform.clone();
        self.base_timestamp = timestamp;
        self.predicted_transform = transform.clone();
        self.generation = generation;
    }

    /// Get the current predicted transform (may call extrapolate first)
    pub fn get_transform(&mut self, current_time: f64) -> &Transform {
        self.extrapolate(current_time);
        &self.predicted_transform
    }
}

/// Extrapolate a transform using dead-reckoning
///
/// Position: x(t+Δt) = x(t) + v(t)·Δt (world frame)
/// Rotation: q(t+Δt) = q(t) ⊗ exp(ω·Δt/2) (quaternion integration)
///
/// # Arguments
/// * `base` - Base transform at base_timestamp
/// * `base_timestamp` - Timestamp of the base transform
/// * `target_timestamp` - Timestamp to extrapolate to
///
/// # Returns
/// Extrapolated transform at target_timestamp
pub fn extrapolate_transform(base: &Transform, base_timestamp: f64, target_timestamp: f64) -> Transform {
    let delta_time = (target_timestamp - base_timestamp).max(0.0) as f32;

    // Extrapolate position: x(t+Δt) = x(t) + v(t)·Δt
    let new_position = [
        base.position[0] + base.velocity[0] * delta_time,
        base.position[1] + base.velocity[1] * delta_time,
        base.position[2] + base.velocity[2] * delta_time,
    ];

    // Extrapolate rotation using angular velocity
    let new_rotation = extrapolate_quaternion(
        &base.rotation,
        &base.angular_velocity,
        delta_time,
    );

    Transform {
        position: new_position,
        rotation: new_rotation,
        velocity: base.velocity,
        angular_velocity: base.angular_velocity,
    }
}

/// Extrapolate a quaternion using angular velocity
///
/// Uses the formula: q(t+Δt) = q(t) ⊗ exp(ω·Δt/2)
/// where exp for a pure imaginary quaternion is:
/// exp((0, v)) = (cos(|v|), v/|v|·sin(|v|))
///
/// # Arguments
/// * `q` - Base quaternion [w, x, y, z]
/// * `omega` - Angular velocity [rad/s] in world frame
/// * `delta_time` - Time delta [s]
///
/// # Returns
/// Extrapolated quaternion [w, x, y, z]
fn extrapolate_quaternion(q: &[f32; 4], omega: &[f32; 3], delta_time: f32) -> [f32; 4] {
    // Handle zero angular velocity or zero delta time
    let omega_magnitude = (omega[0].powi(2) + omega[1].powi(2) + omega[2].powi(2)).sqrt();

    if omega_magnitude < 1e-8 || delta_time < 1e-8 {
        return *q;
    }

    // Compute rotation angle: θ = |ω|·Δt
    let theta = omega_magnitude * delta_time;
    let half_theta = theta * 0.5;

    // Compute delta quaternion from axis-angle
    // Axis = ω/|ω|, Angle = |ω|·Δt
    // Δq = (cos(θ/2), axis·sin(θ/2))
    let sin_half_theta = half_theta.sin();
    let cos_half_theta = half_theta.cos();

    let delta_q = [
        cos_half_theta,
        omega[0] / omega_magnitude * sin_half_theta,
        omega[1] / omega_magnitude * sin_half_theta,
        omega[2] / omega_magnitude * sin_half_theta,
    ];

    // Multiply: q_new = q ⊗ Δq
    quaternion_multiply(q, &delta_q)
}

/// Multiply two quaternions: q_result = q1 ⊗ q2
///
/// Quaternion multiplication formula:
/// w = w1·w2 - x1·x2 - y1·y2 - z1·z2
/// x = w1·x2 + x1·w2 + y1·z2 - z1·y2
/// y = w1·y2 - x1·z2 + y1·w2 + z1·x2
/// z = w1·z2 + x1·y2 - y1·x2 + z1·w2
fn quaternion_multiply(q1: &[f32; 4], q2: &[f32; 4]) -> [f32; 4] {
    [
        q1[0] * q2[0] - q1[1] * q2[1] - q1[2] * q2[2] - q1[3] * q2[3],
        q1[0] * q2[1] + q1[1] * q2[0] + q1[2] * q2[3] - q1[3] * q2[2],
        q1[0] * q2[2] - q1[1] * q2[3] + q1[2] * q2[0] + q1[3] * q2[1],
        q1[0] * q2[3] + q1[1] * q2[2] - q1[2] * q2[1] + q1[3] * q2[0],
    ]
}

/// Manager for prediction states across all vehicles/bodies
#[derive(Debug, Clone)]
pub struct PredictionManager {
    states: std::collections::HashMap<u32, PredictionState>,
}

impl PredictionManager {
    pub fn new() -> Self {
        Self {
            states: std::collections::HashMap::new(),
        }
    }

    /// Get or create prediction state for a vehicle/body
    pub fn get_or_create(&mut self, id: u32) -> &mut PredictionState {
        // We need to insert a default state if it doesn't exist
        // This is a placeholder - in practice you'd want to initialize from a snapshot
        self.states.entry(id).or_insert_with(|| {
            PredictionState::new(
                id,
                &Transform {
                    position: [0.0; 3],
                    rotation: [1.0, 0.0, 0.0, 0.0],
                    velocity: [0.0; 3],
                    angular_velocity: [0.0; 3],
                },
                0.0,
                0,
            )
        })
    }

    /// Update prediction state from new authoritative snapshot
    pub fn update(
        &mut self,
        id: u32,
        transform: &Transform,
        timestamp: f64,
        generation: u64,
    ) {
        let state = self.get_or_create(id);
        state.update_base(transform, timestamp, generation);
    }

    /// Get predicted transform for a vehicle/body at current time
    pub fn get_predicted(&mut self, id: u32, current_time: f64) -> Option<&Transform> {
        self.states.get_mut(&id).map(|state| state.get_transform(current_time))
    }

    /// Remove prediction state for a vehicle/body
    pub fn remove(&mut self, id: u32) -> Option<PredictionState> {
        self.states.remove(&id)
    }

    /// Clear all prediction states
    pub fn clear(&mut self) {
        self.states.clear();
    }
}

impl Default for PredictionManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quaternion_multiply_identity() {
        let identity = [1.0, 0.0, 0.0, 0.0];
        let q = [0.707, 0.0, 0.707, 0.0]; // 90° rotation around Y

        let result = quaternion_multiply(&identity, &q);
        assert!((result[0] - q[0]).abs() < 1e-4);
        assert!((result[1] - q[1]).abs() < 1e-4);
        assert!((result[2] - q[2]).abs() < 1e-4);
        assert!((result[3] - q[3]).abs() < 1e-4);
    }

    #[test]
    fn test_extrapolate_zero_angular_velocity() {
        let q = [1.0, 0.0, 0.0, 0.0];
        let omega = [0.0, 0.0, 0.0];

        let result = extrapolate_quaternion(&q, &omega, 1.0);
        assert!((result[0] - q[0]).abs() < 1e-6);
        assert!((result[1] - q[1]).abs() < 1e-6);
        assert!((result[2] - q[2]).abs() < 1e-6);
        assert!((result[3] - q[3]).abs() < 1e-6);
    }

    #[test]
    fn test_extrapolate_constant_rotation() {
        // Start with identity quaternion
        let q = [1.0, 0.0, 0.0, 0.0];
        // Rotate around Z at 1 rad/s for 1 second = 1 radian rotation
        let omega = [0.0, 0.0, 1.0];

        let result = extrapolate_quaternion(&q, &omega, 1.0);

        // Expected: rotation of 1 radian around Z
        // q = (cos(0.5), 0, 0, sin(0.5))
        let expected_w = 0.5_f32.cos();
        let expected_z = 0.5_f32.sin();

        assert!((result[0] - expected_w).abs() < 1e-4);
        assert!((result[1] - 0.0).abs() < 1e-4);
        assert!((result[2] - 0.0).abs() < 1e-4);
        assert!((result[3] - expected_z).abs() < 1e-4);
    }

    #[test]
    fn test_prediction_position_extrapolation() {
        let transform = Transform {
            position: [0.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [10.0, 0.0, 0.0], // Moving at 10 m/s in X direction
            angular_velocity: [0.0, 0.0, 0.0],
        };

        let mut state = PredictionState::new(1, &transform, 0.0, 0);

        // Extrapolate 2 seconds forward
        let predicted = state.extrapolate(2.0);

        // Should have moved 20 meters in X direction
        assert!((predicted.position[0] - 20.0).abs() < 1e-4);
        assert!((predicted.position[1] - 0.0).abs() < 1e-4);
        assert!((predicted.position[2] - 0.0).abs() < 1e-4);
    }

    #[test]
    fn test_prediction_manager_update_and_get() {
        let mut manager = PredictionManager::new();

        let transform = Transform {
            position: [100.0, 200.0, 50.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [5.0, 0.0, 0.0],
            angular_velocity: [0.0, 0.0, 0.0],
        };

        manager.update(1, &transform, 0.0, 1);

        let predicted = manager.get_predicted(1, 1.0).unwrap();

        // After 1 second at 5 m/s, should be at x=105
        assert!((predicted.position[0] - 105.0).abs() < 1e-4);
    }
}
