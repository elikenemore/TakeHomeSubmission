--!strict
-- Authoritative enemy state and chase AI.
--
-- Performance design:
--   * AI runs at fixed PERFORMANCE.AI_TICK_RATE_HZ via an accumulator inside
--     Heartbeat — predictable cost, decoupled from render rate.
--   * Per tick, at most PERFORMANCE.ACTIVE_AI_CAP enemies run full chase logic;
--     enemies are ranked by distance to the closest player, the top N update,
--     the rest hold pose. This keeps cost bounded even at 250 enemies.
--   * Separation uses a per-tick spatial hash over the 9 surrounding cells —
--     turns the O(N^2) pile into ~O(N).
--   * Closest-player lookup is cached per enemy and refreshed every
--     CLOSEST_PLAYER_CACHE_INTERVAL seconds (cheap re-read of cached target's
--     position in between).
--   * Replication uses delta encoding: an enemy only ships in the position
--     packet if its pos / yaw / state changed beyond threshold OR the force
--     interval elapsed.
--
-- Replication wire format:
--   * Spawn / despawn / attack go through reliable RemoteEvents with compact
--     payloads (no parts cross the wire).
--   * Position + state are sent at REPLICATION.UPDATE_RATE_HZ via an
--     UnreliableRemoteEvent carrying a packed `buffer`. Each enemy that
--     changes that tick costs 11 bytes (id u16, state u8, x/y/z i16
--     fixed-point, yaw i16). Clients lerp between updates to mask the rate.

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
	cachedTarget: Player?,
	cachedTargetPos: Vector3?,
	cachedTargetDist: number,
	cachedTargetAt: number,
	lastReplicatedPos: Vector3,
	lastReplicatedYaw: number,
	lastReplicatedState: number,
	lastReplicatedAt: number,
}

type PlayerInfo = { player: Player, position: Vector3 }

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
local timeSinceTick = 0

-- Server-side perf flag. Toggled by the client UI alongside the client-side
-- visual strip. When on we skip spatial hash + separation entirely so the
-- per-tick AI cost drops to "closest-player chase, no neighbour awareness".
-- The chase + attack + replication paths are unchanged so requirements still
-- hold.
local serverPerfMode = false

-- UnreliableRemoteEvent caps each packet at ~900 bytes (one MTU). At 11 bytes
-- per enemy + a 2-byte header, 80 fits with margin. Going over silently drops
-- the entire packet, so high-count broadcasts MUST chunk.
local MAX_ENEMIES_PER_PACKET = 80

local spawnEvent: RemoteEvent
local despawnEvent: RemoteEvent
local positionsEvent: UnreliableRemoteEvent
local attackEvent: RemoteEvent
local clickEvent: RemoteEvent
local settingsEvent: RemoteEvent
local killAllEvent: RemoteEvent
local getInitialFn: RemoteFunction

-- Reusable scratch tables; cleared per tick instead of re-allocated.
local enemyArray: { Enemy } = {}
local replicateArray: { Enemy } = {}
local spatialGrid: { [number]: { Enemy } } = {}
local playerHRPs: { PlayerInfo } = {}

local CELL_SIZE = Constants.PERFORMANCE.SEPARATION_GRID_CELL

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
	local position = PlatformService.RandomSpawnPosition(rng, heightOffset)
	local yaw = rng:NextNumber() * math.pi * 2
	local enemy: Enemy = {
		id = id,
		position = position,
		yaw = yaw,
		state = STATE_IDLE,
		variant = variant,
		health = Constants.ENEMY.BASE_HEALTH,
		nextAttackAt = 0,
		wanderTarget = nil,
		cachedTarget = nil,
		cachedTargetPos = nil,
		cachedTargetDist = math.huge,
		cachedTargetAt = 0,
		lastReplicatedPos = position,
		lastReplicatedYaw = yaw,
		lastReplicatedState = STATE_IDLE,
		lastReplicatedAt = 0,
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

local function refreshPlayerCache()
	debug.profilebegin("Enemy.RefreshPlayers")
	table.clear(playerHRPs)
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
		table.insert(playerHRPs, { player = player, position = hrp.Position })
	end
	debug.profileend()
end

-- Cached closest-player lookup. Between full refreshes we cheaply re-read the
-- cached target's HRP position so chase still tracks moving players, but skip
-- the full O(P) scan.
local function updateClosestPlayer(enemy: Enemy, now: number)
	if now - enemy.cachedTargetAt < Constants.PERFORMANCE.CLOSEST_PLAYER_CACHE_INTERVAL
		and enemy.cachedTarget
	then
		local character = enemy.cachedTarget.Character
		local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and PlatformService.IsPositionOnPlatform(hrp.Position) then
			enemy.cachedTargetPos = hrp.Position
			enemy.cachedTargetDist = (hrp.Position - enemy.position).Magnitude
			return
		end
	end
	enemy.cachedTargetAt = now
	local closest: Player? = nil
	local closestDist: number = math.huge
	local closestPos: Vector3? = nil
	for _, info in playerHRPs do
		local d = (info.position - enemy.position).Magnitude
		if d < closestDist then
			closest = info.player
			closestDist = d
			closestPos = info.position
		end
	end
	enemy.cachedTarget = closest
	enemy.cachedTargetPos = closestPos
	enemy.cachedTargetDist = closestDist
end

-- Pack two signed cell indices into one number for use as a hash key.
local function gridKey(x: number, z: number): number
	local ix = math.floor(x / CELL_SIZE)
	local iz = math.floor(z / CELL_SIZE)
	return (ix + 32768) * 65536 + (iz + 32768)
end

local function rebuildSpatialGrid()
	debug.profilebegin("Enemy.RebuildGrid")
	table.clear(spatialGrid)
	for _, enemy in enemies do
		local key = gridKey(enemy.position.X, enemy.position.Z)
		local bucket = spatialGrid[key]
		if not bucket then
			bucket = {}
			spatialGrid[key] = bucket
		end
		table.insert(bucket, enemy)
	end
	debug.profileend()
end

-- Hot path: scalar math throughout. Avoids per-pair Vector3 allocation
-- (and the second Vector3 from `flat.Unit`) which dominated this loop at
-- high enemy counts.
local function computeSeparation(self: Enemy): Vector3
	if serverPerfMode then
		return Vector3.zero
	end
	local pushX, pushZ = 0, 0
	local radius = Constants.ENEMY.SEPARATION_RADIUS * self.variant.scale
	local sx, sz = self.position.X, self.position.Z
	local ix = math.floor(sx / CELL_SIZE)
	local iz = math.floor(sz / CELL_SIZE)
	local selfId = self.id
	local baseRadius = Constants.ENEMY.SEPARATION_RADIUS
	for dx = -1, 1 do
		for dz = -1, 1 do
			local key = (ix + dx + 32768) * 65536 + (iz + dz + 32768)
			local bucket = spatialGrid[key]
			if bucket then
				for _, other in bucket do
					if other.id == selfId then
						continue
					end
					local op = other.position
					local fx = sx - op.X
					local fz = sz - op.Z
					local distSq = fx * fx + fz * fz
					local combined = radius + baseRadius * other.variant.scale
					if distSq > 0.000001 and distSq < combined * combined then
						local d = math.sqrt(distSq)
						local strength = (combined - d) / combined / d
						pushX += fx * strength
						pushZ += fz * strength
					end
				end
			end
		end
	end
	local k = Constants.ENEMY.SEPARATION_STRENGTH
	return Vector3.new(pushX * k, 0, pushZ * k)
end

local function fireSmash(enemy: Enemy, target: Player)
	local archetype = EnemyVariants.GetArchetype(enemy.variant.archetypeIndex)
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
	local target = enemy.cachedTarget
	local targetPos = enemy.cachedTargetPos
	local archetype = EnemyVariants.GetArchetype(enemy.variant.archetypeIndex)
	local hipHeight = Constants.ENEMY.HEIGHT_OFFSET * enemy.variant.scale

	if not target or not targetPos then
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
		local step = math.min(Constants.ENEMY.WALK_SPEED * 0.5 * dt, dist)
		local newPos = enemy.position + dir * step
		newPos = PlatformService.ClampToPlatform(newPos)
		newPos = Vector3.new(newPos.X, PlatformService.GetTopY() + hipHeight, newPos.Z)
		enemy.position = newPos
		enemy.yaw = math.atan2(-dir.X, -dir.Z)
		enemy.state = STATE_WALK
		return
	end

	enemy.wanderTarget = nil

	local diff = targetPos - enemy.position
	local flat = Vector3.new(diff.X, 0, diff.Z)
	local dist = flat.Magnitude
	if dist <= archetype.attackRange then
		enemy.state = STATE_ATTACK
		if dist > 0.001 then
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

local function runAITick(dt: number)
	if enemyCount == 0 then
		return
	end
	debug.profilebegin("Enemy.AITick")
	local now = os.clock()
	refreshPlayerCache()

	debug.profilebegin("Enemy.ClosestPlayer")
	table.clear(enemyArray)
	for _, enemy in enemies do
		updateClosestPlayer(enemy, now)
		table.insert(enemyArray, enemy)
	end
	debug.profileend()

	-- Closest enemies get full AI; far / no-target enemies (math.huge) sort
	-- to the back and are skipped this tick.
	debug.profilebegin("Enemy.SortByDist")
	table.sort(enemyArray, function(a, b)
		return a.cachedTargetDist < b.cachedTargetDist
	end)
	debug.profileend()

	if not serverPerfMode then
		rebuildSpatialGrid()
	end

	debug.profilebegin("Enemy.UpdateLoop")
	local cap = Constants.PERFORMANCE.ACTIVE_AI_CAP
	for i, enemy in enemyArray do
		if i > cap then
			-- Inactive: keep state stable, no movement, no attack scheduling.
			enemy.state = STATE_IDLE
		else
			updateEnemy(enemy, dt)
		end
	end
	debug.profileend()
	debug.profileend()
end

local function encodeFixed(v: number): number
	return math.clamp(math.floor(v * Constants.REPLICATION.POSITION_PRECISION + 0.5), -32768, 32767)
end

local function encodeYaw(yaw: number): number
	local wrapped = ((yaw + math.pi) % (math.pi * 2)) - math.pi
	return math.clamp(math.floor(wrapped / math.pi * 32767 + 0.5), -32768, 32767)
end

-- Delta predicate: only ship enemies whose pos / yaw / state actually changed
-- since their last broadcast, OR whose force-resend interval elapsed (catches
-- packet loss on the unreliable channel).
local POS_EPSILON_SQ = Constants.PERFORMANCE.REPLICATION_POSITION_EPSILON
local YAW_EPSILON = 0.05
local FORCE_INTERVAL = Constants.PERFORMANCE.REPLICATION_FORCE_INTERVAL

local function shouldReplicate(enemy: Enemy, now: number): boolean
	if now - enemy.lastReplicatedAt >= FORCE_INTERVAL then
		return true
	end
	if enemy.state ~= enemy.lastReplicatedState then
		return true
	end
	local dx = enemy.position.X - enemy.lastReplicatedPos.X
	local dy = enemy.position.Y - enemy.lastReplicatedPos.Y
	local dz = enemy.position.Z - enemy.lastReplicatedPos.Z
	if dx * dx + dy * dy + dz * dz > POS_EPSILON_SQ then
		return true
	end
	if math.abs(enemy.yaw - enemy.lastReplicatedYaw) > YAW_EPSILON then
		return true
	end
	return false
end

local function replicatePositions()
	if enemyCount == 0 then
		return
	end
	debug.profilebegin("Enemy.Replicate")
	local now = os.clock()
	table.clear(replicateArray)
	for _, enemy in enemies do
		if shouldReplicate(enemy, now) then
			table.insert(replicateArray, enemy)
		end
	end
	local total = #replicateArray
	if total == 0 then
		debug.profileend()
		return
	end
	-- Chunked broadcast: each packet is self-describing (count header) so the
	-- client decoder needs no awareness of chunking. Going over MTU silently
	-- drops the whole packet, which manifests as enemies that don't move.
	local sent = 0
	while sent < total do
		local chunk = math.min(MAX_ENEMIES_PER_PACKET, total - sent)
		local buf = buffer.create(2 + chunk * 11)
		buffer.writeu16(buf, 0, chunk)
		local offset = 2
		for i = 1, chunk do
			local enemy = replicateArray[sent + i]
			buffer.writeu16(buf, offset, enemy.id)
			buffer.writeu8(buf, offset + 2, enemy.state)
			buffer.writei16(buf, offset + 3, encodeFixed(enemy.position.X))
			buffer.writei16(buf, offset + 5, encodeFixed(enemy.position.Y))
			buffer.writei16(buf, offset + 7, encodeFixed(enemy.position.Z))
			buffer.writei16(buf, offset + 9, encodeYaw(enemy.yaw))
			offset += 11
			enemy.lastReplicatedPos = enemy.position
			enemy.lastReplicatedYaw = enemy.yaw
			enemy.lastReplicatedState = enemy.state
			enemy.lastReplicatedAt = now
		end
		positionsEvent:FireAllClients(buf)
		sent += chunk
	end
	debug.profileend()
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
		local rateChanged = false
		if typeof(payload.spawnRate) == "number" then
			spawnRate = math.clamp(payload.spawnRate, Constants.SPAWN.MIN_RATE, Constants.SPAWN.MAX_RATE)
			rateChanged = true
		end
		if typeof(payload.maxCount) == "number" then
			maxCount = math.clamp(math.floor(payload.maxCount), Constants.SPAWN.MIN_CAP, Constants.SPAWN.MAX_CAP)
		end
		if typeof(payload.perfMode) == "boolean" then
			serverPerfMode = payload.perfMode
		end
		-- Pre-fill the accumulator to one full new-rate interval so the next
		-- Heartbeat spawns immediately, then resumes at the configured rate.
		-- Without this, dropping to 0.1/s would mean a 10s wait for the first
		-- visible response — feels broken. Going from low to high also gets a
		-- clean kick rather than picking up stale low-rate debt.
		if rateChanged then
			if spawnRate > 0 then
				timeSinceSpawn = 1 / spawnRate
			else
				timeSinceSpawn = 0
			end
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

	local aiTickInterval = 1 / Constants.PERFORMANCE.AI_TICK_RATE_HZ
	local replicateInterval = 1 / Constants.REPLICATION.UPDATE_RATE_HZ

	RunService.Heartbeat:Connect(function(dt)
		timeSinceSpawn += dt
		timeSinceTick += dt
		timeSinceReplicate += dt

		if spawnRate > 0 then
			debug.profilebegin("Enemy.SpawnLoop")
			local interval = 1 / spawnRate
			-- Cap per-frame burst so an extreme rate can't lock the tick.
			local burst = 0
			local maxBurst = Constants.SPAWN.SPAWN_BURST_PER_FRAME
			while timeSinceSpawn >= interval and enemyCount < maxCount and burst < maxBurst do
				timeSinceSpawn -= interval
				spawnEnemy()
				burst += 1
			end
			if enemyCount >= maxCount then
				timeSinceSpawn = math.min(timeSinceSpawn, interval)
			elseif burst >= maxBurst then
				-- Drop accumulated time so we don't pile up debt across frames.
				timeSinceSpawn = math.min(timeSinceSpawn, interval)
			end
			debug.profileend()
		else
			timeSinceSpawn = 0
		end

		-- Hard cap catch-up: if the server stalled, run at most one tick to
		-- avoid a runaway loop chewing the rest of the frame.
		if timeSinceTick >= aiTickInterval then
			runAITick(aiTickInterval)
			timeSinceTick = math.min(timeSinceTick - aiTickInterval, aiTickInterval)
		end

		if timeSinceReplicate >= replicateInterval then
			timeSinceReplicate -= replicateInterval
			replicatePositions()
		end
	end)
end

return EnemyService
