# KISSDebug & `kissmp_debug` — Design and Implementation Guide

A debugging toolchain for KissMP physics desync work: in-game test scenario authoring, two-instance live diff visualization, and recorded playback for frame-by-frame inspection.

---

## Part I — Design

### Motivation

Multiplayer physics desync investigation in BeamNG is currently bottlenecked by reproducibility. Bugs surface during real play sessions, get described imprecisely in chat, and require multiple people coordinating to attempt a repro — which often fails because nobody can recreate the exact vehicle placements, velocities, network conditions, or trailer states that triggered the original divergence.

The toolchain described here collapses that loop. A test scenario is a YAML file that fully specifies a reproducible test situation. One developer captures it visually in-game; another developer runs a single CLI command and observes the same desync on their machine, with quantitative divergence metrics overlaid in real time and recorded for later inspection.

This is not a general BeamNG modding tool. It exists specifically to serve KissMP physics-sync engineering, and design decisions favor that workflow over generality.

### Three-component architecture

The system splits into three components, each with a clear responsibility and a stable interface to the others.

**KISSMultiplayer** (existing, main repo) gains a small `external_hooks.lua` module exposing a minimal API surface for external tooling: registering externally-spawned vehicles as locally-owned, subscribing to vehicle state changes, and similar mechanism-providing primitives. The hooks are deliberately mechanism-only, never policy-encoding — debugger-specific concepts live in KISSDebug, not here. This module is the only contract between KissMP and any external tool, present or future.

**KISSDebug** (separate repo, BeamNG mod) is the in-game half of the debugger. It implements the four-mode UI panel (Inactive, Edit, Run, Review), executes test scenario load/spawn/state-restoration logic, draws ghost overlays during live diff visualization, handles capture sessions, and renders the playback timeline. It depends on KISSMultiplayer's external hooks but can be installed and uninstalled independently. When loaded, it opens a localhost socket connection to `kissmp_debug` if one is available; when not, it operates in a standalone subset (test scenario authoring and log review work without the Rust binary).

**`kissmp_debug`** (separate repo, Rust binary, cross-platform) is the orchestrator. It owns the CLI, launches and manages the two BeamNG instances for live diff sessions, runs the diff broker that correlates state streams from both instances, writes binary log files, and parses test scenario YAML. It owns no UI itself — visualization is delegated to KISSDebug in-game. Single-process design: the diff broker is not a sidecar, it lives inside the binary.

The reason for this layering: each component is independently installable and useful at reduced functionality. A developer can install KISSDebug alone and get test scenario authoring plus log review. Adding `kissmp_debug` unlocks the live two-instance diff workflow. KissMP itself doesn't need to know any of this exists beyond the hook surface.

### The four modes

KISSDebug's UI is organized around four explicit modes with a persistent indicator (color-coded: gray, yellow, red, blue) showing which is active.

**Inactive** is the neutral state. The panel shows the test scenario list (loaded from `~/.kissmp_debug/test_scenarios/` recursively) and a "New Test Scenario" button. The game behaves normally. This is what you see when you open the panel without doing anything.

**Edit** is entered by clicking "New Test Scenario" from Inactive. The capture buffer becomes active and the inspector populates as the user explicitly adds spawned vehicles to the test scenario via an "Add to Test Scenario" button (vehicles are never auto-added — this avoids accidentally including throwaway test cars). The inspector shows captured vehicles as rows with editable fields; edits to position, rotation, and named state fields update the live spawned vehicle in real time. Velocity edits are visualized as draggable arrow gizmos in 3D since they don't manifest visually while paused. Saving the test scenario triggers a global pause across all instances, allowing the user to confirm or tweak captured values, then resume. On Save, the user chooses whether captured vehicles stay in the scene or despawn. Non-captured vehicles are never touched. Discard exits without writing a file; vehicles stay in place.

**Run** executes a loaded test scenario. Both BeamNG instances spawn the test scenario's vehicles, the diff broker activates, ghosts of the other instance overlay the local view in color-coded form (green/yellow/red by divergence magnitude), and a forward-only timeline controls playback (play/pause/speed/step-forward/restart/bookmark). Recording is opt-in via a "Record logs" checkbox under the Play button or a `--record` CLI flag at launch. Recording starts after both instances confirm ready and stops on manual Stop, test scenario end, or mode exit. Pauses during recording insert a paused-marker rather than recording duplicate frames.

**Review** is entered by opening a `.log` file from Inactive. The game pauses, the recording's vehicle ghosts render at the timeline cursor, and full bidirectional scrubbing is available — there's no live simulation to fight with, just bytes from a file. This mode requires no server connection, no second instance, and arguably no KissMP at all. It's the "study what happened" counterpart to Run's "do desync engineering."

Mode transitions are constrained: Run ↔ Review directly is disallowed to avoid ambiguous states; transitions go through Inactive. Entering Run or Review takes ownership of the scene; exiting returns to a clean Inactive.

### Forward-only timeline (and why)

Run mode's timeline is forward-only. There is no rewind. To revisit an earlier moment, you restart the test scenario and fast-forward to it (or jump to a bookmark, which does the same thing under the hood).

This is not a limitation worked around — it's the correct design. BeamNG's soft-body simulator can't be rewound without either lossy approximation (rigid-body teleport that silently loses deformation state — exactly the kind of subtle wrongness that wastes desync investigation hours) or expensive snapshotting (engineering work that distracts from the goal). Forward-only is honest: what you see is what was actually simulated.

The non-determinism caveat — that BeamNG isn't bit-identical across runs — is not a bug here, it's the problem domain. The whole point of KissMP's sync engineering is to handle two non-deterministic clients agreeing visually. The tool exercises exactly the conditions the code under test must survive. A bit-identical replay would be lying about reality.

Review mode, by contrast, plays back a recording — bytes from a file, not a re-simulation — so bidirectional scrubbing there is fine and trivial to implement.

### Test Scenario format

Test Scenarios are YAML files with the extension `.testscenario.yaml` (e.g., `tBoneCollision.testscenario.yaml`). Recognizable at a glance, conventional, no special tooling needed to read or edit.

A test scenario contains:

- `name`, optional `description`
- `server`: target server URL — hardcoded by the author, since desyncs often only manifest against a specific server's latency profile. Overridable at the CLI via `--server` for cases where running against a different target is useful, but the file's value is the default.
- `players`: list of identities the test scenario expects (looked up against the local `kissmp_debug` identity config; missing identities → clear error at load time)
- `map`: BeamNG map name
- `vehicles`: list of vehicle entries with `name`, `model`, `config`, `pos`, `rot`, `velocity`, optional `color`, optional `state` block for promoted named fields (tilt deck angle, etc.), optional `post_load` Lua snippet for arbitrary mod-specific setup, and a `role` field marking entrypoint/passive
- `couplings`: list of trailer/tractor pairings to establish after all vehicles are ready
- Optional version-pinning fields when the author chooses to record them (KissMP version, mod hashes); permissive when omitted

The `post_load` Lua snippet pattern is the deliberate escape hatch for arbitrary state restoration — anything the system doesn't natively know how to capture (deck angles, ramp positions, fuel levels, etc.) is set by a small inline Lua snippet executed at one of four hooks: `on_spawn`, `on_ready`, `post_settle`, test scenario-level `post_load`. The snippets are direct, not ugly: a config file containing the same language as the code under test, where the dependency on a specific mod's API surface is self-documenting and breaks loudly with a clear error if the mod changes.

### Log format

Logs are flat binary, custom format, readable only by KISSDebug and `kissmp_debug` (no general-purpose inspectability — performance and density first, since recording is at physics rate).

Each log is self-describing: a header containing test scenario name, test scenario hash, recording start timestamp, KissMP/KISSDebug/BeamNG versions, server URL, the full original test scenario YAML embedded inline (a few KB, makes the log a complete standalone artifact), tick rate, list of recorded fields per vehicle. After the header, frame records at physics rate.

Each frame uses the **unified vehicle list with per-instance missing flags** representation: one row per vehicle per tick with explicit flags marking which instances saw it. This pre-correlates the data into the shape every query wants ("when did instance B lose vehicle 3?") and loses no information versus per-instance-independent lists.

Logs live alongside their test scenarios with `.log` extension. When recording is enabled, filenames include a timestamp to avoid overwriting (`tBoneCollision.20260413_143022.log`); a symlink or copy at `tBoneCollision.latest.log` points to the most recent.

### Bridge protocol

KISSDebug ↔ `kissmp_debug` communicate over a localhost TCP socket using JSON (with `serde_derive` on the Rust side, BeamNG's built-in JSON on the Lua side). At command rate this is overkill; at state-streaming rate it's adequate and the inspectability during development is worth more than the marginal performance.

Every message uses the envelope `{type: "...", protocol_version: N, payload: {...}}`. On connect, both sides exchange a handshake including their protocol version; mismatch logs a clear error and refuses the connection. ~20 lines of code, prevents an entire category of future headaches.

### Hot-reloading KissMP Lua code

A primary motivation for the toolchain: eliminating the restart-the-game loop when iterating on KissMP's own Lua mod code.

KissMP's client-side Lua runs as BeamNG extensions. BeamNG's extension system already supports `extensions.reload("moduleName")`, which unloads the module (calls `onExtensionUnloaded` if defined), wipes `package.loaded["moduleName"]`, and re-`require`s it. This is the mechanism KISSDebug builds on.

**File watching.** KISSDebug monitors KissMP's Lua source files for changes. When a file's modification time changes, KISSDebug triggers a reload of the affected module(s). The watcher runs as a Lua-side poll (checking `lfs.attributes(path, "modification")` every N frames) — lightweight, no external dependencies, cross-platform. The poll interval is configurable but defaults to something frequent enough that saves feel instant (~0.5s).

**State preservation across reloads.** Naive `extensions.reload()` destroys all module-local state. KissMP's Lua code holds live state: vehicle ownership mappings, the socket connection to the connector, sync state per vehicle, queued messages. To survive a reload, KISSDebug provides a state-stash convention: before reload, it calls a `onPreReload()` hook (if the module defines one) that serializes critical state into a global table (`_G.__kissmp_reload_state`). After reload, the module's init path checks for that table and rehydrates from it instead of starting fresh. Modules that don't define `onPreReload` get a cold reload — they reinitialize from scratch, which is safe for stateless utility modules.

**Event handler re-registration.** The most common reload bug: stacking duplicate event callbacks. Every KissMP module that registers `M.onVehicleSpawned`, `M.onUpdate`, etc. must deregister cleanly in `onExtensionUnloaded` before the new version re-registers. KISSDebug can't enforce this automatically (it doesn't own KissMP's code), but it logs a warning when it detects a module being reloaded that doesn't define `onExtensionUnloaded` — a signal to the developer that the module may stack handlers.

**Socket connection survival.** The most delicate piece. KissMP holds a live socket to the Rust connector. On reload, the socket handle must either be stashed in `_G` and adopted by the new code, or torn down and reconnected. The recommended approach: stash the handle, have the reloaded module adopt it, and add a reconnect-on-error path so that if the adoption fails (e.g., the connector restarted independently), the module reconnects cleanly rather than crashing. This reconnect path is valuable even outside the reload story — it handles connector crashes gracefully.

**In-game code editor.** KISSDebug includes an in-game code editor panel built on Monaco (the VS Code editor engine) or CodeMirror 6, embedded in a BeamNG UI app. It provides Lua syntax highlighting, basic autocomplete, find/replace, and error markers. The editor can open any file from KissMP's Lua source tree or KISSDebug's own source. On save (Ctrl+S), the editor writes the file to disk, triggers the file watcher (or calls reload directly), and pipes any Lua load errors back as inline error markers on the offending line. The edit-save-reload-see-error cycle stays entirely in-game — no alt-tabbing to an external editor required.

The editor is a convenience, not a requirement. The file watcher works with any external editor. Developers who prefer VS Code, Neovim, or anything else simply edit the files externally and the watcher picks up the changes. The in-game editor exists for quick tweaks and for situations where alt-tabbing is impractical (e.g., iterating while observing a live desync in Run mode).

### Cross-platform

Both `kissmp_debug` and KISSDebug target Windows and Linux. Primary testing is currently Windows (where most KissMP players are). Platform-specific concerns — process spawning for the two-instance launcher, file watching for the edit-reload loop, BeamNG userpath conventions — are isolated behind small platform-abstraction layers in the Rust binary.

### What's deliberately out of scope

Several things were considered and explicitly excluded:

- **AI-driven path-following vehicles** — KissMP test scenarios involve player-driven cars, not AI. Path recording adds complexity for a use case that doesn't exist here.
- **REPL patching of live mod code** — interesting but redundant with the edit-watch-reload loop and an in-game code editor (both planned for later phases). The REPL would be a third way to do something that already has two good ways.
- **Bundled test scenario archives** (zip with paths and reference logs) — mods come from the server, so the server URL implicitly pins the mod set. Bare `.testscenario.yaml` files are sufficient; reference logs travel separately when needed.
- **Friend-on-another-machine for the second instance** — useful eventually but adds significant complexity (cross-machine diff broker peering, network configuration). Two local instances against a remote server cover the primary workflow.
- **Full soft-body state capture** — too expensive, too coupled to engine internals. Position/rotation/velocity/named-state-fields plus the `post_load` escape hatch covers practical cases. Damage state similarly: default to pristine vehicles; use a "drive into a wall" pre-roll if a damaged starting state is needed.
- **CI integration with regression test scenarios** — a year-two ambition once the format and tooling are stable.

---

## Part II — Implementation roadmap

Phased build order. Each phase ends with a working, useful subset — no phase is purely scaffolding. Estimated effort assumes evening/weekend work from someone familiar with both KissMP and BeamNG modding. Stop at any phase that's "good enough" for your current needs.

### Phase 0 — Hook surface in KISSMultiplayer

Add `external_hooks.lua` (or similarly-named module) to KissMP proper. Initial API: register externally-spawned vehicle as locally-owned, subscribe to vehicle state changes, query current vehicle list and ownership. Document the hook surface in the KissMP repo so it's a deliberate API contract, not an implicit dependency.

Get this merged before starting Phase 1 — KISSDebug depends on it.

*Effort: small. A few hundred lines, mostly thin wrappers around existing internals.*

### Phase 1 — KISSDebug skeleton + Inactive mode

Create the KISSDebug repo. Build the BeamNG mod skeleton: extension registration, panel UI app (Vue/Angular under `ui/modules/apps/kissDebug`), mode indicator, test scenario list reading from `~/.kissmp_debug/test_scenarios/` recursively. No test scenario loading yet, no editor, no player — just "open the panel, see the list, mode indicator says Inactive."

Establish the bridge protocol envelope and a stub handshake with `kissmp_debug` (which doesn't exist yet — this is the placeholder). Lua side reads/writes JSON over a localhost socket; the connection is optional, panel works without it.

*Effort: a few evenings. Most of it is BeamNG UI app boilerplate.*

### Phase 2 — Edit mode (single-instance authoring)

Implement Edit mode end-to-end without any multi-instance or networking concerns. Capture buffer, "Add to Test Scenario" button per spawned vehicle, inspector panel with live-updating editable fields for position/rotation/velocity, velocity gizmo in 3D, pause-on-save flow with confirm/resume, YAML serialization to disk.

At this phase, test scenarios save and load on a single instance — loading a test scenario means spawning its vehicles in the current game with the right initial state. No diff visualization yet, no two-instance launching. But you can already author test scenarios and share `.testscenario.yaml` files with other developers who can load them in-game and see the same setup.

Implement `post_load` Lua snippet execution at all four hooks. Implement coupling restoration after vehicle ready. Test specifically with tilt deck trailers since that's a known-important case.

*Effort: 1–2 weeks. The pause-on-save flow and inspector live updates are the trickier pieces; coupling restoration timing has its own gotchas.*

### Phase 3 — `kissmp_debug` binary skeleton + test scenario YAML parsing

Create the `kissmp_debug` Rust repo. Implement the CLI subcommand structure (`run`, `capture`, `replay`, `record`, `diff`), test scenario YAML parsing with `serde_derive`, identity config loading from `~/.kissmp_debug/identities.yaml`, and the bridge protocol server side.

`kissmp_debug run example.testscenario.yaml` at this phase: launches one BeamNG instance with the right identity, instructs KISSDebug over the bridge to load the test scenario, exits when the user closes the game. Single instance only — no diff yet.

This is the phase where the Rust↔Lua bridge gets exercised for real; iron out protocol bugs here before adding the second instance.

*Effort: 1 week. Mostly straightforward Rust glue; the BeamNG launching across platforms is the fiddliest bit.*

### Phase 4 — Two-instance launching

`kissmp_debug` launches two BeamNG instances with separate userpaths (so they have independent KissMP identities and don't fight over config files). Both connect to the test scenario's server. Both load the test scenario. Coordinate the spawn so vehicles appear in the right order with the right ownership.

No diff visualization or recording yet — just "two instances, same test scenario, both running, you can drive on one and watch the other client's view in the second window." Already useful for ad-hoc desync observation.

*Effort: 1 week. Process orchestration, userpath management, ready-coordination handshake.*

### Phase 5 — Diff broker + live ghost overlays

Implement the diff broker inside `kissmp_debug`. Both KISSDebug instances stream their per-vehicle state to the broker every tick over the bridge. The broker correlates against a shared timestamp, computes per-vehicle divergence, and rebroadcasts each instance's view of the world to the other instance. KISSDebug renders the received "other view" as ghost overlays using BeamNG's debug draw API (wireframe boxes at vehicle origins, lines connecting key nodes, color-coded by divergence magnitude). HUD shows numeric deltas per vehicle.

This is the headline feature. After this phase, you can launch a test scenario, drive around, and see desync visualized in real time as colored ghosts diverging from your local view. The basic Run mode is functional.

*Effort: 1–2 weeks. The state streaming and correlation are straightforward; the ghost rendering and tuning the visual language (what colors, what thresholds, what to show on the HUD) takes iteration.*

### Phase 6 — Run mode timeline + recording

Add the forward-only timeline UI to Run mode: play/pause/speed/step-forward/restart/bookmark. Wire pause bidirectionally with BeamNG's native pause control via a single source of truth in KISSDebug. Implement the "Record logs" checkbox and `--record` CLI flag.

Implement the binary log format: header with all standalone-interpretability fields and embedded test scenario YAML, frame records with unified vehicle list and missing flags, timestamped filenames with `.latest.log` symlink/copy.

Recording starts after both instances confirm ready; stops on Stop, test scenario end, or mode exit; pause inserts paused-markers.

*Effort: 1 week. Timeline UI is a few days; log format is a day; integration and edge cases (what if recording-enabled test scenario fails to start, what if one instance disconnects mid-record) take the rest.*

### Phase 7 — Review mode

Build Review mode: open a `.log` file from Inactive, game pauses, ghosts render the recorded state at the timeline cursor, full bidirectional scrubbing. Reuse the timeline widget from Run mode with a different control set underneath. Reuse the ghost rendering from live mode, fed from the log file instead of the bridge.

After this phase the toolchain is functionally complete for the core desync workflow: author, run, record, replay.

*Effort: a few days. Most of the rendering and UI infrastructure already exists from earlier phases; this is mostly wiring.*

### Phase 8 — Hot-reload file watcher

Implement the edit-watch-reload loop for KissMP's Lua source files. This is the feature that eliminates the "quit BeamNG, edit code, relaunch, reconnect, re-drive to the test spot" cycle.

KISSDebug polls KissMP's Lua source directory for file modification time changes (via `lfs.attributes`). On change, it identifies the affected module(s), calls `onPreReload()` on each (if defined) to stash critical state into `_G.__kissmp_reload_state`, triggers `extensions.reload()`, and verifies the reload succeeded. Errors are caught via `pcall` and surfaced in the KISSDebug panel with the filename and line number.

This phase also requires auditing KissMP's Lua modules for reload safety: every module that registers event handlers (`M.onVehicleSpawned`, `M.onUpdate`, etc.) needs a clean `onExtensionUnloaded` that deregisters them. Modules that hold live state (vehicle mappings, socket connections, sync queues) need `onPreReload` / rehydration paths. The socket connection to the Rust connector gets stashed in `_G` and adopted by the reloaded code, with a reconnect-on-error fallback.

After this phase, you can edit KissMP Lua files in any external editor (VS Code, Neovim, whatever) and see changes take effect in-game within ~0.5s of saving, without restarting BeamNG or losing your server connection. Already transformative for iteration speed.

*Effort: 1 week. The file watcher itself is a few hours; the bulk of the work is auditing KissMP's modules for reload safety — adding `onExtensionUnloaded`, identifying what state needs stashing, and testing that the reloaded modules actually work correctly. Socket adoption is the trickiest single piece.*

### Phase 9 — Polish and quality-of-life

Things worth adding once the core works:

- Bookmark feature in Run mode (mark current time, jump back to it via restart-and-fast-forward)
- Divergence-spike auto-detection ("jump to next divergence > threshold" hotkey)
- Inspector panel improvements (arrow gizmos for velocity, drag handles for position in 3D)
- "Save and Run" shortcut from Edit mode (skip the trip through Inactive)
- Test scenario list filtering and search
- Better error messages when identities, server, or required mods are missing

### Phase 10 — In-game code editor

A Monaco or CodeMirror 6 editor embedded as a BeamNG UI app panel in KISSDebug. Opens files from KissMP's Lua source tree, KISSDebug's own source, or test scenario `post_load` snippets. Provides Lua syntax highlighting, basic autocomplete, find/replace, and multi-cursor editing.

On Ctrl+S: writes the buffer to disk, triggers the file watcher's reload path (from Phase 8), and pipes any Lua load errors back as inline red markers on the offending line. The entire edit-save-reload-see-error cycle stays in-game.

The editor is a convenience layer on top of Phase 8's file watcher, not a replacement. Developers who prefer external editors continue using them — the file watcher doesn't care who wrote the file. The in-game editor exists for quick tweaks and for situations where alt-tabbing is impractical (e.g., iterating on sync logic while observing a live desync in Run mode on the same screen).

*Effort: 1–2 weeks. Embedding Monaco/CodeMirror in BeamNG's CEF is the main unknown — the editors are designed for web embedding so it should work, but BeamNG's CEF version and sandbox quirks may need workarounds. The Lua↔UI bridge for file read/write/error-piping is straightforward.*

### Phase 11 — Standalone review viewer (optional, deferred)

A web-based replay viewer (Three.js + standalone HTML) that opens `.log` files outside BeamNG entirely. Useful for sharing logs with people who don't want to install KISSDebug, for embedding in bug reports, for CI artifact viewing. Not essential — Review mode in-game covers the primary use case — but a nice eventual addition.

---

## Appendix — Quick reference

**Components**
- `KISSMultiplayer` — main mod, gains `external_hooks.lua`
- `KISSDebug` — separate BeamNG mod, in-game UI and logic
- `kissmp_debug` — Rust CLI binary, orchestrator

**Modes**
- Inactive (gray) — test scenario list, neutral
- Edit (yellow) — capture buffer active, inspector live, save/discard
- Run (red) — running test scenario, live diff, forward timeline, optional recording
- Review (blue) — log playback, free scrub, no live simulation

**Key files**
- `~/.kissmp_debug/test_scenarios/` — default test scenario library, recursive
- `~/.kissmp_debug/identities.yaml` — KissMP identity credentials
- `*.testscenario.yaml` — test scenario definition
- `*.log` — binary recording, self-describing header

**CLI**
- `kissmp_debug run <test_scenario>` — load and run, optionally `--record` and `--server`
- `kissmp_debug capture <name>` — start authoring session
- `kissmp_debug replay <log>` — open log in Review mode
- `kissmp_debug record <test_scenario>` — run and record in one step
- `kissmp_debug diff <log_a> <log_b>` — side-by-side comparison

**Bridge protocol envelope**
```json
{ "type": "...", "protocol_version": 1, "payload": { ... } }
```

**Test Scenario file extension**: `.testscenario.yaml`
**Log file extension**: `.log`
