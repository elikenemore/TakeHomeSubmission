--!strict
-- Reads the existing `Workspace.Platform` part and exposes spatial helpers
-- (on-platform predicate, edge clamping, random spawn point) so EnemyService
-- never has to know the part directly.

local Workspace = game:GetService("Workspace")

local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)

local PlatformService = {}

local platform: BasePart? = nil

function PlatformService.Init()
	local part = Workspace:WaitForChild("Platform", 5)
	if not part or not part:IsA("BasePart") then
		warn("[PlatformService] Workspace.Platform is missing or not a BasePart")
		return
	end
	platform = part
end

function PlatformService.GetPart(): BasePart?
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

function PlatformService.RandomSpawnPosition(rng: Random, heightOffset: number): Vector3
	if not platform then
		return Vector3.zero
	end
	local hx = platform.Size.X * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	local hz = platform.Size.Z * 0.5 - Constants.PLATFORM.EDGE_BUFFER
	local x = (rng:NextNumber() * 2 - 1) * hx
	local z = (rng:NextNumber() * 2 - 1) * hz
	return platform.Position + Vector3.new(x, platform.Size.Y * 0.5 + heightOffset, z)
end

return PlatformService
