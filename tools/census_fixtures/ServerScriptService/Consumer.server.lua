local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local LiveModule = require(Shared:WaitForChild("LiveModule"))

-- Loaded by a name held in a table: the literal never appears beside `require`.
local LAZY = { "AliasedModule" }
for _, name in ipairs(LAZY) do
	require(Shared:WaitForChild(name))
end

local Hooks = {}
-- A value reference, not a call. This is the shape that fooled the first version of the census.
Hooks.OnPart = LiveModule.CalledAsValue

local function run(part)
	if Hooks.OnPart and Hooks.OnPart(part) then
		return LiveModule.CalledNormally()
	end
	return 0
end

run(nil)
