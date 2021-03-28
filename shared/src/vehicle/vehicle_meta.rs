use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VehicleMeta {
    pub vehicle_id: u32,
    pub plate: Option<String>,
    pub colors_table: [[f32; 4]; 3],
}
