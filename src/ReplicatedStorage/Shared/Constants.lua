--!strict
-- Project-wide constants.
-- Frozen at module return so accidental writes throw at the source.

local Constants = {}

Constants.PLATFORM = {
	SIZE = Vector3.new(50, 1, 50),
	POSITION = Vector3.new(0, 5, 0),
	COLOR = Color3.fromRGB(70, 75, 85),
	MATERIAL = Enum.Material.Concrete,
	EDGE_BUFFER = 1.5,
}

Constants.SPAWN = {
	DEFAULT_RATE_PER_SEC = 1,
	DEFAULT_MAX_COUNT = 20,
	MIN_RATE = 0,
	MAX_RATE = 30,
	MIN_CAP = 0,
	MAX_CAP = 250,
	RATE_STEP = 0.5,
	CAP_STEP = 5,
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
