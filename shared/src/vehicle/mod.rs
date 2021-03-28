pub mod electrics;
pub mod gearbox;
pub mod transform;
pub mod vehicle_meta;

pub use electrics::*;
pub use gearbox::*;
pub use transform::*;
pub use vehicle_meta::*;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleData {
    pub parts_config: String,
    pub in_game_id: u32,
    pub color: [f32; 4],
    pub palete_0: [f32; 4],
    pub palete_1: [f32; 4],
    pub plate: Option<String>,
    pub name: String,
    pub server_id: u32,
    pub owner: Option<u32>,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
}

// A single packet that contains all of the vehicle updates.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VehicleUpdate {
    pub transform: Transform,
    pub electrics: Electrics,
    pub undefined_electrics: ElectricsUndefined,
    pub gearbox: Gearbox,
    pub vehicle_id: u32,
    pub generation: u64,
    pub sent_at: f64,
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
