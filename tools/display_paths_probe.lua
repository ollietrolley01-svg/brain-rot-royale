-- Probe for tools/runtest.ps1 -Probe: every path that puts a gun on the ground or on display, measured
-- part by part against the gun GunModels builds.
--
--   build:  the builder twice over, to show it's deterministic (every other comparison relies on it)
--   floor:  LootService.DropWeapon, the real floor pickup (pad, gun, label, prompt, the pad's z-fight pass)
--   podium: LobbyService.Build's arena podiums, after the whole-lobby z-fight pass
--
-- For each gun it prints the part counts, how many parts are missing, moved or resized against the
-- reference placed the way that path places it, and the worst offenders by name.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/display_paths_probe.lua -WaitSeconds 240

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local WeaponService = require(modules:WaitForChild("WeaponService"))

local POSITION_TOLERANCE = 0.001 -- studs
local SIZE_TOLERANCE = 0.0005
local ANGLE_TOLERANCE = math.rad(0.05)

local function out(text)
	print("[PROBE] " .. text)
end

local function reference(def)
	local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	local list = {}
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(list, { name = child.Name, cframe = child.CFrame, size = child.Size, fixed = child:GetAttribute("ZFixed") ~= nil })
		end
	end
	model:Destroy()
	return list
end

local function baseParts(parent)
	local list = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(list, child)
		end
	end
	return list
end

-- The lobby renames a podium gun's receiver DisplayGun.
local function sameName(part, r)
	return part ~= nil and (part.Name == r.name or (r.name == "Receiver" and part.Name == "DisplayGun"))
end

-- Where the reference's run of names starts among the placed parts (a pad or other parts can come first).
local function lineUp(placed, ref)
	for offset = 0, math.max(0, #placed - 1) do
		local ok = true
		for index = 1, math.min(#ref, 12) do
			if not sameName(placed[offset + index], ref[index]) then
				ok = false
				break
			end
		end
		if ok then
			return offset
		end
	end
	return nil
end

local function compare(path, id, placed, ref, frame)
	local offset = lineUp(placed, ref)
	if not offset then
		out(string.format("%s %s: placed %d parts, reference %d, and the names never line up", path, id, #placed, #ref))
		return
	end
	local missing, moved, turned, resized, fixed, refFixed = 0, 0, 0, 0, 0, 0
	local worst = {}
	for index, r in ipairs(ref) do
		local part = placed[offset + index]
		if r.fixed then
			refFixed += 1
		end
		if not sameName(part, r) then
			missing += 1
		else
			local expected = frame * r.cframe
			local error = (part.Position - expected.Position).Magnitude
			local _, angle = (expected.Rotation:Inverse() * part.CFrame.Rotation):ToAxisAngle()
			local grown = (part.Size - r.size).Magnitude
			if part:GetAttribute("ZFixed") ~= nil then
				fixed += 1
			end
			if error > POSITION_TOLERANCE then
				moved += 1
			end
			if math.abs(angle) > ANGLE_TOLERANCE then
				turned += 1
			end
			if grown > SIZE_TOLERANCE then
				resized += 1
			end
			local score = error + grown + math.abs(angle)
			if score > POSITION_TOLERANCE then
				table.insert(worst, { score = score, text = string.format("%s moved %.4f grew %.4f turned %.2fdeg", r.name, error, grown, math.deg(math.abs(angle))) })
			end
		end
	end
	table.sort(worst, function(a, b)
		return a.score > b.score
	end)
	local names = {}
	for index = 1, math.min(4, #worst) do
		table.insert(names, worst[index].text)
	end
	out(string.format("%s %s: reference %d, placed %d (gun from +%d), missing %d, moved %d, turned %d, resized %d, z-fixed %d (reference %d)%s",
		path, id, #ref, #placed - offset, offset, missing, moved, turned, resized, fixed, refFixed,
		#names > 0 and (" | " .. table.concat(names, "; ")) or ""))
	return missing, moved, turned, resized
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local refs = {}
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, result = pcall(reference, def)
	if ok then
		refs[id] = result
	else
		out(string.format("build %s: failed: %s", id, tostring(result)))
	end
end

-- Self-test: the same gun, placed with three planted faults, has to come back as one moved, one resized
-- and one missing. Otherwise "0 missing, 0 moved" on every path below would only prove the probe ran.
do
	local id = ids[1]
	local def = WeaponData.Get(id)
	local ref = refs[id]
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal)
	if ok and model and ref and #ref >= 16 then
		local parts = baseParts(model)
		parts[2].CFrame = parts[2].CFrame * CFrame.new(0, 0.02, 0)
		parts[3].Size = parts[3].Size + Vector3.new(0.01, 0, 0)
		-- Renamed rather than removed, and past the names lineUp matches on, so the rest still line up.
		parts[14].Name = "PlantedStranger"
		local missing, moved, _, resized = compare("SELFTEST", id, parts, ref, CFrame.identity)
		out(string.format("self-test %s: planted 1 moved, 1 resized, 1 renamed -> missing %d, moved %d, resized %d (want at least 1 each)",
			(missing >= 1 and moved >= 1 and resized >= 1) and "ok" or "FAILED", missing, moved, resized))
		model:Destroy()
	else
		out("self-test FAILED: no reference to plant faults against")
	end
end

-- The builder is deterministic, or nothing below means anything.
for _, id in ipairs(ids) do
	if refs[id] then
		local model = WeaponService.BuildGunModel(WeaponData.Get(id), Rarity.Color(WeaponData.Get(id).rarity), Enum.Material.Metal)
		compare("build", id, baseParts(model), refs[id], CFrame.identity)
		model:Destroy()
	end
end

-- Floor: the real drop, in the air over nothing so the snap to the ground leaves it where it is.
local okLoot, LootService = pcall(require, modules:WaitForChild("LootService"))
if not okLoot then
	out("floor: LootService didn't load: " .. tostring(LootService))
else
	for index, id in ipairs(ids) do
		if refs[id] then
			local before = {}
			local loot = workspace:FindFirstChild("Loot")
			for _, child in ipairs(loot and loot:GetChildren() or {}) do
				before[child] = true
			end
			local ok, err = pcall(LootService.DropWeapon, id, Vector3.new(index * 12, 2000, 3000))
			loot = workspace:FindFirstChild("Loot")
			local base
			for _, child in ipairs(loot and loot:GetChildren() or {}) do
				if not before[child] and child:GetAttribute("WeaponId") == id then
					base = child
				end
			end
			if not ok or not base then
				out(string.format("floor %s: no pickup (%s)", id, tostring(err)))
			else
				compare("floor", id, baseParts(base), refs[id], base.CFrame * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.pi / 2, math.rad(-10)))
			end
		end
	end
end

-- Podiums: the whole lobby, as MatchService builds it, z-fight pass and all.
local okLobby, LobbyService = pcall(require, modules:WaitForChild("LobbyService"))
if not okLobby then
	out("podium: LobbyService didn't load: " .. tostring(LobbyService))
else
	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace
	local started = os.clock()
	local ok, err = pcall(LobbyService.Build, lobby, MatchConfig.LobbyPosition)
	out(string.format("podium: lobby built ok=%s in %.1fs %s, ZFightMoved=%s", tostring(ok), os.clock() - started, ok and "" or tostring(err), tostring(lobby:GetAttribute("ZFightMoved"))))
	-- The podium guns live in GunDisplays (they were in StageDisplay, inside the lobby's z-fight pass).
	local displays = {}
	for _, folderName in ipairs({ "GunDisplays", "StageDisplay" }) do
		local folder = workspace:FindFirstChild(folderName)
		for _, child in ipairs(folder and folder:GetChildren() or {}) do
			table.insert(displays, child)
		end
	end
	local stage = workspace:FindFirstChild("StageDisplay")
	for _, display in ipairs(displays) do
		local receiver = display:FindFirstChild("DisplayGun")
		if receiver then
			local placed = baseParts(display)
			-- Which gun: the one whose part names line up best all the way through.
			local matched, best = nil, -1
			for _, id in ipairs(ids) do
				local ref = refs[id]
				local offset = ref and lineUp(placed, ref)
				if offset then
					local same = 0
					for index, r in ipairs(ref) do
						if sameName(placed[offset + index], r) then
							same += 1
						end
					end
					if same - math.abs(#placed - offset - #ref) > best then
						matched, best = id, same - math.abs(#placed - offset - #ref)
					end
				end
			end
			if matched then
				compare("podium", matched, placed, refs[matched], display.CFrame * CFrame.Angles(0, math.pi / 2, math.rad(-12)))
			else
				out(string.format("podium: a display with %d parts matches no gun", #placed))
			end
		end
	end
	out(string.format("podium: lobby ZFightMoved=%s ZFightRemaining=%s", tostring(lobby:GetAttribute("ZFightMoved")), tostring(lobby:GetAttribute("ZFightRemaining"))))
	lobby:Destroy()
	if stage then
		stage:Destroy()
	end
end
local loot = workspace:FindFirstChild("Loot")
if loot then
	loot:Destroy()
end
out("done")
