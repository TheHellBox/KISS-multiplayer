use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ElectricsUndefined {
    pub diff: std::collections::HashMap<String, f32>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Electrics {
    pub throttle_input: f32,
    pub brake_input: f32,
    pub clutch: f32,
    pub parkingbrake: f32,
    pub steering_input: f32,
}
