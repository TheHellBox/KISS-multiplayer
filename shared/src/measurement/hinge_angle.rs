use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Represents a hinge measurement point between two vehicle parts
/// Used primarily for articulated vehicles (buses with hinge, truck+trailer couplers)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HingeMeasurement {
    /// ID of the first vehicle/object
    pub vehicle_id_a: u32,
    /// ID of the second vehicle/object (can be same vehicle for internal hinges)
    pub vehicle_id_b: u32,
    /// Node ID on the first vehicle (the hinge attachment point)
    pub node_id_a: u32,
    /// Node ID on the second vehicle
    pub node_id_b: u32,
}

impl HingeMeasurement {
    pub fn new(vehicle_id_a: u32, vehicle_id_b: u32, node_id_a: u32, node_id_b: u32) -> Self {
        Self {
            vehicle_id_a,
            vehicle_id_b,
            node_id_a,
            node_id_b,
        }
    }

    /// Create a hinge measurement for an internal vehicle hinge (e.g., bus articulation)
    pub fn internal_hinge(vehicle_id: u32, node_id_a: u32, node_id_b: u32) -> Self {
        Self::new(vehicle_id, vehicle_id, node_id_a, node_id_b)
    }
}

/// Sample of hinge angle measurement
/// The hinge angle is the relative angle between two parts connected by a hinge
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HingeAngleSample {
    /// Timestamp of the sample (seconds since epoch)
    pub timestamp: f64,
    /// The hinge configuration being measured
    pub hinge: HingeMeasurement,
    /// Relative angle [rad] - computed from node positions
    pub angle_rad: f32,
    /// Angular velocity [rad/s] if available
    pub angular_velocity: Option<f32>,
    /// Generation/tick number
    pub generation: u64,
}

impl HingeAngleSample {
    pub fn new(
        timestamp: f64,
        hinge: HingeMeasurement,
        angle_rad: f32,
        angular_velocity: Option<f32>,
        generation: u64,
    ) -> Self {
        Self {
            timestamp,
            hinge,
            angle_rad,
            angular_velocity,
            generation,
        }
    }

    /// Compute hinge angle from node positions
    ///
    /// For a typical bus hinge:
    /// - Node A is on the front section
    /// - Node B is on the rear section
    /// - The angle is computed relative to the "straight" configuration
    ///
    /// This is a simplified model - actual implementation may need to account for
    /// the specific hinge axis and rest configuration
    pub fn compute_angle_from_nodes(
        node_a_pos: [f32; 3],
        node_b_pos: [f32; 3],
        hinge_axis: [f32; 3],
        rest_angle: f32,
    ) -> f32 {
        // Vector from node A to node B
        let delta = [
            node_b_pos[0] - node_a_pos[0],
            node_b_pos[1] - node_a_pos[1],
            node_b_pos[2] - node_a_pos[2],
        ];

        // Project onto the plane perpendicular to hinge axis
        // This gives us the effective rotation
        let hinge_axis_len = (hinge_axis[0].powi(2) + hinge_axis[1].powi(2) + hinge_axis[2].powi(2)).sqrt();

        if hinge_axis_len < 1e-6 {
            return rest_angle;
        }

        let hinge_axis_norm = [
            hinge_axis[0] / hinge_axis_len,
            hinge_axis[1] / hinge_axis_len,
            hinge_axis[2] / hinge_axis_len,
        ];

        // Remove component parallel to hinge axis
        let dot = delta[0] * hinge_axis_norm[0] + delta[1] * hinge_axis_norm[1] + delta[2] * hinge_axis_norm[2];
        let perpendicular = [
            delta[0] - dot * hinge_axis_norm[0],
            delta[1] - dot * hinge_axis_norm[1],
            delta[2] - dot * hinge_axis_norm[2],
        ];

        // For a simple hinge, we measure deviation from rest configuration
        // This is a simplified model - production code may need more sophisticated
        // angle computation based on the specific hinge geometry
        let magnitude = (perpendicular[0].powi(2) + perpendicular[1].powi(2) + perpendicular[2].powi(2)).sqrt();

        if magnitude < 1e-6 {
            return rest_angle;
        }

        // Return angle as deviation from rest (simplified)
        // In practice, you'd want a reference direction to measure against
        rest_angle
    }

    /// Get magnitude of angle (absolute value)
    pub fn angle_magnitude(&self) -> f32 {
        self.angle_rad.abs()
    }
}

/// Ring buffer for hinge angle samples
#[derive(Debug, Clone)]
pub struct HingeAngleBuffer {
    /// The hinge this buffer tracks
    pub hinge: HingeMeasurement,
    /// Circular buffer of samples
    pub samples: VecDeque<HingeAngleSample>,
    /// Maximum capacity
    pub max_capacity: usize,
}

impl HingeAngleBuffer {
    pub fn new(hinge: HingeMeasurement, max_capacity: usize) -> Self {
        Self {
            hinge,
            samples: VecDeque::with_capacity(max_capacity),
            max_capacity,
        }
    }

    /// Default capacity for 30 seconds at 60 Hz
    pub fn default_for_60hz(hinge: HingeMeasurement) -> Self {
        Self::new(hinge, 1800)
    }

    /// Push a new sample, evicting oldest if at capacity
    pub fn push(&mut self, sample: HingeAngleSample) {
        if self.samples.len() >= self.max_capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(sample);
    }

    /// Record a new sample from node positions
    pub fn record(
        &mut self,
        timestamp: f64,
        node_a_pos: [f32; 3],
        node_b_pos: [f32; 3],
        hinge_axis: [f32; 3],
        rest_angle: f32,
        generation: u64,
    ) {
        let angle = HingeAngleSample::compute_angle_from_nodes(
            node_a_pos,
            node_b_pos,
            hinge_axis,
            rest_angle,
        );

        let sample = HingeAngleSample::new(
            timestamp,
            self.hinge.clone(),
            angle,
            None, // Angular velocity would need to be computed from history
            generation,
        );

        self.push(sample);
    }

    pub fn samples(&self) -> &VecDeque<HingeAngleSample> {
        &self.samples
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }
}

/// Manager for hinge angle measurements across all hinges
#[derive(Debug, Clone)]
pub struct HingeAngleManager {
    buffers: HashMap<u64, HingeAngleBuffer>,
    max_capacity: usize,
}

impl HingeAngleManager {
    pub fn new(max_capacity: usize) -> Self {
        Self {
            buffers: HashMap::new(),
            max_capacity,
        }
    }

    /// Generate a unique key for a hinge
    fn hinge_key(hinge: &HingeMeasurement) -> u64 {
        // Combine vehicle IDs and node IDs into a unique key
        // This assumes IDs fit in 16 bits each, adjust if needed
        ((hinge.vehicle_id_a as u64) << 48)
            | ((hinge.vehicle_id_b as u64) << 32)
            | ((hinge.node_id_a as u64) << 16)
            | (hinge.node_id_b as u64)
    }

    /// Get or create buffer for a hinge
    pub fn get_or_create(&mut self, hinge: &HingeMeasurement) -> &mut HingeAngleBuffer {
        let key = Self::hinge_key(hinge);
        let max_capacity = self.max_capacity;
        self.buffers
            .entry(key)
            .or_insert_with(|| HingeAngleBuffer::new(hinge.clone(), max_capacity))
    }

    /// Record a hinge angle sample
    pub fn record(
        &mut self,
        hinge: &HingeMeasurement,
        timestamp: f64,
        node_a_pos: [f32; 3],
        node_b_pos: [f32; 3],
        hinge_axis: [f32; 3],
        rest_angle: f32,
        generation: u64,
    ) {
        let key = Self::hinge_key(hinge);
        if let Some(buffer) = self.buffers.get_mut(&key) {
            buffer.record(timestamp, node_a_pos, node_b_pos, hinge_axis, rest_angle, generation);
        } else {
            let mut buffer = HingeAngleBuffer::new(hinge.clone(), self.max_capacity);
            buffer.record(timestamp, node_a_pos, node_b_pos, hinge_axis, rest_angle, generation);
            self.buffers.insert(key, buffer);
        }
    }

    /// Get buffer for a hinge (if exists)
    pub fn get(&self, vehicle_id_a: u32, vehicle_id_b: u32, node_id_a: u32, node_id_b: u32) -> Option<&HingeAngleBuffer> {
        let hinge = HingeMeasurement::new(vehicle_id_a, vehicle_id_b, node_id_a, node_id_b);
        let key = Self::hinge_key(&hinge);
        self.buffers.get(&key)
    }

    /// Remove buffer for a hinge
    pub fn remove(&mut self, hinge: &HingeMeasurement) -> Option<HingeAngleBuffer> {
        let key = Self::hinge_key(hinge);
        self.buffers.remove(&key)
    }

    /// Clear all buffers
    pub fn clear_all(&mut self) {
        self.buffers.clear();
    }

    /// Get all buffers
    pub fn all_buffers(&self) -> &HashMap<u64, HingeAngleBuffer> {
        &self.buffers
    }
}

/// Export hinge angle buffer to CSV format
pub fn export_hinge_buffer_to_csv(buffer: &HingeAngleBuffer) -> String {
    let mut csv = String::new();

    // Header
    csv.push_str("timestamp,vehicle_id_a,vehicle_id_b,node_id_a,node_id_b,angle_rad,angular_velocity,generation\n");

    // Data rows
    for sample in &buffer.samples {
        let angular_vel_str = match sample.angular_velocity {
            Some(v) => v.to_string(),
            None => String::from("NaN"),
        };

        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            sample.timestamp,
            sample.hinge.vehicle_id_a,
            sample.hinge.vehicle_id_b,
            sample.hinge.node_id_a,
            sample.hinge.node_id_b,
            sample.angle_rad,
            angular_vel_str,
            sample.generation
        ));
    }

    csv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hinge_key_uniqueness() {
        let h1 = HingeMeasurement::new(1, 1, 10, 11);
        let h2 = HingeMeasurement::new(1, 1, 11, 10);
        assert_ne!(HingeAngleManager::hinge_key(&h1), HingeAngleManager::hinge_key(&h2));
    }

    #[test]
    fn test_internal_hinge() {
        let hinge = HingeMeasurement::internal_hinge(5, 100, 101);
        assert_eq!(hinge.vehicle_id_a, 5);
        assert_eq!(hinge.vehicle_id_b, 5);
        assert_eq!(hinge.node_id_a, 100);
        assert_eq!(hinge.node_id_b, 101);
    }
}

use std::collections::VecDeque;
