# Cluster Sync Foundation

This document establishes the theoretical model that ForkedKISS's multi-vehicle sync is built on. It covers the general N-joint case (bendy buses, trailer trains, dollies) under a single-owner authority model. The code in this PR implements a subset; this document explains the model the code assumes so reviewers can evaluate whether the implementation matches the intent.

If you are reviewing a later PR in the sync series, the invariants in §6 are the five things that must still be true. Everything else is derivation.

## 1. State model

A **cluster group** is a set of $N$ rigid bodies $B_0, B_1, \ldots, B_{N-1}$ that move as a coupled unit. A truck with trailer is two bodies. An articulated bus is two bodies. The bodies may be connected via BeamNG couplers, but the sync model treats them as independent rigid bodies whose states are all tracked explicitly.

The cluster group state at time $t$ is the collection of root states for all bodies:

$$\mathbf{S}(t) = \{ (\mathbf{x}_i, \mathbf{q}_i, \mathbf{v}_i, \boldsymbol{\omega}_i) \}_{i=0}^{N-1}$$

where for each body $B_i$:
- $\mathbf{x}_i \in \mathbb{R}^3$ is the body position in world coordinates [m].
- $\mathbf{q}_i \in \mathbb{H}$ is the body orientation as a unit quaternion.
- $\mathbf{v}_i \in \mathbb{R}^3$ is the linear velocity [m/s].
- $\boldsymbol{\omega}_i \in \mathbb{R}^3$ is the angular velocity [rad/s].

**Invariant:** we sync the **outcome** of BeamNG's physics simulation, not joint DOFs. The authority simulates the coupled rig with native BeamNG couplers, and we transmit the resulting state of all bodies.

Hitch/joint angles are **implicit** in the relative transforms between bodies — they are not part of wire state:

$$\theta_{\text{hitch}} = \text{angle}(\mathbf{q}_0^{-1} \cdot \mathbf{q}_1)$$

This is computed from synced body orientations, not transmitted explicitly.

This is what kills trailer drift. Each body's pose comes from exactly one source (the wire), eliminating the two-source conflict that causes drift.

## 2. Coupling model

Bodies in a cluster group may be connected via BeamNG's native coupler system on the authority side. The coupler constraint is solved by BeamNG's physics, and we sync the **resulting body states**.

| Coupling type | Bodies | Constraint | Examples |
|---|---|---|---|
| Fifth wheel | 2 | Kingpin in jaw | Truck + semi-trailer |
| Ball hitch | 2 | Ball in socket | SUV + utility trailer |
| Pintle hook | 2 | Ring on hook | Military + cargo trailer |
| Articulated joint | 2 | Hinge with damping | Articulated bus |

The sync model does not distinguish between coupling types — all are treated as multiple bodies whose root states are synced explicitly. The hitch angle emerges from the relative transform between bodies.

Rear steering on a trailing body is **not** a coupling property. It is an actuator on $B_i$'s wheels — see §4.

## 3. Authority invariant

The cluster group owner integrates physics for all bodies using BeamNG's native coupler constraints. All other peers perform **state replay**: they receive $\mathbf{S}(t)$ snapshots and set each body's pose and twist directly from the wire.

Formally, for any peer $P$ and any body $B_i$ in a cluster group owned by $O \neq P$:

$$T_i^P(t) = T_i^{\text{wire}}(t)$$

where $T_i^{\text{wire}}(t)$ is the body's transform received directly from the wire — no forward kinematics, no chain multiplication.

**Invariant:** replay peers set body states directly from wire, no forward kinematics, no independent dynamics.

This eliminates the "snap at hitch" problem entirely. In the old model, the replay peer had an independent trailer world pose and corrected it toward `tow + hitch offset` each frame. In this model, the replay peer never computes trailer pose independently — it receives the trailer's exact state from the wire, exactly as the authority's physics produced it.

## 4. Rear steering and bidirectional physics

In a classic tractor-trailer, information flows tow → trailer: the tow's path determines the trailer's path, and the trailer's yaw rate is a consequence of the tow's motion and the hitch geometry.

Rear-steered articulated buses are different. The rear body's steered axle generates a lateral force that feeds back through the coupler into the leading body's yaw dynamics. The leading body's trajectory now depends on the rear body's actuation. The physics coupling is bidirectional.

This does not matter for sync. The owner simulates both bodies together with BeamNG's native coupler constraints. The bidirectional coupling happens entirely inside one peer's solver. The wire only carries the resulting body states, and replay peers set both body states directly from that. The rear-steer input is part of the owner's control state, not part of the cluster state, and it enters the simulation through the owner's wheel model before $\mathbf{S}(t)$ is ever computed.

**Invariant:** control inputs and cluster state are separated. Steering angle at any axle on any body is an input that the owner consumes to produce $\mathbf{S}(t+\Delta t)$. Replay peers don't need to know the rear-steer angle to replay the cluster group, because its effect is already baked into the body states they receive.

## 5. Split control

What happens if peer $P$ drives the rear body (a co-op bus where one player drives the front, another operates rear-steer)? You still want a single physics owner, but control inputs come from multiple peers.

Control is separated from physics:

- **Physics owner** $O$ runs the solver, produces $\mathbf{S}(t)$, broadcasts.
- **Control peers** $C_1, C_2, \ldots$ each own a subset of inputs (steering, throttle, brakes, rear-steer angle) on specific bodies. Each broadcasts inputs only to $O$.

$O$ consumes all control-peer inputs, runs physics, broadcasts state. Control peers do not run local physics for the cluster; they see their own inputs reflected through $O$'s state stream, with a round-trip latency.

For the common single-driver case this collapses: the driver is the physics owner, zero-latency on their own inputs, normal replay for everyone else. Split control is a later phase; the model accommodates it without rework.

## 6. Correctness invariants

If these five hold, drift is impossible by construction — not "small and correctable," impossible.

1. **Single integrator.** For each cluster group, exactly one peer (the owner) integrates forces using BeamNG physics. All others replay state directly.
2. **State completeness.** Wire state contains full root state (pose + twist) for every body in the cluster group. No body poses are derived via forward kinematics.
3. **Direct replay.** Replay peers set body states directly from wire data. No forward kinematics, no independent dynamics, no cached predictions.
4. **Control/state separation.** Control inputs flow peer → owner. State flows owner → peers. These are different message types with different guarantees.
5. **Group membership consistency.** Cluster group membership (which vehicles are coupled) is established at handshake and versioned. Coupling/uncoupling events go through a two-phase protocol.

The only drift sources left after these hold are numerical (float precision) and latency (peer sees old state). Both are bounded by how recently the owner's last $\mathbf{S}(t)$ arrived.

## 7. Prediction on replay peers

Replay peers receive $\mathbf{S}(t)$ at discrete times $t_k$. Between snapshots they extrapolate.

**Each body:** standard dead-reckoning per body. Extrapolate $\mathbf{x}_i, \mathbf{q}_i$ using $\mathbf{v}_i, \boldsymbol{\omega}_i$. Blend over a short window when a new snapshot arrives.

**Critical:** all bodies in a cluster group are extrapolated independently, but updated atomically when a new snapshot arrives. This prevents momentary desynchronization where the truck has moved but the trailer hasn't.

**Invariant:** prediction happens in world coordinates for each body. No joint coordinate extrapolation is needed because joint angles are not part of wire state.

## 8. Topology changes

Coupling and decoupling change cluster group membership. Both go through a server-coordinated handshake; neither is a unilateral client decision.

**Coupling** — two previously-separate vehicles $A$ and $B$ form a new cluster group:

1. Any peer detecting geometric coupling conditions sends `COUPLE_REQUEST(A, B, coupler_spec, geometry)` to the designated merge arbiter (the server in ForkedKISS).
2. Arbiter validates: are both vehicles still in claimed poses? Is the coupler geometrically feasible? If yes, broadcasts `COUPLE_COMMIT(group_id, [A, B])`.
3. All peers atomically switch to the new cluster group at the commit tick. Both vehicles are now synced as a single group.

The L-key ball-hitch coupling issue that has shown up in prior debugging is almost certainly a step-1 problem: `onCouplerAttached` fires on one peer but not the other, so the request is never sent, or it is sent but validation fails because the other peer still thinks the bodies are separate. The fix is not to make `onCouplerAttached` more reliable. It is to make coupling a negotiated event rather than a detected event. Detection is a hint; commitment is a handshake.

**Decoupling** — owner broadcasts `DECOUPLE_COMMIT(group_id, [A], [B])` and both vehicles become independent cluster groups from the next tick. Each vehicle continues with its current pose and twist — no pose jump at the split because we're already syncing both bodies independently.

## 9. How this differs from prior KissMP sync approaches

- Previous implementations have separate transform paths for fifth wheel vs ball hitch. In this model, there is no transform path — all body poses come directly from the wire.
- Replay peers in the old model ran their own trailer physics and corrected via forces at the hitch. In this model they run no physics for the cluster group; they set body states directly from wire data. Force-based corrections at the hitch disappear.
- The `applyClusterLinearAngularAccel` concern is confined to the owner. Replay peers do not call it. Its quirks become a local solver problem, not a sync problem.
- Live-tuning parameters are owner-local (they affect how the owner simulates). They are not part of cluster state and do not need to match across peers unless explicitly synced via a separate config channel.

## 10. Implementation order

Suggested order to lower this model into code. Each step produces working, testable behavior.

1. Define the wire schema for $\mathbf{S}(t)$ with per-body root state (pose + twist) for all bodies in cluster group. Trivially extensible to N-body groups.
2. Implement direct state replay: set body transforms from wire data. Pure state application, unit-testable without any networking.
3. Replace the trailer-pose update path on replay peers with direct state setting. The "snap at hitch" logic disappears entirely.
4. Rebuild the coupling handshake as a two-phase protocol.
5. Only then touch the owner's solver. The solver's job is unchanged: integrate forces with native BeamNG couplers, publish $\mathbf{S}(t)$. Sync is now a property of the wire format and direct replay.

---

## Known risks

Three places this model meets the real BeamNG API and may need adjustment:

1. **`applyClusterLinearAngularAccel` compatibility.** The foundation assumes the owner can integrate the cluster group through its solver without the API imposing sync assumptions. Since we sync all body states directly (not via forward kinematics), this reduces to ensuring BeamNG's cluster API doesn't fight our per-body state setting on replay peers. This needs verification on phase 1/2 work.

2. **Coupling handshake latency.** The two-phase protocol adds at least one round-trip between detection and commitment. If this is perceptible to the player pulling up to a hitch, the handshake may need a speculative commit with server rollback rather than a strict two-phase commit.

3. **Multi-body sync atomicity.** We transmit N body states per cluster group. If packets are split or arrive out of order, bodies may momentarily desync. We need to ensure all bodies in a group are updated atomically on the receiver side.
