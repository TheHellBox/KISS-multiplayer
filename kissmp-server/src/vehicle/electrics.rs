use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ElectricsUndefined {
    pub vehicle_id: u32,
    pub diff: std::collections::HashMap<String, f32>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Electrics {
    pub vehicle_id: u32,
    pub throttle_input: f32,
    pub brake_input: f32,
    pub clutch: f32,
    pub parkingbrake: f32,
    pub steering_input: f32,
    #[serde(skip_serializing, skip_deserializing)]
    pub undefined: std::collections::HashMap<String, f32>,
}

impl Electrics {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}

impl ElectricsUndefined {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
