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

export type Variant = {
	color: Color3,
	materialIndex: number,
	nameIndex: number,
	scale: number,
}

function EnemyVariants.Roll(rng: Random): Variant
	return {
		color = Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber()),
		materialIndex = rng:NextInteger(1, #EnemyVariants.MATERIALS),
		nameIndex = rng:NextInteger(1, #EnemyVariants.NAMES),
		scale = EnemyVariants.MIN_SCALE
			+ rng:NextNumber() * (EnemyVariants.MAX_SCALE - EnemyVariants.MIN_SCALE),
	}
end

function EnemyVariants.GetMaterial(index: number): Enum.Material
	return EnemyVariants.MATERIALS[index] or Enum.Material.Plastic
end

function EnemyVariants.GetName(index: number): string
	return EnemyVariants.NAMES[index] or "Enemy"
end

return EnemyVariants
