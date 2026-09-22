-- Companion refresh probe for tools/runtest.ps1 -Probe: what re-spawning a companion does to the
-- creature that was already out.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/companion_refresh_probe.lua
--
-- THE INVARIANT every check here is written against:
--
--     Nothing a player can do from the menu mid-match improves the condition of their companion --
--     not its health, and not how soon its ability is ready.
--
-- Written that way rather than as "equipping twice must not heal", because the exploit had three
-- doors into the same room (SetCompanion, SellBrainrot, SellAllOfRarity, and a trade completing
-- through RefreshAll) and a check aimed at one door goes quiet the moment that door is closed while
-- the others stay open.
--
-- What it was: a re-spawn built a brand new creature at full health with `lastAttackAt = -math.huge`,
-- so toggling the equipped companion off and on healed it and re-armed its ability -- two Menu
-- tokens, against designed cooldowns of 1.35-2.6 s.
--
-- PlayerData.Save is stubbed: a stand-in profile must never reach a real DataStore.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = ServerScriptService:WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local CombatService = require(modules:WaitForChild("CombatService"))
local CompanionService = require(modules:WaitForChild("CompanionService"))

PlayerData.Save = function()
	return true
end
PlayerData.CanSave = function()
	return true
end

-- In a match, and combat live: the two gates the ability itself checks.
CompanionService.IsFighting = function()
	return true
end
CombatService.IsEnabled = function()
	return true
end

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[RefreshProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

local stage = Instance.new("Folder")
stage.Name = "CompanionRefreshProbe"
stage.Parent = workspace

local BASE = Vector3.new(-4200, 900, 4200)
local function character(name, position)
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CFrame = CFrame.new(position)
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = stage
	return model
end

-- A stand-in player: a table with the fields CompanionService reads off a Player.
local player = { UserId = -424288, Name = "RefreshProbe", DisplayName = "RefreshProbe" }
player.Character = character("RefreshProbeOwner", BASE)
local data = PlayerData.Load(player)
-- Registered as a combatant, the way tools/companion_probe.lua registers its stand-ins, so the
-- attack path the ability takes is the real one rather than an early return.
local Combatants = require(modules:WaitForChild("Combatants"))
pcall(Combatants.Register, player.Character, player)

-- Two different companions, so swapping can be told apart from toggling.
local first, second = BrainrotData.Types[1], nil
for _, def in ipairs(BrainrotData.Types) do
	if def.name ~= first.name and def.attack == first.attack then
		second = def
		break
	end
end
second = second or BrainrotData.Types[2]

local function equip(def)
	if not table.find(data.Brainrots, def.name) then
		table.insert(data.Brainrots, def.name)
	end
	data.Companion = def.name
	CompanionService.Refresh(player)
end

local function model()
	return CompanionService.ModelOf(player)
end
local function health()
	local m = model()
	return m and m:GetAttribute("Health") or nil
end
local function maxHealth()
	local m = model()
	return m and m:GetAttribute("MaxHealth") or nil
end
local function fraction()
	local h, max = health(), maxHealth()
	return (h and max and max > 0) and h / max or nil
end
-- Whether the ability is ready, measured the way the game measures it: by trying to use it.
--
-- In a pcall, and an error counts as FIRED. That is not a fudge: UseAbility returns false on the
-- cooldown check before it touches anything that can throw, so anything that throws has already got
-- past the gate this probe is measuring. A stand-in player has no real combat around it, so the
-- swing itself may well throw, and treating that as "did not fire" would hide a re-armed ability.
local function abilityFires()
	local ok, fired = pcall(CompanionService.UseAbility, player, BASE + Vector3.new(0, 0, -10))
	if not ok then
		print("[RefreshProbe] NOTE the ability fired and then errored past the cooldown gate: " .. tostring(fired))
		return true
	end
	return fired == true
end

equip(first)
expect("a companion spawns for the stand-in player", model() ~= nil and (health() or 0) > 0,
	string.format("health %s / %s", tostring(health()), tostring(maxHealth())))

if model() then
	-- Hurt it to about half, and fire the ability so it is on cooldown.
	local hurt = math.floor((maxHealth() or 2) / 2)
	CompanionService.Damage("probe-attacker", model(), hurt)
	local hurtFraction = fraction()
	expect("the probe can hurt the companion (so the heal check has something to detect)",
		hurtFraction ~= nil and hurtFraction < 0.9, string.format("%.2f of max", hurtFraction or -1))
	expect("the ability fires once", abilityFires())
	expect("...and is then on cooldown", not abilityFires())

	-- 1. The exploit, exactly: equip the same companion again, mid-match.
	equip(first)
	expect("re-equipping the same companion does NOT heal it",
		fraction() ~= nil and math.abs(fraction() - hurtFraction) < 0.02, string.format("%.2f -> %.2f", hurtFraction, fraction() or -1))
	expect("re-equipping the same companion does NOT re-arm its ability", not abilityFires())

	-- 1b. OFF, then ON -- which is the exploit as Oliver's list describes it, and the shape the cases
	-- above do NOT cover: unequipping destroys the entry, so a fix that reads the live creature finds
	-- nothing to carry and the next equip hands back a full-health companion with its ability ready.
	data.Companion = nil
	CompanionService.Refresh(player)
	expect("unequipping removes the companion", model() == nil)
	equip(first)
	expect("equipping again after unequipping does NOT heal it",
		fraction() ~= nil and math.abs(fraction() - hurtFraction) < 0.02, string.format("%.2f -> %.2f", hurtFraction, fraction() or -1))
	expect("equipping again after unequipping does NOT re-arm the ability", not abilityFires())

	-- 1c. Ten off/on cycles, which is what the exploit actually looked like at the keyboard.
	for _ = 1, 10 do
		data.Companion = nil
		CompanionService.Refresh(player)
		equip(first)
	end
	expect("ten off/on cycles heal nothing", fraction() ~= nil and math.abs(fraction() - hurtFraction) < 0.02,
		string.format("%.2f -> %.2f", hurtFraction, fraction() or -1))
	expect("...and the ability is still on cooldown after all ten", not abilityFires())

	-- 2. The same through a swap to a DIFFERENT companion: carrying the cooldown matters most here,
	-- because a player with two brainrots could otherwise alternate for an ability every toggle.
	equip(second)
	expect("swapping to a different companion keeps the same fraction of health",
		fraction() ~= nil and math.abs(fraction() - hurtFraction) < 0.05, string.format("%.2f -> %.2f", hurtFraction, fraction() or -1))
	expect("swapping to a different companion does NOT re-arm the ability", not abilityFires())

	-- 3. Toggling repeatedly, which is what the exploit actually looked like.
	local before = fraction()
	for _ = 1, 10 do
		equip(first)
		equip(second)
	end
	expect("twenty re-equips in a row heal nothing", fraction() ~= nil and fraction() <= (before or 1) + 0.02,
		string.format("%.2f -> %.2f", before or -1, fraction() or -1))
	expect("...and the ability is still on cooldown after all of them", not abilityFires())

	-- 4. A trade completing goes through RefreshAll, the fourth door into the same room. It iterates
	-- real Players, which a stand-in is not, so this checks the call is safe rather than its effect.
	local ok = pcall(CompanionService.RefreshAll)
	expect("RefreshAll runs without error", ok)

	-- 5. The match's own boundary still heals and re-arms. If this ever fails, the fix has taken away
	-- something the game is supposed to do.
	CompanionService.ResetStats()
	expect("match start still heals the companion to full", fraction() ~= nil and fraction() > 0.99, string.format("%.2f", fraction() or -1))
	expect("match start still re-arms the ability", abilityFires())

	-- 6. PLANTED: the check must be able to fail. ResetStats does exactly what the old Refresh did --
	-- full health and `lastAttackAt = -math.huge` -- so running it mid-scenario has to look like a
	-- heal to the same comparison used above. If this case ever passes, every PASS here is worthless.
	CompanionService.Damage("probe-attacker", model(), math.floor((maxHealth() or 2) / 2))
	local hurtAgain = fraction()
	abilityFires()
	CompanionService.ResetStats()
	local healed = fraction() ~= nil and fraction() > (hurtAgain or 0) + 0.2
	expect("planted: a full heal and cooldown reset IS detected by these checks", healed and abilityFires(),
		string.format("%.2f -> %.2f", hurtAgain or -1, fraction() or -1))
end

print(string.format("[RefreshProbe] %d passed, %d failed", passes, failures))
print("[PROBE] companion refresh: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))
