-- One-script-hierarchy bootstrap for the server.
-- Requires every ModuleScript under ./Services and runs Init() then Start()
-- on each, mirroring the lifecycle pattern used by the client.

local services = {}
-- Rojo collapses init.server.lua into the parent directory (so `script` IS Game,
-- and Services is a child). DonkeySync makes Game a Folder with init as a Script
-- child (so Services lives on script.Parent). Handle both.
local serviceFolder = script:FindFirstChild("Services") or script.Parent:WaitForChild("Services")

for _, child in serviceFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		services[child.Name] = require(child)
	end
end

for name, service in services do
	if typeof(service.Init) == "function" then
		service.Init()
	end
end

for name, service in services do
	if typeof(service.Start) == "function" then
		service.Start()
	end
end

print("[Server] Game booted with " .. tostring(#serviceFolder:GetChildren()) .. " services.")
