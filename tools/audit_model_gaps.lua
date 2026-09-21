-- Probe for tools/runtest.ps1: is every piece of every ITEM actually attached to the item?
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_model_gaps.lua
--
-- tools/gun_gaps_probe.lua asks this of the guns, and crucially nothing asked it of the items,
-- the crates or the chest. It is the opposite mistake to z-fighting: the z-fight pass hunts faces
-- that sit too CLOSE, and nothing looks for a piece that ends a few hundredths SHORT of the thing
-- it's meant to be fixed to. Welded, it never falls off; it just hangs there with daylight showing
-- round it, which in the hand or the first-person view is exactly what "a hole in the model" looks
-- like. (The Brainrot Fortress's carry handle hung 0.03 under the crate that way.)
--
-- Every part is grown by SLACK and asked what it then touches — real shapes, so a cylinder is a
-- cylinder and not its box. That gives a graph; anything not joined to the body by it is an island,
-- reported with how far it would have to grow to reach the model at all. Parts marked
-- IntentionalFloat are left out, and so are models whose pieces are meant to hang apart.
--
-- The planted round pushes one part of a known-clean model out by a tenth of a stud: it MUST be
-- reported, or a clean result here means nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))

-- Parts closer than this count as joined: half a hundredth of a stud each way, so two faces that
-- end exactly level are touching and a 0.02 slit is not.
local SLACK = 0.005
-- How far out the report looks when saying how far an island sits from everything else.
local STEPS = { 0.02, 0.05, 0.1, 0.2, 0.4, 0.8 }

local function out(fmt, ...)
	print("[AUDIT gaps] " .. string.format(fmt, ...))
end

local stage = Instance.new("Folder")
stage.Name = "GapProbeStage"
stage.Parent = workspace

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.MaxParts = 64

-- The visible parts, with queries turned on: the builders turn CanQuery off, and a spatial query
-- can't see a part that has it off.
local function partsOf(model)
	local parts = {}
	-- The root itself counts when it's a part: the map chest IS a part, with its planks, straps and
	-- lid staves hanging off it, and leaving it out would report every one of them as an island.
	local candidates = model:GetDescendants()
	if model:IsA("BasePart") then
		table.insert(candidates, model)
	end
	for _, d in ipairs(candidates) do
		if d:IsA("BasePart") and d.Transparency < 0.98 and not d:GetAttribute("IntentionalFloat") then
			d.CanQuery = true
			table.insert(parts, d)
		end
	end
	return parts
end

-- What `part` touches when grown by `grow`, as a set. The probe is a copy of the part, so a
-- cylinder is tested as a cylinder and a ball as a ball.
local function touching(part, others, grow)
	overlap.FilterDescendantsInstances = others
	local probe = part:Clone()
	probe:ClearAllChildren()
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanQuery = true
	probe.Transparency = 1
	probe.Size = part.Size + Vector3.new(grow, grow, grow) * 2
	probe.CFrame = part.CFrame
	probe.Parent = stage
	local hit = {}
	for _, other in ipairs(workspace:GetPartsInPart(probe, overlap)) do
		hit[other] = true
	end
	probe:Destroy()
	return hit
end

local function measure(label, model, body)
	if not model then
		out("%s: nothing built", label)
		return 0
	end
	model.Parent = stage
	local parts = partsOf(model)
	if #parts == 0 then
		model:Destroy()
		return 0
	end
	local others = {}
	for _, part in ipairs(parts) do
		table.insert(others, part)
	end

	-- Who touches whom.
	local joined = {}
	for _, part in ipairs(parts) do
		joined[part] = {}
	end
	for _, part in ipairs(parts) do
		for other in pairs(touching(part, others, SLACK)) do
			if other ~= part and joined[other] then
				joined[part][other] = true
				joined[other][part] = true
			end
		end
	end

	-- Everything reachable from the body.
	local root = (body and joined[body]) and body or parts[1]
	local seen, queue = { [root] = true }, { root }
	while #queue > 0 do
		local part = table.remove(queue)
		for other in pairs(joined[part]) do
			if not seen[other] then
				seen[other] = true
				table.insert(queue, other)
			end
		end
	end

	-- Models that are legitimately more than one piece. A pair of boots is a pair.
	local PAIRS = { BounceBoots = true }
	local islands = {}
	for _, part in ipairs(parts) do
		if not seen[part] then
			-- How far it would have to grow to touch anything at all.
			local reach = "over " .. tostring(STEPS[#STEPS])
			for _, grow in ipairs(STEPS) do
				if next(touching(part, others, grow)) ~= nil then
					reach = string.format("%.2f", grow)
					break
				end
			end
			table.insert(islands, string.format("%s (%s from the rest)", part.Name, reach))
		end
	end
	local expected = PAIRS[model:GetAttribute("ItemId")] and 1 or 0
	if #islands > expected then
		out("%s: %d parts, %d hanging apart [%s]", label, #parts, #islands, table.concat(islands, "; "))
	end
	model:Destroy()
	return math.max(#islands - expected, 0)
end

-- Self-test: a model that comes back clean, then the same model with one part pushed out.
local control, controlBody = ItemModels.Build("MedKit")
local clean = measure("self-test control (MedKit)", control, controlBody)
local planted, plantedBody = ItemModels.Build("MedKit")
for _, part in ipairs(planted:GetDescendants()) do
	if part:IsA("BasePart") and part.Name == "Latch" then
		part.CFrame = part.CFrame * CFrame.new(0, 0, -0.1)
		break
	end
end
local plantedBad = measure("self-test planted (MedKit, one latch pushed out 0.1)", planted, plantedBody)
out("self-test: control %d islands, planted %d -> %s", clean, plantedBad,
	(clean == 0 and plantedBad > 0) and "PASS" or "FAIL (a clean result below would prove nothing)")

local total = clean + plantedBad
local ids = {}
for id in pairs(ItemData.Items) do
	table.insert(ids, id)
end
table.sort(ids)
for index, id in ipairs(ids) do
	local model, body = ItemModels.Build(id)
	total += measure("item " .. id, model, body)
	if index % 5 == 0 then
		task.wait()
	end
end

-- The packed glider only; the open canopy's cells are meant to sit on an arc away from the bar.
for _, tier in ipairs(Rarity.Order or {}) do
	local ok, model = pcall(CrateModels.Crate, tier)
	if ok and typeof(model) == "Instance" then
		total += measure("crate " .. tier, model, model:IsA("Model") and model.PrimaryPart or nil)
	end
end
local okChest, chest = pcall(CrateModels.Chest, CFrame.new())
if okChest and typeof(chest) == "Instance" then
	total += measure("chest", chest, chest:IsA("Model") and chest.PrimaryPart or nil)
end

out("RESULT %s: %d parts hanging apart from the model they belong to (the planted one included)",
	total == plantedBad and "PASS" or "FAIL", total)
stage:Destroy()
pcall(flush)
