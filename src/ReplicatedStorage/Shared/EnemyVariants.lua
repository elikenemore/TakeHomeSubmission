--!strict
-- Defines the random variation pool used by spawned enemies.
-- Server rolls once per enemy and replicates compact indices/values so every
-- client builds the same visual.

local EnemyVariants = {}

EnemyVariants.MATERIALS = {
	Enum.Material.Plastic,
	Enum.Material.Slate,
	Enum.Material.Metal,
	Enum.Material.CorrodedMetal,
	Enum.Material.Wood,
	Enum.Material.Neon,
	Enum.Material.Glass,
	Enum.Material.Granite,
}

EnemyVariants.NAMES = {
	"Crawler",
	"Lurker",
	"Husk",
	"Shambler",
	"Reaver",
	"Wraith",
	"Maw",
	"Ghoul",
	"Specter",
	"Dredge",
	"Gnasher",
	"Stalker",
}

EnemyVariants.MIN_SCALE = 0.6
EnemyVariants.MAX_SCALE = 2.0

-- Combat archetypes pair an attack signature with a ground-smash style.
-- Each archetype rolls deterministic parameters per enemy on the server, so
-- every client builds the identical effect from the same indices.
EnemyVariants.ARCHETYPES = {
	{
		name = "Bruiser",
		attackRange = 5,
		damage = 5,
		cooldown = 1.4,
		smashStyle = 1, -- BOULDER
		smashRadius = 6,
		shardCount = 8,
		shardHeight = 4,
		shardSpread = 1.2,
	},
	{
		name = "Crusher",
		attackRange = 7,
		damage = 8,
		cooldown = 1.8,
		smashStyle = 2, -- PILLAR
		smashRadius = 9,
		shardCount = 1,
		shardHeight = 12,
		shardSpread = 0,
	},
	{
		name = "Slasher",
		attackRange = 4,
		damage = 3,
		cooldown = 0.9,
		smashStyle = 3, -- SHARD_RING
		smashRadius = 5,
		shardCount = 12,
		shardHeight = 5,
		shardSpread = 0.6,
	},
	{
		name = "Quaker",
		attackRange = 10,
		damage = 12,
		cooldown = 2.4,
		smashStyle = 4, -- SPIRE_FIELD
		smashRadius = 14,
		shardCount = 18,
		shardHeight = 7,
		shardSpread = 1.6,
	},
	{
		name = "Stomper",
		attackRange = 6,
		damage = 6,
		cooldown = 1.2,
		smashStyle = 5, -- STAR_BURST
		smashRadius = 8,
		shardCount = 6,
		shardHeight = 6,
		shardSpread = 1.0,
	},
}

export type Variant = {
	color: Color3,
	materialIndex: number,
	nameIndex: number,
	scale: number,
	archetypeIndex: number,
}

function EnemyVariants.Roll(rng: Random): Variant
	return {
		color = Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber()),
		materialIndex = rng:NextInteger(1, #EnemyVariants.MATERIALS),
		nameIndex = rng:NextInteger(1, #EnemyVariants.NAMES),
		scale = EnemyVariants.MIN_SCALE
			+ rng:NextNumber() * (EnemyVariants.MAX_SCALE - EnemyVariants.MIN_SCALE),
		archetypeIndex = rng:NextInteger(1, #EnemyVariants.ARCHETYPES),
	}
end

function EnemyVariants.GetArchetype(index: number)
	return EnemyVariants.ARCHETYPES[index] or EnemyVariants.ARCHETYPES[1]
end

function EnemyVariants.GetMaterial(index: number): Enum.Material
	return EnemyVariants.MATERIALS[index] or Enum.Material.Plastic
end

function EnemyVariants.GetName(index: number): string
	return EnemyVariants.NAMES[index] or "Enemy"
end

return EnemyVariants
