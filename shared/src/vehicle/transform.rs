use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transform {
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    pub angular_velocity: [f32; 3],
}

/// Per-cluster pose snapshot, broadcast alongside the whole-vehicle
/// Transform in VehicleUpdate. Phase 3+: one entry per cluster
/// discovered by cluster_spawn on the owner. Phase 2 vehicles send
/// an empty vec (single-cluster degenerate case uses the Transform
/// directly). All values in world frame — parent-relative
/// composition is a Phase 3b optimization deferred until world-frame
/// per-cluster is validated.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterPose {
    pub id: u32,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub linear_velocity: [f32; 3],
    /// World-frame angular velocity (NOT body-frame like Transform.angular_velocity).
    /// The cluster sender computes this from angular momentum / inertia tensor,
    /// so it's already in the world frame. Receivers use it directly for the
    /// ω × r cross product in per-node velocity matching.
    pub angular_velocity: [f32; 3],
}
