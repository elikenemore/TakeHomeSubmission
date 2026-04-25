--!strict
-- Authoritative enemy state and chase AI.
--
-- Replication model:
--   * Enemies are server-only data. No parts are created server-side, so
--     Roblox's default per-frame property replication never runs for them.
--   * Spawn / despawn / attack events go through reliable RemoteEvents with
--     compact payloads (id + variation indices, not the rendered model).
--   * Position + state are sent at REPLICATION.UPDATE_RATE_HZ via an
--     UnreliableRemoteEvent carrying a packed `buffer`. Each enemy costs
--     11 bytes per tick (id u16, state u8, x/y/z i16 fixed-point, yaw i16).
--     Clients lerp between updates to hide the low rate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local RemoteService = require(Shared.RemoteService)
local EnemyVariants = require(Shared.EnemyVariants)

local PlatformService = require(script.Parent.PlatformService)

type Enemy = {
	id: number,
	position: Vector3,
	yaw: number,
	state: number,
	variant: EnemyVariants.Variant,
	health: number,
	nextAttackAt: number,
	wanderTarget: Vector3?,
}

local EnemyService = {}

local STATE_IDLE = 0
local STATE_WALK = 1
local STATE_ATTACK = 2

local enemies: { [number]: Enemy } = {}
local enemyCount = 0
local nextId = 1
local rng = Random.new()

local spawnRate = Constants.SPAWN.DEFAULT_RATE_PER_SEC
local maxCount = Constants.SPAWN.DEFAULT_MAX_COUNT
local timeSinceSpawn = 0
local timeSinceReplicate = 0

local spawnEvent: RemoteEvent
local despawnEvent: RemoteEvent
local positionsEvent: UnreliableRemoteEvent
local attackEvent: RemoteEvent
local clickEvent: RemoteEvent
local settingsEvent: RemoteEvent
local killAllEvent: RemoteEvent
local getInitialFn: RemoteFunction

local function makeSpawnPayload(enemy: Enemy)
	return {
		id = enemy.id,
		cf = CFrame.new(enemy.position) * CFrame.Angles(0, enemy.yaw, 0),
		materialIndex = enemy.variant.materialIndex,
		nameIndex = enemy.variant.nameIndex,
		color = enemy.variant.color,
		scale = enemy.variant.scale,
		archetypeIndex = enemy.variant.archetypeIndex,
	}
end

local function spawnEnemy()
	if enemyCount >= maxCount then
		return
	end
	local id = nextId
	nextId += 1
	local variant = EnemyVariants.Roll(rng)
	local heightOffset = Constants.ENEMY.HEIGHT_OFFSET * variant.scale
	local enemy: Enemy = {
		id = id,
		position = PlatformService.RandomSpawnPosition(rng, heightOffset),
		yaw = rng:NextNumber() * math.pi * 2,
		state = STATE_IDLE,
		variant = variant,
		health = Constants.ENEMY.BASE_HEALTH,
		nextAttackAt = 0,
		wanderTarget = nil,
	}
	enemies[id] = enemy
	enemyCount += 1
	spawnEvent:FireAllClients(makeSpawnPayload(enemy))
end

local function despawnEnemy(id: number)
	if not enemies[id] then
		return
	end
	enemies[id] = nil
	enemyCount -= 1
	despawnEvent:FireAllClients(id)
end

local function getClosestPlayerOnPlatform(position: Vector3): (Player?, Vector3?)
	local closestPlayer: Player? = nil
	local closestDist: number? = nil
	local closestPos: Vector3? = nil
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			continue
		end
		if not PlatformService.IsPositionOnPlatform(hrp.Position) then
			continue
		end
		local d = (hrp.Position - position).Magnitude
		if not closestDist or d < closestDist then
			closestPlayer = player
			closestDist = d
			closestPos = hrp.Position
		end
	end
	return closestPlayer, closestPos
end

-- Sums repulsion from nearby enemies so they spread out instead of stacking
-- on the same target. Linear falloff inside SEPARATION_RADIUS.
local function computeSeparation(self: Enemy): Vector3
	local push = Vector3.zero
	local radius = Constants.ENEMY.SEPARATION_RADIUS * self.variant.scale
	for _, other in enemies do
		if other.id == self.id then
			continue
		end
		local diff = self.position - other.position
		local flat = Vector3.new(diff.X, 0, diff.Z)
		local d = flat.Magnitude
		local combined = radius + Constants.ENEMY.SEPARATION_RADIUS * other.variant.scale
		if d > 0.001 and d < combined then
			local strength = (combined - d) / combined
			push += flat.Unit * strength
		end
	end
	return push * Constants.ENEMY.SEPARATION_STRENGTH
end

local function fireSmash(enemy: Enemy, target: Player)
	local archetype = EnemyVariants.GetArchetype(enemy.variant.archetypeIndex)
	-- Origin sits where the strike lands: in front of the enemy at platform top.
	local platformY = PlatformService.GetTopY()
	local forward = Vector3.new(-math.sin(enemy.yaw), 0, -math.cos(enemy.yaw))
	local origin = Vector3.new(enemy.position.X, platformY, enemy.position.Z)
		+ forward * (archetype.smashRadius * 0.4)
	local payload = {
		id = enemy.id,
		origin = origin,
		yaw = enemy.yaw,
		seed = math.random(1, 2 ^ 31 - 1),
	}
	attackEvent:FireAllClients(payload)

	-- Damage lands at the end of the attack animation; the client stretches
	-- the anim playback to cover the full cooldown so this stays in sync.
	local damage = archetype.damage
	local damageDelay = archetype.cooldown * Constants.ENEMY.DAMAGE_DELAY_FRACTION
	task.delay(damageDelay, function()
		if not enemies[enemy.id] then
			return
		end
		local character = target.Character
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			return
		end
		-- Only land the hit if the player is still inside the smash radius.
		local horiz = (Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
			- Vector3.new(origin.X, 0, origin.Z)).Magnitude
		if horiz <= archetype.smashRadius then
			humanoid:TakeDamage(damage)
		end
	end)
end

local function pickWanderTarget(enemy: Enemy): Vector3
	local hipHeight = Constants.ENEMY.HEIGHT_OFFSET * enemy.variant.scale
	return PlatformService.RandomSpawnPosition(rng, hipHeight)
end

local function updateEnemy(enemy: Enemy, dt: number)
	local target, targetPos = getClosestPlayerOnPlatform(enemy.position)
	local archetype = EnemyVariants.GetArchetype(enemy.variant.archetypeIndex)
	local hipHeight = Constants.ENEMY.HEIGHT_OFFSET * enemy.variant.scale

	if not target or not targetPos then
		-- No player on the platform: pick a random target and amble toward it.
		if not enemy.wanderTarget then
			enemy.wanderTarget = pickWanderTarget(enemy)
		end
		local wt = enemy.wanderTarget :: Vector3
		local diff = wt - enemy.position
		local flat = Vector3.new(diff.X, 0, diff.Z)
		local dist = flat.Magnitude
		if dist < 1.5 then
			enemy.wanderTarget = pickWanderTarget(enemy)
			enemy.state = STATE_IDLE
			return
		end
		local toTarget = flat.Unit
		local separation = computeSeparation(enemy)
		local dir = toTarget + separation * 0.5
		if dir.Magnitude < 0.01 then
			enemy.state = STATE_IDLE
			return
		end
		dir = dir.Unit
		-- Wander at half pace so it reads as ambling, not chasing.
		local step = math.min(Constants.ENEMY.WALK_SPEED * 0.5 * dt, dist)
		local newPos = enemy.position + dir * step
		newPos = PlatformService.ClampToPlatform(newPos)
		newPos = Vector3.new(newPos.X, PlatformService.GetTopY() + hipHeight, newPos.Z)
		enemy.position = newPos
		enemy.yaw = math.atan2(-dir.X, -dir.Z)
		enemy.state = STATE_WALK
		return
	end

	-- Player detected: drop any active wander goal.
	enemy.wanderTarget = nil

	local diff = targetPos - enemy.position
	local flat = Vector3.new(diff.X, 0, diff.Z)
	local dist = flat.Magnitude
	if dist <= archetype.attackRange then
		enemy.state = STATE_ATTACK
		if dist > 0.001 then
			-- Yaw is consumed as CFrame.Angles(0, yaw, 0); the rig's LookVector
			-- needs to align with the chase direction, so negate flat components.
			enemy.yaw = math.atan2(-flat.X, -flat.Z)
		end
		local now = os.clock()
		if now >= enemy.nextAttackAt then
			enemy.nextAttackAt = now + archetype.cooldown
			fireSmash(enemy, target)
		end
		return
	end

	local toTarget = if dist > 0.001 then flat.Unit else Vector3.zero
	local separation = computeSeparation(enemy)
	local dir = toTarget + separation
	if dir.Magnitude < 0.01 then
		enemy.state = STATE_IDLE
		return
	end
	dir = dir.Unit
	local step = math.min(Constants.ENEMY.WALK_SPEED * dt, dist)
	local newPos = enemy.position + dir * step
	newPos = PlatformService.ClampToPlatform(newPos)
	newPos = Vector3.new(newPos.X, PlatformService.GetTopY() + hipHeight, newPos.Z)
	enemy.position = newPos
	enemy.yaw = math.atan2(-dir.X, -dir.Z)
	enemy.state = STATE_WALK
end

local function encodeFixed(v: number): number
	return math.clamp(math.floor(v * Constants.REPLICATION.POSITION_PRECISION + 0.5), -32768, 32767)
end

local function encodeYaw(yaw: number): number
	-- Wrap to [-pi, pi] then map to int16.
	local wrapped = ((yaw + math.pi) % (math.pi * 2)) - math.pi
	return math.clamp(math.floor(wrapped / math.pi * 32767 + 0.5), -32768, 32767)
end

local function replicatePositions()
	if enemyCount == 0 then
		return
	end
	-- 2 byte header (count) + 11 bytes per enemy.
	local buf = buffer.create(2 + enemyCount * 11)
	buffer.writeu16(buf, 0, enemyCount)
	local offset = 2
	for _, enemy in enemies do
		buffer.writeu16(buf, offset, enemy.id)
		buffer.writeu8(buf, offset + 2, enemy.state)
		buffer.writei16(buf, offset + 3, encodeFixed(enemy.position.X))
		buffer.writei16(buf, offset + 5, encodeFixed(enemy.position.Y))
		buffer.writei16(buf, offset + 7, encodeFixed(enemy.position.Z))
		buffer.writei16(buf, offset + 9, encodeYaw(enemy.yaw))
		offset += 11
	end
	positionsEvent:FireAllClients(buf)
end

local function broadcastSettings()
	settingsEvent:FireAllClients({ spawnRate = spawnRate, maxCount = maxCount })
end

function EnemyService.Init()
	spawnEvent = RemoteService.GetEvent(Constants.REMOTES.SPAWN)
	despawnEvent = RemoteService.GetEvent(Constants.REMOTES.DESPAWN)
	positionsEvent = RemoteService.GetUnreliableEvent(Constants.REMOTES.POSITIONS)
	attackEvent = RemoteService.GetEvent(Constants.REMOTES.ATTACK)
	clickEvent = RemoteService.GetEvent(Constants.REMOTES.CLICK)
	settingsEvent = RemoteService.GetEvent(Constants.REMOTES.SETTINGS)
	killAllEvent = RemoteService.GetEvent(Constants.REMOTES.KILL_ALL)
	getInitialFn = RemoteService.GetFunction(Constants.REMOTES.GET_INITIAL)
end

function EnemyService.Start()
	clickEvent.OnServerEvent:Connect(function(player, id)
		if typeof(id) ~= "number" then
			return
		end
		local enemy = enemies[id]
		if not enemy then
			return
		end
		print(string.format("[Server] %s clicked enemy %d (%s)",
			player.Name, id, EnemyVariants.GetName(enemy.variant.nameIndex)))
	end)

	settingsEvent.OnServerEvent:Connect(function(_player, payload)
		if typeof(payload) ~= "table" then
			return
		end
		if typeof(payload.spawnRate) == "number" then
			spawnRate = math.clamp(payload.spawnRate, Constants.SPAWN.MIN_RATE, Constants.SPAWN.MAX_RATE)
		end
		if typeof(payload.maxCount) == "number" then
			maxCount = math.clamp(math.floor(payload.maxCount), Constants.SPAWN.MIN_CAP, Constants.SPAWN.MAX_CAP)
		end
		broadcastSettings()
	end)

	killAllEvent.OnServerEvent:Connect(function(_player)
		local ids = {}
		for id in enemies do
			table.insert(ids, id)
		end
		for _, id in ids do
			despawnEnemy(id)
		end
	end)

	getInitialFn.OnServerInvoke = function(_player)
		local list = table.create(enemyCount)
		for _, enemy in enemies do
			table.insert(list, makeSpawnPayload(enemy))
		end
		return {
			spawnRate = spawnRate,
			maxCount = maxCount,
			enemies = list,
		}
	end

	local replicateInterval = 1 / Constants.REPLICATION.UPDATE_RATE_HZ

	RunService.Heartbeat:Connect(function(dt)
		timeSinceSpawn += dt
		if spawnRate > 0 then
			local interval = 1 / spawnRate
			while timeSinceSpawn >= interval and enemyCount < maxCount do
				timeSinceSpawn -= interval
				spawnEnemy()
			end
			if enemyCount >= maxCount then
				timeSinceSpawn = math.min(timeSinceSpawn, interval)
			end
		else
			timeSinceSpawn = 0
		end

		for _, enemy in enemies do
			updateEnemy(enemy, dt)
		end

		timeSinceReplicate += dt
		if timeSinceReplicate >= replicateInterval then
			timeSinceReplicate -= replicateInterval
			replicatePositions()
		end
	end)
end

return EnemyService
