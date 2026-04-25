--!strict
-- Project-wide constants.
-- Frozen at module return so accidental writes throw at the source.

local Constants = {}

Constants.PLATFORM = {
	-- Platform geometry is read from `Workspace.Platform` at runtime.
	-- This buffer keeps spawned enemies from clipping the edge.
	EDGE_BUFFER = 1.5,
}

Constants.SPAWN = {
	DEFAULT_RATE_PER_SEC = 1,
	DEFAULT_MAX_COUNT = 20,
	MIN_RATE = 0,
	MAX_RATE = 30,
	MIN_CAP = 0,
	MAX_CAP = 250,
}

Constants.ENEMY = {
	WALK_SPEED = 8,
	HEIGHT_OFFSET = 3,
	BASE_HEALTH = 50,
	-- Soft separation between enemies so they don't pile on the same player.
	SEPARATION_RADIUS = 3.5,
	SEPARATION_STRENGTH = 4,
	-- Damage and smash effect both fire at this fraction of the cooldown
	-- (which equals the stretched attack-animation length on the client).
	-- Slightly under 1.0 so the hit lands just before the next attack queues.
	DAMAGE_DELAY_FRACTION = 0.9,
}

Constants.SMASH = {
	-- Geometry rises to peak then falls back. Total lifetime = RISE + HOLD + FALL.
	RISE_TIME = 0.18,
	HOLD_TIME = 0.12,
	FALL_TIME = 0.55,
	-- How far below the platform top shards start (so they punch up through it).
	SUBMERGE_DEPTH = 6,
	-- PointLight pulse at impact.
	LIGHT_BRIGHTNESS = 8,
	LIGHT_RANGE = 32,
	LIGHT_DURATION = 0.45,
	-- Expanding flat ring at ground level.
	SHOCKWAVE_DURATION = 0.5,
	SHOCKWAVE_SCALE = 2.6,
	-- "Launcher" parts that fling high and fall back.
	LAUNCHER_COUNT = 6,
	LAUNCHER_RISE_TIME = 0.45,
	LAUNCHER_FALL_TIME = 0.85,
	LAUNCHER_PEAK_HEIGHT = 16,
	-- Pre-impact windup burst around the enemy.
	WINDUP_DURATION = 0.5,
}

Constants.CAMERA_SHAKE = {
	-- Linear falloff: full intensity at impact, zero past MAX_DISTANCE.
	MAX_DISTANCE = 65,
	MAX_AMPLITUDE = 1.0,
	DURATION = 0.45,
}

Constants.REPLICATION = {
	UPDATE_RATE_HZ = 10,
	POSITION_PRECISION = 100,
}

Constants.ANIMATIONS = {
	IDLE = "rbxassetid://180435571",
	WALK = "rbxassetid://180426354",
	ATTACK = "rbxassetid://184574340",
}

Constants.REMOTES = {
	SPAWN = "EnemySpawned",
	DESPAWN = "EnemyDespawned",
	POSITIONS = "EnemyPositions",
	ATTACK = "EnemyAttack",
	CLICK = "EnemyClicked",
	SETTINGS = "SpawnerSettings",
	KILL_ALL = "KillAllEnemies",
	GET_INITIAL = "GetInitialState",
}

return table.freeze(Constants)
