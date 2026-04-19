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

/// Per-node state of a cluster, carried on the wire for direct replay.
/// The receiver applies both position and velocity per node rather than estimating
/// velocity from cluster body twist (which only works for a single rigid body and
/// drifts on wheels, rotors, and articulated vehicles).
///
/// Keyed by node CID (integer, not necessarily contiguous or zero-indexed), which
/// matches the Lua table shape `{ [cid] = {x, y, z} }` and survives JSON round-trip.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClusterNodes {
    /// Node positions in world space: { cid -> (x, y, z) }.
    pub node_positions: HashMap<u32, [f32; 3]>,
    /// Node velocities in world space: { cid -> (vx, vy, vz) }.
    pub node_velocities: HashMap<u32, [f32; 3]>,
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
