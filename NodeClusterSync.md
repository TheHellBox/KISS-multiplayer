# Multi-Cluster Pose Sync — Implementation Spec

ForkedKISS / KissMP. Replaces the current single-cluster PD/front-puller stack with a per-cluster, force-based, parent-relative sync architecture.

> **Scope note (2026-04-16).** The *inter*-vehicle parts of this spec
> are **superseded by `ContactGraphMerging.md`** — specifically §3.3
> (server-side passive coupling graph), the cross-vehicle tail of
> §4.2, and the old §6.1 coupling-event flow / §10 Phase 5 migration
> path. Those are replaced by a true contact graph with authority
> election, sim suppression on non-authority clients, and single-sim
> coupling for arbitrary multi-vehicle topologies (emergent contact,
> runtime beams, declared couplers — all unified).
>
> The *intra*-vehicle parts of this spec remain authoritative:
> §3.1–§3.2, §4.1, §4.3–§4.6 (cluster discovery, topology, frames,
> per-cluster pose computation, runtime re-cluster). Those are the
> substrate `ContactGraphMerging.md` explicitly depends on — read
> this document first, then that one.

---

## 0. Goal

Each vehicle is decomposed at spawn into one or more **rigid clusters**. The owner client broadcasts per-cluster pose + velocity. Remote clients reconstruct each cluster's target world pose and apply **velocity-matching forces** at the cluster's nodes. The remote's beam physics fills in inter-cluster soft-body shape naturally.

This eliminates the PID swamp: no integrator wind-up, no impulsive angular kicks, no fight with the solver. The remote is pose-*constrained* via spatially distributed force inputs, not pose-dictated.

---

## 1. Architectural decisions (locked)

| Decision | Choice | Notes |
|---|---|---|
| Authority granularity | Per-cluster | Tractor and trailer can have different owners |
| Remote correction primitive | Force-based velocity-matching per cluster | Generalized front-puller across all axes |
| Re-cluster triggers | Event-driven + periodic validation | `onCouplerAttached/Detached`, `onBeamBroken`, plus cheap rigidity check every N seconds |
| Cluster discovery | Semantic-seeded + stiffness-thresholded connected components | Not Louvain |
| Sync packet contents | Pose + linear vel + angular vel per cluster | Mass/inertia cached at spawn, not transmitted |
| Coordinate frame | Parent-relative via spawn-time topology graph | Root cluster = chassis with ref node, in world frame |
| Coupling event auth | Owner-authoritative publication, server passive state tracker | Server snapshots for late-joiners |
| Late-join | Per-vehicle streaming, client computes topology locally, topology_hash check, coupling graph snapshot at end | Reuses existing `VehicleSpawn` plumbing |
| Debug UI | Per-cluster ImGui overlay with colored wireframe AABBs, per-cluster on/off, per-cluster log | Surgical kill-switch granularity |

---

## 2. Module / file layout

### Lua (vehicle-side, runs in owner + remote contexts)

```
lua/vehicle/extensions/forkedkiss/
  cluster_discovery.lua    -- Spawn-time cluster identification
  cluster_topology.lua     -- Parent-child graph construction, frame conversions
  cluster_sender.lua       -- Owner: compute & emit per-cluster pose+vel
  cluster_receiver.lua     -- Remote: apply velocity-matching forces
  cluster_state.lua        -- Shared state: cluster table, topology, hashes
  rigidity_validator.lua   -- Periodic cheap check, triggers re-cluster
```

### Lua (GE/UI-side)

```
lua/ge/extensions/forkedkiss/
  cluster_debug_ui.lua     -- ImGui overlay, wireframe AABBs, per-cluster controls
  cluster_logger.lua       -- Per-cluster trace log
```

### Rust (server)

```
src/server/
  coupling_graph.rs        -- Passive HashMap<VehiclePair, CouplingEdge>
  cluster_handshake.rs     -- Late-join snapshot assembly
  // existing message handlers extended, no new validation logic
```

---

## 3. Data structures

### 3.1 Cluster definition (Lua, per vehicle, computed at spawn)

```lua
-- cluster_state.lua
clusters = {
  [1] = {
    id = 1,
    nodes = {12, 13, 14, ...},          -- node CIDs
    centroid_local = vec3(...),         -- mass-weighted centroid in vehicle ref frame
    node_offsets_local = {              -- per-node offset from centroid in cluster frame
      [12] = vec3(...), ...
    },
    total_mass = 1234.5,                -- kg
    inertia_local = mat3(...),          -- principal-axis tensor, computed once
    is_root = true,                     -- contains ref node
    parent_id = nil,                    -- nil for root, else parent cluster id
    parent_link = {                     -- nil for root, else how we hang off parent
      type = "coupler" | "hydro" | "slidenode",
      anchor_node_local = 87,           -- node on this cluster
      anchor_node_parent = 142,         -- node on parent cluster
    },
    enabled = true,                     -- per-cluster kill-switch
  },
  ...
}

topology_hash = "sha256:abc123..."      -- see §4.4
```

### 3.2 Sync packet (per vehicle, every tick or every N ticks)

```rust
// Rust side, bincode
struct VehicleClusterUpdate {
    vehicle_id: u32,
    seq: u32,                           // monotonic per vehicle
    timestamp_ms: u64,                  // owner's send time
    clusters: Vec<ClusterPose>,         // ordered: parents before children (BFS)
}

struct ClusterPose {
    cluster_id: u8,
    // Pose in PARENT frame (world frame if root)
    pos: [f32; 3],
    rot: [f32; 4],                      // quaternion, normalized
    lin_vel: [f32; 3],                  // m/s in parent frame
    ang_vel: [f32; 3],                  // rad/s in parent frame
}
```

Packet size: ~52 bytes per cluster + small header. A 3-cluster rig (tractor + trailer + dolly) is ~170 B/tick. At 30 Hz that's ~5 kbit/s/vehicle — fine.

### 3.3 Coupling graph (server-side, Rust)

> **Superseded by `ContactGraphMerging.md`.** The passive coupling
> graph described below is replaced by an active contact graph with
> authority election. Retained here for historical context only; do
> not implement this section. The new design handles declared
> couplers, emergent contact, and runtime beams uniformly via a
> single `ContactGraph` with `EdgeSource::DeclaredCoupler` as one of
> three edge source variants. See §2–§7 of the new spec.

```rust
struct CouplingEdge {
    parent_vehicle: u32,
    parent_cluster: u8,
    parent_node: u16,
    child_vehicle: u32,
    child_cluster: u8,
    child_node: u16,
    coupler_type: CouplerType,          // FifthWheel, Ball, Pintle, etc
    established_at: SystemTime,
}

struct CouplingGraph {
    edges: HashMap<(u32, u32), CouplingEdge>,  // keyed by (parent_vid, child_vid)
}
```

### 3.4 Topology hash

Stable across runs given identical JBeam:

```lua
function compute_topology_hash(clusters)
  local parts = {}
  for _, c in ipairs(clusters) do
    local sorted_nodes = sort_copy(c.nodes)
    table.insert(parts, string.format("%d:%s:%d",
      c.id,
      table.concat(sorted_nodes, ","),
      c.parent_id or -1))
  end
  return sha256(table.concat(parts, "|"))
end
```

Sent with `VehicleSpawn`. Joiner recomputes locally and compares. Mismatch → fall back to single-cluster sync for that vehicle, log warning.

---

## 4. Algorithms

### 4.1 Cluster discovery (owner side, runs once at spawn)

Per the algorithm in the questionnaire — keeping it in spec form:

```
Inputs:  v.data.nodes, v.data.beams, v.data.couplers,
         v.data.hydros, v.data.slidenodes
Const:   STIFFNESS_THRESHOLD (default 500_000, tunable)
         MIN_CLUSTER_SIZE (default 8)

1. boundary_nodes := union of all nodes referenced by
   couplers, hydros, slidenodes
2. adj := {}
   for each beam in v.data.beams:
     spring := beam.beamSpring or beam.spring or 0
     if spring >= STIFFNESS_THRESHOLD
        and beam.id1 not in boundary_nodes
        and beam.id2 not in boundary_nodes:
       add undirected edge (id1, id2) to adj
3. components := connected_components(adj)
4. clusters := [c for c in components if len(c) >= MIN_CLUSTER_SIZE]
5. assert ref_node in some cluster c_root
   if not: fallback = whole vehicle as one cluster
6. for each cluster c:
     compute total_mass, mass-weighted centroid_local
     compute node_offsets_local for each node
     compute inertia_local (principal-axis tensor)
```

**Edge cases that need explicit handling:**

- Boundary nodes themselves are never in any cluster. They're "floating" — synced by inter-cluster soft-body physics, not by direct force application. This is correct: the coupler/hydro nodes *should* be free to move because that's where articulation happens.
- A vehicle with no cluster ≥ MIN_CLUSTER_SIZE → fall back to whole-vehicle single cluster (legacy mode).
- Stiffness units in JBeam vary (some mods use unusual scales). Make `STIFFNESS_THRESHOLD` overridable per-vehicle via a JBeam custom field `kissmp:cluster_stiffness_threshold`.

### 4.2 Topology graph construction (owner side, post-clustering)

```
Inputs: clusters[], v.data.couplers, v.data.hydros, v.data.slidenodes

1. For each semantic boundary element (coupler, hydro, slidenode):
     find cluster_a containing one endpoint via beam-graph BFS
     find cluster_b containing the other endpoint
     if cluster_a != cluster_b:
       add candidate parent-child edge (a, b, link_info)

2. Root cluster = cluster containing the ref node
3. BFS from root over candidate edges to assign parent_id direction
   (parent = closer to root in BFS tree)
4. If a cluster has no path to root (only possible for disconnected
   sub-bodies, e.g. detached cargo) → it becomes its own root in
   world frame. Log this as a warning.

5. Cache parent_link details for each non-root cluster:
   anchor_node_local, anchor_node_parent, type
```

**Important:** runtime coupling between two separate vehicles produces a *cross-vehicle* topology edge that lives in the **server's** coupling graph (§3.3), not the per-vehicle Lua topology. The Lua topology is intra-vehicle only. Cross-vehicle parent linkage is resolved at the receiver by joining: `child_vehicle.local_pose × parent_vehicle.world_pose_at_anchor`.

> **Superseded.** Cross-vehicle linkage via receiver-side pose
> composition is replaced by single-sim coupling: the authority
> client of a multi-vehicle component simulates all its members
> together, and the cross-vehicle contact is just a beam / coupler
> constraint in that authority's local sim. No receiver-side
> composition of independently-simulated poses. See
> `ContactGraphMerging.md` §2 and §9 (sim suppression). Intra-vehicle
> parent-relative composition (sender converts child pose to parent
> frame, receiver reconstructs world pose) remains valid — that's a
> within-authority-sim detail.

### 4.3 Owner-side per-tick send (cluster_sender.lua)

Runs in `onUpdate` (or `updateGFX` — whichever matches existing KissMP cadence):

```
for each cluster c:
  // Compute world pose of cluster from current node positions
  centroid_world := mass_weighted_average(c.nodes)
  R_world := best_fit_rotation(c.nodes, c.node_offsets_local)
    // Use Kabsch / Horn quaternion method, weighted by node mass

  // Compute cluster linear & angular velocity
  lin_vel_world := mass_weighted_average(node_velocities)
  ang_vel_world := least_squares_angular_velocity(
                     c.nodes, node_velocities, centroid_world)

  // Convert to parent frame if non-root
  if c.parent_id:
    parent_pose := pose_of(clusters[c.parent_id])  // already computed this tick
    pos_to_send := inverse(parent_pose) * centroid_world
    rot_to_send := inverse(parent_pose.rot) * R_world
    lin_vel_to_send := inverse(parent_pose.rot) * (lin_vel_world - parent.lin_vel)
                       - cross(parent.ang_vel, pos_to_send)
    ang_vel_to_send := inverse(parent_pose.rot) * (ang_vel_world - parent.ang_vel)
  else:
    pos_to_send, rot_to_send := centroid_world, R_world
    lin_vel_to_send, ang_vel_to_send := lin_vel_world, ang_vel_world

  enqueue ClusterPose{...}

emit VehicleClusterUpdate (clusters ordered parent-before-child)
```

**Order matters:** parent must be computed before child within the same tick because child's parent-frame conversion depends on parent's computed world pose.

### 4.4 Remote-side per-tick force application (cluster_receiver.lua)

```
on receive VehicleClusterUpdate:
  // Reconstruct world poses, parent-first
  for cluster_pose in update.clusters (BFS order):
    c := local_clusters[cluster_pose.cluster_id]
    if c.parent_id:
      parent_world := world_pose[c.parent_id]
      target_pose_world := parent_world * cluster_pose.pose
      target_lin_vel_world := parent_world.rot * cluster_pose.lin_vel
                              + parent.lin_vel
                              + cross(parent.ang_vel,
                                      parent_world.rot * cluster_pose.pos)
      target_ang_vel_world := parent_world.rot * cluster_pose.ang_vel
                              + parent.ang_vel
    else:
      target_pose_world := cluster_pose.pose
      target_lin_vel_world := cluster_pose.lin_vel
      target_ang_vel_world := cluster_pose.ang_vel

    world_pose[c.id] := target_pose_world

  // Apply forces (each cluster independent, root or not)
  for c in local_clusters where c.enabled:
    target_centroid_world := world_pose[c.id].pos
    target_R_world         := world_pose[c.id].rot

    for node_id in c.nodes:
      // Where this node SHOULD be in world space
      offset_local := c.node_offsets_local[node_id]
      target_node_pos := target_centroid_world + target_R_world * offset_local

      // What velocity it SHOULD have to reach there (rigid-body extrapolation)
      target_node_vel := target_lin_vel_world
                        + cross(target_ang_vel_world,
                                target_R_world * offset_local)

      // Velocity-matching force (this is the front-puller, generalized)
      current_vel := obj:getNodeVelocityVector(node_id)
      mass := obj:getNodeMass(node_id)
      force := (target_node_vel - current_vel) * mass * physicsFPS

      // Optional position-error correction term (PD-light)
      current_pos := obj:getNodePosition(node_id)
      pos_error := target_node_pos - current_pos
      force = force + pos_error * KP_POS * mass

      obj:applyForceVector(node_id, force)
```

**Key properties:**

- No `applyClusterLinearAngularAccel` or `apply_linear_velocity_ang_torque`. Pure `applyForceVector` per node. Force is always bounded by mass × (vel error × physicsFPS) which is the maximum physically meaningful kick to close one tick of velocity error.
- Boundary nodes (couplers, hydro endpoints) get **no force applied** because they're not in any cluster. They're free to settle via beam dynamics. This is what enables the trailer hitch to behave correctly.
- `KP_POS` is a small position-error spring to prevent slow drift. Start with a value that contributes ~10% of the velocity-matching force at typical errors. Tune empirically; if you find yourself raising it to fight oscillation, the bug is elsewhere.

### 4.5 Best-fit rotation (Kabsch / Horn)

For each cluster, given current node world positions and reference offsets, find the rotation that minimizes squared error. Standard algorithm — quaternion-based Horn method is numerically stable and ~50 ops for typical cluster sizes. Implement once in `cluster_state.lua` as `compute_cluster_pose(cluster, node_positions, node_velocities) -> (centroid, quat, lin_vel, ang_vel)`.

### 4.6 Periodic rigidity validation (rigidity_validator.lua)

Every `RIGIDITY_CHECK_INTERVAL_S` (default: 10 s):

```
for each cluster c:
  // Cheap: just compute current centroid and per-node offset error
  centroid_now := mass_weighted_average(c.nodes)
  R_now := best_fit_rotation(c.nodes, c.node_offsets_local)
  total_sq_error := 0
  for node_id in c.nodes:
    expected := centroid_now + R_now * c.node_offsets_local[node_id]
    actual := obj:getNodePosition(node_id)
    total_sq_error += (actual - expected):squaredLength()
  rms_error := sqrt(total_sq_error / #c.nodes)

  if rms_error > RIGIDITY_REVALIDATION_THRESHOLD_M (default 0.05):
    schedule_recluster(reason="rigidity_drift", cluster_id=c.id)
```

Re-cluster also on `onCouplerAttached`, `onCouplerDetached`, `onBeamBroken` (with debounce — beam break events fire in storms during crashes; coalesce to one re-cluster after a 1 s quiet window).

---

## 5. Network protocol changes

### 5.1 New / modified messages

```
VehicleSpawn (modified)
  + topology_hash: String

VehicleClusterUpdate (new, replaces or complements existing VehicleUpdate)
  vehicle_id, seq, timestamp_ms, clusters: Vec<ClusterPose>

CouplingEvent (probably already exists for KissMP, extend if needed)
  parent_vid, parent_cluster, parent_node,
  child_vid,  child_cluster,  child_node,
  coupler_type, attached: bool

CouplingGraphSnapshot (new, sent once per joiner)
  edges: Vec<CouplingEdge>
```

### 5.2 Late-join handshake sequence

```
Server → Joiner:

  for each existing vehicle (priority order):
    1. VehicleSpawn { ..., topology_hash }
    2. Most recent VehicleClusterUpdate for that vehicle

  3. CouplingGraphSnapshot { all current edges }

  4. (begin normal live streaming)

Joiner actions:
  - VehicleSpawn: spawn vehicle locally; cluster_discovery runs in
    onSpawn; compute local topology_hash; compare to server's.
    Mismatch → mark vehicle as "single-cluster fallback", log warning.
  - VehicleClusterUpdate: apply via cluster_receiver
  - CouplingGraphSnapshot: populate local coupling graph
  - Coupling events arriving for not-yet-spawned vehicles → queue via
    existing pending_coupler_attaches mechanism
```

### 5.3 Server-side state tracking (Rust)

```rust
// In existing message handler for CouplingEvent
match event.attached {
    true  => coupling_graph.edges.insert(key, edge),
    false => coupling_graph.edges.remove(&key),
};
// No validation, no rejection. Server is a passive recorder.

// New handler for joiner connect
fn on_client_join(client: &Client) {
    for vehicle in vehicles.values() {
        client.send(VehicleSpawn { ..., topology_hash: vehicle.topology_hash.clone() });
        if let Some(last) = vehicle.last_cluster_update.as_ref() {
            client.send(last.clone());
        }
    }
    client.send(CouplingGraphSnapshot {
        edges: coupling_graph.edges.values().cloned().collect()
    });
}
```

---

## 6. State machines

### 6.1 Coupling event flow

```
Owner of vehicle A detects onCouplerAttached(node_a, vehicle_b, node_b)
  ↓
Owner emits CouplingEvent { attached: true, ... }
  ↓
Server: insert into coupling_graph; relay event to all clients
  ↓
All clients (incl. owner of B):
  - update local cross-vehicle coupling state
  - mark affected clusters as "needs re-cluster on next opportunity"
    (couplers were boundary nodes; now they're connected — re-discovery
    may merge clusters or reroute parent links)
  - the actual re-cluster happens on next physics-quiet window or after
    debounce timer
```

### 6.2 Ownership transfer

Ownership transfer touches **only** the per-cluster authority field. It does not modify:
- cluster definitions
- topology graph
- coupling graph
- topology_hash

Old owner stops sending `VehicleClusterUpdate` for the transferred vehicle/cluster. New owner starts sending. Remotes don't notice the transition beyond the source IP changing on incoming packets.

### 6.3 Re-cluster execution

```
schedule_recluster(reason, cluster_id?):
  set pending_recluster = true, capture reason
  start/extend debounce timer (1s default)

on debounce expiry:
  run cluster_discovery from scratch
  run topology graph construction
  recompute topology_hash
  if topology_hash changed:
    emit VehicleSpawnUpdate (or equivalent) with new hash
    server stores new hash; relays to all clients
    each client recomputes its local topology to match
  log re-cluster event (reason, old_count → new_count, hash diff)
```

---

## 7. Debug instrumentation

### 7.1 ImGui overlay (cluster_debug_ui.lua)

Per-cluster wireframe AABB rendered in world space:

- **Color per cluster** — deterministic from cluster_id (HSV hue = cluster_id × 137° golden-angle, full saturation/value).
- **AABB computed** from cluster's current node positions (cheap).
- **Label** at AABB centroid: `"V{vid} C{cid} [parent: V{}C{}] mass:{}kg nodes:{} err_rms:{}m"`.
- **Force vectors** (toggleable): per-node arrow showing current applied force direction & magnitude.
- **Parent-child link lines**: thin line from child centroid to parent anchor node.

### 7.2 Per-cluster controls

ImGui window `[KissMP] Cluster Sync`:

```
Vehicle: [dropdown of synced vehicles]
  └─ Cluster 0 (root, 247 nodes, 1832 kg)
       [✓] enabled    [✓] log    [show forces]   err_rms: 0.012 m
  └─ Cluster 1 (child of 0 via fifthWheel, 89 nodes, 4210 kg)
       [✓] enabled    [ ] log    [show forces]   err_rms: 0.034 m
  └─ Cluster 2 (child of 1 via ball, 56 nodes, 980 kg)
       [✓] enabled    [✓] log    [show forces]   err_rms: 0.071 m

[Global controls]
  [✓] Multi-cluster sync enabled (master switch)
  [ ] Force single-cluster fallback (legacy PID path)
  [Re-cluster all]   [Dump topology graph to log]
```

### 7.3 Per-cluster logging (cluster_logger.lua)

When a cluster's `log` flag is set, append per-tick CSV row:

```
ts_ms, vid, cid, target_pos_x/y/z, current_pos_x/y/z,
target_quat_xyzw, current_quat_xyzw, target_lin_vel, current_lin_vel,
target_ang_vel, current_ang_vel, total_force_applied_n, err_rms_m
```

Output to `BeamNG/userdata/forkedkiss_logs/v{vid}_c{cid}_{session}.csv`. Rotate on session end. Trivial to load into pandas/Polars for offline analysis of divergence events.

---

## 8. Tuning constants (one place)

```lua
-- cluster_state.lua: defaults, all overridable via config
M.const = {
  STIFFNESS_THRESHOLD = 500000,           -- N/m, cluster discovery
  MIN_CLUSTER_SIZE = 8,                   -- nodes
  KP_POS = 50.0,                          -- position-error spring (1/s²)
  RIGIDITY_CHECK_INTERVAL_S = 10.0,       -- periodic validator
  RIGIDITY_REVALIDATION_THRESHOLD_M = 0.05,
  RECLUSTER_DEBOUNCE_S = 1.0,             -- coalesce beam-break storms
  SEND_RATE_HZ = 30,                      -- per-vehicle update rate
  MAX_FORCE_PER_NODE_N = 50000,           -- safety clamp; if hit, log
}
```

`MAX_FORCE_PER_NODE_N` is a paranoia clamp — under normal operation it should never be hit. If it fires, something is very wrong (huge timestep drift, bad parent pose, wild target). Log every clamp event with full context.

---

## 9. Test plan / validation milestones

In rough dependency order:

1. **Cluster discovery determinism.** Spawn each of: D-Series, T-Series, ETK 800, Gavril H-Series, Bell 407 helicopter mod. Dump cluster table to log. Re-spawn 5×, verify identical clusters every time. Verify topology_hash stable.

2. **Single-vehicle, single-cluster sync (degenerate case).** Vehicle that produces one cluster (e.g. small car). Should behave identical to legacy single-cluster sync. Round-trip test: drive owner, observe remote.

3. **Single-vehicle, multi-cluster sync.** A vehicle whose JBeam has a cab/chassis/box decomposition. Verify remote tracking under straight-line drive, hard cornering, jumps. Compare error_rms to single-cluster baseline.

4. **Tractor + trailer, same owner.** Hitch tractor to trailer in single-player, then test in MP. Verify trailer cluster is in tractor frame, remote follows correctly through articulation. **This is the case the current PID setup struggles with** — should be the largest single quality gain.

5. **Tractor + trailer, different owners.** Each player owns one vehicle. Couple them. Verify cross-vehicle coupling graph populates server-side, remote clients reconstruct correctly.

6. **Runtime couple/uncouple.** During driving, attach and detach couplers. Verify topology_hash changes propagate, no visible glitch beyond a single-frame correction.

7. **Damage / beam break.** Crash a vehicle. Verify re-cluster fires after debounce, new topology_hash propagated, no oscillation or runaway forces.

8. **Late-join consistency.** Player joins mid-session with already-coupled rigs. Verify all cluster definitions, current poses, and coupling graph land correctly. Topology_hash mismatch path also needs explicit testing — temporarily corrupt the hash to verify fallback works.

9. **Network jitter robustness.** Use `tc` to add 100 ms latency + 50 ms jitter + 1% loss on the KissMP server's interface. Verify cluster sync degrades gracefully (some lag, no whip, no divergence).

10. **Bell 407 helicopter (your existing test case).** Should be a single-cluster vehicle in practice (rigid airframe), main rotor possibly its own cluster if hub stiffness is below threshold. Verify hover sync.

---

## 10. Migration from current PID code

Don't delete the PID/front-puller code yet. Instead:

1. **Add the multi-cluster path behind the master kill-switch** (default: off). Existing PID code path remains primary.
2. **Implement & validate cluster discovery + debug overlay first** with sync still using PID. This proves the partition is sane before you trust it for force application.
3. **Enable multi-cluster sync per-vehicle** via the ImGui controls. Drive both paths side-by-side in the same session (different vehicles using different paths).
4. **Once all milestones in §9 pass**, flip the global default to multi-cluster, keep PID as the fallback for `topology_hash` mismatches and explicit override.
5. **After 2-4 weeks of stable production**, delete the PID code path. Front-puller specifically can be removed at this point — its job is now done by the per-cluster velocity-matching forces.

---

## 11. Known unknowns / open detail

- **Jackknife bounding.** With per-cluster force application and parent-relative frames, jackknife should self-resolve through normal beam dynamics at the coupler. But if the trailer's owner sends a pose implying a 90°+ relative angle that's physically impossible at the current coupler state, the remote will inject huge forces trying to achieve it. Consider clamping `cluster_pose.rot` relative to parent based on coupler geometry (e.g., fifth wheel allows ±90° yaw, ±20° pitch/roll). Ship without the clamp; add only if observed in testing.
- **Stiffness threshold per vehicle class.** 500_000 N/m is a guess. Some mods use very different scales. Plan to expose per-vehicle override and gather data from milestones 1-3 before locking a default.
- **Send rate adaptive vs fixed.** Spec says fixed 30 Hz. Adaptive (send only when error grows or on regular keyframes) is a future bandwidth optimization, not a v1 concern.
- **Cluster ID stability across re-cluster.** Currently re-cluster invalidates cluster IDs (assigned by enumeration order). Not a problem for sync (everyone recomputes from new hash), but per-cluster ImGui toggles will reset. If that's annoying, hash cluster identity by `sorted(node_ids)` instead of enumeration index.
- **Boundary node "between clusters" sync.** Boundary nodes get no direct force. They rely on beam dynamics from both sides. If the two clusters' poses are both correct, the boundary settles correctly. If one cluster is laggy/wrong, the boundary tugs. This is acceptable — it's the natural soft-body behavior. Just don't add a special case "force boundary nodes too" — that re-introduces the original whip problem.

---

## 12. Quick reference — what changed vs. legacy

| Concern | Legacy (PID + front-puller) | This spec |
|---|---|---|
| Granularity | Whole vehicle as one entity | Per-cluster |
| Correction | PID on ref node + lateral force at front cluster | Velocity-matching force per node, per cluster |
| Angular | `apply_linear_velocity_ang_torque` (impulsive) | Emerges from per-cluster pose constraint |
| Coupled rigs | Trailer follows tractor via beam tension | Trailer is its own cluster, possibly own owner |
| Frame | World | Parent-relative for non-root clusters |
| Topology awareness | None | Spawn-time graph from JBeam semantics |
| Network state | Per-vehicle pose+vel | Per-cluster pose+vel ordered parent-first |
| Server role | Pure relay | Relay + passive coupling state tracker 
| Failure mode | Whip, oscillation, drift under articulation | Soft degradation; falls back to single-cluster on hash mismatch |
