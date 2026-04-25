--!strict
-- Renders enemies locally from server replication.
--
-- For each spawn packet we build an R6 rig via CreateHumanoidModelFromDescription
-- so default zombie animations (idle/walk/attack) wire up against the standard
-- Motor6D names. Rigs are anchored at the HumanoidRootPart and driven from the
-- server's 10Hz position packets, with per-frame Lerp interpolation between
-- the previous and next snapshot to mask the lower replication rate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local RemoteService = require(Shared.RemoteService)
local EnemyVariants = require(Shared.EnemyVariants)

local ENEMY_TAG = "ReplicatedEnemy"
local ENEMY_ID_ATTR = "EnemyId"

local EnemyController = {}

type Tracks = {
	idle: AnimationTrack,
	walk: AnimationTrack,
	attack: AnimationTrack,
}

type Entry = {
	id: number,
	model: Model,
	hrp: BasePart,
	humanoid: Humanoid,
	tracks: Tracks,
	currentAnim: string,
	prevCF: CFrame,
	targetCF: CFrame,
	interpStart: number,
	interpDur: number,
	state: number,
}

local STATE_IDLE = 0
local STATE_WALK = 1
local STATE_ATTACK = 2

local enemies: { [number]: Entry } = {}
local enemyFolder: Folder
local localPlayer: Player

local spawnEvent: RemoteEvent
local despawnEvent: RemoteEvent
local positionsEvent: UnreliableRemoteEvent
local attackEvent: RemoteEvent
local clickEvent: RemoteEvent
local getInitialFn: RemoteFunction

local function decodeFixed(v: number): number
	return v / Constants.REPLICATION.POSITION_PRECISION
end

local function decodeYaw(v: number): number
	return v / 32767 * math.pi
end

-- Scales every BasePart's Size and translates Motor6D C0/C1 positions so the
-- whole R6 rig is uniformly scaled while keeping animations valid.
local function scaleRig(model: Model, scale: number)
	if scale == 1 then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Size = descendant.Size * scale
		elseif descendant:IsA("Motor6D") then
			local c0 = descendant.C0
			local c1 = descendant.C1
			descendant.C0 = (c0 - c0.Position) + (c0.Position * scale)
			descendant.C1 = (c1 - c1.Position) + (c1.Position * scale)
		end
	end
end

local function styleRig(model: Model, color: Color3, material: Enum.Material)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = color
			descendant.Material = material
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.CanQuery = descendant.Name ~= "HumanoidRootPart"
			descendant.CanTouch = false
		elseif descendant:IsA("Decal") then
			-- Drop classic faces so the random color reads cleanly.
			descendant:Destroy()
		end
	end
end

local function loadTrack(animator: Animator, assetId: string): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = assetId
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	return track
end

local function attachNameTag(parent: BasePart, name: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.fromOffset(140, 28)
	billboard.StudsOffset = Vector3.new(0, 1.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 80
	billboard.Parent = parent
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = Color3.fromRGB(245, 245, 245)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard
end

local function buildEnemy(payload): Entry?
	local description = Instance.new("HumanoidDescription")
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	end)
	description:Destroy()
	if not ok or not model then
		warn("[EnemyController] Failed to build rig:", model)
		return nil
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp or not hrp:IsA("BasePart") then
		model:Destroy()
		return nil
	end

	local material = EnemyVariants.GetMaterial(payload.materialIndex)
	local enemyName = EnemyVariants.GetName(payload.nameIndex)

	model.Name = string.format("Enemy_%d_%s", payload.id, enemyName)
	model:SetAttribute(ENEMY_ID_ATTR, payload.id)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant:AddTag(ENEMY_TAG)
		end
	end

	styleRig(model, payload.color, material)
	scaleRig(model, payload.scale)

	hrp.Anchored = true
	hrp.Transparency = 1
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.WalkSpeed = 0
	humanoid.Health = humanoid.MaxHealth

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local tracks: Tracks = {
		idle = loadTrack(animator, Constants.ANIMATIONS.IDLE),
		walk = loadTrack(animator, Constants.ANIMATIONS.WALK),
		attack = loadTrack(animator, Constants.ANIMATIONS.ATTACK),
	}
	tracks.idle.Looped = true
	tracks.walk.Looped = true
	tracks.attack.Looped = false
	tracks.idle.Priority = Enum.AnimationPriority.Idle
	tracks.walk.Priority = Enum.AnimationPriority.Movement
	tracks.attack.Priority = Enum.AnimationPriority.Action

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		attachNameTag(head, enemyName)
	end

	model.Parent = enemyFolder
	hrp.CFrame = payload.cf
	tracks.idle:Play(0)

	local entry: Entry = {
		id = payload.id,
		model = model,
		hrp = hrp,
		humanoid = humanoid,
		tracks = tracks,
		currentAnim = "idle",
		prevCF = payload.cf,
		targetCF = payload.cf,
		interpStart = workspace:GetServerTimeNow(),
		interpDur = 1 / Constants.REPLICATION.UPDATE_RATE_HZ,
		state = STATE_IDLE,
	}
	return entry
end

local function setAnim(entry: Entry, name: string, fade: number?)
	if entry.currentAnim == name then
		return
	end
	for trackName, track in entry.tracks do
		if trackName ~= name and track.IsPlaying then
			track:Stop(fade or 0.15)
		end
	end
	local target = (entry.tracks :: any)[name]
	if target and not target.IsPlaying then
		target:Play(fade or 0.15)
	end
	entry.currentAnim = name
end

local function onSpawn(payload)
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	if enemies[payload.id] then
		return
	end
	local entry = buildEnemy(payload)
	if entry then
		enemies[payload.id] = entry
	end
end

local function onDespawn(id: number)
	local entry = enemies[id]
	if not entry then
		return
	end
	enemies[id] = nil
	if entry.model.Parent then
		entry.model:Destroy()
	end
end

local function onAttack(id: number)
	local entry = enemies[id]
	if not entry then
		return
	end
	entry.tracks.attack:Play(0.1)
end

local function onPositions(buf: buffer)
	if typeof(buf) ~= "buffer" then
		return
	end
	local count = buffer.readu16(buf, 0)
	local offset = 2
	local now = workspace:GetServerTimeNow()
	local interpDur = 1 / Constants.REPLICATION.UPDATE_RATE_HZ
	for _ = 1, count do
		local id = buffer.readu16(buf, offset)
		local state = buffer.readu8(buf, offset + 2)
		local x = decodeFixed(buffer.readi16(buf, offset + 3))
		local y = decodeFixed(buffer.readi16(buf, offset + 5))
		local z = decodeFixed(buffer.readi16(buf, offset + 7))
		local yaw = decodeYaw(buffer.readi16(buf, offset + 9))
		offset += 11

		local entry = enemies[id]
		if entry then
			entry.prevCF = entry.hrp.CFrame
			entry.targetCF = CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
			entry.interpStart = now
			entry.interpDur = interpDur
			entry.state = state
			if state == STATE_WALK then
				setAnim(entry, "walk")
			elseif state == STATE_IDLE then
				setAnim(entry, "idle")
			end
		end
	end
end

local function tick(_dt: number)
	local now = workspace:GetServerTimeNow()
	for _, entry in enemies do
		if not entry.hrp.Parent then
			continue
		end
		local t = math.clamp((now - entry.interpStart) / entry.interpDur, 0, 1.25)
		entry.hrp.CFrame = entry.prevCF:Lerp(entry.targetCF, t)
	end
end

local function handleClickRaycast()
	local mouse = localPlayer:GetMouse()
	local target = mouse.Target
	if not target or not target:IsA("BasePart") then
		return
	end
	if not target:HasTag(ENEMY_TAG) then
		return
	end
	local model = target:FindFirstAncestorOfClass("Model")
	if not model then
		return
	end
	local id = model:GetAttribute(ENEMY_ID_ATTR)
	if typeof(id) ~= "number" then
		return
	end
	print(string.format("[Client] Clicked enemy %d (%s)", id, model.Name))
	clickEvent:FireServer(id)
end

function EnemyController.Init()
	localPlayer = Players.LocalPlayer
	enemyFolder = Instance.new("Folder")
	enemyFolder.Name = "ClientEnemies"
	enemyFolder.Parent = Workspace

	spawnEvent = RemoteService.GetEvent(Constants.REMOTES.SPAWN)
	despawnEvent = RemoteService.GetEvent(Constants.REMOTES.DESPAWN)
	positionsEvent = RemoteService.GetUnreliableEvent(Constants.REMOTES.POSITIONS)
	attackEvent = RemoteService.GetEvent(Constants.REMOTES.ATTACK)
	clickEvent = RemoteService.GetEvent(Constants.REMOTES.CLICK)
	getInitialFn = RemoteService.GetFunction(Constants.REMOTES.GET_INITIAL)
end

function EnemyController.Start()
	spawnEvent.OnClientEvent:Connect(onSpawn)
	despawnEvent.OnClientEvent:Connect(onDespawn)
	attackEvent.OnClientEvent:Connect(onAttack)
	positionsEvent.OnClientEvent:Connect(onPositions)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			handleClickRaycast()
		end
	end)

	RunService.RenderStepped:Connect(tick)

	-- Hydrate any enemies that already exist on the server.
	task.spawn(function()
		local ok, payload = pcall(function()
			return getInitialFn:InvokeServer()
		end)
		if not ok or typeof(payload) ~= "table" then
			return
		end
		for _, enemyPayload in payload.enemies do
			onSpawn(enemyPayload)
		end
	end)
end

return EnemyController
