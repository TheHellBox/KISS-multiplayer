# Cluster Sync Foundation

This document establishes the theoretical model that ForkedKISS's multi-vehicle sync is built on. It covers the general N-joint case (bendy buses, trailer trains, dollies) under a single-owner authority model. The code in this PR implements a subset; this document explains the model the code assumes so reviewers can evaluate whether the implementation matches the intent.

If you are reviewing a later PR in the sync series, the invariants in §6 are the five things that must still be true. Everything else is derivation.

## 1. State model

A **cluster** is a tree of $N$ rigid bodies $B_0, B_1, \ldots, B_{N-1}$ connected by $N-1$ joints. $B_0$ is the **root** — the owner-authoritative anchor. Every other body $B_i$ has a parent $B_{p(i)}$ and a joint $J_i$ connecting them.

The full cluster state at time $t$ is:

$$\mathbf{S}(t) = \left(\mathbf{x}_0, \mathbf{q}_0, \mathbf{v}_0, \boldsymbol{\omega}_0, \\{\theta_i, \dot\theta_i\\}_{i=1}^{N-1}\right)$$

where $(\mathbf{x}_0, \mathbf{q}_0, \mathbf{v}_0, \boldsymbol{\omega}_0)$ is the root's 6-DOF pose and twist in world coordinates, and each $\theta_i$ is the joint's internal DOF vector — **not** the child body's world pose.

The child world pose is derived:

$$T_i = T_{p(i)} \cdot H_i(\theta_i)$$

where $T_i$ is the $i$-th body's world transform and $H_i$ is the joint's forward kinematic map parameterized by its internal DOFs.

**Invariant:** network state is the root pose plus joint internal coordinates. Child world poses are a view, never a source of truth.

This is what kills trailer drift. Drift is the symptom of two sources of truth for the same pose; removing one source removes the drift.

## 2. Joint taxonomy as DOF count

Every joint reduces to a small set of $H_i$ functions distinguished by DOF count, not by BeamNG `couplerTag`:

| Joint type | DOFs | $\theta_i$ | Examples |
|---|---|---|---|
| Rigid weld | 0 | — | Welded stacks, rigidly-mounted racks |
| Revolute | 1 | $\mathbb{R}$ (yaw) | Fifth wheel, kingpin |
| Universal | 2 | $\mathbb{R}^2$ (yaw, pitch) | Pintle hitch |
| Ball | 3 | $\mathbb{R}^3$ (yaw, pitch, roll) | Tow ball, articulated bus joint |
| Ball + roll-damper | 3 | $\mathbb{R}^3$ | Most articulated buses (roll constrained by internal forces, not by the kinematic map) |

The existing `couplerTag`-based dispatch collapses into "how many entries does $\theta_i$ have." The transform path no longer branches by hitch type; it branches only by DOF count.

Rear steering on a trailing body is **not** a joint property. It is an actuator on $B_i$'s wheels — see §5.

## 3. Authority invariant

Only the owner integrates physics for the whole cluster. All other peers run the cluster as **kinematic replay**: they receive $\mathbf{S}(t)$ snapshots and reconstruct body poses via the forward map. No peer ever integrates a non-root body from forces.

Formally, for any peer $P$ and any body $B_i$ in a cluster owned by $O \neq P$:

$$T_i^P(t) = T_0^P(t) \cdot \prod_{j \in \text{path}(0 \to i)} H_j(\theta_j^P(t))$$

where all $\theta_j^P$ come from the wire, never from local simulation.

**Invariant:** replay peers have no dynamics for owned clusters, only kinematics.

This generalizes the existing "snap at hitch" correction. In the old model, the replay peer had an independent trailer world pose and snapped it to match `tow + hitch offset` each frame. In this model the replay peer never had an independent trailer world pose at all — it only ever had $\theta_i$, which it applies to the parent's transform.

## 4. Rear steering and bidirectional physics

In a classic tractor-trailer, information flows tow → trailer: the tow's path determines the trailer's path, and the trailer's yaw rate is a consequence of the tow's motion and the hitch geometry. Replay is trivial because the trailer has no independent will.

Rear-steered articulated buses are different. The rear body's steered axle generates a lateral force that feeds back through the joint into the leading body's yaw dynamics. The leading body's trajectory now depends on the rear body's actuation. The arrow is bidirectional at the physics layer.

This does not matter for sync. The owner simulates both bodies together. The bidirectional coupling happens entirely inside one peer's solver. The wire only carries the result — $(\mathbf{x}_0, \mathbf{q}_0, \mathbf{v}_0, \boldsymbol{\omega}_0, \theta_i, \dot\theta_i)$ — and replay peers reconstruct both body poses from that. The rear-steer input is part of the owner's control state, not part of the cluster state, and it enters the simulation through the owner's wheel model before $\mathbf{S}(t)$ is ever computed.

**Invariant:** control inputs and cluster state are separated. Steering angle at any axle on any body is an input that the owner consumes to produce $\mathbf{S}(t+\Delta t)$. Replay peers don't need to know the rear-steer angle to replay the cluster, because its effect is already baked into the root twist and joint rates they receive.

## 5. Split control

What happens if peer $P$ drives the rear body (a co-op bus where one player drives the front, another operates rear-steer)? You still want a single physics owner, but control inputs come from multiple peers.

Control is separated from physics:

- **Physics owner** $O$ runs the solver, produces $\mathbf{S}(t)$, broadcasts.
- **Control peers** $C_1, C_2, \ldots$ each own a subset of inputs (steering, throttle, brakes, rear-steer angle) on specific bodies. Each broadcasts inputs only to $O$.

$O$ consumes all control-peer inputs, runs physics, broadcasts state. Control peers do not run local physics for the cluster; they see their own inputs reflected through $O$'s state stream, with a round-trip latency.

For the common single-driver case this collapses: the driver is the physics owner, zero-latency on their own inputs, normal replay for everyone else. Split control is a later phase; the model accommodates it without rework.

## 6. Correctness invariants

If these five hold, drift is impossible by construction — not "small and correctable," impossible.

1. **Single integrator.** For each cluster, exactly one peer integrates forces. All others replay.
2. **State minimality.** Wire state is (root 6-DOF, $\\{\theta_i, \dot\theta_i\\}$). No child world poses on the wire.
3. **Derived kinematics.** Replay peers compute child poses via $T_i = T_{p(i)} H_i(\theta_i)$. Never cache, never predict forward on a replay peer without also advancing the root.
4. **Control/state separation.** Control inputs flow peer → owner. State flows owner → peers. These are different message types with different guarantees.
5. **Topological consistency.** Cluster topology (bodies, joints, DOFs, parent relationships) is established at handshake and versioned. Mid-flight topology changes go through the two-phase protocol in §8.

The only drift sources left after these hold are numerical (float precision in the forward map) and latency (peer sees old state). Both are bounded by how recently the owner's last $\mathbf{S}(t)$ arrived.

## 7. Prediction on replay peers

Replay peers receive $\mathbf{S}(t)$ at discrete times $t_k$. Between snapshots they extrapolate.

**Root body:** standard dead-reckoning. Extrapolate $\mathbf{x}_0, \mathbf{q}_0$ using $\mathbf{v}_0, \boldsymbol{\omega}_0$. Blend over a short window when a new snapshot arrives.

**Joint DOFs:** extrapolate $\theta_i$ using $\dot\theta_i$ with the same blend. Critically, extrapolate **in joint coordinates**, not in world pose. A trailer swinging behind a tow vehicle has a $\dot\theta$ that is well-behaved even when its world-pose angular velocity looks wild, because the world angular velocity is the sum of parent angular velocity plus joint rate. Extrapolating in joint coordinates avoids the "trailer flies off" failure mode when packet loss spikes.

**Invariant:** prediction happens in the coordinate system where dynamics are simplest. Root in world, joints in joint coordinates.

## 8. Topology changes

Coupling and decoupling change cluster topology. Both go through a server-coordinated handshake; neither is a unilateral client decision.

**Coupling** — two previously-separate clusters $A$ and $B$ merge at a new joint:

1. Any peer detecting geometric coupling conditions sends `COUPLE_REQUEST(A_root, B_root, joint_spec, geometry)` to the designated merge arbiter (the server in ForkedKISS).
2. Arbiter validates: are both clusters still in claimed poses? Is the joint geometrically feasible? If yes, broadcasts `COUPLE_COMMIT(merged_topology, initial_θ)`.
3. All peers atomically switch to the new topology at the commit tick. The formerly-independent root of $B$ becomes a child in the merged tree; its world pose is now derived from the new root + joint chain.

The L-key ball-hitch coupling issue that has shown up in prior debugging is almost certainly a step-1 problem: `onCouplerAttached` fires on one peer but not the other, so the request is never sent, or it is sent but validation fails because the other peer still thinks the bodies are separate. The fix is not to make `onCouplerAttached` more reliable. It is to make coupling a negotiated event rather than a detected event. Detection is a hint; commitment is a handshake.

**Decoupling** — owner broadcasts `DECOUPLE_COMMIT(joint_i, split_topology)` and both sub-clusters have their own owner from the next tick. The formerly-child $B$ is seeded with initial world pose and twist from $T_{p(i)} H_i(\theta_i)$ and the composed twist at the moment of decoupling. This prevents a pose jump at the split.

## 9. How this differs from prior KissMP sync approaches

- Previous implementations have separate transform paths for fifth wheel vs ball hitch. In this model, those are the same code path with different $H_i$ functions selected by DOF count.
- Replay peers in the old model ran their own trailer physics and corrected via forces at the hitch. In this model they run no physics for the cluster; they apply the forward evaluator and that is the entire replay logic. Force-based corrections at the hitch disappear.
- The `applyClusterLinearAngularAccel` concern is confined to the owner. Replay peers do not call it. Its quirks become a local solver problem, not a sync problem.
- Live-tuning parameters are owner-local (they affect how the owner simulates). They are not part of cluster state and do not need to match across peers unless explicitly synced via a separate config channel.

## 10. Implementation order

Suggested order to lower this model into code. Each step produces working, testable behavior.

1. Define the wire schema for $\mathbf{S}(t)$ with joint DOFs as a variable-length array keyed by joint index. Trivially extensible to N-joint.
2. Write the forward kinematic evaluator: `(root_pose, joint_θs, topology) → body_poses[]`. Pure function, unit-testable without any networking.
3. Replace the trailer-pose update path on replay peers with a call to the evaluator. The "snap at hitch" logic becomes a special case (single-joint cluster) of the general replay path.
4. Rebuild the coupling handshake as a two-phase protocol.
5. Only then touch the owner's solver. The solver's job shrinks: integrate forces, publish $\mathbf{S}(t)$. It stops caring about sync, because sync is now a property of the wire format and the replay evaluator.

---

## Known risks

Two places this model meets the real BeamNG API and may need adjustment:

1. **`applyClusterLinearAngularAccel` compatibility.** The foundation assumes the owner can integrate the cluster through its solver without the API imposing sync assumptions that fight the "root is the only integrator" invariant. This needs to be verified in practice on phase 1/2 work.
2. **Coupling handshake latency.** The two-phase protocol adds at least one round-trip between detection and commitment. If this is perceptible to the player pulling up to a hitch, the handshake may need a speculative commit with server rollback rather than a strict two-phase commit.
