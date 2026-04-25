--!strict
-- Lazy creator/getter for RemoteEvents, UnreliableRemoteEvents, and RemoteFunctions.
-- Server creates on demand. Client waits for the instance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RemoteService = {}

local FOLDER_NAME = "Remotes"

local function getOrCreateFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if RunService:IsServer() then
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = ReplicatedStorage
		return f
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

local function getOrCreate(name: string, className: string): Instance
	local folder = getOrCreateFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end
	if RunService:IsServer() then
		local instance = Instance.new(className)
		instance.Name = name
		instance.Parent = folder
		return instance
	end
	return folder:WaitForChild(name)
end

function RemoteService.GetEvent(name: string): RemoteEvent
	return getOrCreate(name, "RemoteEvent") :: RemoteEvent
end

function RemoteService.GetUnreliableEvent(name: string): UnreliableRemoteEvent
	return getOrCreate(name, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
end

function RemoteService.GetFunction(name: string): RemoteFunction
	return getOrCreate(name, "RemoteFunction") :: RemoteFunction
end

return RemoteService
