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

/// Optional per-node deformation payload layered on top of the vehicle
/// transform. Current Lua clients may omit this entirely; older clients may
/// still include both position and velocity residuals.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClusterNodes {
    /// Quantized body-frame deviation from jbeam rest pose.
    #[serde(default)]
    pub node_positions: HashMap<u32, [i16; 3]>,
    /// Legacy residual-velocity field. Deserialize as empty so bridge/server
    /// paths accept newer payloads that omit it.
    #[serde(default)]
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

/// A single packet that contains all state for one vehicle/body update.
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
    /// Component/body ID. Currently equals vehicle_id for single-body replay.
    pub component_id: u32,
    /// Generation/tick number for ordering and deduplication
    pub generation: u64,
    /// Timestamp when this update was sent (seconds since epoch)
    pub sent_at: f64,
    /// Sender-side monotonic vehicle timer used for transform prediction.
    /// Optional for backward compatibility with older Lua clients.
    pub send_timer: Option<f64>,
    /// Sender-side round-trip latency estimate in milliseconds.
    /// Optional for backward compatibility with older Lua clients.
    pub ping_ms: Option<f64>,
    /// Sender-side frame interval included in the prediction-age estimate.
    /// Optional for backward compatibility with older Lua clients.
    pub send_dt: Option<f64>,
    /// Optional per-node deformation layered on top of Transform.
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

#[cfg(test)]
mod tests {
    use super::ClusterNodes;
    use crate::ClientCommand;

    #[test]
    fn cluster_nodes_accept_missing_node_velocities() {
        let nodes: ClusterNodes = serde_json::from_str(
            r#"{
                "node_positions": {
                    "42": [1, 2, 3]
                }
            }"#,
        )
        .unwrap();

        assert_eq!(nodes.node_positions.get(&42), Some(&[1, 2, 3]));
        assert!(nodes.node_velocities.is_empty());
    }

    #[test]
    fn vehicle_update_accepts_deformation_only_cluster_nodes() {
        let command: ClientCommand = serde_json::from_str(
            r#"{
                "VehicleUpdate": {
                    "transform": {
                        "position": [0.0, 0.0, 0.0],
                        "rotation": [0.0, 0.0, 0.0, 1.0],
                        "velocity": [0.0, 0.0, 0.0],
                        "angular_velocity": [0.0, 0.0, 0.0]
                    },
                    "electrics": {
                        "throttle_input": 0.0,
                        "brake_input": 0.0,
                        "clutch": 0.0,
                        "parkingbrake": 0.0,
                        "steering_input": 0.0
                    },
                    "gearbox": {
                        "arcade": false,
                        "lock_coef": 0.0,
                        "mode": null,
                        "gear_indices": [0, 0]
                    },
                    "vehicle_id": 100,
                    "component_id": 100,
                    "generation": 1,
                    "sent_at": 0.0,
                    "cluster_nodes": {
                        "node_positions": {
                            "42": [1, 2, 3]
                        }
                    }
                }
            }"#,
        )
        .unwrap();

        match command {
            ClientCommand::VehicleUpdate(update) => {
                let nodes = update.cluster_nodes.unwrap();
                assert_eq!(nodes.node_positions.get(&42), Some(&[1, 2, 3]));
                assert!(nodes.node_velocities.is_empty());
            }
            other => panic!("unexpected command: {:?}", other),
        }
    }
}
