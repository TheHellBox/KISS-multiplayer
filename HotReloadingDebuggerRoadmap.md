# KISS Debug Toolchain Roadmap

This document lays out the plan for building the KISS multiplayer debugger toolchain. The work proceeds in phases, each producing a working, useful subset — no phase is purely scaffolding. Stop at any phase that's "good enough" for your current needs.

Each phase builds on the previous one. Don't skip ahead — the dependencies are real, and the early phases produce immediately useful tools even if the full vision isn't complete.

For detailed design rationale, protocol specs, and implementation notes, see `HotReloadingDebugger.md`. This roadmap is the actionable checklist; that document is the deep dive.

---

## Roadmap

- [ ] **Phase 0** — Hook surface in KISSMultiplayer
  - [ ] Add `external_hooks.lua` module to KissMP proper
  - [ ] Implement initial API:
    - [ ] Register externally-spawned vehicle as locally-owned
    - [ ] Subscribe to vehicle state changes
    - [ ] Query current vehicle list and ownership
  - [ ] Document the hook surface in the KissMP repo (deliberate API contract, not implicit dependency)
  - [ ] Get merged before starting Phase 1
  - [ ] *Effort: small (a few hundred lines, mostly thin wrappers)*

- [ ] **Phase 1** — KISSDebug skeleton + Inactive mode
  - [ ] Create the KISSDebug repo
  - [ ] Build BeamNG mod skeleton:
    - [ ] Extension registration
    - [ ] Panel UI app (Vue/Angular under `ui/modules/apps/kissDebug`)
    - [ ] Mode indicator (color-coded: gray, yellow, red, blue)
    - [ ] Test scenario list reading from `~/.kissmp_debug/test_scenarios/` recursively
  - [ ] Establish bridge protocol envelope (`{type: "...", protocol_version: N, payload: {...}}`)
  - [ ] Implement stub handshake with `kissmp_debug` (placeholder, connection optional)
  - [ ] Lua side reads/writes JSON over localhost socket
  - [ ] Panel works without `kissmp_debug` connection (standalone subset)
  - [ ] *Effort: a few evenings (mostly BeamNG UI app boilerplate)*

- [ ] **Phase 2** — Edit mode (single-instance authoring)
  - [ ] Implement Edit mode end-to-end (no multi-instance/networking yet)
  - [ ] Capture buffer for "Add to Test Scenario"
  - [ ] "Add to Test Scenario" button per spawned vehicle (never auto-add)
  - [ ] Inspector panel with live-updating editable fields:
    - [ ] Position
    - [ ] Rotation
    - [ ] Velocity (with 3D arrow gizmo)
    - [ ] Named state fields (tilt deck angle, etc.)
  - [ ] Pause-on-save flow:
    - [ ] Global pause across all instances on Save
    - [ ] Confirm/tweak captured values
    - [ ] Resume
  - [ ] On Save: user chooses whether captured vehicles stay or despawn
  - [ ] Discard exits without writing file (vehicles stay in place)
  - [ ] YAML serialization to disk (`.testscenario.yaml` format)
  - [ ] Test scenario loading (spawn vehicles with right initial state)
  - [ ] Implement `post_load` Lua snippet execution at all four hooks:
    - [ ] `on_spawn`
    - [ ] `on_ready`
    - [ ] `post_settle`
    - [ ] Test scenario-level `post_load`
  - [ ] Implement coupling restoration after vehicle ready
  - [ ] Test specifically with tilt deck trailers
  - [ ] *Effort: 1–2 weeks (pause-on-save flow, inspector live updates, coupling timing)*

- [ ] **Phase 3** — `kissmp_debug` binary skeleton + YAML parsing
  - [ ] Create the `kissmp_debug` Rust repo
  - [ ] Implement CLI subcommand structure:
    - [ ] `run`
    - [ ] `capture`
    - [ ] `replay`
    - [ ] `record`
    - [ ] `diff`
  - [ ] Test scenario YAML parsing with `serde_derive`
  - [ ] Identity config loading from `~/.kissmp_debug/identities.yaml`
  - [ ] Bridge protocol server side
  - [ ] `kissmp_debug run <scenario>.yaml`:
    - [ ] Launches one BeamNG instance with right identity
    - [ ] Instructs KISSDebug over bridge to load test scenario
    - [ ] Exits when user closes game
  - [ ] Iron out protocol bugs before adding second instance
  - [ ] *Effort: 1 week (BeamNG launching across platforms is fiddliest bit)*

- [ ] **Phase 4** — Two-instance launching
  - [ ] `kissmp_debug` launches two BeamNG instances with separate userpaths
    - [ ] Independent KissMP identities
    - [ ] No config file conflicts
  - [ ] Both instances connect to test scenario's server
  - [ ] Both load the test scenario
  - [ ] Coordinate spawn so vehicles appear in right order with right ownership
  - [ ] Ready-coordination handshake
  - [ ] Already useful for ad-hoc desync observation (no diff viz yet)
  - [ ] *Effort: 1 week (process orchestration, userpath management)*

- [ ] **Phase 5** — Diff broker + live ghost overlays
  - [ ] Implement diff broker inside `kissmp_debug`
  - [ ] Both KISSDebug instances stream per-vehicle state to broker every tick
  - [ ] Broker correlates against shared timestamp
  - [ ] Broker computes per-vehicle divergence
  - [ ] Broker rebroadcasts each instance's view to the other
  - [ ] KISSDebug renders "other view" as ghost overlays:
    - [ ] Wireframe boxes at vehicle origins (BeamNG debug draw API)
    - [ ] Lines connecting key nodes
    - [ ] Color-coded by divergence magnitude (green/yellow/red)
  - [ ] HUD shows numeric deltas per vehicle
  - [ ] Tune visual language (colors, thresholds, what to show)
  - [ ] Run mode functional after this phase
  - [ ] *Effort: 1–2 weeks (ghost rendering and tuning takes iteration)*

- [ ] **Phase 6** — Run mode timeline + recording
  - [ ] Add forward-only timeline UI to Run mode:
    - [ ] Play
    - [ ] Pause
    - [ ] Speed control
    - [ ] Step-forward
    - [ ] Restart
    - [ ] Bookmark (mark current time, jump back via restart-and-fast-forward)
  - [ ] Wire pause bidirectionally with BeamNG's native pause control
  - [ ] Single source of truth in KISSDebug for pause state
  - [ ] Implement "Record logs" checkbox
  - [ ] Implement `--record` CLI flag
  - [ ] Binary log format:
    - [ ] Header with standalone-interpretability fields
    - [ ] Embedded test scenario YAML (makes log complete artifact)
    - [ ] Frame records with unified vehicle list and missing flags
    - [ ] Timestamped filenames (`.latest.log` symlink/copy)
  - [ ] Recording starts after both instances confirm ready
  - [ ] Recording stops on Stop, test scenario end, or mode exit
  - [ ] Pause inserts paused-markers (not duplicate frames)
  - [ ] Handle edge cases:
    - [ ] Recording-enabled test scenario fails to start
    - [ ] One instance disconnects mid-record
  - [ ] *Effort: 1 week (timeline UI, log format, integration)*

- [ ] **Phase 7** — Review mode
  - [ ] Open `.log` file from Inactive
  - [ ] Game pauses
  - [ ] Ghosts render recorded state at timeline cursor
  - [ ] Full bidirectional scrubbing (no live sim to fight)
  - [ ] Reuse timeline widget from Run mode
  - [ ] Reuse ghost rendering from live mode (fed from log file)
  - [ ] No server connection required
  - [ ] No second instance required
  - [ ] No KissMP required (standalone review)
  - [ ] Toolchain functionally complete after this phase
  - [ ] *Effort: a few days (reuse existing infrastructure)*

- [ ] **Phase 8** — Hot-reload file watcher
  - [ ] Implement edit-watch-reload loop for KissMP's Lua source files
  - [ ] KISSDebug polls KissMP's Lua source directory for mtime changes (`lfs.attributes`)
  - [ ] On file change:
    - [ ] Identify affected module(s)
    - [ ] Call `onPreReload()` if defined (stash state to `_G.__kissmp_reload_state`)
    - [ ] Trigger `extensions.reload()`
    - [ ] Verify reload succeeded via `pcall`
    - [ ] Surface errors in KISSDebug panel with filename and line number
  - [ ] Audit KissMP's Lua modules for reload safety:
    - [ ] Every module with event handlers needs clean `onExtensionUnloaded`
    - [ ] Deregister handlers in `onExtensionUnloaded` (prevent stacking)
    - [ ] Log warning when module being reloaded lacks `onExtensionUnloaded`
    - [ ] Modules with live state need `onPreReload` / rehydration paths:
      - [ ] Vehicle ownership mappings
      - [ ] Socket connection to connector
      - [ ] Sync state per vehicle
      - [ ] Queued messages
  - [ ] Socket connection survival:
    - [ ] Stash handle in `_G`
    - [ ] Reloaded module adopts handle
    - [ ] Add reconnect-on-error path (handles connector crashes gracefully)
  - [ ] Poll interval configurable (default ~0.5s, frequent enough that saves feel instant)
  - [ ] Works with any external editor (VS Code, Neovim, etc.)
  - [ ] *Effort: 1 week (file watcher is easy; module audit is the bulk)*

- [ ] **Phase 9** — Polish and quality-of-life
  - [ ] Divergence-spike auto-detection (hotkey: "jump to next divergence > threshold")
  - [ ] Inspector panel improvements:
    - [ ] Arrow gizmos for velocity
    - [ ] Drag handles for position in 3D
  - [ ] "Save and Run" shortcut from Edit mode (skip trip through Inactive)
  - [ ] Test scenario list filtering and search
  - [ ] Better error messages when identities, server, or required mods are missing
  - [ ] *Effort: ongoing (nice-to-haves)*

- [ ] **Phase 10** — In-game code editor
  - [ ] Monaco or CodeMirror 6 editor embedded as BeamNG UI app panel
  - [ ] Opens files from:
    - [ ] KissMP's Lua source tree
    - [ ] KISSDebug's own source
    - [ ] Test scenario `post_load` snippets
  - [ ] Features:
    - [ ] Lua syntax highlighting
    - [ ] Basic autocomplete
    - [ ] Find/replace
    - [ ] Multi-cursor editing
  - [ ] On Ctrl+S:
    - [ ] Write buffer to disk
    - [ ] Trigger file watcher's reload path
    - [ ] Pipe Lua load errors back as inline red markers on offending line
  - [ ] Entire edit-save-reload-see-error cycle stays in-game
  - [ ] Convenience layer on top of Phase 8 (not replacement)
  - [ ] External editors still work (file watcher doesn't care who wrote the file)
  - [ ] Embedding challenges:
    - [ ] Monaco/CodeMirror in BeamNG's CEF
    - [ ] BeamNG CEF version and sandbox quirks
  - [ ] Lua↔UI bridge for file read/write/error-piping
  - [ ] *Effort: 1–2 weeks (embedding is the main unknown)*

- [ ] **Phase 11** — Standalone review viewer (optional, deferred)
  - [ ] Web-based replay viewer (Three.js + standalone HTML)
  - [ ] Opens `.log` files outside BeamNG entirely
  - [ ] Useful for:
    - [ ] Sharing logs with people who don't want KISSDebug installed
    - [ ] Embedding in bug reports
    - [ ] CI artifact viewing
  - [ ] Not essential — Review mode in-game covers primary use case
  - [ ] *Effort: TBD (future enhancement)*

---

## Component architecture

| Component | Description | Dependencies |
|---|---|---|
| **KISSMultiplayer** (existing) | Gains `external_hooks.lua` module | None |
| **KISSDebug** (new repo, BeamNG mod) | In-game debugger UI, four modes, ghost overlays, capture, timeline | KISSMultiplayer hooks |
| **`kissmp_debug`** (new repo, Rust binary) | CLI, two-instance launcher, diff broker, log writer, YAML parser | None |

## Mode transitions

- **Inactive** (gray) → **Edit** (yellow): click "New Test Scenario"
- **Edit** (yellow) → **Inactive** (gray): Discard or Save + despawn
- **Inactive** (gray) → **Run** (red): select test scenario + Run
- **Inactive** (gray) → **Review** (blue): open `.log` file
- Run ↔ Review directly: disallowed (transition through Inactive)

## Test scenario format (`.testscenario.yaml`)

- `name`, optional `description`
- `server`: target server URL (overridable via `--server`)
- `players`: list of expected identities
- `map`: BeamNG map name
- `vehicles`: list with `name`, `model`, `config`, `pos`, `rot`, `velocity`, optional `color`, `state`, `post_load`, `role`
- `couplings`: trailer/tractor pairings
- Optional version-pinning (KissMP version, mod hashes)

## Log format

- Flat binary, custom format (performance and density first)
- Self-describing header: test scenario name/hash, timestamp, versions, server URL, embedded test scenario YAML, tick rate, field list
- Frame records at physics rate with unified vehicle list + per-instance missing flags
- Timestamped filenames (`.latest.log` symlink/copy)

---

## What's out of scope

- AI-driven path-following vehicles (KissMP scenarios are player-driven)
- REPL patching of live mod code (redundant with edit-watch-reload + in-game editor)
- Bundled test scenario archives (server URL pins mod set)
- Friend-on-another-machine for second instance (adds cross-machine diff broker peering)
- Full soft-body state capture (too expensive; use `post_load` escape hatch)
- CI integration with regression tests (year-two ambition)