-- Run through runtest.ps1 -Probe tools/arsenal_probe.lua -WaitSeconds 240.
-- Exercises the real Roblox models and Viewmodel, then makes a selectable review wall.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Pack = require(Shared:WaitForChild("ArsenalExpansion"))
local Weapons = require(Shared:WaitForChild("WeaponData"))
local Models = require(Shared:WaitForChild("GunModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Viewmodel = require(game:GetService("StarterPlayer").StarterPlayerScripts.Viewmodel)
local checks, failures = 0, {}
local function check(ok, message)
	checks += 1
	if not ok then table.insert(failures, message); warn("[ARSENAL] FAIL " .. message) end
end
local eye = CFrame.new(0, 600, 0)
local function input(extra)
	local result = { camera = eye, grounded = true, sway = false, speed = 0 }
	for k, v in pairs(extra or {}) do result[k] = v end
	return result
end
local function step(vm, seconds, controls)
	for _ = 1, math.ceil(seconds * 60) do vm:Update(1 / 60, input(controls)) end
end
local function snapshot(vm)
	local result = {}
	for group, parts in pairs(vm.groupParts) do
		result[group] = vm.frame:ToObjectSpace(parts[1].CFrame)
	end
	return result
end
local function moved(vm, before)
	for group, old in pairs(before) do
		local new = vm.frame:ToObjectSpace(vm.groupParts[group][1].CFrame)
		if (new.Position - old.Position).Magnitude > 0.002 or new.LookVector:Dot(old.LookVector) < 0.9999 then return true end
	end
	return false
end

local compiled = 0
for _, service in ipairs({ Shared, game:GetService("StarterPlayer"), game:GetService("ServerScriptService") }) do
	for _, source in ipairs(service:GetDescendants()) do
		if source:IsA("LuaSourceContainer") then
			local fn, err = loadstring(source.Source, source.Name)
			check(fn ~= nil, "compile " .. source.Name .. ": " .. tostring(err))
			compiled += 1
		end
	end
end
check(#Pack.Order == 15, "exactly fifteen new guns")
local tiers = {}
for _, id in ipairs(Pack.Order) do
	local ok, err = pcall(function()
		local def = Weapons.Get(id)
		check(def and def.id == id, id .. " registered")
		tiers[def.rarity] = (tiers[def.rarity] or 0) + 1
		check(def.chestWeight > 0, id .. " obtainable in chests")
		check((def.groundWeight > 0) == (Rarity.Index[def.rarity] <= 2), id .. " floor rarity policy")
		check(def.pellets > 1 or def.damage < 100, id .. " single bullet body damage below 100")
		for _, detail in ipairs({ "full", "world" }) do
			local model = Models.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = detail })
			check(model:GetAttribute("Action") == Pack.Actions[id], id .. " " .. detail .. " correct action: " .. tostring(model:GetAttribute("Action")))
			for _, key in ipairs({ "Sight", "Muzzle", "GripHand", "SupportHand" }) do
				check(typeof(model:GetAttribute("KP_" .. key)) == "CFrame", id .. " " .. key)
			end
			check(model.PrimaryPart ~= nil, id .. " world mount")
			model:Destroy()
		end
		local events = {}
		local vm = Viewmodel.new(def, { parent = workspace, onEvent = function(kind, value)
			events[kind] = (events[kind] or 0) + 1
			if kind == "drop" and typeof(value) == "Instance" then value:Destroy() end
		end })
		vm:Pose(eye, {})
		local rest = snapshot(vm)
		vm:Pose(eye, { aim = 1 })
		local sight = eye:PointToObjectSpace((vm.frame * vm.keys.Sight).Position)
		check(math.abs(sight.X) < 0.001 and math.abs(sight.Y) < 0.001 and sight.Z < 0, id .. " ADS centered")
		vm:Pose(eye, {})
		local hip = vm.frame
		step(vm, 0.8, { sprinting = true, speed = 22, sway = true })
		check(vm.sprint > 0.95 and (vm.frame.Position - hip.Position).Magnitude > 0.04, id .. " running pose")
		step(vm, 0.8, { aiming = true })
		check(vm.sprint < 0.05 and vm.aim > 0.95, id .. " sprint to ADS transition")
		vm:Pose(eye, {})
		local rackMoved = false
		for _, t in ipairs({ 0.35, 0.5, 0.6, 0.7 }) do
			vm:Pose(eye, { clip = "rack", progress = t })
			rackMoved = rackMoved or moved(vm, rest)
		end
		check(rackMoved, id .. " racking moves mechanism")
		for _, rounds in ipairs({ 0, math.max(1, def.magSize - 2) }) do
			local reloadMoved = false
			for _, t in ipairs({ 0.22, 0.4, 0.6, 0.86, 0.93 }) do
				vm:Pose(eye, { clip = "reload", progress = t, roundsLeft = rounds, magSize = def.magSize })
				reloadMoved = reloadMoved or moved(vm, rest)
				-- Topping up a tube need not cycle the action: the hand feeds visible shells.
				if vm.action == "pump" or vm.action == "lever" then
					for _, prop in pairs(vm.props) do
						reloadMoved = reloadMoved or (prop.shown and (vm.hands.left.Position - vm.keys.SupportHand.Position).Magnitude > 0.02)
					end
				end
			end
			check(reloadMoved, id .. " reload moves parts, rounds=" .. rounds)
			vm:Pose(eye, {})
			vm:StartReload(def.reloadTime, rounds, def.magSize)
			step(vm, def.reloadTime + 0.2)
			check(vm.clips.reload == nil and not vm.slideLocked, id .. " reload completes")
			vm:Update(0, input())
			check(not moved(vm, rest), id .. " mechanism restored after reload")
		end
		vm:StartReload(def.reloadTime, 0, def.magSize)
		step(vm, 0.5)
		vm:StopReload()
		vm:Update(0, input())
		check(vm.clips.reload == nil and not moved(vm, rest), id .. " cancelled reload restores parts")
		vm:Equip(true)
		step(vm, 1.2)
		check(vm.pendingRack == nil and vm.clips.rack == nil, id .. " equip/rack completes")
		check(vm:Fire(0) ~= nil, id .. " firing has muzzle")
		step(vm, 1.1)
		check((events.sound or 0) > 0 and (events.casing or 0) > 0, id .. " reload/rack sound and casing events")
		if vm.action == "pistol" then check(vm.slideLocked, id .. " empty slide locks") end
		vm:Destroy()
		print("[ARSENAL] checked " .. id)
	end)
	check(ok, id .. " runtime: " .. tostring(err))
	task.wait()
end
for _, tier in ipairs(Rarity.Order) do check((tiers[tier] or 0) >= 2, "coverage " .. tier) end
print(string.format("[ARSENAL] RESULT %d checks, %d failures, %d scripts compiled", checks, #failures, compiled))
assert(#failures == 0, table.concat(failures, " | "))

-- Review wall: individual models remain a normal, inspectable Studio hierarchy.
local folder = Instance.new("Folder")
folder.Name = "AfterHours15_Review"
folder.Parent = workspace
game:GetService("Lighting").ClockTime = 14
game:GetService("Lighting").Ambient = Color3.fromRGB(140, 140, 150)
game:GetService("Lighting").ExposureCompensation = 0.2
for index, id in ipairs(Pack.Order) do
	local col, row = (index - 1) % 3, math.floor((index - 1) / 3)
	local origin = Vector3.new((col - 1) * 6.1, 609 - row * 3.6, -10)
	local def = Weapons.Get(id)
	local model = Models.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	model.Name = id
	for _, part in ipairs(model:GetDescendants()) do if part:IsA("BasePart") then part.Anchored = true end end
	model:PivotTo(CFrame.new(origin) * CFrame.Angles(0, -math.pi / 2, 0))
	model.Parent = folder
	local label = Instance.new("Part")
	label.Anchored = true
	label.Transparency = 1
	label.CanCollide = false
	label.Size = Vector3.new(1, 1, 1)
	label.Position = origin + Vector3.new(0, -1.5, 0)
	label.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(150, 37)
	gui.AlwaysOnTop = true
	gui.Parent = label
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(23, 28, 34)
	text.BackgroundTransparency = 0.15
	text.TextColor3 = Rarity.Color(def.rarity)
	text.Font = Enum.Font.GothamBold
	text.TextSize = 11
	text.Text = def.name .. "\n" .. string.upper(def.rarity)
	text.Parent = gui
end
game:GetService("Selection"):Set({ folder })
print("[ARSENAL] REVIEW WALL ready; select viewport and press F to frame it")
