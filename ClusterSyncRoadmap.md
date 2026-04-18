# KISS Multiplayer Sync Roadmap

This document lays out the plan for multiplayer vehicle synchronization in the KISS multiplayer mod for BeamNG. The work proceeds in stages, adding one new dimension of complexity at a time.

Each phase introduces exactly one new axis of difficulty. A phase is done when its acceptance criteria are met under measurement — not when it "feels okay." Later phases depend on infrastructure built in earlier ones and should not begin until their predecessor is closed out.

---

## Implementation Notes

### Interleaved implementation order with debugger toolchain

Complete ClusterSync Phase 1 (single-vehicle sync with measurement primitives) first. Then build the debugger toolchain (HotReloadingDebuggerRoadmap Phases 0-7). Then tackle ClusterSync Phases 2-4 (multi-cluster, authority election, props) with the debugger available. Debugging complex cluster sync without visualization and recording tools is painful — don't skip the debugger.

---

## Roadmap

- [ ] **Phase 0** — Audit and baseline (done; see audit document)

- [ ] **Phase 1** — Single-vehicle sync, including rear-steered articulated bus
  - [ ] **1a. Measurement and characterization (bootstrap primitives)**
    - [ ] Pose divergence ring buffer API (in-memory, ~30 s at 60 Hz, queryable)
    - [ ] CSV dump on demand via console command or hotkey
    - [ ] Divergence stats computation (p50/p95/p99 position and orientation delta, queryable)
    - [ ] Hinge-angle scalar sampling (relative angle across bus hinge, logged to ring buffer)
    - [ ] Network loss injection via external app (not built here)
    - [ ] No console spam — everything opt-in via explicit dump or tuning UI query
    - [ ] *Note: UI visualization, test scenario integration, and recording are part of the debugger toolchain (see `HotReloadingDebuggerRoadmap.md`). Phase 1a provides the data layer those tools consume.*
    - [ ] Exit: tooling produces sensible numbers on trivial scenario (one vehicle, straight drive)
    - [ ] Exit: ring dump loads cleanly in whatever plotting tool is being used
  - [ ] **1b. Core single-vehicle sync**
    - [ ] Wire format with `component_id` field (reserved for phase 2 extension)
    - [ ] Transform channel (position, rotation, linear velocity, angular velocity)
    - [ ] Electrics channel (throttle, brake, steering, clutch, parking brake)
    - [ ] Gearbox channel
    - [ ] Electrics-undefined channel for sparse diffs (lights, drive modes, actuator states)
    - [ ] Control input pipeline (local consumption by authority, zero-latency)
    - [ ] Receiver-side dead-reckoning prediction during gaps between snapshots
    - [ ] Receiver-side blend on snapshot arrival (no hard teleports)
    - [ ] Prediction in smoothest coordinate system (world-frame position, body-frame angular)
    - [ ] Exit: p95 position delta < 5 cm, p95 orientation delta < 2° across four clients
  - [ ] **1c. Deformation sync**
    - [ ] Node-position-based deformation (authority samples, receivers apply deltas)
    - [ ] Quantize positions in local body frame (8–10 bits per axis, determined empirically)
    - [ ] Delta encoding against rest state — only dirty nodes on the wire
    - [ ] Priority accumulator (nodes near hinge, collision impulses get bandwidth priority)
    - [ ] Single unified scheme for all deformation (no hinge-specific hacks)
    - [ ] Hinge-angle scalar as acceptance measurement for bus articulation
    - [ ] Exit: hinge-angle delta p95 < 0.5° at close range, < 2° at distance
    - [ ] *Out of scope for 1c:* damage model, broken-beam list, visual deformation templates, region-level LOD
  - [ ] **1d. Hardening and tuning defaults**
    - [ ] Sweep tunables via tuning UI (extrapolation clamps, blend gains, deformation priority weights, quantization bit depths)
    - [ ] Lock in defaults per vehicle class (bus vs car vs heli), document rationale, commit presets
    - [ ] Reconnection correctness (mid-session join sees current pose and deformation, not reset)
    - [ ] Stress-scenario pass: curb hop, high-speed cornering, low-speed scraping contact, controlled crash
    - [ ] Network degradation testing via external loss-injection app
    - [ ] Exit: four-player server, measurements confirm tolerances hold under 5–15% simulated packet loss

- [ ] **Phase 2** — Same-owner trailers (declared coupler, single authority, no election)
  - [ ] Wire format extension: broadcast carries root 6-DOF + joint DOFs for all cluster members
  - [ ] `component_id` field now distinguishes clusters (reserved in 1b, activated here)
  - [ ] Forward kinematic evaluator: pure function `(root_pose, joint_θs, topology) → body_poses[]`
  - [ ] Unit tests for forward kinematic evaluator (without networking)
  - [ ] Joint state extraction: read θ_i and θ̇_i from BeamNG vehicle Lua API every tick
  - [ ] One extractor per coupler type (fifth wheel, ball hitch)
  - [ ] Coupling handshake: `onCouplerAttached`/`onCouplerDetached` triggers topology-change broadcast
  - [ ] Atomic wire format switch at commit tick across all clients
  - [ ] Replay path: non-authority receivers apply forward evaluator using wire-received joint DOFs
  - [ ] No local "snap to hitch" correction (no independent trailer pose to correct against)
  - [ ] **Open questions to resolve:**
    - [ ] Does coupler API expose clean per-joint DOF access, or must joint state be reverse-engineered from node positions?
    - [ ] Does L-key ball-hitch coupling issue reproduce on ForkedKISS? If so, root cause in coupling detection, handshake, or joint-state extraction?
  - [ ] Exit: no pose snaps at hitch/unhitch, no drift during driving, no jackknife-correction artifacts
  - [ ] Exit: pose divergence stays within phase 1 tolerances for both truck and trailer

- [ ] **Phase 3** — Cross-owner trailers (authority election, epoch system, handover)
  - [ ] Server-side contact graph: server maintains canonical coupling edges, clients hold mirrored views
  - [ ] Authority election rule: continuity-preserving (larger component wins), vehicle-ID tiebreaker
  - [ ] Election runs on server; clients do not self-promote
  - [ ] Epoch system: server-issued epoch in every cluster state packet
  - [ ] Receiver-side epoch enforcement: drop stale-epoch packets
  - [ ] Epoch bumps on every authority change
  - [ ] Handover protocol: two-phase commit (pre-handoff state from outgoing → incoming authority)
  - [ ] Timeout fallback if pre-handoff fails to deliver
  - [ ] Sim suppression: non-authority owner must not advance physics for vehicles whose cluster is elsewhere
  - [ ] Locate sim-tick path and gate it on authority status
  - [ ] Ranked candidates: election produces ordered candidate list for fallback without restarting election
  - [ ] Disconnect handling: re-election when authority leaves, using ranked candidate list
  - [ ] **Failure modes covered:**
    - [ ] Stale authority keeps broadcasting after handover → receivers drop by epoch
    - [ ] New authority starts early → receivers drop by epoch (haven't seen epoch bump yet)
    - [ ] Different clients receive handover at different ticks → each internally consistent, no double-authority corruption
  - [ ] Known tradeoff: authority-disconnect accepts visible glitch (new authority starts from own replay state)
  - [ ] Exit: hitch, drive, unhitch sequence matches phase 2 behavior
  - [ ] Exit: trailer owner disconnect → truck continues, trailer stays or detaches cleanly based on authority
  - [ ] Exit: truck owner disconnect → authority migrates to trailer owner, cluster continues or dissolves
  - [ ] Exit: artificially delayed client confirms stale packets are dropped, not applied

- [ ] **Phase 4** — Server-spawned props and non-vehicle entities
  - [ ] Script identity: the spawning script becomes the authority
  - [ ] Hide name tags: script identity should not be visible to players
  - [ ] Spawn/despawn lifecycle sync
  - [ ] Damage/break state for props (intact → broken → removed)

Beyond phase 4 — N-vehicle clusters, emergent contact, runtime beams, input UX, wild cases — is tracked separately in the dynamic-merging spec.

---

## Phase 1 — Single-vehicle sync

One vehicle, one owner, one authority. No coupling, no clusters. Receivers reconstruct the vehicle's state from what the authority broadcasts.

Scope includes the rear-steered articulated bus. Because the bus is a single-JBeam with a soft-body hinge, its articulation angle is an emergent property of deformation and cannot be reconstructed from pose data alone. Deformation sync is therefore in phase 1.

### 1a — Measurement and characterization

Build the measurement tooling before touching sync code. Every subsequent phase depends on being able to answer "is this worse than before?" with numbers.

| Tool | Purpose | Output |
|---|---|---|
| Pose divergence ring buffer | In-memory per-vehicle log of position/orientation delta between authoritative and reconstructed pose | ~30 s at 60 Hz, dumped to CSV on demand via console command or hotkey |
| Live divergence stats | p50/p95/p99 position and orientation delta over the ring window | Displayed in the tuning UI |
| Hinge-angle scalar | Relative angle between selected node pairs straddling the bus hinge, sampled on both authority and receivers | Logged into the same ring buffer as a scalar column |

Network loss injection is handled by an external app, not built here.

No console spam. Everything is opt-in via explicit dump or tuning UI query.

Exit: tooling works, produces sensible numbers on a trivial scenario (one vehicle, driven straight), and the ring dump loads cleanly in whatever plotting tool is being used.

### 1b — Core single-vehicle sync

Wire format and broadcast pipeline for a single vehicle. This is the substrate everything else builds on, so get the schema right the first time.

Included:

- Transform channel (position, rotation, linear velocity, angular velocity)
- Electrics channel (throttle, brake, steering, clutch, parking brake, and a separate rear-steer axis)
- Gearbox channel
- Electrics-undefined channel for sparse diffs (lights, drive modes, actuator states) — accept that intermediates collapse between sends; document as a known limitation
- Control input pipeline: inputs are consumed locally by the authority (zero-latency); no cross-client routing yet

Wire format reserves a `component_id` field even though it is always equal to the vehicle ID in phase 1. This lets phase 2 extend to cluster state without a format rev.

Receiver-side reconstruction:

- Dead-reckoning prediction during the gap between snapshots
- Blend on snapshot arrival (no hard teleports during normal operation)
- Predict in the coordinate system where dynamics are smoothest — for a single rigid vehicle this is world-frame for position, body-frame for angular quantities

Exit: single vehicle driven through aggressive cornering, braking, and rough terrain stays within a defined pose-divergence tolerance (target: p95 position delta < 5 cm, p95 orientation delta < 2°) across four clients.

### 1c — Deformation sync

Node-position-based deformation sync. Authority samples node positions, transmits deltas from rest state, receivers apply deltas to their local vehicle representation.

Approach:

- Quantize positions aggressively in local body frame (8–10 bits per axis range to be determined empirically)
- Delta encoding against rest state — only dirty nodes on the wire
- Priority accumulator: nodes near high-activity regions (hinge, recent collision impulses) get bandwidth preferentially
- Single unified scheme for all deformation, including the bus hinge — no hinge-specific hacks

Hinge-angle scalar from 1a is the acceptance measurement for the bus: authority's and receivers' hinge angles must track within tolerance.

Not built here: damage model, broken-beam list, visual deformation templates, region-level LOD. Those are part of the separate deformation-modeling plan.

Exit: rear-steered articulated bus driven through cornering, lane changes, and figure-eights. Receivers see the articulation matching the authority to within target tolerance (hinge-angle delta p95 < 0.5° at close range, < 2° at distance).

### 1d — Hardening and tuning defaults

On the clean-slate ForkedKISS implementation, the tunables introduced in 1b and 1c (extrapolation clamps, blend gains, deformation priority weights, quantization bit depths) need empirical defaults backed by measurement.

Use the tuning UI to sweep parameters under repeatable scenarios. Lock in defaults per vehicle class where needed (bus vs car vs heli), document the rationale, commit the presets.

Also in 1d:

- Reconnection correctness — client joining mid-session sees current pose and deformation, not a clean reset
- Stress-scenario pass: curb hop, high-speed cornering, low-speed scraping contact, a controlled crash (to exercise deformation sync under impulse), network degradation via the external loss-injection app

Exit: four-player server, one rear-steered articulated bus, one regular car, one helicopter (rotors stopped). Drive the bus through a defined course; measurement tooling confirms pose and hinge-angle tolerances hold under 5–15% simulated packet loss. No visible artifacts reported by observers.

---

## Phase 2 — Same-owner trailers

One player owns both the truck and the trailer. They hitch via a declared coupler (fifth wheel or ball hitch), drive, unhitch. Authority is the owning player — no election, no transfer, no epoch system, no cross-owner protocol.

This is where the foundation's theoretical model first meets the BeamNG coupler API in practice.

### Scope

- Declared couplers only (fifth wheel, ball hitch) — emergent contact and runtime beams are later phases
- Single-owner only — cross-owner trailers are phase 3
- Static cluster topology during a coupling lifetime — topology changes only at hitch/unhitch events

### Work items

| Item | Description |
|---|---|
| Wire format extension | Broadcast carries root 6-DOF + joint DOFs for all cluster members. `component_id` (reserved in 1b) now actually distinguishes clusters. |
| Forward kinematic evaluator | Pure function, receiver-side: `(root_pose, joint_θs, topology) → body_poses[]`. Unit-testable without networking. |
| Joint state extraction | Given an attached coupler, read $\theta_i$ and $\dot\theta_i$ from the BeamNG vehicle Lua API every tick. One extractor per coupler type. |
| Coupling handshake | On owner's client, `onCouplerAttached`/`onCouplerDetached` triggers a topology-change event broadcast via server. All clients atomically switch wire format at the commit tick. |
| Replay path | Non-authority receivers apply forward evaluator using wire-received joint DOFs. No local "snap to hitch" correction — there is no independent trailer pose to correct against. |

### Open questions to answer during phase 2

- Does the existing coupler API on BeamNG expose clean per-joint DOF access, or does joint state have to be reverse-engineered from node positions?
- Does the L-key ball-hitch coupling issue (from prior KissMP debugging) reproduce on ForkedKISS phase 2? If so, is the root cause in the coupling detection, the handshake, or the joint-state extraction?

### Exit criteria

One player, one truck, one trailer. Hitch, drive aggressive course, unhitch, re-hitch. Across all observers:

- No pose snaps at hitch or unhitch events
- No drift during driving (joint DOF reconstruction exact, within float precision)
- No jackknife-correction artifacts (there is no jackknife correction — the authority's solver produces whatever articulation is physical, and receivers replay it faithfully)
- Pose divergence stays within phase 1 tolerances, applied to both truck and trailer

---

## Phase 3 — Cross-owner trailers

Truck and trailer owned by different players. Exactly one of them is cluster authority; the other's client must not run physics for the cluster member they own.

### New complexity

- Authority election (continuity rule from the foundation: larger component wins, tiebreaker by vehicle ID)
- Epoch-tagged state with receiver-side epoch enforcement (non-negotiable correctness layer)
- `PreHandoffState` transmission on authority transitions, with timeout fallback
- Non-authority sim suppression — the non-authoritative owner's client stops advancing its vehicle's physics while a different client has authority
- Disconnect handling — re-election when the authority goes away, using a ranked candidate list so cascades don't require per-tick escalation

Trailers specifically keep the control-input story simple: trailers have no driver, so the "my inputs go nowhere" UX problem doesn't bite here. That problem reappears in later phases and will be addressed then.

### Work items

| Item | Description |
|---|---|
| Server-side contact graph | Server maintains the canonical graph of coupling edges. Clients hold mirrored views for local decisions. |
| Election rule | Continuity-preserving with vehicle-ID tiebreaker. Runs on the server; clients do not self-promote. |
| Epoch system | Every cluster's state packet carries a server-issued epoch. Receivers drop stale-epoch packets. Epoch bumps on every authority change. |
| Handover protocol | Two-phase commit: pre-handoff state from outgoing → incoming authority, then server commits the epoch bump with a timeout fallback if pre-handoff fails to deliver. |
| Sim suppression | Non-authority owner must not advance physics for vehicles whose cluster is elsewhere. Locate the sim-tick path and gate it on authority status. |
| Ranked candidates | Election rule produces an ordered list of candidates; if the top one fails to ack, fall through to the next without restarting the election. |

### Failure modes covered

Epoch-tagged state with receiver enforcement resolves most of them:

- Stale authority keeps broadcasting after handover → receivers drop by epoch
- New authority starts early → receivers haven't seen the epoch bump yet, drop by epoch
- Different clients receive the handover event at different ticks → each is internally consistent, no double-authority corruption

Authority-disconnect accepts a visible glitch (new authority starts from its own replay state as initial conditions) — documented as a known tradeoff rather than hidden behind a complex reconstruction scheme.

### Exit criteria

Two players, one owns the truck, the other owns the trailer. Sequence:

- Hitch, drive, unhitch — no pose snaps, no drift, matches phase 2 behavior
- Trailer owner disconnects while hitched — truck continues driving, trailer either stays in cluster (if authority was truck-owner) or detaches cleanly (if authority was trailer-owner and left)
- Truck owner disconnects while hitched — authority migrates to trailer owner, cluster either continues or dissolves to size-1
- Epoch enforcement verified: artificially delay a client by a few ticks, confirm stale packets are dropped rather than applied

---

## Deferred to later phases

Not part of this roadmap:

- N-vehicle clusters beyond truck+trailer (N=3+ declared couplers)
- Emergent sustained-contact cluster formation (car on trailer, stacked loads)
- Runtime inter-vehicle beams (tow rope, mod-created couplings)
- Input UX when the player's vehicle is taken over by another client's authority
- Damage modeling, broken-beam sync, deformation region LOD
- Helicopter rotor sync, prop sync
- Acceptance tests from the dynamic-merging spec §11 (forklift-through-windows, pile-ups, etc.)

These live in the dynamic-merging spec and are the subject of phases 4+.
