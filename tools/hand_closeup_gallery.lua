-- Hand close-ups: the firing hand on the grip, framed close enough to see whether it holds the gun.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/hand_closeup_gallery.lua -OutDir <folder> -PlaceFile <place>
--
-- The first-person view puts the hands at the very bottom of the screen, where a rig change is hard to
-- judge. These views pose the same viewmodel and then look down at the grip from over the player's
-- shoulder, close in: the gun sits where it really sits, but the hand fills the frame. With a
-- ViewmodelBefore module beside Viewmodel, each gun is shot with both rigs for comparison.

local SHOW = { "SahurPistol", "CrocodiloRifle", "LarilaSniper", "NonnaDoubleBarrel", "CameloLMG", "YardWorkBlower" }
local MOMENTS = { { "ads", { aim = 1 } } }
-- What to frame: the firing hand on the grip, the support hand on whatever it holds, and the support
-- arm's own elbow -- on a long rifle the support hand is far enough forward that the arm stretches, and
-- a stretched arm is where a joint would show a seam.
local HANDS = { "grip", "support", "elbow" }
-- Where the camera sits relative to that hand, in studs, and how wide it looks. Looking back from in
-- front and outboard of the hand: over the shoulder, the player's own forearm fills the frame and hides
-- the very thing these views are for. Stand well back and use a narrow angle rather than close and wide:
-- a hand is about 80 mm across and an arm is a stud thick, so a close camera is inside the arm.
local OFFSETS = {
	{ "front", Vector3.new(1.5, 0.55, -1.15), 20 },
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local Viewmodel = require(scripts:WaitForChild("Viewmodel"))
local beforeModule = scripts:FindFirstChild("ViewmodelBefore")
local ViewmodelBefore = beforeModule and require(beforeModule) or nil

local ORIGIN = Vector3.new(0, 640, 0)
Lighting.ClockTime = 14
Lighting.Brightness = 2.6

local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	avatar = nil
end

local function backdrop(folder, position, facing)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(40, 40, 1)
	part.CFrame = CFrame.lookAt(position, position + facing)
	part.Color = Color3.fromRGB(150, 160, 170)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
end

local function view(module, id, moment, offset, which)
	return function(folder, camera)
		local def = WeaponData.Get(id)
		local vm = module.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
		vm.model.Parent = folder
		local eye = CFrame.new(ORIGIN)
		local state = table.clone(moment[2])
		state.magSize = def.magSize
		vm:Pose(eye, state)
		-- Look at the hand's own anchor, wherever the pose has put it, and stand on that hand's side.
		-- The elbow view frames the support arm's two bones where they meet, and stands further back so
		-- both are in shot.
		local arm = which == "elbow" and vm.arms and vm.arms.sides and vm.arms.sides[-1]
		local elbow = arm and arm.lower and arm.lower.part
		local support = which == "support" and vm.keys and vm.keys.SupportHand
		local target = elbow and elbow.Position or vm.frame * (support and support.Position or vm.gripPoint)
		local place = offset[2]
		if support or elbow then
			place = Vector3.new(-offset[2].X, offset[2].Y, offset[2].Z)
		end
		if elbow then
			place = place * 1.6
		end
		local from = target + eye:VectorToWorldSpace(place)
		backdrop(folder, target - eye:VectorToWorldSpace(place).Unit * 6, eye:VectorToWorldSpace(place).Unit)
		camera.FieldOfView = offset[3]
		camera.CFrame = CFrame.lookAt(from, target)
	end
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			backdrop(folder, ORIGIN + Vector3.new(0, 0, -6), Vector3.new(0, 0, 1))
			camera.CFrame = CFrame.new(ORIGIN)
		end,
	},
}

for _, id in ipairs(SHOW) do
	for _, moment in ipairs(MOMENTS) do
		for _, offset in ipairs(OFFSETS) do
			for _, which in ipairs(HANDS) do
				local label = id .. "_" .. which .. "_" .. moment[1] .. "_" .. offset[1]
				if ViewmodelBefore then
					table.insert(views, { name = label .. "_before", setup = view(ViewmodelBefore, id, moment, offset, which) })
				end
				table.insert(views, { name = label .. "_after", setup = view(Viewmodel, id, moment, offset, which) })
			end
		end
	end
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
