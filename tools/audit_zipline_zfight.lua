-- Probe for tools/runtest.ps1 -Probe: flush face pairs on a zipline model by itself.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_zipline_zfight.lua
--
-- Builds a zipline with a post at each end, and one that starts from a platform rail (no post at
-- the top), out of the workspace so nothing pairs with the Terrain, and lists every flush pair
-- ZFight's fix pass would act on. Also prints each part's bottom and top, to show what stands above
-- the ground (y = 0 here) is as it was: mat top 0.3, base plate top 0.6.

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local ZiplineService = require(modules:WaitForChild("ZiplineService"))

local function out(fmt, ...)
	print("[AUDIT zipline] " .. string.format(fmt, ...))
end

local holder = Instance.new("Folder")
local cases = {
	{ "posts at both ends", Vector3.new(0, 0, 0), Vector3.new(80, -30, 0), nil },
	{ "from a platform rail", Vector3.new(0, 0, 40), Vector3.new(80, -30, 40), Vector3.new(0, 20, 40) },
}
local total = 0
for _, case in ipairs(cases) do
	local model = ZiplineService.Create(holder, case[2], case[3], case[4])
	if not model then
		out("%s: not built", case[1])
	else
		local pairsFound = ZFight.Scan({ model }, ZFight.FixTolerance)
		total += #pairsFound
		out("%s: %d parts, %d flush pairs", case[1], #model:GetChildren(), #pairsFound)
		for _, pair in ipairs(pairsFound) do
			out("    %s (%s) / %s (%s), gap %.3f", pair.a.Name, tostring(pair.a.Size), pair.b.Name, tostring(pair.b.Size), pair.gap or -1)
		end
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") then
				local ground = case[3].Y
				local extent = math.abs(part.CFrame.UpVector.Y) * part.Size.Y + math.abs(part.CFrame.RightVector.Y) * part.Size.X
					+ math.abs(part.CFrame.LookVector.Y) * part.Size.Z
				local bottom, top = part.Position.Y - extent / 2, part.Position.Y + extent / 2
				if bottom < ground + 1 then
					out("    near the landing ground: %s %s bottom %.2f top %.2f (relative to the ground)", part.Name, tostring(part.Size), bottom - ground,
						top - ground)
				end
			end
		end
	end
end
holder:Destroy()
out("RESULT %d flush pairs", total)
pcall(flush)
