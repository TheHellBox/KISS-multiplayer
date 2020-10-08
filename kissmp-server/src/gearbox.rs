use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Gearbox {
    pub vehicle_id: u32,
    pub arcade: bool,
    pub lock_coef: f32,
    pub mode: Option<String>,
    pub gear_index: i8,
}

impl Gearbox {
    pub fn from_bytes(data: &[u8]) -> Self {
        let decoded: Self = rmp_serde::decode::from_read_ref(data).unwrap();
        decoded
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
