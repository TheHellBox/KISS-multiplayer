pub mod electrics;
pub mod gearbox;
pub mod transform;
pub mod vehicle_meta;

pub use electrics::*;
pub use gearbox::*;
pub use transform::*;
pub use vehicle_meta::*;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Layer 2 of the layered sync model: per-node **deviations** from the rigid
/// cluster motion that Layer 1 (Transform) already describes.
///
/// The two layers are orthogonal by construction — Layer 1 carries cluster
/// pose/twist, Layer 2 carries only what Layer 1 cannot reconstruct (soft-body
/// deformation, wheel spin tangential motion, suspension travel, crash damage).
/// Receiver reconstructs absolute per-node state as `rigid_prediction +
/// deviation`; this structurally prevents the double-counting that happens if
/// you transmit absolute per-node state alongside cluster state.
///
/// - `node_positions`: body-frame deviation from rest pose, per node
/// - `node_velocities`: world-frame deviation from `v_cluster + ω_cluster × r`, per node
///
/// Nodes whose deviation magnitude falls below the sender's threshold are
/// omitted entirely — chassis nodes during steady driving deviate zero and
/// cost nothing on the wire.
///
/// Default quantization: mm precision for positions, cm/s for velocities.
/// Both scales are runtime-tunable via imgui sliders on the sender.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClusterNodes {
    /// Quantized body-frame deviation from jbeam rest pose. Omitted when near-zero.
    pub node_positions: HashMap<u32, [i16; 3]>,
    /// Quantized world-frame deviation from rigid cluster prediction. Omitted when near-zero.
    pub node_velocities: HashMap<u32, [i16; 3]>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleReset {
    pub vehicle_id: u32,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleData {
    pub parts_config: String,
    pub in_game_id: u32,
    pub color: [f32; 8],
    pub palete_0: [f32; 8],
    pub palete_1: [f32; 8],
    pub plate: Option<String>,
    pub name: String,
    pub server_id: u32,
    pub owner: Option<u32>,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
}

/// A single packet that contains all of the vehicle updates.
///
/// Phase 1b: Single vehicle sync - `component_id` equals `vehicle_id`.
/// Phase 2: Cluster support - `component_id` identifies individual bodies within a cluster group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VehicleUpdate {
    /// Transform state (pose + twist) for this body/vehicle
    pub transform: Transform,
    /// Electrics state (control inputs for telemetry)
    pub electrics: Electrics,
    /// Gearbox state
    pub gearbox: Gearbox,
    /// Unique vehicle ID on the server
    pub vehicle_id: u32,
    /// Component/body ID within cluster group (equals vehicle_id in Phase 1)
    /// Reserved for Phase 2 multi-body cluster support
    pub component_id: u32,
    /// Generation/tick number for ordering and deduplication
    pub generation: u64,
    /// Timestamp when this update was sent (seconds since epoch)
    pub sent_at: f64,
    /// Per-node state (position + velocity) for direct replay on the receiver.
    pub cluster_nodes: Option<ClusterNodes>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct CouplerAttached {
    obj_a: u32,
    obj_b: u32,
    node_a_id: u32,
    node_b_id: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct CouplerDetached {
    obj_a: u32,
    obj_b: u32,
    node_a_id: u32,
    node_b_id: u32,
}

pub struct ServerSetupResult {
    pub addr: String,
    pub port: u16,
    pub is_upnp: bool,
}
