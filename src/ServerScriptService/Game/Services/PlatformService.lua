--!strict
-- Builds and exposes the 50x50 enemy platform.
-- Spawn position queries and on-platform predicates live here so EnemyService
-- never has to know the part directly.

local Workspace = game:GetService("Workspace")

local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)

local PlatformService = {}

local platform: Part? = nil

function PlatformService.Init()
	local part = Instance.new("Part")
	part.Name = "EnemyPlatform"
	part.Anchored = true
	part.CanCollide = true
	part.Size = Constants.PLATFORM.SIZE
	part.Position = Constants.PLATFORM.POSITION
	part.Color = Constants.PLATFORM.COLOR
	part.Material = Constants.PLATFORM.MATERIAL
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = Workspace
	platform = part

	local existingSpawn = Workspace:FindFirstChild("PlayerSpawn")
	if not existingSpawn then
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "PlayerSpawn"
		spawn.Anchored = true
		spawn.CanCollide = true
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Position = Constants.PLATFORM.POSITION
			+ Vector3.new(0, Constants.PLATFORM.SIZE.Y * 0.5 + 0.5, 0)
		spawn.Color = Color3.fromRGB(60, 200, 110)
		spawn.Material = Enum.Material.Neon
		spawn.TopSurface = Enum.SurfaceType.Smooth
		spawn.BottomSurface = Enum.SurfaceType.Smooth
		spawn.Parent = Workspace
	end
end

function PlatformService.GetPart(): Part?
	return platform
end

function PlatformService.GetTopY(): number
	if not platform then
		return 0
	end
	return platform.Position.Y + platform.Size.Y * 0.5
end

function PlatformService.IsPositionOnPlatform(position: Vector3): boolean
	if not platform then
		return false
	end
	local rel = position - platform.Position
	local hx = platform.Size.X * 0.5
	local hz = platform.Size.Z * 0.5
	return math.abs(rel.X) <= hx and math.abs(rel.Z) <= hz
end

function PlatformService.ClampToPlatform(position: Vector3): Vector3
	if not platform then
		return position
	end
	local rel = position - platform.Position
	local hx = platform.Size.X * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	local hz = platform.Size.Z * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	rel = Vector3.new(math.clamp(rel.X, -hx, hx), rel.Y, math.clamp(rel.Z, -hz, hz))
	return platform.Position + rel
end

function PlatformService.RandomSpawnPosition(rng: Random): Vector3
	if not platform then
		return Vector3.zero
	end
	local hx = platform.Size.X * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	local hz = platform.Size.Z * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	local x = (rng:NextNumber() * 2 - 1) * hx
	local z = (rng:NextNumber() * 2 - 1) * hz
	return platform.Position
		+ Vector3.new(x, platform.Size.Y * 0.5 + Constants.ENEMY.HEIGHT_OFFSET, z)
end

return PlatformService
