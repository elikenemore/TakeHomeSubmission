--!strict
-- Renders ground-impact effects for enemy attacks.
--
-- The server only sends the strike origin + variant indices; clients build
-- the geometry locally so the effect costs zero replication bandwidth past
-- the single attack RemoteEvent payload.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local EnemyVariants = require(Shared.EnemyVariants)

local SmashEffect = {}

local STYLE_BOULDER = 1
local STYLE_PILLAR = 2
local STYLE_SHARD_RING = 3
local STYLE_SPIRE_FIELD = 4
local STYLE_STAR_BURST = 5

local effectFolder: Folder? = nil

local function ensureFolder(): Folder
	if effectFolder and effectFolder.Parent then
		return effectFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "SmashEffects"
	folder.Parent = Workspace
	effectFolder = folder
	return folder
end

local function makeShard(
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType,
	size: Vector3
): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Color = color
	p.Material = material
	p.Shape = shape
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function tweenShardPunch(part: Part, restCF: CFrame, peakCF: CFrame)
	local risen = TweenInfo.new(Constants.SMASH.RISE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local fall = TweenInfo.new(Constants.SMASH.FALL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	-- Start submerged, snap part into world, animate.
	part.CFrame = restCF * CFrame.new(0, -Constants.SMASH.SUBMERGE_DEPTH, 0)
	TweenService:Create(part, risen, { CFrame = peakCF }):Play()
	task.delay(Constants.SMASH.RISE_TIME + Constants.SMASH.HOLD_TIME, function()
		if not part.Parent then
			return
		end
		local fallCF = restCF * CFrame.new(0, -Constants.SMASH.SUBMERGE_DEPTH * 0.6, 0)
		TweenService:Create(part, fall, {
			CFrame = fallCF,
			Transparency = 1,
		}):Play()
	end)
	Debris:AddItem(part, Constants.SMASH.RISE_TIME + Constants.SMASH.HOLD_TIME + Constants.SMASH.FALL_TIME + 0.1)
end

local function spawnRing(
	parent: Folder,
	origin: Vector3,
	yaw: number,
	color: Color3,
	material: Enum.Material,
	count: number,
	radius: number,
	height: number,
	spread: number,
	shape: Enum.PartType,
	rng: Random
)
	for i = 1, count do
		local angle = (i - 1) / count * math.pi * 2 + yaw
		local jitter = (rng:NextNumber() - 0.5) * spread
		local r = math.max(0.2, radius + jitter)
		local x = math.sin(angle) * r
		local z = math.cos(angle) * r
		local h = height * (0.7 + rng:NextNumber() * 0.6)
		local thickness = 0.6 + rng:NextNumber() * 0.7
		local sizeVec = Vector3.new(thickness, h, thickness)
		local part = makeShard(color, material, shape, sizeVec)

		local tilt = (rng:NextNumber() - 0.5) * 0.5
		local restPos = origin + Vector3.new(x, h * 0.5, z)
		local peakCF = CFrame.new(restPos)
			* CFrame.Angles(tilt, angle, 0)
		local restCF = CFrame.new(restPos) * CFrame.Angles(tilt, angle, 0)
		part.Parent = parent
		tweenShardPunch(part, restCF, peakCF)
	end
end

local function spawnPillar(
	parent: Folder,
	origin: Vector3,
	color: Color3,
	material: Enum.Material,
	radius: number,
	height: number
)
	local size = Vector3.new(radius * 0.8, height, radius * 0.8)
	local part = makeShard(color, material, Enum.PartType.Block, size)
	local restCF = CFrame.new(origin + Vector3.new(0, height * 0.5, 0))
	part.Parent = parent
	tweenShardPunch(part, restCF, restCF)
end

local function spawnBoulder(
	parent: Folder,
	origin: Vector3,
	color: Color3,
	material: Enum.Material,
	count: number,
	radius: number,
	height: number,
	spread: number,
	rng: Random
)
	for i = 1, count do
		local angle = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber() * radius
		local x = math.sin(angle) * r
		local z = math.cos(angle) * r
		local sz = (0.8 + rng:NextNumber() * 1.2) * (height * 0.5)
		local sizeVec = Vector3.new(sz, sz, sz) * (0.8 + spread * 0.1)
		local part = makeShard(color, material, Enum.PartType.Block, sizeVec)
		local rotX = rng:NextNumber() * math.pi
		local rotY = rng:NextNumber() * math.pi
		local rotZ = rng:NextNumber() * math.pi
		local restCF = CFrame.new(origin + Vector3.new(x, sz * 0.4, z))
			* CFrame.Angles(rotX, rotY, rotZ)
		part.Parent = parent
		tweenShardPunch(part, restCF, restCF)
	end
end

local function spawnStarBurst(
	parent: Folder,
	origin: Vector3,
	yaw: number,
	color: Color3,
	material: Enum.Material,
	count: number,
	radius: number,
	height: number,
	rng: Random
)
	-- Long thin slabs radiating outward like spokes.
	for i = 1, count do
		local angle = (i - 1) / count * math.pi * 2 + yaw
		local len = radius * (0.7 + rng:NextNumber() * 0.5)
		local sizeVec = Vector3.new(0.6, height * 0.6, len)
		local part = makeShard(color, material, Enum.PartType.Block, sizeVec)
		local mid = origin + Vector3.new(math.sin(angle) * len * 0.5, sizeVec.Y * 0.4, math.cos(angle) * len * 0.5)
		local restCF = CFrame.new(mid) * CFrame.Angles(0, angle, 0)
		part.Parent = parent
		tweenShardPunch(part, restCF, restCF)
	end
end

function SmashEffect.Play(
	origin: Vector3,
	yaw: number,
	color: Color3,
	materialIndex: number,
	archetypeIndex: number,
	seed: number
)
	local archetype = EnemyVariants.GetArchetype(archetypeIndex)
	local material = EnemyVariants.GetMaterial(materialIndex)
	local rng = Random.new(seed)
	local parent = ensureFolder()
	local style = archetype.smashStyle
	local count = archetype.shardCount
	local radius = archetype.smashRadius
	local height = archetype.shardHeight
	local spread = archetype.shardSpread

	if style == STYLE_BOULDER then
		spawnBoulder(parent, origin, color, material, count, radius, height, spread, rng)
	elseif style == STYLE_PILLAR then
		spawnPillar(parent, origin, color, material, radius, height)
	elseif style == STYLE_SHARD_RING then
		spawnRing(parent, origin, yaw, color, material, count, radius, height, spread, Enum.PartType.Wedge, rng)
	elseif style == STYLE_SPIRE_FIELD then
		spawnRing(parent, origin, yaw, color, material, count, radius * 0.55, height, spread, Enum.PartType.Block, rng)
		-- Outer ring offsets the inner one to fill the field.
		spawnRing(parent, origin, yaw + 0.3, color, material, count, radius, height * 0.7, spread, Enum.PartType.Block, rng)
	elseif style == STYLE_STAR_BURST then
		spawnStarBurst(parent, origin, yaw, color, material, count, radius, height, rng)
	else
		spawnBoulder(parent, origin, color, material, count, radius, height, spread, rng)
	end
end

return SmashEffect
