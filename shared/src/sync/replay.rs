use serde::{Deserialize, Serialize};
use crate::vehicle::Transform;

/// Blending state for smooth snapshot transitions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlendState {
    /// Vehicle/body ID this blend state tracks
    pub id: u32,
    /// Start of blend (predicted state before snapshot arrival)
    pub blend_start: Transform,
    /// Target of blend (authoritative snapshot from wire)
    pub blend_target: Transform,
    /// Blend start timestamp
    pub blend_start_time: f64,
    /// Blend duration [s]
    pub blend_duration: f64,
    /// Whether a blend is currently in progress
    pub is_blending: bool,
}

impl BlendState {
    pub fn new(id: u32) -> Self {
        Self {
            id,
            blend_start: Transform {
                position: [0.0; 3],
                rotation: [1.0, 0.0, 0.0, 0.0],
                velocity: [0.0; 3],
                angular_velocity: [0.0; 3],
            },
            blend_target: Transform {
                position: [0.0; 3],
                rotation: [1.0, 0.0, 0.0, 0.0],
                velocity: [0.0; 3],
                angular_velocity: [0.0; 3],
            },
            blend_start_time: 0.0,
            blend_duration: 0.0,
            is_blending: false,
        }
    }

    /// Start a new blend from current state to new authoritative snapshot
    ///
    /// # Arguments
    /// * `current` - Current state (predicted or previous)
    /// * `target` - New authoritative snapshot from wire
    /// * `current_time` - Current timestamp
    /// * `blend_duration` - How long to blend [s] (typical: 0.1-0.2s)
    pub fn start_blend(
        &mut self,
        current: &Transform,
        target: &Transform,
        current_time: f64,
        blend_duration: f64,
    ) {
        self.blend_start = current.clone();
        self.blend_target = target.clone();
        self.blend_start_time = current_time;
        self.blend_duration = blend_duration.max(0.01); // Minimum 10ms blend
        self.is_blending = true;
    }

    /// Get blended transform at current time
    ///
    /// Returns the target directly if blend is complete or not active.
    pub fn get_blended(&mut self, current_time: f64) -> Transform {
        if !self.is_blending {
            return self.blend_target.clone();
        }

        let elapsed = current_time - self.blend_start_time;
        let t = (elapsed / self.blend_duration).clamp(0.0, 1.0);

        let blended = blend_transforms(&self.blend_start, &self.blend_target, t as f32);

        // Blend is complete
        if t >= 1.0 {
            self.is_blending = false;
        }

        blended
    }

    /// Cancel current blend and jump to target
    pub fn cancel_blend(&mut self) {
        self.is_blending = false;
    }

    /// Update blend target (e.g., when new snapshot arrives during blend)
    pub fn update_target(&mut self, target: &Transform, current_time: f64) {
        // Get current blended state as new blend start
        self.blend_start = self.get_blended(current_time);
        self.blend_target = target.clone();
        self.blend_start_time = current_time;
        // Keep existing blend duration
    }

    /// Get blend progress [0, 1]
    pub fn blend_progress(&self, current_time: f64) -> f32 {
        let elapsed = current_time - self.blend_start_time;
        (elapsed / self.blend_duration).clamp(0.0, 1.0) as f32
    }
}

/// Blend between two transforms using linear interpolation for position
/// and spherical linear interpolation (slerp) for rotation
///
/// # Arguments
/// * `start` - Start transform
/// * `target` - Target transform
/// * `t` - Blend factor [0, 1]
///
/// # Returns
/// Blended transform
fn blend_transforms(start: &Transform, target: &Transform, t: f32) -> Transform {
    // Linear interpolation for position: lerp(a, b, t) = a + (b - a) * t
    let position = [
        start.position[0] + (target.position[0] - start.position[0]) * t,
        start.position[1] + (target.position[1] - start.position[1]) * t,
        start.position[2] + (target.position[2] - start.position[2]) * t,
    ];

    // Spherical linear interpolation for rotation
    let rotation = slerp_quaternion(&start.rotation, &target.rotation, t);

    // Blend velocities linearly
    let velocity = [
        start.velocity[0] + (target.velocity[0] - start.velocity[0]) * t,
        start.velocity[1] + (target.velocity[1] - start.velocity[1]) * t,
        start.velocity[2] + (target.velocity[2] - start.velocity[2]) * t,
    ];

    let angular_velocity = [
        start.angular_velocity[0] + (target.angular_velocity[0] - start.angular_velocity[0]) * t,
        start.angular_velocity[1] + (target.angular_velocity[1] - start.angular_velocity[1]) * t,
        start.angular_velocity[2] + (target.angular_velocity[2] - start.angular_velocity[2]) * t,
    ];

    Transform {
        position,
        rotation,
        velocity,
        angular_velocity,
    }
}

/// Spherical linear interpolation between two quaternions
///
/// Formula: slerp(q1, q2, t) = (sin((1-t)θ)/sin(θ))·q1 + (sin(tθ)/sin(θ))·q2
/// where θ = acos(q1 · q2)
///
/// # Arguments
/// * `q1` - Start quaternion [w, x, y, z]
/// * `q2` - End quaternion [w, x, y, z]
/// * `t` - Interpolation factor [0, 1]
///
/// # Returns
/// Interpolated quaternion [w, x, y, z]
fn slerp_quaternion(q1: &[f32; 4], q2: &[f32; 4], t: f32) -> [f32; 4] {
    // Compute dot product
    let mut dot = q1[0] * q2[0] + q1[1] * q2[1] + q1[2] * q2[2] + q1[3] * q2[3];

    // If dot < 0, negate one quaternion to take shortest path
    let q2 = if dot < 0.0 {
        dot = -dot;
        [-q2[0], -q2[1], -q2[2], -q2[3]]
    } else {
        *q2
    };

    // Clamp dot to [-1, 1] to handle floating point errors
    let dot = dot.clamp(-1.0, 1.0);

    // If quaternions are nearly identical, use linear interpolation
    if dot > 0.9995 {
        return normalize_quaternion(&[
            q1[0] + (q2[0] - q1[0]) * t,
            q1[1] + (q2[1] - q1[1]) * t,
            q1[2] + (q2[2] - q1[2]) * t,
            q1[3] + (q2[3] - q1[3]) * t,
        ]);
    }

    // Compute angle and sine
    let theta = dot.acos();
    let sin_theta = theta.sin();

    if sin_theta < 1e-8 {
        // Fallback to linear interpolation
        return normalize_quaternion(&[
            q1[0] + (q2[0] - q1[0]) * t,
            q1[1] + (q2[1] - q1[1]) * t,
            q1[2] + (q2[2] - q1[2]) * t,
            q1[3] + (q2[3] - q1[3]) * t,
        ]);
    }

    let ratio_a = ((1.0 - t) * theta).sin() / sin_theta;
    let ratio_b = (t * theta).sin() / sin_theta;

    normalize_quaternion(&[
        q1[0] * ratio_a + q2[0] * ratio_b,
        q1[1] * ratio_a + q2[1] * ratio_b,
        q1[2] * ratio_a + q2[2] * ratio_b,
        q1[3] * ratio_a + q2[3] * ratio_b,
    ])
}

/// Normalize a quaternion to unit length
fn normalize_quaternion(q: &[f32; 4]) -> [f32; 4] {
    let magnitude = (q[0].powi(2) + q[1].powi(2) + q[2].powi(2) + q[3].powi(2)).sqrt();
    if magnitude < 1e-8 {
        return [1.0, 0.0, 0.0, 0.0]; // Return identity if degenerate
    }
    [
        q[0] / magnitude,
        q[1] / magnitude,
        q[2] / magnitude,
        q[3] / magnitude,
    ]
}

/// State replay engine for a single vehicle/body
/// Combines prediction and blending for smooth reconstruction
#[derive(Debug, Clone)]
pub struct ReplayEngine {
    /// Vehicle/body ID
    pub id: u32,
    /// Last authoritative snapshot from wire
    pub last_snapshot: Option<Transform>,
    /// Last snapshot timestamp
    pub last_snapshot_time: f64,
    /// Last snapshot generation/tick
    pub last_generation: u64,
    /// Current blend state
    pub blend_state: BlendState,
    /// Current applied transform (what's actually rendered)
    pub applied_transform: Transform,
}

impl ReplayEngine {
    pub fn new(id: u32) -> Self {
        Self {
            id,
            last_snapshot: None,
            last_snapshot_time: 0.0,
            last_generation: 0,
            blend_state: BlendState::new(id),
            applied_transform: Transform {
                position: [0.0; 3],
                rotation: [1.0, 0.0, 0.0, 0.0],
                velocity: [0.0; 3],
                angular_velocity: [0.0; 3],
            },
        }
    }

    /// Apply a new authoritative snapshot from wire
    ///
    /// # Arguments
    /// * `transform` - Authoritative transform from wire
    /// * `timestamp` - Timestamp of the snapshot
    /// * `generation` - Generation/tick number
    /// * `current_time` - Current local time (for blend calculation)
    /// * `blend_duration` - How long to blend [s] (0.0 for instant snap)
    pub fn apply_snapshot(
        &mut self,
        transform: &Transform,
        timestamp: f64,
        generation: u64,
        current_time: f64,
        blend_duration: f64,
    ) {
        let is_first_snapshot = self.last_snapshot.is_none();

        // Compute predicted state based on last snapshot
        let predicted = if let Some(ref last) = self.last_snapshot {
            crate::sync::prediction::extrapolate_transform(
                last,
                self.last_snapshot_time,
                timestamp,
            )
        } else {
            transform.clone()
        };

        // Update last snapshot
        self.last_snapshot = Some(transform.clone());
        self.last_snapshot_time = timestamp;
        self.last_generation = generation;

        // Start blend from predicted to authoritative
        if is_first_snapshot || blend_duration <= 0.0 {
            // Instant snap for first snapshot or when blend is disabled
            self.applied_transform = transform.clone();
            self.blend_state.cancel_blend();
        } else {
            // Blend from predicted to authoritative
            self.blend_state.start_blend(
                &predicted,
                transform,
                current_time,
                blend_duration,
            );
            self.applied_transform = self.blend_state.get_blended(current_time);
        }
    }

    /// Get current applied transform (may call blend update)
    pub fn get_transform(&mut self, current_time: f64) -> &Transform {
        if self.blend_state.is_blending {
            self.applied_transform = self.blend_state.get_blended(current_time);
        }
        &self.applied_transform
    }

    /// Get last authoritative snapshot (for measurement/debugging)
    pub fn get_authoritative(&self) -> Option<&Transform> {
        self.last_snapshot.as_ref()
    }

    /// Check if engine has received any snapshots
    pub fn is_initialized(&self) -> bool {
        self.last_snapshot.is_some()
    }

    /// Reset replay engine state
    pub fn reset(&mut self) {
        self.last_snapshot = None;
        self.last_snapshot_time = 0.0;
        self.last_generation = 0;
        self.blend_state = BlendState::new(self.id);
    }
}

/// Manager for replay engines across all vehicles/bodies in a cluster group
#[derive(Debug, Clone)]
pub struct ReplayManager {
    engines: std::collections::HashMap<u32, ReplayEngine>,
    /// Default blend duration [s] for all replay engines
    pub default_blend_duration: f64,
}

impl ReplayManager {
    pub fn new(default_blend_duration: f64) -> Self {
        Self {
            engines: std::collections::HashMap::new(),
            default_blend_duration,
        }
    }

    /// Default blend duration: 150ms (smooth but responsive)
    pub fn with_defaults() -> Self {
        Self::new(0.15)
    }

    /// Get or create replay engine for a vehicle/body
    pub fn get_or_create(&mut self, id: u32) -> &mut ReplayEngine {
        self.engines
            .entry(id)
            .or_insert_with(|| ReplayEngine::new(id))
    }

    /// Apply snapshot to a vehicle/body's replay engine
    pub fn apply_snapshot(
        &mut self,
        id: u32,
        transform: &Transform,
        timestamp: f64,
        generation: u64,
        current_time: f64,
    ) {
        // Copy blend duration before borrowing self mutably
        let blend_duration = self.default_blend_duration;
        let engine = self.get_or_create(id);
        engine.apply_snapshot(
            transform,
            timestamp,
            generation,
            current_time,
            blend_duration,
        );
    }

    /// Get current applied transform for a vehicle/body
    pub fn get_applied(&mut self, id: u32, current_time: f64) -> Option<&Transform> {
        self.engines.get_mut(&id).map(|e| e.get_transform(current_time))
    }

    /// Get authoritative snapshot for a vehicle/body (for divergence measurement)
    pub fn get_authoritative(&self, id: u32) -> Option<&Transform> {
        self.engines.get(&id).and_then(|e| e.get_authoritative())
    }

    /// Remove replay engine for a vehicle/body
    pub fn remove(&mut self, id: u32) -> Option<ReplayEngine> {
        self.engines.remove(&id)
    }

    /// Clear all replay engines
    pub fn clear(&mut self) {
        self.engines.clear();
    }

    /// Get iterator over all engines
    pub fn all_engines(&self) -> impl Iterator<Item = (&u32, &ReplayEngine)> {
        self.engines.iter()
    }

    /// Get mutable iterator over all engines
    pub fn all_engines_mut(&mut self) -> impl Iterator<Item = (&u32, &mut ReplayEngine)> {
        self.engines.iter_mut()
    }

    /// Check if all bodies in a cluster group are initialized
    pub fn all_initialized(&self, body_ids: &[u32]) -> bool {
        body_ids.iter().all(|id| {
            self.engines.get(id).map(|e| e.is_initialized()).unwrap_or(false)
        })
    }
}

impl Default for ReplayManager {
    fn default() -> Self {
        Self::with_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slerp_identity() {
        let q = [1.0, 0.0, 0.0, 0.0];
        let result = slerp_quaternion(&q, &q, 0.5);

        assert!((result[0] - 1.0).abs() < 1e-6);
        assert!((result[1] - 0.0).abs() < 1e-6);
        assert!((result[2] - 0.0).abs() < 1e-6);
        assert!((result[3] - 0.0).abs() < 1e-6);
    }

    #[test]
    fn test_slerp_endpoints() {
        let q1 = [1.0, 0.0, 0.0, 0.0];
        let q2 = [0.0, 0.0, 0.0, 1.0]; // 180° around Z

        let at_start = slerp_quaternion(&q1, &q2, 0.0);
        let at_end = slerp_quaternion(&q1, &q2, 1.0);

        // Should match endpoints
        assert!((at_start[0] - q1[0]).abs() < 1e-6);
        assert!((at_end[0] - q2[0]).abs() < 1e-6);
    }

    #[test]
    fn test_blend_transforms_linear() {
        let start = Transform {
            position: [0.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [0.0; 3],
            angular_velocity: [0.0; 3],
        };

        let target = Transform {
            position: [10.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [0.0; 3],
            angular_velocity: [0.0; 3],
        };

        let blended = blend_transforms(&start, &target, 0.5);

        // Halfway point should be at x=5
        assert!((blended.position[0] - 5.0).abs() < 1e-6);
    }

    #[test]
    fn test_replay_engine_blend() {
        let mut engine = ReplayEngine::new(1);

        let transform = Transform {
            position: [0.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [10.0, 0.0, 0.0],
            angular_velocity: [0.0, 0.0, 0.0],
        };

        // First snapshot - instant snap
        engine.apply_snapshot(&transform, 0.0, 1, 0.0, 0.2);
        assert!(engine.is_initialized());
        assert!(!engine.blend_state.is_blending);

        // Second snapshot - should blend
        let target = Transform {
            position: [5.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [10.0, 0.0, 0.0],
            angular_velocity: [0.0, 0.0, 0.0],
        };
        engine.apply_snapshot(&target, 0.5, 2, 0.5, 0.2);
        assert!(engine.blend_state.is_blending);

        // After blend duration, should be at target
        // Use time slightly after blend completion to account for float precision
        let final_transform = engine.get_transform(0.71); // 0.5 + 0.2 + epsilon
        assert!((final_transform.position[0] - 5.0).abs() < 1e-4);
        assert!(!engine.blend_state.is_blending);
    }

    #[test]
    fn test_replay_manager_multiple_bodies() {
        let mut manager = ReplayManager::new(0.15);
        let current_time = 0.0;

        // Create snapshots for two bodies (e.g., truck + trailer)
        let truck = Transform {
            position: [0.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [5.0, 0.0, 0.0],
            angular_velocity: [0.0, 0.0, 0.0],
        };

        let trailer = Transform {
            position: [-2.0, 0.0, 0.0],
            rotation: [1.0, 0.0, 0.0, 0.0],
            velocity: [5.0, 0.0, 0.0],
            angular_velocity: [0.0, 0.0, 0.0],
        };

        // Apply snapshots to both bodies
        manager.apply_snapshot(0, &truck, 0.0, 1, current_time);
        manager.apply_snapshot(1, &trailer, 0.0, 1, current_time);

        // Check both are initialized
        assert!(manager.all_initialized(&[0, 1]));

        // Get applied transforms separately to avoid double mutable borrow
        let applied_truck_pos = manager.get_applied(0, current_time).unwrap().position;
        let applied_trailer_pos = manager.get_applied(1, current_time).unwrap().position;

        assert!((applied_truck_pos[0] - 0.0).abs() < 1e-6);
        assert!((applied_trailer_pos[0] - (-2.0)).abs() < 1e-6);
    }
}
