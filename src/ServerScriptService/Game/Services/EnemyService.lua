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
	}
end

local function spawnEnemy()
	if enemyCount >= maxCount then
		return
	end
	local id = nextId
	nextId += 1
	local enemy: Enemy = {
		id = id,
		position = PlatformService.RandomSpawnPosition(rng),
		yaw = rng:NextNumber() * math.pi * 2,
		state = STATE_IDLE,
		variant = EnemyVariants.Roll(rng),
		health = Constants.ENEMY.BASE_HEALTH,
		nextAttackAt = 0,
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

local function updateEnemy(enemy: Enemy, dt: number)
	local target, targetPos = getClosestPlayerOnPlatform(enemy.position)

	if not target or not targetPos then
		enemy.state = STATE_IDLE
		return
	end

	local diff = targetPos - enemy.position
	local flat = Vector3.new(diff.X, 0, diff.Z)
	local dist = flat.Magnitude
	if dist <= Constants.ENEMY.ATTACK_RANGE then
		enemy.state = STATE_ATTACK
		if dist > 0.001 then
			enemy.yaw = math.atan2(flat.X, flat.Z)
		end
		local now = os.clock()
		if now >= enemy.nextAttackAt then
			enemy.nextAttackAt = now + Constants.ENEMY.ATTACK_COOLDOWN
			attackEvent:FireAllClients(enemy.id)
			local character = target.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:TakeDamage(Constants.ENEMY.ATTACK_DAMAGE)
			end
		end
		return
	end

	local dir = flat.Unit
	local step = math.min(Constants.ENEMY.WALK_SPEED * dt, dist)
	local newPos = enemy.position + dir * step
	newPos = PlatformService.ClampToPlatform(newPos)
	newPos = Vector3.new(newPos.X, PlatformService.GetTopY() + Constants.ENEMY.HEIGHT_OFFSET, newPos.Z)
	enemy.position = newPos
	enemy.yaw = math.atan2(dir.X, dir.Z)
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
