use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use crate::vehicle::Transform;

/// Sample of pose divergence between authoritative and reconstructed state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoseDivergenceSample {
    /// Timestamp of the sample (seconds since epoch)
    pub timestamp: f64,
    /// Position delta [m]
    pub position_delta: [f32; 3],
    /// Orientation delta [rad] - computed as quaternion angle difference
    pub orientation_delta: f32,
    /// Vehicle ID this sample belongs to
    pub vehicle_id: u32,
    /// Generation/tick number
    pub generation: u64,
}

impl PoseDivergenceSample {
    pub fn new(
        timestamp: f64,
        authoritative: &Transform,
        reconstructed: &Transform,
        vehicle_id: u32,
        generation: u64,
    ) -> Self {
        let position_delta = [
            authoritative.position[0] - reconstructed.position[0],
            authoritative.position[1] - reconstructed.position[1],
            authoritative.position[2] - reconstructed.position[2],
        ];

        let orientation_delta = quaternion_angle_diff(
            &authoritative.rotation,
            &reconstructed.rotation,
        );

        Self {
            timestamp,
            position_delta,
            orientation_delta,
            vehicle_id,
            generation,
        }
    }

    /// Compute magnitude of position delta [m]
    pub fn position_magnitude(&self) -> f32 {
        (self.position_delta[0].powi(2)
            + self.position_delta[1].powi(2)
            + self.position_delta[2].powi(2))
            .sqrt()
    }
}

/// Ring buffer storing pose divergence samples for a single vehicle
#[derive(Debug, Clone)]
pub struct PoseDivergenceBuffer {
    /// Vehicle ID this buffer tracks
    pub vehicle_id: u32,
    /// Circular buffer of samples (~30s at 60Hz = 1800 samples)
    pub samples: VecDeque<PoseDivergenceSample>,
    /// Maximum capacity of the buffer
    pub max_capacity: usize,
}

impl PoseDivergenceBuffer {
    pub fn new(vehicle_id: u32, max_capacity: usize) -> Self {
        Self {
            vehicle_id,
            samples: VecDeque::with_capacity(max_capacity),
            max_capacity,
        }
    }

    /// Default capacity for 30 seconds at 60 Hz
    pub fn default_for_60hz() -> Self {
        Self::new(0, 1800)
    }

    /// Push a new sample, evicting oldest if at capacity
    pub fn push(&mut self, sample: PoseDivergenceSample) {
        if self.samples.len() >= self.max_capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(sample);
    }

    /// Get all samples for CSV export
    pub fn samples(&self) -> &VecDeque<PoseDivergenceSample> {
        &self.samples
    }

    /// Clear all samples
    pub fn clear(&mut self) {
        self.samples.clear();
    }

    /// Get sample count
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }
}

/// Manager for pose divergence buffers across all vehicles
#[derive(Debug, Clone)]
pub struct PoseDivergenceManager {
    buffers: std::collections::HashMap<u32, PoseDivergenceBuffer>,
    max_capacity: usize,
}

impl PoseDivergenceManager {
    pub fn new(max_capacity: usize) -> Self {
        Self {
            buffers: std::collections::HashMap::new(),
            max_capacity,
        }
    }

    /// Get or create buffer for a vehicle
    pub fn get_or_create(&mut self, vehicle_id: u32) -> &mut PoseDivergenceBuffer {
        let max_capacity = self.max_capacity;
        self.buffers
            .entry(vehicle_id)
            .or_insert_with(|| PoseDivergenceBuffer::new(vehicle_id, max_capacity))
    }

    /// Record a divergence sample
    pub fn record(
        &mut self,
        vehicle_id: u32,
        timestamp: f64,
        authoritative: &Transform,
        reconstructed: &Transform,
        generation: u64,
    ) {
        let buffer = self.get_or_create(vehicle_id);
        let sample = PoseDivergenceSample::new(
            timestamp,
            authoritative,
            reconstructed,
            vehicle_id,
            generation,
        );
        buffer.push(sample);
    }

    /// Get buffer for a vehicle (if exists)
    pub fn get(&self, vehicle_id: u32) -> Option<&PoseDivergenceBuffer> {
        self.buffers.get(&vehicle_id)
    }

    /// Get mutable buffer for a vehicle (if exists)
    pub fn get_mut(&mut self, vehicle_id: u32) -> Option<&mut PoseDivergenceBuffer> {
        self.buffers.get_mut(&vehicle_id)
    }

    /// Remove buffer for a vehicle
    pub fn remove(&mut self, vehicle_id: u32) -> Option<PoseDivergenceBuffer> {
        self.buffers.remove(&vehicle_id)
    }

    /// Get all buffers
    pub fn all_buffers(&self) -> &std::collections::HashMap<u32, PoseDivergenceBuffer> {
        &self.buffers
    }

    /// Clear all buffers
    pub fn clear_all(&mut self) {
        self.buffers.clear();
    }
}

/// Compute angle difference between two quaternions [w, x, y, z]
/// Returns angle in radians [0, π]
fn quaternion_angle_diff(q1: &[f32; 4], q2: &[f32; 4]) -> f32 {
    // Ensure quaternions are normalized and take shortest path
    let dot = q1[0] * q2[0] + q1[1] * q2[1] + q1[2] * q2[2] + q1[3] * q2[3];

    // Clamp to [-1, 1] to handle floating point errors
    let dot = dot.max(-1.0).min(1.0);

    // Angle is 2 * acos(|dot|) for unit quaternions
    // We use abs to ensure we take the shortest path
    2.0 * dot.abs().acos()
}

/// Export buffer to CSV format
pub fn export_buffer_to_csv(buffer: &PoseDivergenceBuffer) -> String {
    let mut csv = String::new();

    // Header
    csv.push_str("timestamp,vehicle_id,generation,pos_delta_x,pos_delta_y,pos_delta_z,pos_magnitude,orient_delta_rad\n");

    // Data rows
    for sample in &buffer.samples {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            sample.timestamp,
            sample.vehicle_id,
            sample.generation,
            sample.position_delta[0],
            sample.position_delta[1],
            sample.position_delta[2],
            sample.position_magnitude(),
            sample.orientation_delta
        ));
    }

    csv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quaternion_angle_diff_identity() {
        let q = [1.0, 0.0, 0.0, 0.0]; // Identity quaternion
        assert!(quaternion_angle_diff(&q, &q) < 1e-6);
    }

    #[test]
    fn test_quaternion_angle_diff_180_degrees() {
        let q1 = [1.0, 0.0, 0.0, 0.0];
        let q2 = [0.0, 1.0, 0.0, 0.0]; // 180 degree rotation around X
        let diff = quaternion_angle_diff(&q1, &q2);
        assert!((diff - std::f32::consts::PI).abs() < 1e-5);
    }

    #[test]
    fn test_ring_buffer_capacity() {
        let mut buffer = PoseDivergenceBuffer::new(1, 10);
        for i in 0..15 {
            buffer.push(PoseDivergenceSample {
                timestamp: i as f64,
                position_delta: [0.0, 0.0, 0.0],
                orientation_delta: 0.0,
                vehicle_id: 1,
                generation: i,
            });
        }
        assert_eq!(buffer.samples.len(), 10);
        assert_eq!(buffer.samples.front().unwrap().generation, 5);
    }
}
