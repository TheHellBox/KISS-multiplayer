use serde::{Deserialize, Serialize};

#[derive(Debug, Copy, Clone, Deserialize, Serialize)]
pub struct Colors(pub (u32, [[f32; 4]; 3]));

impl Colors {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
