--!strict
-- Spawner control panel.
-- Ships a single ScreenGui with adjustable spawn rate, max enemy count,
-- and a Kill All button. Server is authoritative; client just nudges
-- values and re-renders whatever the server broadcasts back.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local RemoteService = require(Shared.RemoteService)

local UIController = {}

local settings = {
	spawnRate = Constants.SPAWN.DEFAULT_RATE_PER_SEC,
	maxCount = Constants.SPAWN.DEFAULT_MAX_COUNT,
}

local spawnRateLabel: TextLabel
local maxCountLabel: TextLabel

local settingsEvent: RemoteEvent
local killAllEvent: RemoteEvent
local getInitialFn: RemoteFunction

local function pushSettings()
	settingsEvent:FireServer({
		spawnRate = settings.spawnRate,
		maxCount = settings.maxCount,
	})
end

local function refreshLabels()
	if spawnRateLabel then
		spawnRateLabel.Text = string.format("Spawn Rate  %.1f / s", settings.spawnRate)
	end
	if maxCountLabel then
		maxCountLabel.Text = string.format("Max Enemies  %d", settings.maxCount)
	end
end

local function adjustRate(delta: number)
	settings.spawnRate = math.clamp(
		settings.spawnRate + delta,
		Constants.SPAWN.MIN_RATE,
		Constants.SPAWN.MAX_RATE
	)
	refreshLabels()
	pushSettings()
end

local function adjustCap(delta: number)
	settings.maxCount = math.clamp(
		settings.maxCount + delta,
		Constants.SPAWN.MIN_CAP,
		Constants.SPAWN.MAX_CAP
	)
	refreshLabels()
	pushSettings()
end

local function styleButton(button: TextButton, color: Color3)
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
	button.TextColor3 = Color3.fromRGB(245, 245, 245)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button
end

local function makeRow(parent: Instance, layoutOrder: number): (Frame, TextLabel, TextButton, TextButton)
	local row = Instance.new("Frame")
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	local label = Instance.new("TextLabel")
	label.LayoutOrder = 1
	label.Size = UDim2.new(1, -90, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(225, 225, 230)
	label.Font = Enum.Font.Gotham
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local minus = Instance.new("TextButton")
	minus.LayoutOrder = 2
	minus.Size = UDim2.fromOffset(36, 32)
	minus.Text = "−"
	minus.Parent = row
	styleButton(minus, Color3.fromRGB(70, 72, 84))

	local plus = Instance.new("TextButton")
	plus.LayoutOrder = 3
	plus.Size = UDim2.fromOffset(36, 32)
	plus.Text = "+"
	plus.Parent = row
	styleButton(plus, Color3.fromRGB(70, 72, 84))

	return row, label, minus, plus
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
	panel.AnchorPoint = Vector2.new(0, 0)
	panel.Position = UDim2.new(0, 16, 0, 64)
	panel.Size = UDim2.fromOffset(280, 220)
	panel.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

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
	subtitle.Text = "Adjust live · synced to server"
	subtitle.TextColor3 = Color3.fromRGB(150, 155, 170)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = panel

	local _, rateLabel, rateMinus, ratePlus = makeRow(panel, 3)
	spawnRateLabel = rateLabel
	rateMinus.MouseButton1Click:Connect(function()
		adjustRate(-Constants.SPAWN.RATE_STEP)
	end)
	ratePlus.MouseButton1Click:Connect(function()
		adjustRate(Constants.SPAWN.RATE_STEP)
	end)

	local _, capLabel, capMinus, capPlus = makeRow(panel, 4)
	maxCountLabel = capLabel
	capMinus.MouseButton1Click:Connect(function()
		adjustCap(-Constants.SPAWN.CAP_STEP)
	end)
	capPlus.MouseButton1Click:Connect(function()
		adjustCap(Constants.SPAWN.CAP_STEP)
	end)

	local killAll = Instance.new("TextButton")
	killAll.LayoutOrder = 5
	killAll.Size = UDim2.new(1, 0, 0, 38)
	killAll.Text = "KILL ALL ENEMIES"
	killAll.Parent = panel
	styleButton(killAll, Color3.fromRGB(165, 50, 60))
	killAll.MouseButton1Click:Connect(function()
		killAllEvent:FireServer()
	end)

	refreshLabels()
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
		refreshLabels()
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
			refreshLabels()
		end
	end)
end

return UIController
