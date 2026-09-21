-- Every crate CrateData sells, for tools/gallery.ps1 — it renders AND measures (the notes are the probe):
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crate_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Oliver's #21: crates that read as their tier at the size of a card. Each crate is shown from the
-- card's angle at the reveal's scale, then the whole row. Measured per crate, the way the items
-- were: built once with the z-fight pass OFF (the geometry as written) and once as the game builds
-- it, so a flush pair the builder's own pass would silently reshape shows up as written; plus the
-- contract the reveal and the altar rely on — the lid is a Part named Lid with its pivot at the
-- hinge, lidBand is neon and tinted, every tinted part is a BasePart, halo lights are marked as
-- floating on purpose. Planted every run: a part duplicated in place must read as a flush pair.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CrateData = require(Shared:WaitForChild("CrateData"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local BASE = Vector3.new(0, 1200, 0)
local SPACING = 7

local state = { checks = 0, failures = 0, crates = {} }

local function note(text)
	print("[BRR_Gallery] note " .. text)
end
local function check(ok, text)
	state.checks += 1
	if not ok then
		state.failures += 1
	end
	note((ok and "PASS  " or "FAIL  ") .. text)
end
local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 40
	camera.CFrame = CFrame.lookAt(eye, target)
end
local function partsOf(model)
	local list = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

local tiers = CrateData.Order or Rarity.Order
local stage = Instance.new("Folder")
stage.Name = "CrateGalleryStage"
stage.Parent = workspace

local views = {}
local function add(name, fn, hold)
	table.insert(views, { name = name, settle = 1.2, hold = hold or 2, setup = fn })
end

-- Builds one tier twice and measures it; parents the normal build into the row.
local function measure(tier, index)
	local color = (CrateData.Crates[tier] and CrateData.Crates[tier].color) or Rarity.Color(tier)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local okRaw, raw = pcall(CrateModels.Crate, tier, { color = color })
	ZFight.Enabled = wasEnabled
	local okBuilt, model, lid, lidBand, tinted = pcall(CrateModels.Crate, tier, { color = color })
	if not (okRaw and raw and okBuilt and model) then
		check(false, string.format("%s: build failed (%s / %s)", tier, tostring(raw), tostring(model)))
		return nil
	end
	local written = #ZFight.Scan({ raw }, ZFight.FixTolerance)
	raw:Destroy()
	local moved = 0
	for _, p in ipairs(partsOf(model)) do
		if p:GetAttribute("ZFixed") then
			moved += 1
		end
	end
	local tintedParts, tintedOk = 0, true
	for _, p in ipairs(tinted or {}) do
		tintedParts += 1
		if not (typeof(p) == "Instance" and p:IsA("BasePart")) then
			tintedOk = false
		end
	end
	local halo, haloMarked = 0, 0
	for _, p in ipairs(partsOf(model)) do
		if p.Name == "HaloLight" then
			halo += 1
			if p:GetAttribute("IntentionalFloat") then
				haloMarked += 1
			end
		end
	end
	local hinge = lid and lid:GetAttribute("Hinge")
	check(written == 0 and moved == 0, string.format("%-14s %2d parts; written flush pairs %d, parts the pass changed %d", tier, #partsOf(model), written, moved))
	check(lid ~= nil and lid:IsA("BasePart") and lid.Name == "Lid" and typeof(hinge) == "CFrame" and lid.PivotOffset == hinge,
		string.format("%-14s lid is a Part named Lid, pivot at its hinge (%s)", tier, tostring(hinge)))
	check(lidBand ~= nil and lidBand.Material == Enum.Material.Neon and tintedOk and tintedParts > 0,
		string.format("%-14s lidBand neon %s; %d tinted parts, all BaseParts %s", tier, tostring(lidBand and lidBand.Material == Enum.Material.Neon), tintedParts, tostring(tintedOk)))
	if halo > 0 then
		check(haloMarked == halo, string.format("%-14s %d halo lights, %d marked IntentionalFloat", tier, halo, haloMarked))
	end
	model:PivotTo(CFrame.new(BASE + Vector3.new((index - (#tiers + 1) / 2) * SPACING, 0, 0)))
	model.Parent = stage
	return model
end

add("crate_row", function(_, camera)
	for index, tier in ipairs(tiers) do
		state.crates[tier] = measure(tier, index)
	end
	-- Planted: a part duplicated in place must read as a flush pair.
	local sample = state.crates[tiers[1]]
	if sample then
		local victim = sample:FindFirstChild("Body")
		local twin = victim:Clone()
		twin.Parent = sample
		local planted = #ZFight.Scan({ sample }, ZFight.FixTolerance)
		twin:Destroy()
		check(planted > 0, string.format("self-test: a part duplicated in place reads %d flush pairs (want > 0)", planted))
	end
	look(camera, BASE + Vector3.new(0, 9, -34), BASE + Vector3.new(0, 1.8, 0), 62)
end, 3)

-- Each crate from the card's angle: a quarter turn to its left, a little above, facing its front.
for _, tier in ipairs(tiers) do
	add("crate_" .. tier, function(_, camera)
		local model = state.crates[tier]
		if not model then
			return
		end
		local at = model:GetPivot().Position
		look(camera, at + Vector3.new(4.6, 4.4, -6.6), at + Vector3.new(0, 1.7, 0), 40)
		local style = CrateModels.Styles[tier]
		local features = {}
		for key, value in pairs(style or {}) do
			table.insert(features, key .. "=" .. tostring(value))
		end
		table.sort(features)
		note(string.format("%s: %s", tier, table.concat(features, " ")))
	end, 2)
end

add("crate_row_front", function(_, camera)
	look(camera, BASE + Vector3.new(0, 4, -30), BASE + Vector3.new(0, 1.8, 0), 70)
end, 2)

add("result", function(_, camera)
	note(string.format("RESULT %s: %d checks, %d failed", state.failures == 0 and "PASS" or "FAIL", state.checks, state.failures))
	look(camera, BASE + Vector3.new(0, 9, -34), BASE + Vector3.new(0, 1.8, 0), 62)
end, 1)

return views
