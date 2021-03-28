use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Gearbox {
    pub arcade: bool,
    pub lock_coef: f32,
    pub mode: Option<String>,
    pub gear_indices: [i8; 2],
}
