# Motion-First Vehicle Sync Overhaul

## Summary

This PR replaces the old follower replay path from `master` with a motion-first, Layer-1-centric vehicle sync model.

Compared to `master`, the new path:

- introduces a proper per-vehicle sync state module with snapshot application and optional short-horizon prediction
- moves follower correction into a dedicated vehicle-side Layer 1 controller
- expands the wire format to carry optional per-node Layer 2 data without requiring it
- adds live in-game tuning for the new controller
- hardens reset/teleport handling so large discontinuities are treated explicitly instead of being blended through

The design goal is not exact soft-body replication. The design goal is:

1. keep the visible vehicle envelope on the correct path
2. keep heading and lateral placement stable enough to avoid phantom departures/collisions
3. keep local solver fights bounded instead of trying to force exact node-level agreement

This branch started from layered cluster-sync experiments, but the implementation that survived testing is intentionally narrower:

- **Layer 1 owns normal driving**
- **Layer 2 is optional/secondary**
- **path and yaw authority stay on a very small structural control surface**

## What Changes Compared To `master`

### 1. New snapshot/state flow

`master` mostly treated incoming transforms as direct target state plus local force correction.

This PR adds a dedicated sync-state layer in [`kiss_sync.lua`](KISSMultiplayer/lua/vehicle/extensions/kiss_mp/kiss_sync.lua) that:

- stores authoritative snapshots
- supports blend state
- supports optional dead-reckoning prediction
- exposes a clean "apply snapshot / get current replay transform" contract

That gives the rest of the vehicle-side code a much clearer input:

```text
wire snapshot
    ↓
sync state / optional short prediction
    ↓
filtered Layer 1 target
    ↓
vehicle-side structural actuation
```

### 2. Wire format grows from rigid-only to rigid + optional node payload

[`shared/src/vehicle/mod.rs`](shared/src/vehicle/mod.rs) now extends `VehicleUpdate` with:

- `component_id`
- `cluster_nodes: Option<ClusterNodes>`

`ClusterNodes` carries:

- `node_positions`
- `node_velocities`

with `node_velocities` kept as an optional legacy/compatibility field so newer senders can omit it and the Rust side still deserializes correctly.

This is important for compatibility even though the current motion-first path relies mainly on Layer 1. The protocol can carry node data, but the controller is no longer built around needing it for basic driving.

### 3. Owned vehicle capture and GE forwarding are reworked

Compared to `master`, [`vehiclemanager.lua`](KISSMultiplayer/lua/ge/extensions/vehiclemanager.lua) and [`kisstransform.lua`](KISSMultiplayer/lua/ge/extensions/kisstransform.lua) now:

- capture richer transform data from owned vehicles
- pass ownership into vehicle Lua so non-owned vehicles can skip expensive per-node capture work
- include optional `cluster_nodes` in outgoing `VehicleUpdate`
- process transforms through the new sync path instead of the old simpler target application flow
- treat large jumps as teleport/reset events instead of blending them blindly

The result is less wasted capture work on remote vehicles and a cleaner separation between:

- sender-side authoritative capture
- GE-side distribution/orchestration
- vehicle-side replay logic

### 4. Layer 1 is no longer "generic force blob"

The biggest practical change from `master` is in [`kiss_vehicle.lua`](KISSMultiplayer/lua/vehicle/extensions/kiss_mp/kiss_vehicle.lua) and [`kiss_transforms.lua`](KISSMultiplayer/lua/vehicle/extensions/kiss_mp/kiss_transforms.lua).

The old broad-node actuation approach has been replaced with a structurally split controller:

- **strict frame trio** for planar path/yaw ownership
- **mirrored support pairs** for vertical and tilt support

Conceptually:

```text
Frame trio:
  x / y / yaw
  planar velocity
  yaw rate

Support pairs:
  z
  pitch / roll
  vertical velocity
  roll / pitch rates
```

This separation is the core of the approach.

The frame trio is good at defining and correcting the vehicle's global envelope.
The support pairs are good at gently supporting the body shell.
Letting support nodes own planar path turned out to reintroduce drift through compliance, so this PR keeps them out of planar authority by design.

### 5. Robust centroid handling replaces the old biased control origin

One of the major problems found during testing was that a naive observation/mass centroid can be:

- off-center laterally
- too far forward longitudinally

That gives the controller the wrong reference point and creates tuning-resistant drift and bad spawn leverage.

For wheeled vehicles, the Layer 1 control centroid is now derived from the mirrored support-pair geometry:

- `x = 0`
- `y = average support-pair center`
- `z = average support-pair height`

This makes the control origin consistent with the actual structural actuation surface instead of with a potentially biased observation set.

### 6. Support-node selection is hardened

The support-node picker is no longer allowed to naively treat outer shell/body extremes as good actuator nodes.

The current selection logic:

- builds mirrored left/right pairs
- uses a configurable shell inset in centimeters
- biases inward toward structural shell instead of bumper/fender edges

That was necessary because outer shell nodes can:

- bend before the chassis really follows
- create visible bumper/fender drag
- reintroduce drift through compliance instead of through the intended rigid envelope path

### 7. Weak-channel filtering is explicit

The follower no longer treats all rigid-body channels as equally authoritative.

The filtered target in [`kiss_transforms.lua`](KISSMultiplayer/lua/vehicle/extensions/kiss_mp/kiss_transforms.lua) is intentionally asymmetric:

- strong: `x`, `y`, `yaw`, planar velocity, yaw rate
- weak: `z`, `pitch`, `roll`, vertical velocity, roll/pitch rates

This reflects the project principles:

- path/heading must stay believable
- suspension/contact-local behavior can remain approximate
- the follower should not aggressively chase every bit of heave or local tilt

### 8. Yaw is now a first-class control path

`master` did not have a dedicated yaw/shell split.

This PR adds explicit yaw control tuning:

- yaw gain
- yaw rate gain
- yaw max `Δv`

and keeps that authority on the frame path instead of diffusing it through the support shell.

That was critical in practice: once yaw ownership became explicit and support lost planar authority, long vehicles started to behave much more naturally.

### 9. Drift handling is now explicit and switchable

This PR also adds long-horizon drift handling in [`kiss_transforms.lua`](KISSMultiplayer/lua/vehicle/extensions/kiss_mp/kiss_transforms.lua), switchable between:

- **nudge mode**
  rare small planar `setPositionNoPhysicsReset` corrections
- **integral mode**
  slow bounded planar/yaw trim during calm driving

This is not meant to replace Layer 1. It is meant to clean up the remaining slow bias that can accumulate over long drives even after the main controller is behaving well.

### 10. Rude correction is less naive

`master` used a simpler large-error correction path.

The current rude correction path has been hardened to work on the same filtered geometry the visible controller uses, with persistence, instead of snapping based only on a crude raw-distance notion of "far away".

This matters because a vehicle can look visually acceptable while a raw origin metric says otherwise, especially on long vehicles.

## How The Current Approach Works

### High-level pipeline

```text
Owner capture
  rigid state (+ optional cluster nodes)
        ↓
VehicleUpdate over network
        ↓
GE receives and forwards to vehicle Lua
        ↓
kiss_sync stores snapshot / blend state
        ↓
kiss_transforms builds filtered Layer 1 target
        ↓
kiss_vehicle applies:
  - frame trio for path + yaw
  - support pairs for z / tilt only
```

### Control-surface layout

The intent is roughly:

```text
Car

   F........F
   .        .
   o        o
   .        .
   S........S

F = frame-controlled structure for planar/yaw ownership
S = mirrored support-controlled structure for z/tilt support
o = wheels/contact-local subtree, not part of Layer 1 authority
```

For longer vehicles:

```text
Long vehicle

   F..............F
   .              .
   o              o
   .              .
   S......S.......S
```

The important point is not the exact count of nodes. It is the separation of responsibility:

- small rigid-ish frame surface owns path
- broader symmetric support surface helps the body settle
- support surface does **not** own planar drift correction

## Why This Is Better Than `master`

`master` was simpler, but it also gave us fewer places to express the right control structure.

This branch is more explicit about:

- where authority enters the follower
- which channels matter most for believable multiplayer
- which channels should stay approximate/local
- how to avoid tuning against the wrong geometric reference

The practical benefits seen during testing were:

- much more natural turning once yaw authority was isolated
- much less violent spawn/reset behavior once the centroid was fixed
- better long-vehicle path hold
- less dependence on broad shell actuation

## UI / Tuning Changes

This PR adds a dedicated Tuning tab and live push path through:

- [`kissui.lua`](KISSMultiplayer/lua/ge/extensions/kissui.lua)
- [`tuning.lua`](KISSMultiplayer/lua/ge/extensions/kissmp/ui/tabs/tuning.lua)

The new tuning surface exposes:

- Layer 1 gains/deadbands/clamps
- yaw/support split
- shell inset
- weak-channel filters
- drift mode/strength
- yaw prediction toggle

One intentional behavior change: tuning is no longer persisted across sessions in config. The sync tuning surface now comes up at code defaults each launch, which makes comparative testing cleaner.

## Out Of Scope / Non-Goals

This PR does **not** claim to solve:

- exact damage replay
- exact wheel-chain/suspension replication
- cluster splitting/merging or authority transfer for damage topology
- perfect articulated-bus hinge modeling

The current target is narrower:

- believable envelope motion
- believable heading/path
- bounded correction error
- no violent self-inflicted solver fights

## Maintainer Notes

If you review this PR from the branch history alone, you will see earlier layered node-sync experiments. The final working approach is intentionally narrower than some of that exploration.

The key idea worth judging is:

- **Layer 1 became explicit and structural**
- **Layer 2 became optional instead of foundational**

That is what made the behavior tractable.

The most important invariants of the final approach are:

1. frame trio owns planar path and yaw
2. support pairs do not own planar path
3. wheeled-vehicle centroid comes from support geometry, not raw observation mass
4. weak channels stay weak
5. long-horizon drift cleanup stays bounded and secondary

## Validation

Runtime validation was focused on the cases that `master` handled poorly:

- ordinary cars
- pickups
- long bus-like vehicles
- spawn/reset behavior
- long-distance drift

The architecture is intentionally biased toward the project principles:

- bounded error over exact replication
- contact-local behavior stays local
- stability beats forcing detail through the wrong surface
