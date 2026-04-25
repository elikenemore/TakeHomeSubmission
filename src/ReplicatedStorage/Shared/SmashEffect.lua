--!strict
-- Renders ground-impact effects for enemy attacks.
--
-- The server only sends the strike origin + variant indices; clients build
-- the geometry locally so the effect costs zero replication bandwidth past
-- the single attack RemoteEvent payload. Each smash combines:
--   * Style-specific anchored shards rising out of the ground
--   * "Launcher" parts that fling high in the air, spinning, then fall back
--   * A flat shockwave ring expanding outward at ground level
--   * A coloured PointLight pulse for the flash
--   * ParticleEmitter bursts for dust + sparks
-- All driven by deterministic Random.new(seed) so every client sees the same.

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

local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/sparkle.png"

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

-- Anchored attachment-host part used as a particle / light origin.
-- Always invisible; the part itself just exists so we can parent emitters.
local function anchorHost(parent: Folder, origin: Vector3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Transparency = 1
	p.Size = Vector3.new(0.1, 0.1, 0.1)
	p.CFrame = CFrame.new(origin)
	p.Parent = parent
	return p
end

local function spawnLightPulse(parent: Folder, origin: Vector3, color: Color3)
	local host = anchorHost(parent, origin + Vector3.new(0, 1, 0))
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = Constants.SMASH.LIGHT_BRIGHTNESS
	light.Range = Constants.SMASH.LIGHT_RANGE
	light.Shadows = false
	light.Parent = host
	TweenService:Create(light, TweenInfo.new(Constants.SMASH.LIGHT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
		Range = 0,
	}):Play()
	Debris:AddItem(host, Constants.SMASH.LIGHT_DURATION + 0.05)
end

local function spawnParticleBurst(parent: Folder, origin: Vector3, color: Color3, radius: number)
	local host = anchorHost(parent, origin + Vector3.new(0, 0.5, 0))

	local dust = Instance.new("ParticleEmitter")
	dust.Texture = DUST_TEXTURE
	dust.Color = ColorSequence.new(color)
	dust.LightEmission = 0.1
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.max(1.5, radius * 0.2)),
		NumberSequenceKeypoint.new(0.4, math.max(3, radius * 0.45)),
		NumberSequenceKeypoint.new(1, math.max(4.5, radius * 0.7)),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.6, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Lifetime = NumberRange.new(0.8, 1.4)
	dust.Speed = NumberRange.new(8, 18)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-90, 90)
	dust.Acceleration = Vector3.new(0, -6, 0)
	dust.Rate = 0
	dust.Parent = host
	dust:Emit(math.clamp(math.floor(radius * 3), 25, 70))

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(color)
	sparks.LightEmission = 0.9
	sparks.LightInfluence = 0
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(0.45, 0.9)
	sparks.Speed = NumberRange.new(22, 42)
	sparks.SpreadAngle = Vector2.new(90, 90)
	sparks.Rotation = NumberRange.new(0, 360)
	sparks.RotSpeed = NumberRange.new(-180, 180)
	sparks.Acceleration = Vector3.new(0, -55, 0)
	sparks.Rate = 0
	sparks.Parent = host
	sparks:Emit(math.clamp(math.floor(radius * 2.2), 18, 55))

	Debris:AddItem(host, 2.5)
end

local function spawnShockwave(parent: Folder, origin: Vector3, color: Color3, radius: number)
	-- Cylinder rotated 90° on Z so its flat face lies on the ground.
	local ring = Instance.new("Part")
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Size = Vector3.new(0.3, 1.5, 1.5)
	ring.Transparency = 0.2
	ring.CFrame = CFrame.new(origin + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = parent

	local maxDiameter = radius * Constants.SMASH.SHOCKWAVE_SCALE
	local tween = TweenService:Create(ring, TweenInfo.new(
		Constants.SMASH.SHOCKWAVE_DURATION,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	), {
		Size = Vector3.new(0.2, maxDiameter, maxDiameter),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(ring, Constants.SMASH.SHOCKWAVE_DURATION + 0.1)
end

local function spawnLaunchers(
	parent: Folder,
	origin: Vector3,
	color: Color3,
	material: Enum.Material,
	radius: number,
	rng: Random
)
	local count = Constants.SMASH.LAUNCHER_COUNT
	local rise = TweenInfo.new(Constants.SMASH.LAUNCHER_RISE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local fall = TweenInfo.new(Constants.SMASH.LAUNCHER_FALL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for i = 1, count do
		local angle = (i - 1) / count * math.pi * 2 + rng:NextNumber() * 0.4
		local r = radius * (0.25 + rng:NextNumber() * 0.5)
		local startPos = origin + Vector3.new(math.sin(angle) * r, 1, math.cos(angle) * r)
		local size = Vector3.new(
			0.5 + rng:NextNumber() * 0.5,
			1.4 + rng:NextNumber() * 1.6,
			0.5 + rng:NextNumber() * 0.5
		)
		local part = makeShard(color, material, Enum.PartType.Block, size)

		local startCF = CFrame.new(startPos)
			* CFrame.Angles(rng:NextNumber() * math.pi, rng:NextNumber() * math.pi, rng:NextNumber() * math.pi)
		local peakHeight = Constants.SMASH.LAUNCHER_PEAK_HEIGHT * (0.7 + rng:NextNumber() * 0.6)
		local driftX = (rng:NextNumber() - 0.5) * 5
		local driftZ = (rng:NextNumber() - 0.5) * 5
		local peakCF = CFrame.new(startPos + Vector3.new(driftX * 0.5, peakHeight, driftZ * 0.5))
			* CFrame.Angles(rng:NextNumber() * math.pi * 4, rng:NextNumber() * math.pi * 4, rng:NextNumber() * math.pi * 4)
		local fallCF = CFrame.new(startPos + Vector3.new(driftX, -3, driftZ))
			* CFrame.Angles(rng:NextNumber() * math.pi * 8, rng:NextNumber() * math.pi * 8, rng:NextNumber() * math.pi * 8)

		part.CFrame = startCF
		part.Parent = parent
		TweenService:Create(part, rise, { CFrame = peakCF }):Play()
		task.delay(Constants.SMASH.LAUNCHER_RISE_TIME, function()
			if not part.Parent then
				return
			end
			TweenService:Create(part, fall, {
				CFrame = fallCF,
				Transparency = 1,
			}):Play()
		end)
		Debris:AddItem(part, Constants.SMASH.LAUNCHER_RISE_TIME + Constants.SMASH.LAUNCHER_FALL_TIME + 0.1)
	end
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

	-- Universal impact polish — flash, particles, shockwave, launchers.
	-- These read off archetype radius/color so big slow archetypes feel heavier.
	spawnLightPulse(parent, origin, color)
	spawnParticleBurst(parent, origin, color, radius)
	spawnShockwave(parent, origin, color, radius)
	spawnLaunchers(parent, origin, color, material, radius, rng)

	if style == STYLE_BOULDER then
		spawnBoulder(parent, origin, color, material, count, radius, height, spread, rng)
	elseif style == STYLE_PILLAR then
		spawnPillar(parent, origin, color, material, radius, height)
	elseif style == STYLE_SHARD_RING then
		spawnRing(parent, origin, yaw, color, material, count, radius, height, spread, Enum.PartType.Wedge, rng)
	elseif style == STYLE_SPIRE_FIELD then
		spawnRing(parent, origin, yaw, color, material, count, radius * 0.55, height, spread, Enum.PartType.Block, rng)
		spawnRing(parent, origin, yaw + 0.3, color, material, count, radius, height * 0.7, spread, Enum.PartType.Block, rng)
	elseif style == STYLE_STAR_BURST then
		spawnStarBurst(parent, origin, yaw, color, material, count, radius, height, rng)
	else
		spawnBoulder(parent, origin, color, material, count, radius, height, spread, rng)
	end
end

-- Brief upward dust + spark plume at the enemy's body during the wind-up,
-- so the swing has a visual ramp before the ground-impact effect plays.
function SmashEffect.PlayWindup(origin: Vector3, color: Color3)
	local parent = ensureFolder()
	local host = anchorHost(parent, origin)

	local plume = Instance.new("ParticleEmitter")
	plume.Texture = DUST_TEXTURE
	plume.Color = ColorSequence.new(color)
	plume.LightEmission = 0.2
	plume.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 2),
	})
	plume.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	plume.Lifetime = NumberRange.new(0.4, 0.8)
	plume.Speed = NumberRange.new(2, 6)
	plume.SpreadAngle = Vector2.new(40, 40)
	plume.Rotation = NumberRange.new(0, 360)
	plume.RotSpeed = NumberRange.new(-60, 60)
	plume.Acceleration = Vector3.new(0, 4, 0)
	plume.Rate = 28
	plume.Parent = host

	local energy = Instance.new("ParticleEmitter")
	energy.Texture = SPARK_TEXTURE
	energy.Color = ColorSequence.new(color)
	energy.LightEmission = 1
	energy.LightInfluence = 0
	energy.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	energy.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	energy.Lifetime = NumberRange.new(0.3, 0.6)
	energy.Speed = NumberRange.new(8, 16)
	energy.SpreadAngle = Vector2.new(180, 180)
	energy.Rotation = NumberRange.new(0, 360)
	energy.RotSpeed = NumberRange.new(-180, 180)
	energy.Acceleration = Vector3.new(0, 12, 0)
	energy.Rate = 24
	energy.Parent = host

	task.delay(Constants.SMASH.WINDUP_DURATION, function()
		plume.Enabled = false
		energy.Enabled = false
	end)
	Debris:AddItem(host, Constants.SMASH.WINDUP_DURATION + 1.2)
end

return SmashEffect
