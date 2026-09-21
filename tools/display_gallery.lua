-- Display gallery: guns where they sit still in the world, each next to a shot of the gun GunModels
-- builds, to see that the floor and the podium show the same gun you hold.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/display_gallery.lua -OutDir <folder>
--
--   podium*:   the lobby as MatchService builds it (its z-fight pass included): the arena's three
--              podium guns from the terrace, then each side on, then its reference from the same place
--   floor_*:   LootService.DropWeapon onto a floor, side on, then its reference from the same place
--
-- AmbientClient doesn't run in edit mode, so nothing turns; the shots are of the rest pose.

local FLOOR_GUNS = { "CrocodiloRifle", "SahurPistol", "TralalaThumper", "AuraCrossbow", "BubbleBurster", "PatapimChaingun", "LarilaSniper", "NonnaDoubleBarrel" }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local WeaponService = require(modules:WaitForChild("WeaponService"))
local LootService = require(modules:WaitForChild("LootService"))
local LobbyService = require(modules:WaitForChild("LobbyService"))

Lighting.ClockTime = 14
Lighting.Brightness = 2.4

-- The lobby and the drops are built once, the first time a view needs them, and outlive the views
-- (the gallery clears only its own folder between shots).
local lobbyBuilt, floorBuilt = false, false
local podiums = {}
local drops = {}
local FLOOR_ORIGIN = Vector3.new(0, 900, 4000)

local function reference(id, cframe, parent)
	local def = WeaponData.Get(id)
	local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model:PivotTo(cframe)
	model.Parent = parent
	return model
end

local function ensureLobby()
	if lobbyBuilt then
		return
	end
	lobbyBuilt = true
	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace
	LobbyService.Build(lobby, MatchConfig.LobbyPosition)
	print(string.format("[BRR_Gallery] lobby ZFightMoved=%s ZFightRemaining=%s", tostring(lobby:GetAttribute("ZFightMoved")), tostring(lobby:GetAttribute("ZFightRemaining"))))
	for _, folderName in ipairs({ "GunDisplays", "StageDisplay" }) do
		local folder = workspace:FindFirstChild(folderName)
		for _, display in ipairs(folder and folder:GetChildren() or {}) do
			if display:FindFirstChild("DisplayGun") then
				table.insert(podiums, display)
			end
		end
	end
	table.sort(podiums, function(a, b)
		return a.Position.Z < b.Position.Z
	end)
	-- Which gun each podium holds: the prompt on its pedestal names it.
	for _, display in ipairs(podiums) do
		local best, bestDistance = nil, math.huge
		for _, descendant in ipairs(lobby:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and descendant.Parent.Name == "RangePodium" then
				local distance = (descendant.Parent.Position - display.Position).Magnitude
				if distance < bestDistance then
					best, bestDistance = descendant.ObjectText, distance
				end
			end
		end
		for id, def in pairs(WeaponData.Weapons) do
			if def.name == best then
				display:SetAttribute("GalleryWeaponId", id)
			end
		end
	end
end

local function ensureFloor()
	if floorBuilt then
		return
	end
	floorBuilt = true
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(200, 2, 40)
	floor.CFrame = CFrame.new(FLOOR_ORIGIN + Vector3.new(0, -1, 0))
	floor.Color = Color3.fromRGB(118, 120, 112)
	floor.Material = Enum.Material.Concrete
	floor.Parent = workspace
	for index, id in ipairs(FLOOR_GUNS) do
		local at = FLOOR_ORIGIN + Vector3.new((index - 1) * 16, 0.5, 0)
		local loot = workspace:FindFirstChild("Loot")
		local before = {}
		for _, child in ipairs(loot and loot:GetChildren() or {}) do
			before[child] = true
		end
		LootService.DropWeapon(id, at)
		loot = workspace:FindFirstChild("Loot")
		for _, child in ipairs(loot and loot:GetChildren() or {}) do
			if not before[child] and child:GetAttribute("WeaponId") == id then
				drops[id] = child
			end
		end
	end
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 40
	camera.CFrame = CFrame.lookAt(eye, target)
end

-- Each gun is shot twice from the same place relative to it, once where the game put it and once as a
-- reference build out in the open, so the pair can be compared like for like. The guns lie with the
-- barrel along -X (turned a quarter round from the model's -Z), so the camera looks at their side
-- from +Z.
local REF_ORIGIN = Vector3.new(0, 900, 5200)

local function sideOn(camera, frame)
	look(camera, frame.Position + Vector3.new(0.4, 1.1, 7.5), frame.Position, 38)
end

local views = {
	{
		name = "podiums_terrace",
		setup = function(folder, camera)
			ensureLobby()
			if #podiums == 0 then
				return
			end
			local middle = podiums[math.ceil(#podiums / 2)].Position
			-- Low, from the arena edge, all three in frame.
			look(camera, middle + Vector3.new(24, -1.2, 0), middle + Vector3.new(0, -0.6, 0), 62)
		end,
	},
}
for index = 1, 3 do
	table.insert(views, {
		name = "podium" .. index,
		setup = function(folder, camera)
			ensureLobby()
			local display = podiums[index]
			if display then
				sideOn(camera, display.CFrame)
				print(string.format("[BRR_Gallery] podium %d: %s", index, tostring(display:GetAttribute("GalleryWeaponId"))))
			end
		end,
	})
	table.insert(views, {
		name = "podium" .. index .. "_reference",
		setup = function(folder, camera)
			ensureLobby()
			local display = podiums[index]
			local id = display and display:GetAttribute("GalleryWeaponId")
			if id then
				local frame = CFrame.new(REF_ORIGIN + Vector3.new(index * 30, 0, 0))
				reference(id, frame * CFrame.Angles(0, math.pi / 2, math.rad(-12)), folder)
				sideOn(camera, frame)
			end
		end,
	})
end
for index, id in ipairs(FLOOR_GUNS) do
	table.insert(views, {
		name = "floor_" .. id,
		setup = function(folder, camera)
			ensureFloor()
			local base = drops[id]
			if not base then
				print("[BRR_Gallery] no floor pickup for " .. id)
				return
			end
			sideOn(camera, base.CFrame * CFrame.new(0, 1.5, 0))
		end,
	})
	table.insert(views, {
		name = "floor_" .. id .. "_reference",
		setup = function(folder, camera)
			local frame = CFrame.new(REF_ORIGIN + Vector3.new(index * 30, 0, 60))
			reference(id, frame * CFrame.Angles(0, math.pi / 2, math.rad(-10)), folder)
			sideOn(camera, frame)
		end,
	})
end

return views
