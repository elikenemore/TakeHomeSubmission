-- One-script-hierarchy bootstrap for the client.
-- Mirror of the server bootstrap: requires every controller, then runs Init()
-- and Start() in two passes so cross-controller wiring is safe in Start.

local controllers = {}
local controllerFolder = script.Parent:WaitForChild("Controllers")

for _, child in controllerFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		controllers[child.Name] = require(child)
	end
end

for _, controller in controllers do
	if typeof(controller.Init) == "function" then
		controller.Init()
	end
end

for _, controller in controllers do
	if typeof(controller.Start) == "function" then
		controller.Start()
	end
end

print("[Client] Game booted with " .. tostring(#controllerFolder:GetChildren()) .. " controllers.")
