--!strict
-- Spawner control panel.
-- Two TextBox inputs (spawn rate, max count) and a Kill All button.
-- Server is authoritative; client sends edits, then re-renders whatever the
-- server broadcasts back.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local RemoteService = require(Shared.RemoteService)

local EnemyController = require(script.Parent.EnemyController)

local UIController = {}

local settings = {
	spawnRate = Constants.SPAWN.DEFAULT_RATE_PER_SEC,
	maxCount = Constants.SPAWN.DEFAULT_MAX_COUNT,
}

local rateBox: TextBox
local capBox: TextBox

local settingsEvent: RemoteEvent
local killAllEvent: RemoteEvent
local getInitialFn: RemoteFunction

local function pushSettings()
	settingsEvent:FireServer({
		spawnRate = settings.spawnRate,
		maxCount = settings.maxCount,
	})
end

local function refreshInputs()
	if rateBox then
		rateBox.Text = string.format("%.1f", settings.spawnRate)
	end
	if capBox then
		capBox.Text = tostring(settings.maxCount)
	end
end

local function commitRate(text: string)
	local n = tonumber(text)
	if not n then
		refreshInputs()
		return
	end
	settings.spawnRate = math.clamp(n, Constants.SPAWN.MIN_RATE, Constants.SPAWN.MAX_RATE)
	refreshInputs()
	pushSettings()
end

local function commitCap(text: string)
	local n = tonumber(text)
	if not n then
		refreshInputs()
		return
	end
	settings.maxCount = math.clamp(math.floor(n), Constants.SPAWN.MIN_CAP, Constants.SPAWN.MAX_CAP)
	refreshInputs()
	pushSettings()
end

local function styleCorner(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function makeInputRow(parent: Instance, layoutOrder: number, labelText: string): TextBox
	local row = Instance.new("Frame")
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	local label = Instance.new("TextLabel")
	label.LayoutOrder = 1
	label.Size = UDim2.new(1, -90, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(225, 225, 230)
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local box = Instance.new("TextBox")
	box.LayoutOrder = 2
	box.Size = UDim2.fromOffset(80, 32)
	box.BackgroundColor3 = Color3.fromRGB(50, 52, 62)
	box.BorderSizePixel = 0
	box.TextColor3 = Color3.fromRGB(245, 245, 245)
	box.Font = Enum.Font.GothamMedium
	box.TextSize = 16
	box.PlaceholderText = "..."
	box.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
	box.ClearTextOnFocus = false
	box.Parent = row
	styleCorner(box, 6)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 85, 100)
	stroke.Transparency = 0.5
	stroke.Parent = box

	return box
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "EnemyControlUI"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.new(0, 16, 0, 64)
	panel.Size = UDim2.fromOffset(280, 268)
	panel.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = screenGui
	styleCorner(panel, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 65, 80)
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 14)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 24)
	title.BackgroundTransparency = 1
	title.Text = "ENEMY SPAWNER"
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = panel

	local subtitle = Instance.new("TextLabel")
	subtitle.LayoutOrder = 2
	subtitle.Size = UDim2.new(1, 0, 0, 16)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Type a value, press Enter"
	subtitle.TextColor3 = Color3.fromRGB(150, 155, 170)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = panel

	rateBox = makeInputRow(panel, 3, "Spawn Rate / s")
	rateBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			commitRate(rateBox.Text)
		else
			refreshInputs()
		end
	end)

	capBox = makeInputRow(panel, 4, "Max Enemies")
	capBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			commitCap(capBox.Text)
		else
			refreshInputs()
		end
	end)

	local killAll = Instance.new("TextButton")
	killAll.LayoutOrder = 5
	killAll.Size = UDim2.new(1, 0, 0, 38)
	killAll.Text = "KILL ALL ENEMIES"
	killAll.BackgroundColor3 = Color3.fromRGB(165, 50, 60)
	killAll.AutoButtonColor = true
	killAll.BorderSizePixel = 0
	killAll.TextColor3 = Color3.fromRGB(245, 245, 245)
	killAll.Font = Enum.Font.GothamBold
	killAll.TextSize = 16
	killAll.Parent = panel
	styleCorner(killAll, 6)
	killAll.MouseButton1Click:Connect(function()
		killAllEvent:FireServer()
	end)

	-- Performance mode: client-side strip of VFX, nametags, animations,
	-- and camera shake. Server-side AI is unchanged. Used when stress
	-- testing high spawn counts.
	local perfBtn = Instance.new("TextButton")
	perfBtn.LayoutOrder = 6
	perfBtn.Size = UDim2.new(1, 0, 0, 38)
	perfBtn.BackgroundColor3 = Color3.fromRGB(55, 100, 70)
	perfBtn.AutoButtonColor = true
	perfBtn.BorderSizePixel = 0
	perfBtn.TextColor3 = Color3.fromRGB(245, 245, 245)
	perfBtn.Font = Enum.Font.GothamBold
	perfBtn.TextSize = 14
	perfBtn.Text = "PERFORMANCE MODE: OFF"
	perfBtn.Parent = panel
	styleCorner(perfBtn, 6)

	local function refreshPerfButton()
		if EnemyController.IsPerformanceMode() then
			perfBtn.Text = "PERFORMANCE MODE: ON"
			perfBtn.BackgroundColor3 = Color3.fromRGB(180, 130, 50)
		else
			perfBtn.Text = "PERFORMANCE MODE: OFF"
			perfBtn.BackgroundColor3 = Color3.fromRGB(55, 100, 70)
		end
	end

	perfBtn.MouseButton1Click:Connect(function()
		local enabled = not EnemyController.IsPerformanceMode()
		EnemyController.SetPerformanceMode(enabled)
		-- Also tell the server so it can drop spatial-hash + separation work.
		settingsEvent:FireServer({ perfMode = enabled })
		refreshPerfButton()
	end)

	refreshInputs()
	refreshPerfButton()
end

function UIController.Init()
	settingsEvent = RemoteService.GetEvent(Constants.REMOTES.SETTINGS)
	killAllEvent = RemoteService.GetEvent(Constants.REMOTES.KILL_ALL)
	getInitialFn = RemoteService.GetFunction(Constants.REMOTES.GET_INITIAL)
end

function UIController.Start()
	buildUI()

	settingsEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		if typeof(payload.spawnRate) == "number" then
			settings.spawnRate = payload.spawnRate
		end
		if typeof(payload.maxCount) == "number" then
			settings.maxCount = payload.maxCount
		end
		refreshInputs()
	end)

	task.spawn(function()
		local ok, payload = pcall(function()
			return getInitialFn:InvokeServer()
		end)
		if ok and typeof(payload) == "table" then
			if typeof(payload.spawnRate) == "number" then
				settings.spawnRate = payload.spawnRate
			end
			if typeof(payload.maxCount) == "number" then
				settings.maxCount = payload.maxCount
			end
			refreshInputs()
		end
	end)
end

return UIController
