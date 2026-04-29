use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transform {
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    pub angular_velocity: [f32; 3],
    /// Sender-derived linear acceleration in m/s^2. Optional for backward
    /// compatibility with older Lua clients; receivers fall back to
    /// `(v_new - v_prev)/dt` differencing when this is absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acceleration: Option<[f32; 3]>,
    /// Sender-derived angular acceleration in rad/s^2 (world frame, matches
    /// `angular_velocity` convention). Optional, same fallback as above.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub angular_acceleration: Option<[f32; 3]>,
}
