# CLAUDE.md

## Project Overview

KissMP — multiplayer mod for BeamNG.drive. Rust workspace with Lua client-side mod.

## Architecture

### Rust crates (workspace)
- **`shared`** — Data types, serialization structs. Used by both server and bridge. Wire format is **bincode** (positional binary, not JSON). Any struct change requires rebuilding all components.
- **`kissmp-server`** — Game server. Forwards events between clients, manages vehicle ownership, runs Lua hooks.
- **`kissmp-bridge`** — Client-side network bridge. Connects to server via QUIC, communicates with BeamNG via local HTTP.
- **`kissmp-master`** — Master server for server list.

### Lua mod (`KISSMultiplayer/`)
- **GE-side extensions** (`lua/ge/extensions/`) — Game engine scope. Access to all vehicles, world state, `be:getObjectByID()`. Key files:
  - `vehiclemanager.lua` — Vehicle spawning, ownership, coupler events, network dispatch
  - `kisstransform.lua` — Per-tick transform application. Branches coupled vs uncoupled vehicles.
  - `kissui.lua` — UI tabs and settings
  - `network.lua` — Bridge communication
- **Vehicle-side extensions** (`lua/vehicle/extensions/kiss_mp/`) — Per-vehicle scope. Access to `obj`, `v.data`, node physics. Key files:
  - `kiss_transforms.lua` — PD controller for uncoupled vehicles, drift-detection + hard snap for coupled
  - `kiss_vehicle.lua` — Node-level force application (`apply_linear_velocity`, `apply_linear_velocity_ang_torque`), transform capture
  - `kiss_electrics.lua` — Electrics sync, coupler controller management, drive modes
  - `kiss_couplers.lua` — Coupler attach/detach events, ownership gating
  - `kiss_input.lua` — Remote vehicle input application
  - `kiss_gearbox.lua` — Gearbox state sync

## Key Concepts

### Vehicle sync
- Uncoupled vehicles: PD controller with position prediction, acceleration clamping, angular force gating
- Coupled vehicles (trailers): Constraint-preserving sync. Expected trailer position computed on GE side from tow vehicle state + articulation geometry. Vehicle side only does threshold-based hard snap. Zero continuous correction between snaps.

### Coupler sync branching
- Hitch type detected once at attach time from `couplerTag` on the BeamNG node
- Three internal paths: `fifthwheel` (yaw-only scalar), `ball` (full quaternion), `pintle` (full quaternion, wider thresholds)
- Canonical tags: `fifthwheel_v2`, `fifthwheel` → fifthwheel path; `tow_hitch`, `gooseneck_hitch` → ball path; `pintle` → pintle path; unknown → ball path

### Ownership
- `vehiclemanager.ownership[local_game_id]` — true if this client owns the vehicle
- Only owners send transforms and coupler events
- Remote vehicles receive transforms and have inputs/gearbox applied

### Coupling tracking
- `vehiclemanager.coupled_to[trailer_id]` — table with `truck_id`, `node_a`, `node_b`, `hitch_type`, cached offset vectors
- Coupler events flow: vehicle Lua → `attach_coupler_inner` → network → server broadcast → `attach_coupler` on receivers

## Building

### Server/bridge (x86_64 Linux from macOS ARM)
```bash
docker run --rm --platform linux/amd64 -v "$(pwd)":/src -w /src rust:latest cargo build --release -p kissmp-server
docker run --rm --platform linux/amd64 -v "$(pwd)":/src -w /src rust:latest cargo build --release -p kissmp-bridge
```
Output: `target/release/kissmp-server`, `target/release/kissmp-bridge`

### Shared crate check
```bash
cargo check -p shared
```

### Lua mod
No build step. Pack `KISSMultiplayer/` into `KISSMultiplayer.zip` and place in BeamNG mods folder.

## Important Notes

- Wire format is bincode. All components (server + bridge + client mod) must be built from the same `shared` crate version. Struct field additions break old binaries.
- `getNodePosition()` returns local-space offset from vehicle CG, not world position.
- `setPositionNoPhysicsReset()` is the hard-snap mechanism — repositions without velocity impulse.
- `v.data.nodes` is only available on vehicle Lua side, not GE side.
- GE→vehicle communication is via `vehicle:queueLuaCommand()` (async, one-way).
- Vehicle→GE communication is via `obj:queueGameEngineLua()` (async, one-way).
- Debug flags: `kiss_transforms.debug` (visualization), `kiss_transforms.debug_log` (console logging).
