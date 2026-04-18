# Phase 1b: Core Single-Vehicle Sync — Implementation Summary

**Status:** ✅ Complete  
**Date:** 2024  
**Author:** ForkedKISS Team

---

## Overview

Phase 1b implements the core single-vehicle synchronization pipeline: wire format, dead-reckoning prediction, and smooth state replay. This is the foundation that all future multi-body cluster sync builds upon.

**Key achievement:** Replay peers now reconstruct vehicle state from authoritative snapshots using prediction during gaps and blending on arrival — no hard teleports during normal operation.

---

## Wire Format

### VehicleUpdate Structure

The [`VehicleUpdate`](shared/src/vehicle/mod.rs#L40-58) packet now includes all fields needed for Phase 1 single-vehicle sync, with extensibility reserved for Phase 2 clusters:

```rust
pub struct VehicleUpdate {
    /// Transform state (pose + twist) for this body/vehicle
    pub transform: Transform,
    /// Electrics state (control inputs for telemetry)
    pub electrics: Electrics,
    /// Gearbox state
    pub gearbox: Gearbox,
    /// Unique vehicle ID on the server
    pub vehicle_id: u32,
    /// Component/body ID within cluster group (equals vehicle_id in Phase 1)
    /// Reserved for Phase 2 multi-body cluster support
    pub component_id: u32,
    /// Generation/tick number for ordering and deduplication
    pub generation: u64,
    /// Timestamp when this update was sent (seconds since epoch)
    pub sent_at: f64,
}
```

**Phase 1 invariant:** `component_id == vehicle_id` for all packets. This reservation allows Phase 2 to extend to multi-body clusters without breaking the wire format.

**Transform channel** carries the authoritative state:
- Position [m] — world frame
- Rotation — unit quaternion [w, x, y, z]
- Linear velocity [m/s] — world frame
- Angular velocity [rad/s] — world frame

**Electrics and Gearbox channels** are transmitted for telemetry/visualization. Control inputs are consumed locally by the authority (zero-latency) — no cross-client routing in Phase 1b.

---

## Receiver-Side Reconstruction

### Dead-Reckoning Prediction

**Module:** [`shared/src/sync/prediction.rs`](shared/src/sync/prediction.rs)

Between authoritative snapshots, peers extrapolate state using dead-reckoning:

**Position** (world-frame linear extrapolation):
```
x(t+Δt) = x(t) + v(t)·Δt
```

**Rotation** (quaternion integration with angular velocity):
```
q(t+Δt) = q(t) ⊗ exp(ω·Δt/2)
```

Where:
- `⊗` is quaternion multiplication
- `exp` for pure imaginary quaternion is: `exp((0, v)) = (cos(|v|), v/|v|·sin(|v|))`

**Implementation highlights:**
- [`PredictionState`](shared/src/sync/prediction.rs#L5-72) tracks per-body prediction state
- [`extrapolate_quaternion`](shared/src/sync/prediction.rs#L80-112) handles quaternion integration
- [`PredictionManager`](shared/src/sync/prediction.rs#L142-193) manages prediction for all vehicles/bodies
- **Unit tests:** 5 tests covering quaternion math, position extrapolation, and manager operations

### Blending on Snapshot Arrival

**Module:** [`shared/src/sync/replay.rs`](shared/src/sync/replay.rs)

When new authoritative snapshots arrive, we blend from predicted to authoritative state to avoid hard teleports:

**Blending approach:**
- Position: Linear interpolation (lerp)
- Rotation: Spherical linear interpolation (slerp) for shortest-path rotation
- Velocities: Linear interpolation for smooth transition
- Default blend duration: 150ms (tunable, responsive but smooth)

**Key insight:** Blend from _predicted_ state (where peer thought vehicle was) to _authoritative_ state (where it actually is). This minimizes visible correction.

**Implementation highlights:**
- [`BlendState`](shared/src/sync/replay.rs#L5-102) manages smooth interpolation
- [`ReplayEngine`](shared/src/sync/replay.rs#L191-281) combines prediction + blending per body
- [`ReplayManager`](shared/src/sync/replay.rs#L283-338) manages replay for all vehicles/bodies
- [`slerp_quaternion`](shared/src/sync/replay.rs#L143-184) handles quaternion slerp with shortest-path and degenerate case handling
- **Unit tests:** 5 tests covering slerp, blending, and multi-body replay

### Mathematical Foundation

Prediction uses **world-frame** for position (smoothest dynamics for rigid body) and applies angular velocity in the standard quaternion integration formula. This matches the single rigid body dynamics model from [`ClusterSyncFoundation.md`](ClusterSyncFoundation.md).

---

## API Usage

### Prediction (Peer-Side Reconstruction)

```rust
use shared::sync::{PredictionManager, extrapolate_transform};

let mut prediction = PredictionManager::new();

// When authoritative snapshot arrives
prediction.update(vehicle_id, &transform, timestamp, generation);

// Between snapshots, get predicted state
let predicted = prediction.get_predicted(vehicle_id, current_time);
```

### Replay (Full Reconstruction Engine)

```rust
use shared::sync::ReplayManager;

let mut replay = ReplayManager::with_defaults(); // 150ms blend

// When snapshot arrives
replay.apply_snapshot(vehicle_id, &transform, timestamp, generation, current_time);

// Get applied transform (includes active blend)
let applied = replay.get_applied(vehicle_id, current_time);
```

### Multi-Body Support (Phase 2 Ready)

The same APIs work for cluster groups — just call with different `component_id` values:

```rust
// Truck + trailer cluster group
replay.apply_snapshot(truck_id, &truck_transform, timestamp, gen, now);
replay.apply_snapshot(trailer_id, &trailer_transform, timestamp, gen, now);

// Both bodies updated atomically on receive
let all_ready = replay.all_initialized(&[truck_id, trailer_id]);
```

---

## Test Coverage

**Total:** 20 unit tests in `shared` crate (10 from Phase 1a measurement, 10 from Phase 1b sync)

### Phase 1b Test Breakdown

**Prediction module** (5 tests):
- `test_quaternion_multiply_identity` — Quaternion multiplication correctness
- `test_extrapolate_zero_angular_velocity` — No rotation when ω=0
- `test_extrapolate_constant_rotation` — Quaternion integration accuracy
- `test_prediction_position_extrapolation` — Linear position extrapolation
- `test_prediction_manager_update_and_get` — Manager operations

**Replay module** (5 tests):
- `test_slerp_identity` — Slerp with identical quaternions
- `test_slerp_endpoints` — Slerp at t=0 and t=1
- `test_blend_transforms_linear` — Linear position blending
- `test_replay_engine_blend` — Full replay engine blend cycle
- `test_replay_manager_multiple_bodies` — Multi-body atomic update

**All tests pass:** ✅ `cargo test -p shared` (20/20 passing)

---

## Integration Points

### Server-Side Broadcast

[`kissmp-server/src/lib.rs#L551-562`](kissmp-server/src/lib.rs#L551-562) — Server broadcasts `VehicleUpdate` packets with `component_id` field set equal to `vehicle_id`:

```rust
ServerCommand::VehicleUpdate(VehicleUpdate {
    transform: transform.clone(),
    electrics: electrics.clone(),
    gearbox: gearbox.clone(),
    vehicle_id: vehicle_id.clone(),
    component_id: vehicle_id.clone(), // Phase 1: component_id = vehicle_id
    generation: self.tick,
    sent_at: 0.0,
})
```

### Lua Bridge Integration (TODO)

The Lua side (BeamNG) needs updating to:
1. Use `ReplayManager` or equivalent logic for snapshot application
2. Implement dead-reckoning prediction between snapshots
3. Blend applied transforms (no hard teleports)

**Recommended approach:** Port `ReplayEngine` logic to Lua, or call into Rust via FFI bridge.

---

## Exit Criteria Status

From [`ClusterSyncRoadmap.md#L147-169`](ClusterSyncRoadmap.md#L147-169):

> Exit: single vehicle driven through aggressive cornering, braking, and rough terrain stays within a defined pose-divergence tolerance (target: p95 position delta < 5 cm, p95 orientation delta < 2°) across four clients.

**Status:** 🔶 Ready for validation testing

**Implemented:**
- ✅ Wire format with per-body root state (pose + twist)
- ✅ Dead-reckoning prediction during snapshot gaps
- ✅ Blend on snapshot arrival (no hard teleports)
- ✅ World-frame prediction for position and angular quantities
- ✅ Multi-body ready (component_id field reserved)
- ✅ Unit tests for prediction and blending math

**Pending validation:**
- Live testing with 4+ clients on aggressive driving scenarios
- Measurement integration using Phase 1a [`PoseDivergenceManager`](shared/src/measurement/pose_divergence.rs)
- Packet loss simulation (5-15%) to verify prediction holds
- Blend duration tuning based on real-world feedback

**Next step:** Hook up Phase 1a measurement primitives to track live divergence metrics during testing. Use `mp_measurement_stats` console command to monitor p50/p95/p99 percentiles.

---

## Known Limitations

1. **`sent_at` timestamp** — Currently hardcoded to `0.0`. Should be set to actual send time for accurate prediction extrapolation.

2. **Electrics/Gearbox telemetry** — These channels are transmitted but not used for replay in Phase 1b. Control inputs stay local to authority.

3. **Lua integration** — The Rust sync module is complete, but BeamNG-side integration (Lua) is pending. This is the critical path for live testing.

4. **Cluster group atomicity** — For multi-body groups, all bodies should be updated atomically. The `ReplayManager` supports this ([`all_initialized`](shared/src/sync/replay.rs#L403-407)), but the server broadcast code currently sends per-vehicle packets. Phase 2 will batch cluster group updates.

---

## Architecture Decisions

### Why Separate Prediction and Replay Modules?

**Prediction** (`prediction.rs`) — Pure dead-reckoning math, no blending. Used when you need to extrapolate state forward.

**Replay** (`replay.rs`) — Combines prediction + blending for smooth reconstruction. This is what peer clients use for vehicle rendering.

**Separation rationale:**
- Prediction is a lower-level primitive (used by replay, but also potentially by other systems)
- Easier to test quaternion math and extrapolation in isolation
- Replay can swap blending strategies without touching prediction logic

### Why World-Frame Prediction?

For a single rigid vehicle, world-frame dynamics are smoothest:
- Position changes linearly with velocity (constant velocity = straight line)
- Angular velocity integrates cleanly via quaternion formula

This contrasts with body-frame prediction, which would require additional transforms. World-frame is simpler and matches the single-rigid-body assumption of Phase 1.

### Why Blend from Predicted to Authoritative?

Alternative approaches:
1. **Snap to authoritative** — Causes visible teleports during latency spikes
2. **Blend from previous authoritative** — Ignores prediction, creates "rubber band" effect
3. **Blend from predicted** — ✅ Minimizes correction distance, smoothest visual result

We blend from **where peer thought vehicle was** (predicted) to **where it actually is** (authoritative). This makes corrections invisible during normal operation.

---

## Files Changed

**New files:**
- `shared/src/sync/mod.rs` — Module exports
- `shared/src/sync/prediction.rs` — Dead-reckoning prediction (298 lines)
- `shared/src/sync/replay.rs` — State replay with blending (538 lines)

**Modified files:**
- `shared/src/lib.rs` — Added `pub mod sync;` export
- `shared/src/vehicle/mod.rs` — Added `component_id` field to `VehicleUpdate`
- `kissmp-server/src/lib.rs` — Set `component_id` field in broadcast loop

**Total additions:** ~850 lines of Rust code, 10 unit tests

---

## Next Steps: Phase 1c

Phase 1c (Deformation Sync) builds on this foundation by adding:
- Damage state synchronization (broken beams, deformation)
- Visual damage state (textures, meshes)
- Consistent crash reconstruction across peers

The wire format is ready — `component_id` field supports multi-body clusters, and the replay engine handles N bodies. Phase 1c will extend the packet schema to include deformation state.

---

## References

- **Mathematical model:** [`ClusterSyncFoundation.md`](ClusterSyncFoundation.md)
- **Roadmap:** [`ClusterSyncRoadmap.md`](ClusterSyncRoadmap.md#L147-169)
- **Phase 1a (Measurement):** [`shared/src/measurement/`](shared/src/measurement/)
- **Phase 1b (This PR):** [`shared/src/sync/`](shared/src/sync/)