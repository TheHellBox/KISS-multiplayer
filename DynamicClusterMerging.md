# Dynamic Cluster Merging for KissMP

**A spec for agentic implementation.**

---

## 0. Read this first

**Audience.** An agentic coding CLI (Claude Code or equivalent) implementing this system in the KissMP/ForkedKISS fork. A human (the project owner) will review your changes incrementally.

**Status.** This system does not yet exist. Some of the substrate it relies on (single-owner pose-based cluster sync, declared-coupler handling for fifth wheel and tow hitch, deformation sync pipeline) does exist or is in progress in the fork. Before changing any existing file, locate the relevant code and propose changes as granular diffs. Do not rewrite existing files wholesale.

**Posture.** This spec encodes decisions that have already been argued through with the project owner. Do not second-guess them. If you find a decision underspecified, surface it as a question rather than picking arbitrarily. If you find a decision wrong on technical grounds, raise it explicitly and stop until it's resolved. Silent reinterpretation is the failure mode being guarded against here.

**Style mandates from project owner.**

- Small single-purpose functions. No god-functions.
- Prose-style "why over what" comments in the spirit of Robert Nystrom.
- `anyhow` for application-layer errors, `thiserror` for library/protocol errors.
- Enum-based state machines. Not typestate.
- TDD where feasible — write the test for a state transition before the transition itself.
- Granular snippets over full file rewrites when proposing changes.
- Do not write speculative code. If a decision is unclear, surface it.

**Type sketches in this document are illustrative.** They show shape and intent. They are not finished signatures. Adapt names and exact types to fit existing fork conventions.

---

## 1. The problem this solves

KissMP currently runs each vehicle's physics simulation on its owner's client. When two vehicles interact through sustained mechanical coupling — a trailer behind a truck, a car sitting on a trailer, a forklift carrying a car, a heli on a trailer deck, a tow rope between two vehicles, a pile-up of crashed cars — independent simulations diverge. Each client's local sim has only its own vehicle's state and approximated guesses about the others, so coupled physics produces drift, jitter, clipping, and inexplicable launches.

The fix is **single-sim coupling**: when two or more vehicles are mechanically connected, one client simulates all of them together and broadcasts coordinated state. Existing fork code does this for declared couplers (fifth wheel, tow hitch). This spec generalizes the same machinery to handle **any** sustained mechanical connection, declared or emergent, and to handle arbitrary multi-vehicle topologies.

---

## 2. Core abstraction: the contact graph

Maintain one global data structure: an undirected graph where

- **Nodes** are vehicles currently in the world.
- **Edges** represent sustained mechanical coupling between two vehicles.

Edges are added by three trigger paths (section 3). Edges are removed when the coupling that created them ends.

**Connected components of this graph are the simulation units.** Every connected component runs on exactly one client. A vehicle in a component of size 1 (no edges) runs on its owner's client, exactly as today. A component of size > 1 runs on the elected authority's client (section 4) regardless of who owns the individual vehicles.

The contact graph is **server-authoritative**. The server holds the canonical graph; clients hold mirrored views for local decision-making but do not unilaterally mutate the canonical state. Edge add/remove events flow through the server so all clients converge on the same component structure.

```rust
// Illustrative shape only. Adapt to fork conventions.
struct ContactGraph {
    edges: HashMap<UnorderedPair<VehicleId>, Vec<EdgeSource>>,
    // Components recomputed when edges change. Cache invalidated on mutation.
    components_cache: Option<Vec<Component>>,
}

enum EdgeSource {
    DeclaredCoupler { coupler_id: CouplerId, tag: CouplerTag },
    EmergentContact { detector_id: DetectorId },
    RuntimeBeam { beam_uid: BeamUid },
}

struct Component {
    vehicles: BTreeSet<VehicleId>,  // ordered for deterministic iteration
    authority: ClientId,
    formed_at: Tick,                  // for continuity rule (section 4)
}
```

Multiple edge sources can coexist between the same vehicle pair (a trailer with both a fifth-wheel coupler and a safety chain has two edges by source, one logical edge by graph topology). Track sources per pair so that removing one source doesn't dissolve the coupling if others remain.

**AGENT NOTE.** The graph data structure should support cheap membership queries (which component is vehicle X in?) since these run every tick. Use a Union-Find / disjoint-set under the hood if profiling shows component recomputation is hot, but only after measurement. Do not premature-optimize.

---

## 3. Trigger paths

Three distinct ways an edge enters the contact graph. All three feed the same graph; downstream machinery does not branch on source.

### 3.1 Declared coupler (existing path)

JBeam authors mark contact points as semantically meaningful via the coupler system. The fork already handles `onCouplerAttached` / `onCouplerDetached` for fifth wheel and tow hitch types.

**Change required.** Refactor the existing coupler-attached handling to add an edge to the global contact graph rather than directly mutating cluster authority state. The downstream machinery (component recomputation, authority election, sync routing) handles the rest.

The semantic specifics of each coupler type — fifth-wheel rotational constraints, ball-hitch DOFs, jackknife tension/compression state — remain valid and should be preserved. They become **contact-constraint configuration** attached to the edge, not separate code paths in the sync layer.

### 3.2 Sustained emergent contact (new path)

`nodeCollision` events between nodes belonging to two different vehicles indicate physical contact. Brief contact (sideswipe, fender-tap) should not trigger merging. Sustained meaningful contact should.

**Detector logic.** Per vehicle pair, maintain a contact tracker:

- Accumulate `nodeCollision` events as they fire.
- A contact is "active" if normal force exceeds a meaningful threshold (placeholder: `MIN_NORMAL_FORCE_NEWTONS`, tune empirically) and contact-point count exceeds a threshold (placeholder: `MIN_CONTACT_POINTS`, tune empirically).
- Edge is added when the contact has been continuously active for `MERGE_FORMATION_MS` (placeholder: 200ms — tune later).
- Edge is removed when the contact has been continuously inactive (force or point count below threshold) for `MERGE_DISSOLUTION_MS` (placeholder: 500ms — tune later).

The longer dissolution timer is intentional. Brief separations during chaotic contact (a vehicle in a pile-up momentarily losing contact during a bounce) should not trigger expensive component splits and re-elections.

**Filter out garbage early.** Vehicles in invalid states (just-spawned and pre-handshake, mid-disconnect, ghost/replay state) must not appear in the contact graph at all. Filter at the source — when iterating contact events for graph updates, skip pairs involving any invalid-state vehicle. This is not a "merge denial"; the vehicle is simply not yet a valid graph node.

### 3.3 Runtime inter-vehicle beam (new path)

Beams created at runtime — by the in-game tow rope tool, by mods calling `obj:addBeam`, by custom coupler mods, or any other source — that connect nodes belonging to two different vehicles are mechanical couplings and must be edges in the contact graph.

**Trigger condition.** Edge is added immediately on beam creation (no sustained-contact threshold; the user/mod's intent is explicit). Edge is removed immediately on beam destruction (whether by break, by player removing it, by vehicle reset, by mod action).

**Hook required.** Wrap or monkey-patch the vehicle Lua beam-creation API in the KissMP vehicle extension so that any beam created at runtime is inspected:

- Beam endpoints both within the same vehicle: ignore. Intra-vehicle structural changes are a different concern and do not affect the cluster graph.
- Beam endpoints across two different vehicles: fire a `BeamCreate` sync event automatically.

This hook will affect any mod that creates inter-vehicle beams. Document it clearly. Mod authors will need to know that their inter-vehicle beam creation is automatically synced and they should not add their own sync layer on top.

**Rate-limit considerations.** Some mods create and destroy beams at high frequency (per-frame creation patterns from magnetic crane mods, for example). If profiling shows the reliable-ordered channel saturating from beam events, batch beam create/destroy at tick boundaries (suggested: at most one batch per vehicle per tick). Do not implement batching preemptively — wait until measurement shows it's needed.

---

## 4. Authority election

When a component forms or its membership changes, exactly one client must be elected as authority for the entire component. The election rule is:

**Continuity-preserving with vehicle-ID tiebreaker.**

In plain terms: when multiple components merge into one, the new authority is the authority of whichever pre-merge component had the most vehicles. Tiebreaker: lowest vehicle ID among the candidate authorities' owned vehicles.

### 4.1 Election cases

**Case A — single vehicle gains an edge to another single vehicle.** Two components of size 1 merge into one component of size 2. Both pre-merge components are tied in size. Tiebreaker: lower vehicle ID's owner becomes authority.

**Case B — single vehicle joins an existing larger component.** The existing component is larger. Its current authority remains authority of the enlarged component. The joining vehicle's owner cedes control.

**Case C — two existing components merge.** Whichever component is larger contributes its authority. The other's authority cedes. Ties go to lower vehicle ID among authority candidates.

**Case D — component splits (edge removed, graph splits into two components).** Each resulting sub-component re-elects. Continuity rule: whichever sub-component contains the original authority's primary owned vehicle keeps that authority. The other sub-component runs the election fresh among its members.

**Case E — current authority's client disconnects.** Component re-elects immediately. Continuity is broken by force majeure; pick the next candidate by component-size-then-vehicle-ID rule among remaining members.

### 4.2 Re-election dampening

Do not re-elect just because a "better" candidate appeared this tick. An election fires only on:

- Component formation (edge added that creates or grows a component).
- Component split (edge removed that divides a component).
- Authority disconnect or vehicle deletion that removes the current authority.

Routine churn (a vehicle joining and leaving a component repeatedly across several seconds) should not produce a thrash of authority handoffs. The merge formation / dissolution timers in section 3.2 already provide most of this dampening at the edge level.

### 4.3 Handover protocol

When authority transfers from client A to client B:

1. **Pre-handoff state sync.** A few ticks before the formal handover, A sends B a complete state packet for every vehicle in the component: pose, velocity, angular velocity, deformation offsets, any per-vehicle sim state (rotor RPM, engine state, electrics, etc. — anything B's sim needs to continue from). Send reliable.
2. **Handover event.** Server broadcasts `AuthorityChanged { component_id, new_authority: B }` to all clients reliable-ordered. Includes the tick at which the handover takes effect.
3. **A stops sending** the component's state at the handover tick.
4. **B starts sending** the component's state at the handover tick.
5. **Brief overlap allowed.** If A's last broadcast and B's first broadcast for a given tick are both received by a third client, the third client uses B's (the new authority's) and discards A's.

The pre-handoff state sync is critical for transitions where physical state is changing rapidly (helicopter takeoff, see scenario in section 11). Without it, B's sim takes over with stale state and produces a visible snap.

---

## 5. The merge state machine

Per vehicle pair, the edge between them is in one of these states:

```
NoContact ──[contact starts]──▶ ContactPending
                                       │
                                       ├──[contact sustained MERGE_FORMATION_MS]──▶ Edged
                                       │
                                       └──[contact ends before threshold]──▶ NoContact

Edged ──[contact ends]──▶ EdgePending
                                │
                                ├──[contact resumes]──▶ Edged
                                │
                                └──[contact absent MERGE_DISSOLUTION_MS]──▶ NoContact
```

For declared couplers and runtime beams, the state machine collapses: edge transitions are instant on attach/detach. The pending states only exist for the emergent contact path.

```rust
// Illustrative.
enum EdgeState {
    NoContact,
    ContactPending { since: Tick, source: EdgeSource },
    Edged { sources: Vec<EdgeSource> },
    EdgePending { since: Tick, sources: Vec<EdgeSource> },
}
```

When the state of any edge transitions across the `Edged` boundary (NoContact-or-pending → Edged, or Edged → NoContact-or-pending), recompute the affected components and run elections as needed.

---

## 6. Tick loop integration

The merge layer runs as a phase between physics tick and network broadcast. Approximate ordering per server tick:

1. **Receive client inputs and reports.** Authority clients have just simulated their components and sent state.
2. **Receive contact event reports.** Each authority client reports node-collision events for vehicle pairs in its component, plus any cross-component contact events involving its vehicles.
3. **Update edge states.** Run the per-pair edge state machine.
4. **Recompute components.** If any edge crossed the `Edged` boundary, recompute the connected components.
5. **Run elections.** For each component that formed, split, or lost its authority, run section 4 election. Issue `AuthorityChanged` events.
6. **Broadcast component state.** Per component, the elected authority's last-sent state is forwarded to other clients (or the server broadcasts based on its mirror; depends on existing fork architecture).

On the client side, vehicle-side Lua extensions:

- Report `nodeCollision`, `beamBroken`, `beamDeformed` events upward to the network layer.
- Report `obj:addBeam` / beam-destruction events if endpoints are inter-vehicle.
- Receive component state and apply it (pose, deformation offsets, runtime beam additions/removals).
- For non-authority components containing vehicles the client owns, **suppress local sim**. The non-authority client must not run physics for vehicles whose authority is elsewhere — its sim will diverge and create work for nothing.

**AGENT NOTE.** Suppressing local sim for owned-but-not-authoritative vehicles is the single biggest behavioral change for existing code. Locate the sim-tick path and identify how to gate it on authority status. Likely involves checking component membership and authority before letting the BeamNG vehicle simulation step. If gating at the BeamNG level isn't possible from Lua, the next-best option is to let the local sim step but discard its output (do not broadcast, do not apply locally). Profile to determine if this wastes meaningful CPU.

---

## 7. Network protocol

New message types. Names are illustrative; conform to existing fork conventions.

| Message | Direction | Reliability | Payload (sketch) |
|---|---|---|---|
| `ContactReport` | client → server | unreliable | `{ vehicle_a, vehicle_b, normal_force, contact_points, tick }` — sent per tick by authority while contact is active |
| `EdgeAdded` | server → all | reliable ordered | `{ vehicle_a, vehicle_b, source: EdgeSource, tick }` |
| `EdgeRemoved` | server → all | reliable ordered | `{ vehicle_a, vehicle_b, source: EdgeSource, tick }` |
| `ComponentChanged` | server → all | reliable ordered | `{ component_id, vehicles: [...], authority: ClientId, tick }` — sent on formation, merge, split |
| `AuthorityChanged` | server → all | reliable ordered | `{ component_id, new_authority: ClientId, effective_tick }` |
| `PreHandoffState` | A → B | reliable | full per-vehicle state for every vehicle in the component being handed over |
| `BeamCreate` | client → server → all | reliable ordered | `{ vehicle_a, node_a, vehicle_b, node_b, beam_props, beam_uid, creator: ClientId }` |
| `BeamDestroy` | client → server → all | reliable ordered | `{ beam_uid }` |
| `LateJoinComponentSnapshot` | server → joining client | reliable | full graph state plus per-component authority assignments plus runtime beam registry |

The existing pose/deformation channels continue to operate, but routing changes: state for a vehicle is sent by the authority of its component, not by its owner. Receiving clients route incoming state by `(component, vehicle)` rather than by `(owner, vehicle)`.

**`ContactReport` semantics.** Authority clients are responsible for reporting contacts within their components (since they're the ones simulating and have the data). Cross-component contacts are reported by both involved authorities — server deduplicates by `(vehicle_a, vehicle_b)` pair. A vehicle in a size-1 component (no merge yet) still has its owner reporting any cross-vehicle contacts it observes locally, since it's still simulating itself.

---

## 8. Late-join handshake

A new client connecting to a server with an active world needs:

1. **Vehicle list** with current owners (existing).
2. **Contact graph state** — full edge list with sources, plus current component membership and authority assignments. New.
3. **Runtime beam registry** — every runtime-created inter-vehicle beam currently in the world, with creation parameters, so the joining client can instantiate them locally. New.
4. **Damage snapshot** per visible vehicle (existing or planned per deformation spec).

The runtime beam registry is the easy-to-forget piece. Without it, a late-joiner sees two vehicles in one component (server tells them so) but no visible mechanical link, because the `BeamCreate` event that originally established the link was broadcast before they joined.

Send vehicles and beams visible/nearby to the joining player first; defer distant ones. Throttle the joining client's inbound bandwidth — late join can ship a lot of data and shouldn't saturate other traffic.

---

## 9. What to do about vehicle-side sim suppression

Restating because this is the most likely place for subtle bugs.

When client X owns vehicle V, but V is in a component whose authority is client Y (Y ≠ X):

- X must not advance V's physics simulation.
- X must not apply player inputs to V (the player may continue pressing accelerator/brake, but those inputs go nowhere in terms of physics — **but see UX note below**).
- X receives V's pose and deformation from Y via the normal sync channels and applies them to V's local representation.

**Player input UX.** When a player loses physics control of their vehicle (e.g., their car was just picked up by a forklift), they should get a visual indicator that their car is currently controlled by another player's simulation. Existing fork may or may not have a mechanism for this — surface as a TODO if not. Players actively pressing controls during a take-over should not have those inputs silently dropped without feedback; either show an indicator or relay the inputs to the new authority for application. Inputs-relayed-to-authority is the cleaner model but more work; a clear visual indicator is acceptable for v1.

When authority returns to X (component dissolves, V is alone again), X resumes local sim seamlessly using the last-received state from Y as initial conditions. If a few player inputs were buffered during the takeover, decide explicitly: drop them, or apply on resume? Likely drop — applying buffered inputs after a multi-second takeover would produce a confusing burst of action.

---

## 10. Constants and tuning placeholders

These values are placeholders. Tune empirically. Do not enshrine them in code as magic numbers — define them as named constants in one config module so the project owner can adjust without code archaeology.

| Constant | Placeholder | Purpose |
|---|---|---|
| `MERGE_FORMATION_MS` | 200 | Sustained contact duration before edge is added (emergent path only) |
| `MERGE_DISSOLUTION_MS` | 500 | Continuous absence of contact before edge is removed (emergent path only) |
| `MIN_NORMAL_FORCE_NEWTONS` | TBD | Minimum contact normal force to count as "active" contact |
| `MIN_CONTACT_POINTS` | TBD | Minimum simultaneous contact points to count as "active" contact |
| `PRE_HANDOFF_LEAD_TICKS` | TBD | How many ticks before formal handover to send pre-handoff state |
| `LATE_JOIN_NEAR_RADIUS_M` | TBD | Vehicles within this radius are sent first during late-join |

---

## 11. Worked scenarios

The following scenarios test the system end-to-end. They are also the acceptance bar: each should produce the described behavior with no visible artifacts when the system is correctly implemented.

### 11.1 Truck pulling trailer (declared baseline)

The existing case. JBeam author declared a fifth-wheel coupler. `onCouplerAttached` fires when the trailer is hitched. Edge added with source `DeclaredCoupler`. Component {truck, trailer} forms with truck owner as authority (continuity rule: truck was a size-1 component before, trailer was size-1; equal sizes; tiebreaker by vehicle ID).

This must still work after the refactor. Existing trailer behavior is the regression baseline.

### 11.2 Truck + trailer + car (declared + emergent stacked)

Component {truck, trailer} exists from 11.1. Player drives a car onto the trailer deck. Car's wheels make contact with deck nodes. Contact tracker accumulates contact across both wheels, normal force above threshold (car's weight). After `MERGE_FORMATION_MS`, edge added between car and trailer with source `EmergentContact`. Component now {truck, trailer, car} with truck owner as authority (continuity rule: existing component {truck, trailer} of size 2 absorbs car of size 1).

Car's physics now runs on truck owner's client. Car-tire-on-deck friction is computed in the same sim as trailer suspension, so the car sits stably regardless of trailer pose changes from cornering, braking, going over bumps. Car owner's client sees their car being driven correctly — but cannot apply driving inputs to it. (See section 9 UX note.)

### 11.3 Tilt-deck trailer with car loading

Two interpretations of "tilt deck"; system handles both identically.

**Interpretation A: tilt deck is articulated within the trailer's JBeam.** The deck is part of the trailer; the tilt motion is internal to the trailer's structure (hinged beams + hydraulic cylinder beams). System sees: one trailer behind one truck. Car drives onto tilted deck; emergent contact forms; component {truck, trailer, car} as in 11.2. Deck tilts back up under hydraulic force; this is internal trailer simulation, no graph changes. Drive-off in reverse: car drives down tilted deck, contact ends, dissolution timer, component splits.

**Interpretation B: tilt deck is a separate vehicle attached to the trailer chassis via a coupler/hinge.** Now the chain is truck → trailer chassis → tilt deck → car. Two declared edges (truck-chassis, chassis-deck) plus one emergent edge (deck-car). Component {truck, chassis, deck, car} forms, all authoritative on truck owner.

**Important behavioral test.** During the load sequence, tilt the deck down to ground level, then have the car drive up. As the car's front wheels first touch the deck, contact starts. The car is also still in contact with the ground at this moment (rear wheels). The graph correctly represents both contacts: car-to-deck edge forming, car-to-ground (terrain isn't a vehicle, so this is a regular collision, no graph edge). As the car drives further onto the deck and its rear wheels leave the ground, only car-to-deck contact remains. Driving back off reverses the process. The graph never has a car-to-terrain edge because terrain isn't in the vehicle graph at all.

### 11.4 Helicopter on stationary trailer (rotors stopped)

Heli sits on trailer deck, skids loaded. Sustained contact, edge forms, component {truck (if present), trailer, heli} with truck/trailer authority. Identical to car case. Works.

### 11.5 Helicopter on moving trailer (rotors stopped, trailer being driven)

Same component as 11.4. Truck owner's sim simulates: truck driving, trailer following with heli mass loading suspension, heli sitting on deck experiencing the trailer's accelerations. Receivers see the heli sitting stably on the deck through cornering, acceleration, braking. Works.

### 11.6 Helicopter in transit, rotors running, partial lift

Heli pilot starts rotors while heli is on the trailer in transit. Rotor lift partially unloads the skids. As long as normal force on the contact remains above `MIN_NORMAL_FORCE_NEWTONS`, the contact tracker continues to consider the contact active, and the edge persists. Heli stays in component, simulated by truck owner. Receivers see heli on trailer with rotors spinning.

If rotor lift is enough to fully unload the skids briefly (heli "hovers" above the deck while still on the trailer), contact drops below threshold. `MERGE_DISSOLUTION_MS` (500ms) gives the pilot time to settle back down before the edge dissolves. This is intentional: brief unloads during turbulence shouldn't trigger handover thrash.

### 11.7 Helicopter takeoff from moving trailer

The transition that needs care.

**Sequence with pre-handoff state sync.**

- Pilot increases collective. Lift rises. Normal force on skid contact decreases.
- Authority client (truck owner) detects sustained decreasing trend in contact normal force. **This is a heuristic; surface as an open question whether to act on the trend or wait for the threshold.** For v1, recommend: act on threshold only. Trend-based prediction is a refinement.
- Normal force drops below threshold. Dissolution timer starts.
- During the dissolution window (500ms), truck owner sends `PreHandoffState` to heli owner: heli's current pose, velocity, angular velocity, rotor state, any other per-vehicle sim state.
- Heli owner's client receives the state and primes its local sim with it (sim is suppressed but state is loaded).
- Dissolution timer expires. `EdgeRemoved` fires. Component splits into {truck, trailer} and {heli}.
- Election runs for {heli}: only candidate is heli owner; they take authority.
- `AuthorityChanged` propagates. Heli owner's sim un-suppresses, continues from the primed state.
- Heli is now flown by its pilot, simulated on their client, broadcast to others normally.

**Risk.** If the heli is climbing at the moment of handover, the truck owner's last broadcast may be slightly stale by the time the heli owner takes over. Result: a small backward snap in altitude. Mitigations (in increasing complexity):

1. Pre-handoff state sync (above) — primes the new sim with recent state, but doesn't eliminate the gap.
2. Predictive dissolution — start handoff while contact is still present but trending toward zero. Eliminates the snap but adds heuristic complexity.
3. Speculative simulation overlap — heli owner runs sim speculatively during the handover window, reconciles with authoritative state when it arrives. Most graceful, most expensive.

For v1: implement (1). Surface (2) and (3) as known refinements if user feedback indicates the takeoff transition feels janky.

### 11.8 Helicopter landing on moving trailer

Reverse of 11.7.

- Heli descends toward trailer, owned and authoritative on pilot client.
- Skids touch deck. `nodeCollision` fires. Contact tracker starts accumulating.
- During the formation window (200ms), heli's local sim continues to authoritative; contact forces are computed within the heli's local sim against approximated trailer pose. This is *imperfect* during the 200ms — bounce dynamics may differ slightly between clients — but the window is short and the heli is at low velocity.
- Formation timer expires. Edge added. Component formation merges {heli} into {truck, trailer}, authority transfers to truck owner.
- Pre-handoff state sync (heli owner → truck owner) delivers heli's current state.
- From this point, truck owner simulates everything together. Heli is glued to deck with correct contact constraints.

### 11.9 Forklift through windows + carry

The motivating wild case.

- Forklift driver advances tines into car's side window.
- Tines collide with window beams. High-impulse `nodeCollision` events fire. `beamBroken` events fire as window beams snap.
- Beam break events are broadcast as authoritative reliable-ordered messages (per deformation spec). Receivers fire local `beamBroken` callbacks, which trigger deformGroup activation: glass shatters on all clients, the *correct specific* windows.
- Deformation deltas in the door region transmit at high rate during the burst (per deformation spec).
- Tines now penetrate the door cavity. Continuous contact between tine nodes and door-frame nodes. Contact tracker accumulates.
- After 200ms of sustained contact above force threshold, edge added between forklift and car. Component {forklift, car} forms with forklift owner as authority (continuity tiebreaker if both were size 1; or forklift owner already has authority if they were in a larger component, e.g. if they were towing something).
- Forklift owner now simulates the car's motion as well, with the tine-on-door-frame contact constraints providing the lift. Lifting collective on the forklift raises the car. Driving the forklift moves the car. Receivers see coordinated motion.
- Forklift driver lowers and backs away. Car settles; tines retract. Contact ends. Dissolution timer (500ms) fires; component splits. Car returns to its owner, authority restored, deformed windows preserved.

**This works because the system doesn't care that "carrying a car with a forklift" is unusual.** It's just sustained contact between two vehicles, handled by the same machinery as a trailer.

### 11.10 Multi-vehicle car carrier (auto transporter) with several cars

Truck pulling a multi-deck trailer designed to carry several cars. Cars driven on one at a time. Each car's loading process is identical to 11.2: drive on, sustained contact, edge forms, component grows.

After all cars loaded: component {truck, trailer, car1, car2, car3, car4, car5, car6} all on truck owner's sim. This is the case that worried earlier discussion about performance caps. Per project owner direction: do not implement a cap in v1. Let this run; profile if it becomes a problem; address it later if needed.

### 11.11 Pile-up after collision (cycles, multi-edge)

Three cars collide and end up wedged together in a stable configuration:

- Car A hits car B head-on; sustained contact forms, component {A, B}, A's owner authoritative (whoever was authority of the larger pre-merge component, or tiebreaker since both were size 1).
- Car C rear-ends the pile, making contact with B (and possibly A as well, depending on geometry).
- Edges form: B-C (and possibly A-C). Component grows to {A, B, C}.
- Topology may include cycles (A-B, B-C, A-C). The contact graph handles this naturally; connected components don't care about cycles. A is still in the same component as before. Authority unchanged (continuity rule).
- All three cars now simulated together by A's owner. Stack stays stable; no clipping; no inexplicable launches.

If one car later rolls free of the pile, contact drops below threshold for that pair, dissolution timer fires, that pair's edge removed. If after removal the connected component splits (the rolling-free car has no other edges to the pile), it becomes its own component. Election in the size-1 sub-component returns it to its owner.

### 11.12 Wreck on flatbed tow truck

Tow truck lowers its flatbed (articulated within the truck's JBeam, or as a coupler-attached separate vehicle). Wrecked car is winched onto the flatbed (winching itself is *another* runtime-beam case — see 11.14). Once the wreck is on the flatbed, sustained contact, edge forms, component {tow truck, flatbed (if separate), wreck}.

Tow truck driver raises flatbed and drives away. Wreck stays put on the deck because it's in the same sim as the flatbed. Other clients see the wreck securely transported.

### 11.13 Tow rope between two vehicles

Player A uses the in-game tow rope tool to attach a rope between their truck and player B's stuck car.

- Tool creates a runtime beam between truck node and car node. Beam-creation hook in the vehicle Lua extension fires `BeamCreate`. Server broadcasts `BeamCreate` reliable-ordered.
- All clients including A and B instantiate the beam locally.
- Edge added with source `RuntimeBeam`. Component {truck, car} forms with A as authority (continuity tiebreaker).
- A drives forward; rope goes taut; tension transmits through the rope to the car; car follows. All on A's sim. Receivers see B's car being correctly towed.
- Eventually B's car gets unstuck, A stops, both players agree to unhook. Tool destroys the beam. `BeamDestroy` fires. Edge removed. Component splits. Authority returns to B for their car.

If the rope breaks under load instead: `beamBroken` callback on the rope beam fires on A's sim. A's client sends `BeamDestroy` for the rope's UID. Same downstream behavior.

### 11.14 Two helicopters carrying a long object via cables (cross-component, runtime beams)

Player A's heli and player B's heli both attach cables to a long beam/object (some custom mod cargo, or even another vehicle). Two runtime beams: heliA-cargo and heliB-cargo.

- First cable creates edge {heliA, cargo}. Component forms, A authoritative.
- Second cable creates edge {heliB, cargo}. Component {heliA, cargo} merges with {heliB} (B was size 1) into {heliA, heliB, cargo}. Continuity rule: the larger pre-merge component {heliA, cargo} contributes its authority. A remains authoritative for the combined component.
- A simulates all three: own heli, B's heli, the cargo, with both cable constraints. B's heli responds to A's sim outputs.
- B is flying their heli but their inputs go nowhere unless they're relayed to A, or unless B has a clear UI that they're not in control. (See section 9 UX note. This case makes the input UX problem more visible; it's worth discussing with the project owner whether input-relay is needed for v1.)

This case demonstrates that the system handles arbitrary topology, including cases where neither involved player is "obviously" the authority. Continuity rule produces a deterministic answer.

### 11.15 Push-starting a stalled car

Player A's truck pushes player B's stalled car from behind. Sustained low-energy contact between truck's front bumper nodes and car's rear bumper nodes. After 200ms, edge forms, component {truck, car} with A as authority. A's sim now drives both: the truck's drivetrain pushes the car, the car experiences the push as an external force. Receivers see the car being correctly pushed. When B's engine catches and they accelerate away, contact ends, dissolution timer fires, component splits, B regains authority of their now-running car.

---

## 12. Edge cases and failure modes

**Vehicle reset/respawn while in a component.** The reset destroys all of the vehicle's runtime beams; fire `BeamDestroy` for each before the reset. Vehicle exits the contact graph (becomes invalid-state briefly). Component containing it splits as if the edges were removed normally. After reset completes, vehicle re-enters the graph as a fresh size-1 component.

**Authority client crashes or hard-disconnects.** Server detects via timeout. Re-elect immediately for affected components. Other clients see a brief freeze in the affected component's state until the new authority's first broadcast arrives.

**Network partition between authority and a non-owning component member's owner.** Authority continues simulating. The disconnected client's view freezes for the affected component until the partition heals or they're disconnected. No special handling — falls under standard network resilience.

**Beam endpoint references a node that doesn't exist on the receiver.** Modded variants of vehicles may have different node counts than vanilla. When applying a `BeamCreate` from the network, validate node IDs locally. If a referenced node doesn't exist, log and reject the beam creation gracefully — do not crash. The sender's authoritative simulation is still using the beam, so there will be a divergence: the vehicle pair is in the same component on the server but not visibly connected on the receiver. This is a content mismatch problem (clients running different mods); document as a known limitation.

**Two clients simultaneously create runtime beams between the same vehicle pair.** Server serializes via reliable-ordered. Both beams are created. Both edges (sources distinguished by `beam_uid`) coexist in the per-pair source list. Component formation already handled the merge after the first beam; the second is a no-op for graph topology.

**Coupler attaches at the same instant a runtime beam is created on the same vehicle pair.** Two edges with different sources. Single graph edge for component purposes. Both must be removed before the connection is considered gone.

**Vehicle with active component memberships gets deleted.** Treat as: remove all edges involving the vehicle, recompute components, run elections in any sub-components that result. Then remove vehicle from graph.

**Late-join during a chaotic moment** (active 8-vehicle pile-up with several runtime beams). The late-join snapshot may be large. Throttle it so other clients' regular traffic is not disrupted. If snapshot ships in chunks, the joining client should not consider their world-state valid until all chunks arrive — show a loading indicator.

---

## 13. Non-goals

Out of scope for this spec, deferred or explicitly not pursued:

- **Performance caps on component size.** Project owner directed: do not optimize. Implement for correctness; revisit if performance complaints arise.
- **Cable physics sync** (separate from runtime-beam sync). Cables modeled as series of beams will work via the beam-creation hook. Cables modeled via custom non-beam Lua physics would need their own sync layer; not in scope.
- **Rotor downwash / aerodynamic effects between nearby vehicles.** BeamNG doesn't really model these in single-player; not a regression to omit.
- **Server-side physics validation.** Authority is the elected client; server trusts their sim outputs. Anti-cheat / griefing prevention is a separate concern not addressed here.
- **Splitting authority within a single vehicle** (different parts of one vehicle simulated by different clients). Explicitly not pursued; would require constant sub-vehicle state exchange and would break at boundaries.
- **Predictive dissolution** for heli takeoff (mitigation 2 in 11.7). Refinement, not v1.
- **Speculative simulation overlap** during handover (mitigation 3 in 11.7). Refinement, not v1.
- **Input relay** to authority client. Recommended for v1 but project-owner decision pending. Document as an open question.

---

## 14. Open questions for project owner

These are decisions the project owner has not yet made, or that should be revisited based on early implementation experience. Surface answers before writing code that depends on them.

1. **Input relay vs. visual indicator only.** When a player's vehicle is taken over by another client's authority, do their control inputs route to the new authority for application, or are they suppressed locally with only a UI indicator? Input relay is the cleaner UX but more implementation work and adds latency to inputs.
2. **Empirical values for** `MIN_NORMAL_FORCE_NEWTONS`, `MIN_CONTACT_POINTS`, `PRE_HANDOFF_LEAD_TICKS`, `LATE_JOIN_NEAR_RADIUS_M`. Cannot be determined without testing.
3. **Does the existing fork's pose sync layer expose a clean injection point for "route by component authority instead of vehicle owner"?** If not, this refactor is larger than it first appears. Investigate first; report back before proceeding.
4. **Tilt deck implementation in popular trailer mods.** Determine empirically whether common tilt-deck trailers in BeamNG mods use interpretation A (articulated within JBeam) or interpretation B (separate coupled vehicle) from scenario 11.3. The system handles both, but knowing the prevalent pattern affects what to test against.
5. **Existing fork's late-join handshake.** Locate it and design the contact-graph + runtime-beam-registry extensions to fit cleanly. Do not design in a vacuum.

---

## 15. Implementation order

Suggested order. Each step should produce working, testable behavior before moving to the next. Do not pile up uncommitted work across multiple steps.

**Step 1: Refactor declared-coupler handling onto the contact graph.** Replace direct cluster-authority mutation with edge add/remove on the graph. Components recompute; authority elects via continuity rule (which for a single declared coupler reduces to existing behavior). At the end of this step, existing trailer behavior should be unchanged but the underlying mechanism is now graph-based. This is the regression test.

**Step 2: Implement local sim suppression for non-authority owners.** When a vehicle is in a component whose authority is not its owner, suppress local physics for that vehicle. Verify with a truck-trailer scenario that the trailer no longer simulates on its owner's client (assuming trailer is owned separately, which it usually is in current fork architecture).

**Step 3: Implement the network protocol.** `EdgeAdded`, `EdgeRemoved`, `ComponentChanged`, `AuthorityChanged`, `PreHandoffState`. Wire into existing fork transport. Verify message flow with declared couplers from step 1.

**Step 4: Implement emergent contact path.** Per-pair contact tracker, formation/dissolution timers, edge add/remove. Verify with car-on-trailer (scenario 11.2). Test scenarios 11.3, 11.10, 11.11 once basic case works.

**Step 5: Implement runtime beam path.** `obj:addBeam` hook in vehicle Lua extension, `BeamCreate`/`BeamDestroy` messages, late-join beam registry. Verify with the in-game tow rope tool (scenario 11.13).

**Step 6: Implement pre-handoff state sync.** Add to the authority handover protocol. Verify with helicopter takeoff (scenario 11.7) and landing (11.8). Specifically test the takeoff transition for visible snaps; if present, surface to project owner as feedback for whether to escalate to mitigations 2 or 3.

**Step 7: Late-join handshake extension.** Contact graph state plus runtime beam registry plus damage snapshots. Test by joining mid-game scenarios.

**Step 8: Edge case hardening.** Vehicle reset during component membership, authority disconnect, modded vehicle node mismatches, simultaneous beam creations. Test each from the failure modes section.

After each step: commit working code, write tests for the new behavior, update this document with any decisions made or constants tuned. Do not skip the test step. Do not skip the documentation update.

---

## 16. What "done" looks like

The system is complete when all scenarios in section 11 produce the described behavior with no visible artifacts in normal play, and all edge cases from section 12 are handled without crashes or sync corruption. The acceptance bar is set by the project owner's own playtesting on their KissMP server, not by automated tests alone.

The original motivating goal — *"drive a forklift's tines through another player's car windows and carry them around"* — must work end-to-end including the window-break specificity (correct windows shatter on all clients) and the carry physics (car's weight loads the forklift correctly, car stays on the tines through driving).

Cars on trailers behave correctly through cornering, braking, and rough terrain. Helicopters land on, ride, and take off from moving trailers without inexplicable launches. Pile-ups stay piled. Tow ropes work. The system handles arbitrary topologies that emerge from real player activity on populated servers.
