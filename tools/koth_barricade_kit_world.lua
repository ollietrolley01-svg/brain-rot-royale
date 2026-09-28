-- The kit half of tools/koth_barricade_proof_check.py (#114 a: "popup barricade in the team-mode kit").
-- Plain Lua (lupa), loaded after tools/destruct_mocks.lua and tools/defense_anywhere_world.lua, whose
-- world it reuses: the heightfield terrain, the exact raycasts, and the REAL DefensePlacement and
-- DefenseService already loaded there. This file adds the rest of the chain a spawned player goes
-- through, all of it the shipped code:
--
--   GameModes.RollLoadout -> ModeTeams.GrantLoadout (cut out of ModeTeams.lua) -> the REAL WeaponService
--   inventory -> Equip + StartUse (the click) -> WeaponService.DefenseEffect (DefenseService's hook) ->
--   the throw lands -> a structure stands -> CombatService.DamageStructure (DefenseService's hook) ->
--   it collapses.
--
-- and one King of the Hill scene: the REAL ModeKingOfTheHill builds its two objectives, and a kit
-- barricade is thrown at an objective's centre (must refuse) and at its ring off the centre (must build).
--
-- What is not real here: CombatService (only its DamageStructure hook, which DefenseService installs, is
-- called; no ray finds the wall), the gun models (GunModels is a stub), PlayerData, and BotService (read
-- from source by the Python side).

local mock, W0, sources = ...
local compileChunk = rawget(_G, "load")
local V = Vector3.new
local K = { problems = {}, lines = {}, counts = { lives = 0, uses = 0, built = 0, collapsed = 0, throws = 0 } }

local function problem(tag, text)
	table.insert(K.problems, string.format("[%s] %s", tag, text))
end
local function line(text)
	table.insert(K.lines, text)
end

K.warns = {}
warn = function(msg)
	table.insert(K.warns, tostring(msg))
end

--------------------------------------------------------------------------------
-- Modules: the defense world's loader, plus what this chain needs
--------------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local shared = ReplicatedStorage:FindFirstChild("Shared")
local modules = ServerScriptService:FindFirstChild("Modules")
local function moduleInstance(name, parent)
	local inst = parent:FindFirstChild(name)
	if inst then
		return inst
	end
	inst = mock.newInstance("ModuleScript")
	inst.Name = name
	inst.Parent = parent
	return inst
end
for _, name in ipairs({ "GameModes", "Rarity", "CosmeticData", "WeaponData", "ArsenalExpansion", "CreativeArsenal",
	"CreativeRounds", "Ballistics", "WorkshopArsenal", "MatchConfig", "GunModels", "ObjectiveZone" }) do
	moduleInstance(name, shared)
end
for _, name in ipairs({ "PlayerData", "Combatants", "ModeTeams", "ModeKingOfTheHill" }) do
	moduleInstance(name, modules)
end

-- The defense world's stubs answer first for their names (CombatService, WeaponService, LootService...).
local baseRequire = require
local battleground = nil
local extraStubs = {
	GunModels = { Supports = function() return false end, Build = function() return nil end },
	PlayerData = { Get = function() return nil end },
	Combatants = { All = function() return {} end },
	ModeTeams = {
		Battleground = function() return battleground end,
		TeamOf = function() return nil end,
		IsDowned = function() return false end,
	},
}
require = function(inst)
	local name = type(inst) == "table" and inst.Name or tostring(inst)
	if extraStubs[name] then
		return extraStubs[name]
	end
	return baseRequire(inst)
end

local function compile(name, src, scriptInst, extraEnv)
	local env = setmetatable(extraEnv or {}, { __index = _G })
	env.script = scriptInst
	local chunk, err = compileChunk(src, "=" .. name, "t", env)
	if not chunk then
		error(name .. ": " .. tostring(err))
	end
	return chunk()
end

local ItemData = require(shared.ItemData)
local GameModes = require(shared.GameModes)
local DefenseService = require(modules.DefenseService)
local DefensePlacement = W0.DefensePlacement
local combatHooks = require(modules.CombatService)

-- The REAL WeaponService, loaded as its own module (the defense world's "WeaponService" is the stub that
-- DefenseService required and hooked). DefenseService puts DefenseEffect on whatever WeaponService it
-- requires -- in the game that is this module -- so the hook is carried across, not rewritten.
local WeaponService = compile("WeaponService", sources.WeaponServiceReal, modules.WeaponService)
WeaponService.DefenseEffect = require(modules.WeaponService).DefenseEffect

-- ModeTeams.GrantLoadout, cut out of ModeTeams.lua by the Python side: the shipped function, run with the
-- module's own names bound to the real modules (RollGreenWeapon picks one of the green guns).
local WeaponData = require(shared.WeaponData)
local greens = {}
for id, def in pairs(WeaponData.Weapons) do
	if def.rarity == GameModes.GreenRarity then
		table.insert(greens, id)
	end
end
table.sort(greens)
local GREEN_GUN = greens[1]
local ModeTeamsCut = { RollGreenWeapon = function() return GREEN_GUN end }
compile("GrantLoadout", sources.GrantLoadout, nil, {
	ModeTeams = ModeTeamsCut, WeaponService = WeaponService, GameModes = GameModes, ItemData = ItemData,
})

local STRUCTURES = { RotBarricade = 250, PopupBunker = 1250, BrainrotFortress = 2500 }
local STACK_CAP = 2

--------------------------------------------------------------------------------
-- A player standing on flat ground
--------------------------------------------------------------------------------
local playersFolder = mock.newInstance("Folder")
playersFolder.Name = "Players"
local function block(name, size, cf, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.Parent = parent
	return part
end
local player = mock.newInstance("Player")
player.Name = "KitPlayer"
player.UserId = 114
player.Parent = playersFolder
local function stand(at, facing)
	local old = workspace:FindFirstChild("KitCharacter")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "KitCharacter"
	local look = CFrame.lookAt(at + V(0, 3, 0), at + V(0, 3, 0) + facing)
	block("HumanoidRootPart", V(2, 2, 1), look, model).CanCollide = false
	block("Head", V(1.2, 1.2, 1.2), CFrame.lookAt(at + V(0, 4.6, 0), at + V(0, 4.6, 0) + facing), model)
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Health = 100
	humanoid.MaxHealth = 100
	humanoid.Parent = model
	model.Parent = workspace
	player.Character = model
	return model
end

local function standing(id)
	local list = {}
	local folder = workspace:FindFirstChild("Defenses")
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		if child.Name == id and DefenseService.OwnerOf(child) ~= nil then
			table.insert(list, child)
		end
	end
	return list
end

local function defenseSlot(loadout)
	for index = 1, WeaponService.SlotCount do
		local slot = loadout.slots[index]
		if slot and slot.kind == "item" and STRUCTURES[slot.id] then
			return index, slot
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- 1. The kit: what a spawned player carries, over many rolled lives
--------------------------------------------------------------------------------
local byKind = { RotBarricade = 0, PopupBunker = 0, BrainrotFortress = 0 }
local firstLifeOf = {}
local LIVES = 90
for life = 1, LIVES do
	W0.reset()
	stand(V(0, 0, 0), V(0, 0, -1))
	ModeTeamsCut.GrantLoadout(player)
	local loadout = WeaponService.Get(player)
	local defenses = {}
	for index = 1, WeaponService.SlotCount do
		local slot = loadout.slots[index]
		local item = slot and slot.kind == "item" and ItemData.Get(slot.id)
		if item and item.kind == "defense" and STRUCTURES[slot.id] then
			table.insert(defenses, { id = slot.id, count = slot.count, stack = item.stack, issued = slot.issued })
		end
	end
	K.counts.lives = K.counts.lives + 1
	if #defenses ~= 1 then
		problem("kit", string.format("life %d carries %d pop-up structure kinds, want exactly 1", life, #defenses))
	else
		local d = defenses[1]
		byKind[d.id] = byKind[d.id] + 1
		firstLifeOf[d.id] = firstLifeOf[d.id] or life
		if d.count ~= math.min(STACK_CAP, d.stack) then
			problem("kit", string.format("life %d: %s x%d, want %d", life, d.id, d.count, math.min(STACK_CAP, d.stack)))
		end
		if d.issued ~= true then
			problem("kit", string.format("life %d: the %s is not tagged issued", life, d.id))
		end
	end
end
line(string.format("kit: %d lives rolled; Rot Barricade %d, Pop-up Bunker %d, Brainrot Fortress %d",
	LIVES, byKind.RotBarricade, byKind.PopupBunker, byKind.BrainrotFortress))
for id in pairs(STRUCTURES) do
	if byKind[id] == 0 then
		problem("kit", id .. " never came up in " .. LIVES .. " lives")
	end
end
K.byKind = byKind

--------------------------------------------------------------------------------
-- 2. Using it: the click throws the kit and a structure pops up; the stack runs down
--------------------------------------------------------------------------------
local EQUIP = 2
local function useOnce(aim)
	-- Past the raise time and the instant-item cooldown, as a player clicking a second later would be.
	mock.advance(EQUIP, 1 / 10)
	local started, why = WeaponService.StartUse(player, aim)
	K.counts.throws = K.counts.throws + (started and 1 or 0)
	-- Every kit has landed by then (DefenseService THROW_TIMEOUT is 4 s; a structure kit lands on its arc).
	mock.advance(4, 1 / 20)
	return started, why
end

local function useScene(id)
	-- A life that rolled this kind: re-roll until one does, so every kind is used, not just the common one.
	local life = 0
	repeat
		life = life + 1
		W0.reset()
		stand(V(0, 0, 0), V(0, 0, -1))
		ModeTeamsCut.GrantLoadout(player)
		local _, slot = defenseSlot(WeaponService.Get(player))
		if slot and slot.id == id then
			break
		end
	until life > 200
	local loadout = WeaponService.Get(player)
	local index, slot = defenseSlot(loadout)
	if not slot or slot.id ~= id then
		problem("use", id .. ": no life in 200 rolled it")
		return
	end
	local startCount = slot.count
	WeaponService.Equip(player, index)
	if loadout.equipped ~= index then
		problem("use", id .. ": could not hold the kit's slot")
		return
	end
	local built = {}
	local aims = { V(-14, 0, -26), V(14, 0, -26), V(0, 0, 30) }
	for use = 1, startCount + 1 do
		local before = #standing(id)
		local dropsBefore = #W0.dropped
		local started = useOnce(aims[use])
		local after = standing(id)
		local slotNow = loadout.slots[index]
		local left = slotNow and slotNow.id == id and slotNow.count or 0
		if use <= startCount then
			K.counts.uses = K.counts.uses + 1
			if not started then
				problem("use", string.format("%s use %d: the click did not start", id, use))
			elseif #after ~= before + 1 then
				problem("use", string.format("%s use %d: spent (%d left) but %d built (%d dropped back as a pickup)",
					id, use, left, #after - before, #W0.dropped - dropsBefore))
			else
				K.counts.built = K.counts.built + 1
				table.insert(built, after[#after])
			end
			if left ~= startCount - use then
				problem("use", string.format("%s use %d: %d left in the stack, want %d", id, use, left, startCount - use))
			end
		else
			-- The stack is spent: the next click has nothing to throw.
			if started or #after ~= before then
				problem("use", string.format("%s: a click with the stack spent still threw (%s, %d built)", id, tostring(started), #after - before))
			end
		end
	end
	line(string.format("use %-16s kit x%d -> %d thrown, %d standing, stack left %d",
		id, startCount, #built, #standing(id), loadout.slots[index] and loadout.slots[index].count or 0))

	-- 3. Working: each one it built has its health, its owner, and solid parts that stop a body and a ray.
	for n, model in ipairs(built) do
		local want = STRUCTURES[id]
		local solid = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide and part.CanQuery and part.Name ~= "Core" then
				solid = solid + 1
			end
		end
		if model:GetAttribute("Health") ~= want or model:GetAttribute("MaxHealth") ~= want then
			problem("works", string.format("%s #%d: health %s/%s, want %d", id, n, tostring(model:GetAttribute("Health")),
				tostring(model:GetAttribute("MaxHealth")), want))
		end
		if DefenseService.OwnerOf(model) ~= player then
			problem("works", string.format("%s #%d: not owned by the thrower", id, n))
		end
		if solid == 0 then
			problem("works", string.format("%s #%d: no part that collides and can be hit", id, n))
		end
		-- Worn down through the hook CombatService calls for a bullet that hits it (and explosions through
		-- DamageStructuresInRadius): a hit short of its health leaves it standing and says so on the model.
		local first = combatHooks.DamageStructure(player, model, want * 0.4)
		local stillUp = DefenseService.OwnerOf(model) ~= nil and model.Parent ~= nil
		if first ~= want * 0.4 or not stillUp or model:GetAttribute("Health") ~= math.ceil(want * 0.6) then
			problem("works", string.format("%s #%d: a %.0f hit dealt %s, health %s, standing %s", id, n, want * 0.4,
				tostring(first), tostring(model:GetAttribute("Health")), tostring(stillUp)))
		end
		combatHooks.DamageStructuresInRadius(model.PrimaryPart.Position, 6, want)
		local collidingAfter = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				collidingAfter = collidingAfter + 1
			end
		end
		if DefenseService.OwnerOf(model) ~= nil or collidingAfter > 0 then
			problem("works", string.format("%s #%d: shot out but still standing (%d parts still collide)", id, n, collidingAfter))
		else
			mock.advance(4, 1 / 5)
			if model.Parent ~= nil then
				problem("works", string.format("%s #%d: collapsed but never cleared away", id, n))
			else
				K.counts.collapsed = K.counts.collapsed + 1
			end
		end
	end
end
for _, id in ipairs({ "RotBarricade", "PopupBunker", "BrainrotFortress" }) do
	useScene(id)
end

--------------------------------------------------------------------------------
-- 4. King of the Hill: a kit barricade thrown onto the real objectives
--------------------------------------------------------------------------------
local ModeKingOfTheHill = require(modules.ModeKingOfTheHill)
local ObjectiveZone = require(shared.ObjectiveZone)
local kothMode = GameModes.Modes.KingOfTheHill
local A, B = V(0, 0, -120), V(0, 0, 120)
local function kothScene(label, aim, expect)
	W0.reset()
	battleground = { objectives = { A, B } }
	local sites = ModeKingOfTheHill.Start(kothMode, {})
	local character = stand(aim + V(0, 0, 24), V(0, 0, -1))
	WeaponService.Reset(player)
	WeaponService.GiveConsumable(player, "RotBarricade", 2)
	local loadout = WeaponService.Get(player)
	local index = defenseSlot(loadout)
	WeaponService.Equip(player, index)
	local before = #standing("RotBarricade")
	local dropsBefore = #W0.dropped
	local notesBefore = #W0.notes
	local started = useOnce(aim)
	local built = #standing("RotBarricade") - before
	local note = W0.notes[#W0.notes] or ""
	local refusedForObjective = #W0.notes > notesBefore and string.find(note, "objective", 1, true) ~= nil
	line(string.format("koth %-30s %d objectives; thrown %s; %s", label, sites or 0, tostring(started),
		built > 0 and "BUILT" or ("REFUSED: " .. note)))
	if (sites or 0) ~= 2 then
		problem("koth", label .. ": " .. tostring(sites) .. " objectives built, want 2")
	end
	if expect == "build" and built ~= 1 then
		problem("koth", label .. ": a barricade thrown here must build, got: " .. note)
	elseif expect == "refuse" then
		if built ~= 0 then
			problem("koth", label .. ": a barricade built on an objective's centre")
		elseif not refusedForObjective or #W0.dropped == dropsBefore then
			problem("koth", label .. ": refused, but not for the objective or the kit was not given back (" .. note .. ")")
		end
	end
	-- The same answer on the bots' path (Deploy, no throw).
	local model, reason = DefenseService.Deploy(player, character, "RotBarricade", aim + V(0, DefensePlacement.LandLift, 0), V(0, 0, -1))
	if (model ~= nil) ~= (expect == "build") then
		problem("koth", string.format("%s: Deploy (a bot's path) said %s", label, model and "built" or tostring(reason)))
	end
	ModeKingOfTheHill.Stop()
	battleground = nil
end
local R = ObjectiveZone.Radius(kothMode)
kothScene("objective A's centre", A, "refuse")
kothScene("objective B's centre", B, "refuse")
kothScene("A's ring, 0.8 of its radius out", A + V(R * 0.8, 0, 0), "build")
kothScene("B's ring, 0.6 of its radius out", B + V(0, 0, -R * 0.6), "build")

return K
