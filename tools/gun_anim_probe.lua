-- Does every gun carry the moving parts and keypoints its own action needs?
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_anim_probe.lua -WaitSeconds 240
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- Viewmodel animates a gun by name: it moves the parts whose Anim attribute is "slide", "bolt", "pump",
-- "spin", "string" and so on, by the Travel_/Swing_/Pivot_ numbers on the model, and puts the hands on
-- the KP_ keypoints. Nothing errors when one is missing -- the clip just doesn't move anything and the
-- hand goes to the default. A gun borrowing a mechanism (Action) has to carry that mechanism's whole set.
--
-- Rather than restate the contract here -- a second copy to drift out of date -- the requirement is read
-- off the guns that already work: for each Action, whatever EVERY stock gun with that Action carries is
-- what a gun of that Action needs. A creative gun (GunModelsCreative) missing something the stock guns
-- of its action all have is a real hole; the stock guns themselves are reported the same way against
-- their siblings, so a newly-broken stock gun shows up too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local creativeModule = Shared:FindFirstChild("GunModelsCreative")
local GunModelsCreative = creativeModule and require(creativeModule) or { Builders = {} }

-- Keypoints whose only consumer guards on their being there, so a gun may legitimately not have one.
-- Anything added here needs that same justification, by name, or the check stops meaning anything:
--   KP_Backblast  CombatClient: `if vm.action == "rocket" and vm.keys.Backblast then GunFx.Backblast(...)`,
--                 a cone of rocket smoke that a disc launcher or a toaster has no business venting.
local OPTIONAL = {
	["attr:KP_Backblast"] = "CombatClient only draws a backblast when the keypoint is there",
}

local function say(fmt, ...)
	print(string.format("[BRR_Anim] " .. fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "BRR_AnimProbe"
folder.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

-- [id] = { action, creative, has = { ["group:slide"] = true, ["attr:KP_Eject"] = true, ... } }
local guns = {}

for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if ok and model then
		local has = {}
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				local group = part:GetAttribute("Anim")
				if type(group) == "string" and group ~= "" then
					has["group:" .. group] = true
				end
			end
		end
		for name, value in pairs(model:GetAttributes()) do
			-- Only the names that drive an animation or a hand; a colour or a style isn't one.
			if name:match("^KP_") or name:match("^Travel_") or name:match("^Swing_") or name:match("^Pivot_") or name == "SupportGroup" then
				if value ~= nil then
					has["attr:" .. name] = true
				end
			end
		end
		guns[id] = {
			action = model:GetAttribute("Action") or "?",
			creative = GunModelsCreative.Builders[id] ~= nil,
			has = has,
		}
		model:Destroy()
	else
		say("%-24s FAILED to build: %s", id, tostring(model))
	end
end

-- What every stock gun of an action carries: the intersection, which is the action's real requirement.
local required, roster = {}, {}
for id, gun in pairs(guns) do
	if not gun.creative then
		roster[gun.action] = roster[gun.action] or {}
		table.insert(roster[gun.action], id)
		local set = required[gun.action]
		if not set then
			set = {}
			for key in pairs(gun.has) do
				set[key] = true
			end
			required[gun.action] = set
		else
			for key in pairs(set) do
				if not gun.has[key] then
					set[key] = nil
				end
			end
		end
	end
end

local actions = {}
for action in pairs(roster) do
	table.insert(actions, action)
end
table.sort(actions)
for _, action in ipairs(actions) do
	local keys = {}
	for key in pairs(required[action]) do
		table.insert(keys, key)
	end
	table.sort(keys)
	table.sort(roster[action])
	say("action %-10s from %d stock gun(s) (%s): %s", action, #roster[action], table.concat(roster[action], ", "), table.concat(keys, " "))
end

local problems, checked, lonely = 0, 0, 0
for _, id in ipairs(ids) do
	local gun = guns[id]
	if gun then
		local set = required[gun.action]
		if not set or #(roster[gun.action] or {}) == 0 then
			lonely += 1
			say("%-24s action %-10s has no stock gun to compare with", id, gun.action)
		elseif not (#roster[gun.action] == 1 and roster[gun.action][1] == id) then
			checked += 1
			local missing, optional = {}, {}
			for key in pairs(set) do
				if not gun.has[key] then
					table.insert(OPTIONAL[key] and optional or missing, key)
				end
			end
			if #missing > 0 then
				table.sort(missing)
				problems += 1
				say("PROBLEM %-20s (%s%s) is missing what every %s carries: %s",
					id, gun.action, gun.creative and ", creative" or "", gun.action, table.concat(missing, " "))
			end
			for _, key in ipairs(optional) do
				say("note    %-20s has no %s, which every other %s has: %s", id, key:sub(6), gun.action, OPTIONAL[key])
			end
		end
	end
end

folder:Destroy()
say("guns %d; checked against their action's stock guns %d; actions with nothing to compare %d; problems %d", #ids, checked, lonely, problems)
say("done")
