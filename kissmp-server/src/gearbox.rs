use serde::{Deserialize, Serialize};

#[derive(Debug, PartialEq, Deserialize, Serialize)]
pub struct Gearbox {
    arcade: bool,
    lock_coef: f32,
    mode: Option<String>,
    gear_index: u8
}

impl Gearbox {
    pub fn from_bytes(data: &[u8]) -> Self{
        let decoded: Electrics = rmp_serde::decode::from_read_ref(data).unwrap();
        decoded
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
