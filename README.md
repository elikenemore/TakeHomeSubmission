# Cave-Game Take-Home — Enemy Spawner

Submission for the WKEY Studios Gameplay Engineer take-home (LUAU programmer, due 2026-04-26).

## What it does

- A **50 × 50 stud slate platform** sits at the origin (defined in
  `default.project.json` so a fresh `rojo build` produces a complete
  place); enemies spawn on top of it.
- **1 enemy / second**, capped at **20 concurrent** by default; both values are
  live-tunable from an in-game **HUD panel** (per-player UI sends to a
  server-authoritative settings remote).
- Each enemy gets a **random color, material, scale, and name** rolled once
  on the server and replicated by index — every client renders identical
  visuals.
- Enemies **chase the closest player who is on the platform** and ignore
  anyone off it. Within attack range they play the default Zombie attack
  animation, fire a smash VFX, and deal damage on a per-archetype cooldown.
- **Wander when no target.** With no on-platform players, enemies pick a
  random point on the platform and stroll there at half walk speed.
- Each enemy carries a **unique numeric ID** consistent on both sides.
  Clicking an enemy (raycast on the local rig) prints the ID on the client
  *and* fires a server remote that prints it on the server.
- A red **Kill All Enemies** button on the HUD wipes every enemy via a
  reliable remote.

## Architecture

One-script hierarchy as recommended in the brief.

```
ReplicatedStorage/Shared/
  Constants.lua        -- frozen config (sizes, rates, anim ids, remote names)
  RemoteService.lua    -- lazy create/get for RemoteEvents, UnreliableRemoteEvents, RemoteFunctions
  EnemyVariants.lua    -- material/name pools + Roll(rng) -> variant

ServerScriptService/Game/
  Bootstrap.server.lua       -- one Script that requires every Service ModuleScript
  Services/
    PlatformService.lua      -- reads Workspace.Platform; on-platform / clamping / random-spawn helpers
    EnemyService.lua         -- spawn loop, chase AI, attack, custom replication

StarterPlayer/StarterPlayerScripts/Game/
  Bootstrap.client.lua       -- one LocalScript that requires every Controller ModuleScript
  Controllers/
    EnemyController.lua      -- builds R6 rigs locally, lerps positions, click raycast
    UIController.lua         -- HUD panel and Kill All
```

Each Service / Controller exposes `Init()` and `Start()`. `Init` is for local
state only; cross-module wiring happens in `Start` so order is irrelevant.

## Custom replication (the interesting part)

The brief weights heavily on the network `Recv` stat, so default Roblox
replication is bypassed for enemies entirely.

- **Server holds no enemy parts.** Each enemy lives only as a Lua table
  (`id, position, yaw, state, variant, health`). Position is updated every
  Heartbeat against the closest on-platform player; clamped to the platform
  rect. No physics, no Workspace touch.
- **Spawn / despawn / attack** events go through reliable RemoteEvents with
  small payloads (id + variation indices, not models or full descriptions).
- **Position + state** are batched and sent at **10 Hz** over an
  **UnreliableRemoteEvent** — losing a packet just means the next one
  refreshes you 100 ms later, which is exactly what unreliable remotes are
  for.
- **Each enemy = 11 bytes** packed into a single `buffer`:

  | bytes | field   | encoding                                     |
  | ----- | ------- | -------------------------------------------- |
  | 0..1  | id      | `u16`                                        |
  | 2     | state   | `u8` (0=idle, 1=walk, 2=attack)              |
  | 3..4  | x       | `i16`, fixed-point (1 stud = 100, ≈1 cm)     |
  | 5..6  | y       | `i16`                                        |
  | 7..8  | z       | `i16`                                        |
  | 9..10 | yaw     | `i16` mapped to `[-π, π]`                    |

  At 20 enemies × 10 Hz that is `(2 + 20·11) · 10 = 2,220 B/s` of position
  payload per client, with no per-part property syncing on top.
- **Chunked broadcast.** UnreliableRemoteEvent caps at ~900 bytes per packet
  (one MTU). At 11 bytes/enemy that's ~80 max per packet, so the broadcast
  splits into 80-enemy chunks above that. Each chunk is self-describing
  (count header), so the client decoder is unchanged.
- **Delta encoding.** An enemy is only included in a packet if its
  position / yaw / state changed beyond a threshold since the last send,
  with a 1-second force-resend interval as a safety net for dropped packets.
- **Late-join** is handled by a `RemoteFunction` (`GetInitialState`) that
  returns current settings + a snapshot of every live enemy. A new client
  hydrates from this snapshot, then keeps up via the position stream.

## Server scalability

Default-cap (20 enemies) is trivial. The system is built to scale far past
that with bounded cost:

- **Fixed-rate AI tick.** AI runs at 20 Hz via a Heartbeat accumulator,
  decoupled from frame rate. Each tick is sized to fit a hard CPU budget.
- **Active AI cap.** At most 60 enemies run full chase logic per tick,
  ranked by distance to the closest player. Far enemies hold pose. Cost
  stays flat regardless of total population.
- **Spatial hash separation.** The per-tick pile-up problem (every enemy
  pushing on every other) becomes O(N) instead of O(N²) by bucketing into
  8-stud cells and only checking the 9 surrounding cells per enemy.
- **Cached closest-player.** Each enemy refreshes its closest-player
  scan every 0.2 s and reads the cached target's HRP cheaply in between.
- **Performance mode toggle.** A button on the HUD flips a flag that:
  - **Client:** strips name tags + animators on every existing rig and
    skips them on new spawns; cancels camera shake and smash VFX.
    Toggling off restores name tags + animators on all live rigs.
  - **Server:** skips the spatial hash rebuild and short-circuits the
    separation calculation entirely. Chase / attack / replication paths
    are unchanged so requirements still hold.

Profiled per-tick costs at extreme densities (40 × 40 platform):

| N      | Grid rebuild | Sep top-60 | Sort by dist | Encode | Total / tick |
| ------ | -----------: | ---------: | -----------: | -----: | -----------: |
|  1,000 |     0.07 ms  |    0.45 ms |      0.25 ms | 0.12 ms |       ~0.7 ms |
| 10,000 |     0.65 ms  |    5.26 ms |      4.35 ms | 1.32 ms |        ~10 ms |

(50 ms tick budget at 20 Hz.) At 10K the AI tick is still ~20% of budget.

## Client side
- Each spawn packet builds a fresh **R6 rig** via
  `Players:CreateHumanoidModelFromDescription` so the standard Motor6D
  layout matches the default zombie animations
  (idle `180435571`, walk `180426354`, attack `184574340`).
- All BaseParts get the rolled color/material; the rig is uniformly scaled
  by sizing parts and translating Motor6D `C0/C1` positions.
- The HumanoidRootPart is **anchored**, the Humanoid is `PlatformStand`-ed
  with `AutoRotate = false`, so the rig is purely visual — no physics, no
  state machine fighting our CFrame writes.
- Each frame the client **lerps `prevCF → targetCF`** over the 100 ms tick
  window, so visual movement looks smooth despite the 10 Hz update rate.
- **Bulk move.** Per-rig CFrame writes go through the engine's PVInstance
  event path; at hundreds of visible rigs that loop dominates the client
  tick. The lerp instead fills two reusable scratch arrays
  (`bulkParts`, `bulkCFrames`) and dispatches them through
  `Workspace:BulkMoveTo(..., FireCFrameChanged)` — one C++ call per
  frame regardless of population.
- **Three-band LOD.** Per-frame, each enemy is classified by squared
  camera distance:
  - **Near:** full lerp every frame.
  - **Far:** lerp every Nth frame, hashed by id so the cost is staggered.
  - **Cull:** parented out of Workspace entirely — no render or animation
    eval — and re-parented when it returns to range.

## Click handling
Clicks are detected client-side: `UserInputService.InputBegan` + `Mouse.Target`
checked against an `ENEMY_TAG` on rig parts, lifted to the model's `EnemyId`
attribute. Client prints, then fires the `EnemyClicked` remote with the ID;
server validates the ID exists and prints its own line.

## Building and running

The repo is a standard Rojo project with `default.project.json` at the root.

```
rojo build default.project.json -o EnemySpawner.rbxlx
```

Open the resulting `.rbxlx` in Roblox Studio and press Play. A 50 × 50
slate platform appears at the origin with a SpawnLocation; enemies start
spawning at 1 / s once the place loads.

To live-edit during development, `rojo serve` and connect from the Studio
plugin. (DonkeySync also works for the same `src/` layout.)

### Libraries used

None. Only the Roblox standard libraries (`buffer`, `task`, `RunService`,
etc.) and the default zombie animations (asset IDs in `Constants.lua`).

## Trade-offs

Every choice below was made to keep the system cheap at high counts, not
because the brief required it.

- **Server-replicated rigs.** The obvious starting point, but default
  replication pushes every CFrame change at the engine's tick rate, and
  the cost grows linearly with enemy count. Moved rigs to clients and
  fed them from a packed unreliable stream so network cost is bounded
  by the broadcast rate, not the AI rate.
- **PathfindingService.** Per-call `ComputeAsync` allocates and yields;
  fine at 20 enemies, blows the 50 ms tick budget at 1K+. Straight-line
  steering with edge clamping is constant-time per enemy and fits
  inside the spatial-hash separation that already runs each tick.
- **Per-player network throttling (frustum / distance).** Would help at
  very large caps, but adds per-player buffer partitioning to a path
  that already costs only ~2 KB/s/client at the default cap. Easy to
  bolt onto `replicatePositions` later if the cap is raised.
- **R15 + HumanoidDescription scaling.** R15 is 17 parts with full
  Motor6D animation evaluation per rig per frame; R6 is 6 parts. With
  thousands of client-side rigs that per-frame difference dominates,
  so R6 with manual part scaling stays.
