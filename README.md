# Cave-Game Take-Home — Enemy Spawner

Submission for the WKEY Studios Gameplay Engineer take-home (LUAU programmer, due 2026-04-26).

## What it does

- Builds a **50 × 50 stud platform** at runtime and spawns enemies on it.
- **1 enemy / second**, capped at **20 concurrent** by default; both values are
  live-tunable from an in-game **HUD panel** (per-player UI sends to a
  server-authoritative settings remote).
- Each enemy gets a **random color, material, scale, and name** rolled once
  on the server and replicated by index — every client renders identical
  visuals.
- Enemies **chase the closest player who is on the platform** and ignore
  anyone off it. Within attack range they play the default Zombie attack
  animation and deal 5 damage on a 1.4s cooldown.
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
  init.server.lua            -- one Script that requires every Service ModuleScript
  Services/
    PlatformService.lua      -- builds the platform, on-platform/clamping helpers
    EnemyService.lua         -- spawn loop, chase AI, attack, custom replication

StarterPlayer/StarterPlayerScripts/Game/
  init.client.lua            -- one LocalScript that requires every Controller ModuleScript
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
- **Late-join** is handled by a `RemoteFunction` (`GetInitialState`) that
  returns current settings + a snapshot of every live enemy. A new client
  hydrates from this snapshot, then keeps up via the position stream.

### Client side
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

## Click handling
Clicks are detected client-side: `UserInputService.InputBegan` + `Mouse.Target`
checked against an `ENEMY_TAG` on rig parts, lifted to the model's `EnemyId`
attribute. Client prints, then fires the `EnemyClicked` remote with the ID;
server validates the ID exists and prints its own line.

## Running locally

```
dsync serve            # starts DonkeySync on localhost:8080
```
Then in Roblox Studio: open the DonkeySync plugin → Connect. Press play.
A 50 × 50 platform appears with a green spawn pad; enemies start spawning
once the place loads.

## Things considered and dropped

- **Server-side enemy models with PVInstance / Anchored parts**, which is the
  obvious starting point but immediately replicates every CFrame change at
  the default rate. Pulled the parts onto the client and replaced the
  property sync with a packed buffer instead.
- **Wandering AI**. The brief lists it as optional, and adding noise on top
  of a target chase would have meant a separate "no target" code path with
  its own movement budget. Skipped to keep the chase behavior clean.
- **Pathfinding**. Brief says it is not required and the platform is flat
  and unobstructed, so straight-line steering with edge clamping is enough.
- **Per-enemy network throttling by view frustum / distance**. Would have
  saved more bandwidth on very large caps, but at the requested 20-enemy
  default the savings are negligible against the readability cost. Easy to
  bolt on later in `replicatePositions` by partitioning the buffer per
  player.
- **R15 + HumanoidDescription scaling.** Cleaner scale path, but the default
  R15 zombie animations look noticeably less menacing than the R6 ones.
  Stayed on R6 and scaled manually.
