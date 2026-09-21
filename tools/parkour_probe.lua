-- Parkour geometry probe: Shared/Parkour.Find against a course of known obstacles, in edit mode.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/parkour_probe.lua -WaitSeconds 300
--
-- Every case builds its obstacle in its own lane far from everything, stands (or hangs) an R15 rig in
-- front of it, asks Parkour.Find what it would do, and compares with what the design says should
-- happen: steps and slopes are ignored, crates and walls up to hand reach are climbed, thin fences
-- are vaulted only at speed, nothing higher than MaxRiseFromGround above the last ground is ever
-- reached, an intact window pane blocks the vault through its window and a broken (removed) one
-- doesn't, NoMantle on a part or an ancestor wins, and nothing is climbed with no room for the body.
-- The obby tower is built by EasterEggs itself, with a same-shaped untagged control beside it.
-- Physics (does the body really get there) is tools/movement_probe.lua's job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Parkour = require(Shared:WaitForChild("Parkour"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local CFG = MovementConfig.Parkour
local ORIGIN = Vector3.new(6000, 400, 6000)

local function out(fmt, ...)
	print("[ParkourProbe] " .. string.format(fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "ParkourProbe"
folder.Parent = workspace

local function block(parent, size, cframe, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

-- The rig: a real R15 if Studio will make one here, else a stand-in with the same metrics.
local template
do
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and model then
		template = model
		out("rig: R15 from description")
	else
		out("rig: stand-in (%s)", tostring(model))
		template = Instance.new("Model")
		local rootPart = block(template, Vector3.new(2, 2, 1), CFrame.new(), { Name = "HumanoidRootPart", Transparency = 1 })
		block(template, Vector3.new(2, 1, 1), CFrame.new(0, 2, 0), { Name = "Head" })
		local humanoid = Instance.new("Humanoid")
		humanoid.HipHeight = 2
		humanoid.Parent = template
		template.PrimaryPart = rootPart
	end
	for _, part in ipairs(template:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
end

local templateHumanoid = template:FindFirstChildOfClass("Humanoid")
local templateRoot = template:FindFirstChild("HumanoidRootPart")
local STAND = templateHumanoid.HipHeight + templateRoot.Size.Y / 2
out("rig hipHeight %.2f root %s stand %.2f", templateHumanoid.HipHeight, tostring(templateRoot.Size), STAND)

local passed, failed = 0, 0
local laneIndex = 0

-- `setup(lane, base)` builds the obstacle (face at x = base.X + faceX); the rig's feet are at
-- base.Y + feet, facing +X (or `facing`). `expect` is "mantle", "vault" or nil.
local function case(name, expect, options, setup)
	laneIndex += 1
	local lane = Instance.new("Model")
	lane.Name = name
	lane.Parent = folder
	local base = ORIGIN + Vector3.new(0, 0, laneIndex * 60)
	block(lane, Vector3.new(80, 2, 40), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })
	local extra = setup(lane, base) or {}
	task.wait(extra.wait or 0)

	local rig = template:Clone()
	local at = extra.rigAt or (base + Vector3.new(-(options.faceGap or 1.2) - 0.5, 0, 0))
	local feet = options.feet or 0
	local facing = extra.facing or Vector3.new(1, 0, 0)
	local rootAt = Vector3.new(at.X, at.Y + feet + STAND, at.Z)
	rig:PivotTo(CFrame.lookAt(rootAt, rootAt + facing))
	rig.Parent = lane

	local plan, reason = Parkour.Find(rig, facing, {
		speed = options.speed or 0,
		groundY = at.Y + (options.groundY or 0),
		exhausted = options.exhausted,
		allowMantle = options.allowMantle,
	})
	local kind = plan and plan.kind or nil
	local ok = kind == expect
	-- A refusal has to be refused for the reason the case is about, or it proves nothing (a ceiling case
	-- that was really refused as "out of reach" once passed here).
	if ok and not plan and options.reason and not string.find(tostring(reason), options.reason, 1, true) then
		ok = false
	end
	local detail
	if plan then
		local finish = plan.points[#plan.points]
		detail = string.format("rise %.2f depth %.2f%s duration %.2fs cost %d, ends %.2f above the top, %.2f past the start",
			plan.rise, plan.depth, plan.deep and "+" or "", plan.duration, plan.cost,
			finish.Y - STAND - plan.topY, (finish - rootAt):Dot(facing))
	else
		detail = "nothing: " .. tostring(reason)
	end
	if extra.check and plan then
		local problem = extra.check(plan, rootAt)
		if problem then
			ok = false
			detail ..= " | " .. problem
		end
	end
	if ok then
		passed += 1
	else
		failed += 1
	end
	out("%s %-40s want %-6s got %-6s %s%s", ok and "PASS" or "FAIL", name, tostring(expect), tostring(kind), detail,
		(not plan and options.reason) and (" (want: " .. options.reason .. ")") or "")
	return plan
end

-- A box obstacle `height` tall and `depth` deep, face at base.X, as wide as the lane.
local function obstacle(lane, base, height, depth, props)
	return block(lane, Vector3.new(depth, height, 16), CFrame.new(base + Vector3.new(depth / 2, height / 2, 0)), props)
end

case("step 1.2 (walk onto it)", nil, { reason = "nothing ahead" }, function(lane, base)
	obstacle(lane, base, 1.2, 8)
end)
case("crate 3 deep, standing", "mantle", {}, function(lane, base)
	obstacle(lane, base, 3, 8)
end)
case("crate 3 deep, running 22", "mantle", { speed = 22 }, function(lane, base)
	obstacle(lane, base, 3, 8)
end)
case("fence 3.5 x 0.4, running 22", "vault", { speed = 22 }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4)
end)
case("fence 3.5 x 0.4, standing", nil, { reason = "too thin" }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4)
end)
case("fence 3.5 x 0.4, running but exhausted", nil, { speed = 22, exhausted = true, reason = "too thin" }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4)
end)
case("low wall 2 x 2.8, running 18", "vault", { speed = 18 }, function(lane, base)
	obstacle(lane, base, 2, 2.8)
end)
case("wall 4.8 x 1.4, running 18 (tallest vault)", "vault", { speed = 18 }, function(lane, base)
	obstacle(lane, base, 4.8, 1.4)
end)
case("wall 5.5 x 1.4, running 18 (too tall to vault)", "mantle", { speed = 18 }, function(lane, base)
	obstacle(lane, base, 5.5, 1.4)
end)
case("wall 6, standing", "mantle", {}, function(lane, base)
	obstacle(lane, base, 6, 8)
end)
case("wall 7, standing", "mantle", {}, function(lane, base)
	obstacle(lane, base, 7, 8)
end)
case("wall 8, standing (out of reach)", nil, { reason = "too high" }, function(lane, base)
	obstacle(lane, base, 8, 8)
end)
case("wall 9, mid-jump feet at 3", "mantle", { feet = 3 }, function(lane, base)
	obstacle(lane, base, 9, 8)
end)
case(string.format("wall %.1f, mid-jump feet at 3 (cap)", CFG.MaxRiseFromGround), "mantle", { feet = 3 }, function(lane, base)
	obstacle(lane, base, CFG.MaxRiseFromGround - 0.05, 8)
end)
case(string.format("wall %.1f, mid-jump feet at 4 (over cap)", CFG.MaxRiseFromGround + 0.6), nil, { feet = 4, reason = "too high from the ground" }, function(lane, base)
	obstacle(lane, base, CFG.MaxRiseFromGround + 0.6, 8)
end)
case("wall 12, mid-jump feet at 6.3", nil, { feet = 6.3, reason = "too high from the ground" }, function(lane, base)
	obstacle(lane, base, 12, 8)
end)

-- A building wall 1.4 thick with a 5 x 5 window, sill 4 above the ground, and a room behind it.
local function windowWall(lane, base, withPane)
	local thick, sill, top, width = 1.4, 4, 9, 5
	local x = base.X + thick / 2
	block(lane, Vector3.new(thick, sill, 30), CFrame.new(x, base.Y + sill / 2, base.Z), { Name = "Wall" })
	block(lane, Vector3.new(thick, 15 - top, 30), CFrame.new(x, base.Y + top + (15 - top) / 2, base.Z), { Name = "Wall" })
	block(lane, Vector3.new(thick, top - sill, (30 - width) / 2), CFrame.new(x, base.Y + (sill + top) / 2, base.Z - width / 2 - (30 - width) / 4), { Name = "Wall" })
	block(lane, Vector3.new(thick, top - sill, (30 - width) / 2), CFrame.new(x, base.Y + (sill + top) / 2, base.Z + width / 2 + (30 - width) / 4), { Name = "Wall" })
	block(lane, Vector3.new(0.7, 0.3, width + 0.8), CFrame.new(base.X - 0.35, base.Y + sill - 0.15, base.Z), { Name = "Sill" })
	if withPane then
		block(lane, Vector3.new(0.2, top - sill + 0.2, width + 0.2), CFrame.new(x, base.Y + (sill + top) / 2, base.Z),
			{ Name = "WindowGlass", Transparency = 0.45, CanTouch = false })
	end
	-- The room's floor and ceiling.
	block(lane, Vector3.new(20, 1, 30), CFrame.new(x + thick / 2 + 10, base.Y + 0.5, base.Z), { Name = "Floor" })
	block(lane, Vector3.new(20, 1, 30), CFrame.new(x + thick / 2 + 10, base.Y + 15, base.Z), { Name = "Ceiling" })
end

case("window with an intact pane, running 22", nil, { speed = 22, reason = "blocked over the lip" }, function(lane, base)
	windowWall(lane, base, true)
end)
-- The vault alone (no climb fallback), so the pane is shown to be what refuses the vault: the same
-- window with the pane broken vaults.
case("window with an intact pane, vault only", nil, { speed = 22, allowMantle = false, reason = "no climb" }, function(lane, base)
	windowWall(lane, base, true)
end)
case("window with the pane broken, running 22", "vault", { speed = 22 }, function(lane, base)
	windowWall(lane, base, false)
end)
case("window with the pane broken, standing", nil, { reason = "blocked over the lip" }, function(lane, base)
	windowWall(lane, base, false)
end)

case("fence with a bar 2.5 over it, running 22", nil, { speed = 22 }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4)
	block(lane, Vector3.new(4, 0.4, 16), CFrame.new(base + Vector3.new(0.2, 3.5 + 2.5 + 0.2, 0)))
end)
case("fence at a 14-stud drop, running 22 (vault only)", nil, { speed = 22, allowMantle = false, reason = "no climb" }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4)
	-- Cut the ground away beyond the fence.
	for _, child in ipairs(lane:GetChildren()) do
		if child.Name == "Ground" then
			child.Size = Vector3.new(40.4, 2, 40)
			child.CFrame = CFrame.new(base + Vector3.new(-19.8, -1, 0))
		end
	end
	block(lane, Vector3.new(40, 2, 40), CFrame.new(base + Vector3.new(20.4, -15, 0)))
end)
case("wall 5 under a ceiling at 6.5 over the player", nil, { reason = "no headroom to rise" }, function(lane, base)
	obstacle(lane, base, 5, 8)
	-- Over the player only (x -8..0), stopping at the wall's face, so the wall's top is what's found.
	block(lane, Vector3.new(8, 1, 16), CFrame.new(base + Vector3.new(-4, 7, 0)))
end)
-- An awning overhanging a low wall, its front edge within reach: the sweep meets the awning's edge before
-- the wall, so the climb goes onto the awning from its edge, never up through it from underneath.
case("wall 3 with an awning out over its face", "mantle", {}, function(lane, base)
	obstacle(lane, base, 3, 8)
	block(lane, Vector3.new(7.2, 0.5, 16), CFrame.new(base + Vector3.new(2.4, 6.25, 0)))
	return {
		check = function(plan)
			if math.abs(plan.topY - (base.Y + 6.5)) > 0.1 then
				return string.format("climbed onto %.2f, not the awning's top at 6.5", plan.topY - base.Y)
			end
		end,
	}
end)
case("wall 5 with a roof slab right on top", nil, { reason = "blocked over the lip" }, function(lane, base)
	obstacle(lane, base, 5, 8)
	block(lane, Vector3.new(8, 1, 16), CFrame.new(base + Vector3.new(4, 5 + 3, 0)))
end)
case("NoMantle wall 6", nil, { reason = "unclimbable" }, function(lane, base)
	obstacle(lane, base, 6, 8):SetAttribute("NoMantle", true)
end)
case("wall 6 inside a NoMantle model", nil, { reason = "unclimbable" }, function(lane, base)
	local holder = Instance.new("Model")
	holder:SetAttribute("NoMantle", true)
	holder.Parent = lane
	obstacle(holder, base, 6, 8)
end)
case("NoMantle fence 3.5, running 22", nil, { speed = 22, reason = "unclimbable" }, function(lane, base)
	obstacle(lane, base, 3.5, 0.4):SetAttribute("NoMantle", true)
end)
case("a character in the way", nil, { speed = 22, reason = "unclimbable" }, function(lane, base)
	local dummy = Instance.new("Model")
	dummy.Name = "Dummy"
	block(dummy, Vector3.new(1.4, 3.5, 3), CFrame.new(base + Vector3.new(0.7, 1.75, 0)), { Name = "Torso" })
	Instance.new("Humanoid").Parent = dummy
	dummy.Parent = lane
end)
case("loose unanchored crate", nil, { reason = "unclimbable" }, function(lane, base)
	obstacle(lane, base, 3, 3, { Anchored = false })
end)
case("30-degree ramp (a slope, walk it)", nil, { speed = 22, reason = "a slope" }, function(lane, base)
	-- A slab tipped 30 degrees about Z, its top surface rising along +X from the ground 1.5 studs in front
	-- of the rig's front, so it's already knee-high inside the reach.
	block(lane, Vector3.new(20, 1, 16), CFrame.new(base + Vector3.new(7.41, 4.567, 0)) * CFrame.Angles(0, 0, math.rad(30)))
end)
case("thin wall 6 at 70 degrees (too oblique)", nil, { reason = "too oblique" }, function(lane, base)
	block(lane, Vector3.new(0.6, 6, 30), CFrame.new(base + Vector3.new(3, 3, 0)) * CFrame.Angles(0, math.rad(70), 0))
end)
case("wall 6 turned 35 degrees (squares up)", "mantle", {}, function(lane, base)
	block(lane, Vector3.new(8, 6, 16), CFrame.new(base + Vector3.new(5, 3, 0)) * CFrame.Angles(0, math.rad(35), 0))
	return {
		check = function(plan)
			local angle = math.deg(math.acos(math.clamp(plan.forward:Dot(Vector3.new(1, 0, 0)), -1, 1)))
			if math.abs(angle - 35) > 3 then
				return string.format("forward not squared to the wall (%.1f deg off +X)", angle)
			end
		end,
	}
end)
case("terrain ledge 6", "mantle", {}, function(lane, base)
	-- A smooth-terrain surface sits 2 studs above a block fill's top (MapTerrain.SurfaceLift), so a fill
	-- to 4 makes a ledge at 6.
	workspace.Terrain:FillBlock(CFrame.new(base + Vector3.new(6, 2, 0)), Vector3.new(12, 4, 16), Enum.Material.Rock)
	return { wait = 1 }
end)

-- The obby tower, as EasterEggs builds it, and the same step shape without the tag.
do
	local EasterEggs = require(modules:WaitForChild("EasterEggs"))
	local eggsOrigin = ORIGIN + Vector3.new(400, 0, 0)
	local models = EasterEggs.BuildAll(folder, eggsOrigin, 90)
	local obby
	for _, model in ipairs(models) do
		if model.Name == "Obby" then
			obby = model
		end
	end
	if not obby then
		failed += 1
		out("FAIL obby tower: EasterEggs.BuildAll built no Obby")
	else
		out("obby tower NoMantle attribute: %s", tostring(obby:GetAttribute("NoMantle")))
		-- Step 1 sits 11 out at 48 degrees, top 5 above the tower's origin; stand on the 1-high pad
		-- in front of it and face it.
		-- The 22 x 22 base pad sits half a stud above the tower's origin.
		local towerOrigin
		for _, part in ipairs(obby:GetDescendants()) do
			if part:IsA("BasePart") and math.abs(part.Size.X - 22) < 0.01 and math.abs(part.Size.Z - 22) < 0.01 then
				towerOrigin = part.Position - Vector3.new(0, 0.5, 0)
			end
		end
		local stepCentre
		for _, part in ipairs(towerOrigin and obby:GetDescendants() or {}) do
			if part:IsA("BasePart") and part.Material == Enum.Material.Neon and math.abs(part.Position.Y - (towerOrigin.Y + 4.5)) < 0.3 then
				stepCentre = part.Position
			end
		end
		if not stepCentre then
			failed += 1
			out("FAIL obby tower: couldn't find step 1")
		else
			local outward = Vector3.new(stepCentre.X - towerOrigin.X, 0, stepCentre.Z - towerOrigin.Z).Unit
			local tangent = Vector3.new(-outward.Z, 0, outward.X)
			for _, spec in ipairs({ { "obby tower step 1 (tagged)", obby }, { "same step, untagged control", nil } }) do
				local target = stepCentre
				local parentModel = spec[2]
				local laneModel
				if not parentModel then
					laneIndex += 1
					laneModel = Instance.new("Model")
					laneModel.Parent = folder
					local shift = Vector3.new(0, 0, 300)
					block(laneModel, Vector3.new(30, 1, 30), CFrame.new(towerOrigin + shift + Vector3.new(0, 0.5, 0)))
					block(laneModel, Vector3.new(6, 1, 6), CFrame.lookAt(stepCentre + shift, stepCentre + shift + tangent))
					target = stepCentre + shift
				end
				local rig = template:Clone()
				-- On the pad (top 1 above the origin), 4.6 in from the step's centre, facing it.
				local stand = Vector3.new(target.X, towerOrigin.Y + 1 + STAND, target.Z) - outward * 4.6
				rig:PivotTo(CFrame.lookAt(stand, stand + outward))
				rig.Parent = laneModel or folder
				local plan, reason = Parkour.Find(rig, outward, { speed = 0, groundY = towerOrigin.Y + 1 })
				local want = "mantle"
				if parentModel then
					want = nil
				end
				local got = plan and plan.kind or nil
				local ok = got == want
				if ok then
					passed += 1
				else
					failed += 1
				end
				out("%s %-40s want %-6s got %-6s %s", ok and "PASS" or "FAIL", spec[1], tostring(want), tostring(got),
					plan and string.format("rise %.2f", plan.rise) or ("nothing: " .. tostring(reason)))
				rig:Destroy()
			end
		end
	end
end

-- The server API bots use, on a case that should vault.
do
	local ok, MovementService = pcall(require, modules:WaitForChild("MovementService"))
	if not ok then
		failed += 1
		out("FAIL MovementService require: %s", tostring(MovementService))
	else
		laneIndex += 1
		local lane = Instance.new("Model")
		lane.Parent = folder
		local base = ORIGIN + Vector3.new(0, 0, laneIndex * 60)
		block(lane, Vector3.new(80, 2, 40), CFrame.new(base + Vector3.new(0, -1, 0)))
		obstacle(lane, base, 3.5, 0.4)
		local rig = template:Clone()
		local rootAt = base + Vector3.new(-1.7, STAND, 0)
		rig:PivotTo(CFrame.lookAt(rootAt, rootAt + Vector3.new(1, 0, 0)))
		rig.Parent = lane
		local kind, plan = MovementService.CanParkour(rig, Vector3.new(1, 0, 0), { speed = 22 })
		local bad = MovementService.CanParkour(rig, Vector3.new(0 / 0, 0, 0), { speed = 22 })
		local good = kind == "vault" and type(plan) == "table" and bad == nil
		if good then
			passed += 1
		else
			failed += 1
		end
		out("%s MovementService.CanParkour: %s (want vault), NaN forward -> %s (want nil)", good and "PASS" or "FAIL",
			tostring(kind), tostring(bad))
	end
end

-- The Quick Movement key: WeaponService.StartUse(player, aimPoint, slotIndex). A probe has no Player,
-- and every loadout change ends in a FireClient to one, which throws for a stand-in token, so each call
-- is pcalled and judged by the state it changed before that. Covered: bad indices refused, a quick
-- instant use from a non-equipped slot with a gun up (and still raising), only movement items, and the
-- plain path unchanged. NOT covered here (needs a live client): a quick timed use finishing, and a swap
-- cancelling it — those go on the playtest checklist.
do
	local function check(name, ok, detail)
		if ok then
			passed += 1
		else
			failed += 1
		end
		out("%s quick-use: %-44s %s", ok and "PASS" or "FAIL", name, detail or "")
	end
	local okRequire, WeaponService = pcall(require, modules:WaitForChild("WeaponService"))
	pcall(require, modules:WaitForChild("MovementService"))
	local WeaponData = require(Shared:WaitForChild("WeaponData"))
	if not okRequire then
		check("require WeaponService", false, tostring(WeaponService))
	else
		local effects = {}
		WeaponService.MovementEffect = function(_, itemId)
			table.insert(effects, itemId)
			return true
		end
		laneIndex += 1
		local rig = template:Clone()
		local base = ORIGIN + Vector3.new(0, 0, laneIndex * 60)
		rig:PivotTo(CFrame.new(base + Vector3.new(0, STAND, 0)))
		rig.Parent = folder
		local token = { Name = "ProbeQuickUse", Character = rig, character = rig, isBot = true }
		pcall(WeaponService.Reset, token)
		local loadout = WeaponService.Get(token)
		local weaponId = nil
		for id in pairs(WeaponData.Weapons or WeaponData) do
			if type(id) == "string" and WeaponData.Get(id) then
				weaponId = id
				break
			end
		end
		if not loadout or not weaponId then
			check("set up a loadout", false, string.format("loadout %s weapon %s", tostring(loadout), tostring(weaponId)))
		else
			loadout.slots[1] = { kind = "weapon", id = weaponId, mag = 1, reserve = 0 }
			loadout.slots[2] = { kind = "item", id = "SpeedSoda", count = 2 }
			loadout.slots[3] = { kind = "item", id = "Bandage", count = 3 }
			loadout.slots[4] = { kind = "item", id = "RotRocket", count = 2 }
			-- The refusals run with a usable Rot Rocket equipped and raised: a StartUse that ignored the slot
			-- index would fire it and fail every one of these, so they can't pass vacuously.
			loadout.equipped = 4
			loadout.equipReadyAt = 0
			for _, bad in ipairs({ { "NaN", 0 / 0 }, { "0", 0 }, { "65", 65 }, { "1.5", 1.5 }, { "an empty slot (7)", 7 },
				{ "a string", "4" }, { "a heal slot (3)", 3 }, { "the gun slot (1)", 1 }, { "infinity", math.huge } }) do
				local ok, result = pcall(WeaponService.StartUse, token, nil, bad[2])
				check("refuses " .. bad[1], ok and result == false and #effects == 0 and loadout.slots[3].count == 3,
					string.format("returned %s", tostring(result)))
			end
			-- Now the gun in hand, still being raised.
			loadout.equipped = 1
			loadout.equipReadyAt = os.clock() + 30
			pcall(WeaponService.StartUse, token, nil, 4)
			check("Rot Rocket from slot 4 with the gun still raising",
				effects[1] == "RotRocket" and loadout.slots[4] and loadout.slots[4].count == 1 and loadout.equipped == 1,
				string.format("effects %s, rockets left %s, equipped %s", table.concat(effects, ","),
					tostring(loadout.slots[4] and loadout.slots[4].count), tostring(loadout.equipped)))
			pcall(WeaponService.StartUse, token, nil, 2)
			check("Speed Soda from slot 2 starts a timed use",
				loadout.using ~= nil and loadout.using.index == 2 and loadout.equipped == 1,
				string.format("using %s", loadout.using and tostring(loadout.using.index) or "nil"))
			pcall(WeaponService.CancelUse, token)
			-- The plain path: no slot index uses the equipped slot only, and still waits for the raise.
			local before = #effects
			local okPlain, plain = pcall(WeaponService.StartUse, token, nil)
			check("plain use with a gun equipped does nothing", okPlain and plain == false and #effects == before,
				string.format("returned %s", tostring(plain)))
			loadout.equipped = 4
			local okRaise, raise = pcall(WeaponService.StartUse, token, nil)
			check("plain use still waits for the raise", okRaise and raise == false and #effects == before,
				string.format("returned %s", tostring(raise)))
			loadout.equipReadyAt = 0
			-- Instant items share a 0.45s cooldown, and the quick rocket above started it.
			task.wait(0.6)
			pcall(WeaponService.StartUse, token, nil)
			check("plain use of the equipped rocket after the raise", #effects == before + 1 and effects[#effects] == "RotRocket",
				string.format("effects %s", table.concat(effects, ",")))
		end
		pcall(WeaponService.Clear, token)
	end
end

out("passed %d, failed %d", passed, failed)
folder:Destroy()
print("[BRR_Probe] done")
