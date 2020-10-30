use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VehicleMeta {
    pub vehicle_id: u32,
    pub plate: Option<String>,
    pub colors_table: [[f32; 4]; 3],
}

impl VehicleMeta {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
