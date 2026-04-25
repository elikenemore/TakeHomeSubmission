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
	ATTACK_RANGE = 5,
	ATTACK_DAMAGE = 5,
	ATTACK_COOLDOWN = 1.4,
	HEIGHT_OFFSET = 3,
	BASE_HEALTH = 50,
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
