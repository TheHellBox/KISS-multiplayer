use serde::{Deserialize, Serialize};

#[derive(Debug, Copy, Clone, PartialEq, Deserialize, Serialize)]
pub struct Electrics {
    pub vehicle_id: u32,
    pub throttle_input: f32,
    pub brake_input: f32,
    pub clutch: f32,
    pub parkingbrake: f32,
    pub steering_input: f32,
    pub horn: f32,
    pub toggle_right_signal: f32,
    pub toggle_left_signal: f32,
    pub toggle_lights: f32,
}

impl Electrics {
    pub fn from_bytes(data: &[u8]) -> Self {
        let decoded: Electrics = rmp_serde::decode::from_read_ref(data).unwrap();
        decoded
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
