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
local SmashEffect = require(Shared.SmashEffect)

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
	tracks: Tracks?,
	currentAnim: string,
	prevCF: CFrame,
	targetCF: CFrame,
	interpStart: number,
	interpDur: number,
	state: number,
	color: Color3,
	materialIndex: number,
	nameIndex: number,
	archetypeIndex: number,
	perfStripped: boolean,
	parentedTo: Folder?,
	visible: boolean,
}

local STATE_IDLE = 0
local STATE_WALK = 1
local STATE_ATTACK = 2

local enemies: { [number]: Entry } = {}
local enemyFolder: Folder
local localPlayer: Player
local frameCounter = 0

-- Reusable scratch buffers for Workspace:BulkMoveTo. Keeping them module-scoped
-- means tick() does no per-frame array allocation; we just `table.clear` and
-- refill. BulkMoveTo collapses N CFrame property writes into one engine call,
-- which is the dominant per-frame cost when hundreds of rigs are visible.
local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}

-- Performance mode: when on, new spawns skip name tags + animations + VFX,
-- and existing rigs are stripped on toggle. Camera shake and smash effects
-- short-circuit. Toggling off restores name tags + animators on every
-- already-spawned rig, so the change applies to existing enemies too.
local perfMode = false

-- Concurrent smash cap. Each Play() bumps the counter, a delayed task
-- decrements it after the longest tween TTL. New smashes past the cap
-- are dropped — bounds VFX cost when the spawner is wide open.
local activeSmashes = 0
local smashTtl = Constants.SMASH.RISE_TIME + Constants.SMASH.HOLD_TIME + Constants.SMASH.FALL_TIME
	+ Constants.SMASH.LAUNCHER_RISE_TIME + Constants.SMASH.LAUNCHER_FALL_TIME

-- Camera shake state. Drives Humanoid.CameraOffset on the local character so
-- impacts near the player rattle the view. Multiple shakes stack via max-amp.
local shakeAmplitude = 0
local shakeStartTime = 0
local shakeDuration = 0
local shakeRng = Random.new()

local function triggerShake(amplitude: number, duration: number)
	if amplitude <= 0 then
		return
	end
	if amplitude >= shakeAmplitude or os.clock() - shakeStartTime > shakeDuration * 0.5 then
		shakeAmplitude = math.max(shakeAmplitude, amplitude)
		shakeStartTime = os.clock()
		shakeDuration = duration
	end
end

local function applyShake()
	local character = localPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if shakeAmplitude <= 0 then
		if humanoid.CameraOffset.Magnitude > 0.001 then
			humanoid.CameraOffset = Vector3.zero
		end
		return
	end
	local elapsed = os.clock() - shakeStartTime
	if elapsed >= shakeDuration then
		shakeAmplitude = 0
		humanoid.CameraOffset = Vector3.zero
		return
	end
	-- Quadratic falloff so the rumble decays naturally.
	local fade = 1 - (elapsed / shakeDuration)
	local amp = shakeAmplitude * fade * fade
	humanoid.CameraOffset = Vector3.new(
		(shakeRng:NextNumber() - 0.5) * 2 * amp,
		(shakeRng:NextNumber() - 0.5) * 2 * amp,
		(shakeRng:NextNumber() - 0.5) * 2 * amp
	)
end

local function maybeShakeForImpact(origin: Vector3)
	if perfMode then
		return
	end
	local character = localPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local dist = (hrp.Position - origin).Magnitude
	local maxDist = Constants.CAMERA_SHAKE.MAX_DISTANCE
	if dist > maxDist then
		return
	end
	local strength = 1 - (dist / maxDist)
	triggerShake(Constants.CAMERA_SHAKE.MAX_AMPLITUDE * strength, Constants.CAMERA_SHAKE.DURATION)
end

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
	-- The default Animate LocalScript ships with rigs returned by
	-- CreateHumanoidModelFromDescription and would clobber our manual
	-- AnimationTracks. BodyColors and the face/torso decals also need to
	-- go so the rolled color/material reads cleanly.
	for _, child in model:GetChildren() do
		if child:IsA("LocalScript") or child:IsA("Script") or child.ClassName == "BodyColors" then
			child:Destroy()
		end
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = color
			descendant.Material = material
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.CanQuery = descendant.Name ~= "HumanoidRootPart"
			descendant.CanTouch = false
		elseif descendant:IsA("Decal") or descendant:IsA("CharacterMesh") or descendant:IsA("Shirt") or descendant:IsA("Pants") then
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

	hrp.Transparency = 1

	if not perfMode then
		local head = model:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			attachNameTag(head, enemyName)
		end
	end

	-- Parent before configuring the Humanoid + loading animations so the
	-- Animator runs in a fully initialised hierarchy.
	model.Parent = enemyFolder
	hrp.CFrame = payload.cf
	hrp.Anchored = true

	humanoid.AutoRotate = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0
	humanoid.DisplayName = ""
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.Health = humanoid.MaxHealth

	-- Drop the bundled Animator unconditionally. The default one comes from
	-- CreateHumanoidModelFromDescription as a "Player" rig and can refuse to
	-- advance when no Player owns the Humanoid; in perf mode we want it gone
	-- so the rig stays in bind pose with zero animation cost.
	local oldAnimator = humanoid:FindFirstChildOfClass("Animator")
	if oldAnimator then
		oldAnimator:Destroy()
	end

	local tracks: Tracks? = nil
	if not perfMode then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid

		tracks = {
			idle = loadTrack(animator, Constants.ANIMATIONS.IDLE),
			walk = loadTrack(animator, Constants.ANIMATIONS.WALK),
			attack = loadTrack(animator, Constants.ANIMATIONS.ATTACK),
		} :: Tracks
		local t = tracks :: Tracks
		t.idle.Looped = true
		t.walk.Looped = true
		t.attack.Looped = false
		t.idle.Priority = Enum.AnimationPriority.Idle
		t.walk.Priority = Enum.AnimationPriority.Movement
		t.attack.Priority = Enum.AnimationPriority.Action
		t.idle:Play(0)
	end

	local entry: Entry = {
		id = payload.id,
		model = model,
		hrp = hrp,
		humanoid = humanoid,
		tracks = tracks,
		currentAnim = if perfMode then "none" else "idle",
		prevCF = payload.cf,
		targetCF = payload.cf,
		interpStart = workspace:GetServerTimeNow(),
		interpDur = 1 / Constants.REPLICATION.UPDATE_RATE_HZ,
		state = STATE_IDLE,
		color = payload.color,
		materialIndex = payload.materialIndex,
		nameIndex = payload.nameIndex,
		archetypeIndex = payload.archetypeIndex,
		perfStripped = perfMode,
		parentedTo = enemyFolder,
		visible = true,
	}
	return entry
end

-- Strip name tag + stop animations on an existing rig. Used when toggling
-- perf mode on at runtime so we don't need to rebuild every enemy.
--
-- Stopping a non-looped Action-priority track mid-play (the attack swing)
-- leaves Motor6D.Transform at the last evaluated frame, which reads as a
-- freeze. So we also destroy the Animator (no further pose evaluation) and
-- snap every Motor6D.Transform to identity to put the rig back in bind pose.
local function stripRigForPerfMode(entry: Entry)
	if entry.perfStripped then
		return
	end
	entry.perfStripped = true
	local head = entry.model:FindFirstChild("Head")
	if head then
		local nameTag = head:FindFirstChild("NameTag")
		if nameTag then
			nameTag:Destroy()
		end
	end
	if entry.tracks then
		for _, track in entry.tracks do
			if track.IsPlaying then
				track:Stop(0)
			end
		end
	end
	entry.tracks = nil
	local animator = entry.humanoid:FindFirstChildOfClass("Animator")
	if animator then
		animator:Destroy()
	end
	for _, descendant in entry.model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			descendant.Transform = CFrame.identity
		end
	end
	entry.currentAnim = "none"
end

-- Inverse of stripRigForPerfMode. Re-attaches the name tag, rebuilds the
-- Animator + idle/walk/attack tracks, and starts idle. Called for each live
-- enemy when perf mode is toggled off so existing rigs come back instead of
-- staying stripped until they're replaced.
local function restoreRigFromPerfMode(entry: Entry)
	if not entry.perfStripped then
		return
	end
	entry.perfStripped = false

	local head = entry.model:FindFirstChild("Head")
	if head and head:IsA("BasePart") and not head:FindFirstChild("NameTag") then
		attachNameTag(head, EnemyVariants.GetName(entry.nameIndex))
	end

	-- Strip should have destroyed the Animator; create a fresh one. Defensive
	-- destroy first in case toggling raced with something else.
	local oldAnimator = entry.humanoid:FindFirstChildOfClass("Animator")
	if oldAnimator then
		oldAnimator:Destroy()
	end
	local animator = Instance.new("Animator")
	animator.Parent = entry.humanoid

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
	entry.tracks = tracks

	-- Drive the right loop based on the last replicated state instead of
	-- always idling — otherwise a walking enemy reads as frozen for one tick.
	if entry.state == STATE_WALK then
		tracks.walk:Play(0)
		entry.currentAnim = "walk"
	else
		tracks.idle:Play(0)
		entry.currentAnim = "idle"
	end
end

local function setAnim(entry: Entry, name: string, fade: number?)
	if perfMode or entry.perfStripped or not entry.tracks then
		return
	end
	if entry.currentAnim == name then
		return
	end
	local tracks = entry.tracks
	for trackName, track in tracks do
		if trackName ~= name and track.IsPlaying then
			track:Stop(fade or 0.15)
		end
	end
	local target = (tracks :: any)[name]
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

local function onAttack(payload)
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local entry = enemies[payload.id]
	if not entry then
		return
	end
	local archetype = EnemyVariants.GetArchetype(entry.archetypeIndex)
	local cooldown = archetype.cooldown
	local swingDuration = cooldown * 0.9

	-- Perf mode: skip every visual; server still does damage on schedule.
	if perfMode or entry.perfStripped or not entry.tracks then
		return
	end
	local tracks = entry.tracks

	local attackTrack = tracks.attack
	-- The raw asset has trailing recovery frames after the visible swing
	-- peaks. We only stretch `0..PEAK` of the asset to cover the swing window
	-- and Stop the track at the peak, so the recovery never plays and the
	-- rig never freezes on the last frame. Passing speed via Play() avoids
	-- the implicit speed=1 reset that Play(fadeTime) does on its own.
	local rawLength = attackTrack.Length
	if rawLength <= 0 then
		rawLength = 0.7
	end
	local visibleSwing = rawLength * Constants.ENEMY.ATTACK_ANIM_PEAK_FRACTION
	local speed = visibleSwing / swingDuration
	if not tracks.walk.IsPlaying and not tracks.idle.IsPlaying then
		tracks.idle:Play(0)
	end
	attackTrack:Play(0.05, 1, speed)
	attackTrack:AdjustSpeed(speed)

	task.delay(swingDuration, function()
		if attackTrack.IsPlaying then
			attackTrack:Stop(0.15)
		end
	end)

	-- Drop VFX entirely once concurrent budget is spent. Anim still plays.
	if activeSmashes >= Constants.PERFORMANCE.MAX_CONCURRENT_SMASHES then
		return
	end

	SmashEffect.PlayWindup(entry.hrp.Position, entry.color)

	if typeof(payload.origin) == "Vector3" and typeof(payload.yaw) == "number" then
		local origin = payload.origin
		local yaw = payload.yaw
		local seed = payload.seed or 0
		local color = entry.color
		local materialIndex = entry.materialIndex
		local archetypeIndex = entry.archetypeIndex
		activeSmashes += 1
		task.delay(swingDuration, function()
			if not perfMode then
				SmashEffect.Play(origin, yaw, color, materialIndex, archetypeIndex, seed)
				maybeShakeForImpact(origin)
			end
		end)
		task.delay(swingDuration + smashTtl, function()
			activeSmashes -= 1
		end)
	end
end

local function onPositions(buf: buffer)
	if typeof(buf) ~= "buffer" then
		return
	end
	debug.profilebegin("Enemy.DecodePositions")
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
	debug.profileend()
end

local function tick(_dt: number)
	debug.profilebegin("Enemy.ClientTick")
	frameCounter += 1
	local now = workspace:GetServerTimeNow()
	-- Cache camera position once per frame; LOD bands are cheap squared compares.
	local camera = Workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	local farSq = Constants.PERFORMANCE.CLIENT_LOD_FAR ^ 2
	local cullSq = Constants.PERFORMANCE.CLIENT_CULL_DISTANCE ^ 2
	local farFrames = Constants.PERFORMANCE.CLIENT_THROTTLE_FRAMES

	table.clear(bulkParts)
	table.clear(bulkCFrames)
	local moveCount = 0

	for _, entry in enemies do
		if not entry.model then
			continue
		end
		local pos = entry.targetCF.Position
		local dx = pos.X - camPos.X
		local dy = pos.Y - camPos.Y
		local dz = pos.Z - camPos.Z
		local distSq = dx * dx + dy * dy + dz * dz

		-- Cull band: park out of Workspace so render doesn't see it. Re-parent
		-- on return. Cheaper than transparency tweaks because the rig stops
		-- being considered for rendering / animation eval entirely.
		if distSq > cullSq then
			if entry.visible then
				entry.model.Parent = nil
				entry.visible = false
			end
			continue
		elseif not entry.visible then
			entry.model.Parent = entry.parentedTo
			entry.visible = true
		end

		-- Far band: throttle interpolation updates.
		if distSq > farSq and (frameCounter % farFrames) ~= (entry.id % farFrames) then
			continue
		end

		if not entry.hrp.Parent then
			continue
		end
		local t = math.clamp((now - entry.interpStart) / entry.interpDur, 0, 1.25)
		moveCount += 1
		bulkParts[moveCount] = entry.hrp
		bulkCFrames[moveCount] = entry.prevCF:Lerp(entry.targetCF, t)
	end

	-- One C++ call replaces N CFrame property writes. FireCFrameChanged keeps
	-- attachments / welds / streaming aware of the move; the alternative
	-- (FireAllEvents) is unnecessary work for anchored rigs with no welds.
	if moveCount > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	if not perfMode then
		applyShake()
	end
	debug.profileend()
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

function EnemyController.SetPerformanceMode(enabled: boolean)
	if perfMode == enabled then
		return
	end
	perfMode = enabled
	if enabled then
		-- Strip existing rigs in place — name tags off, animations stopped.
		for _, entry in enemies do
			stripRigForPerfMode(entry)
		end
		-- Cancel any pending camera shake.
		shakeAmplitude = 0
		shakeDuration = 0
		local character = localPlayer and localPlayer.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			humanoid.CameraOffset = Vector3.zero
		end
	else
		-- Re-attach name tags + rebuild animators on existing rigs so they
		-- come back to full visuals immediately, not only on next spawn.
		for _, entry in enemies do
			restoreRigFromPerfMode(entry)
		end
	end
end

function EnemyController.IsPerformanceMode(): boolean
	return perfMode
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
