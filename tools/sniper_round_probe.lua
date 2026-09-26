-- Sniper round probe (task 17): a sniper's bullet flying through the real ProjectileService and
-- CombatService inside Studio, in edit mode.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/sniper_round_probe.lua -WaitSeconds 120
--   python tools/linux/studio.py runtest -Probe tools/sniper_round_probe.lua          (Jacob's Linux harness)
--
-- Stepped by hand (SetAutoStep(false)) in a lane high above the map, with anchored stand-in combatants
-- registered with Combatants, the way tools/projectile_probe.lua does it. It prints:
--   FLIGHT   the round's position every 0.05 s on its way to a target 300 studs off, and when the hit lands
--   HEAD     a head-centre shot at 300 studs: a headshot, for the gun's multiplier
--   WALL     a 0.5-stud wall at 200 studs, stepped at 0.1 s (90 studs a step): the target behind takes nothing
-- Lines starting "PROBLEM" are failures. The offline twin is tools/sniper_round_check.py.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local CombatService = require(Modules:WaitForChild("CombatService"))
local ProjectileService = require(Modules:WaitForChild("ProjectileService"))

ProjectileService.SetAutoStep(false)
CombatService.SetEnabled(true)
-- Two stand-in bots with no team: whatever veto the loaded game mode left behind could read them as
-- team-mates, and a round flies through a team-mate. The battle royale has no veto; neither does this.
local savedVeto = CombatService.DamageVeto
CombatService.DamageVeto = nil

local V = Vector3.new
local ORIGIN = V(-9000, 3000, 9000)
local problems = 0

local function say(text)
	print("[sniper_round_probe] " .. text)
end
local function problem(text)
	problems += 1
	say("PROBLEM " .. text)
end

local map = workspace:FindFirstChild("Map")
local ownMap = false
if not map then
	map = Instance.new("Model")
	map.Name = "Map"
	map.Parent = workspace
	ownMap = true
end
local lane = Instance.new("Model")
lane.Name = "SniperRoundProbe"
lane.Parent = map
-- People stand outside Map, as characters do in a match: a part under Map is the map's (a destructible),
-- and the hitscan rules check the map before bodies.
local bodies = Instance.new("Model")
bodies.Name = "SniperRoundProbeBodies"
bodies.Parent = workspace

local function block(name, size, position)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Anchored = true
	part.Parent = lane
	return part
end

local function dummy(position, name)
	local model = Instance.new("Model")
	model.Name = name
	local function limb(limbName, size, offset)
		local part = Instance.new("Part")
		part.Name = limbName
		part.Size = size
		part.CFrame = CFrame.new(position + offset)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		return part
	end
	local root = limb("HumanoidRootPart", V(2, 2, 1), V(0, 0, 0))
	root.Transparency = 1
	limb("UpperTorso", V(2, 1.6, 1), V(0, 0.2, 0))
	limb("Head", V(1.2, 1.2, 1.2), V(0, 1.6, 0))
	limb("LowerTorso", V(1.8, 2, 1), V(0, -2, 0))
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = bodies
	humanoid.MaxHealth = 5000
	humanoid.Health = 5000
	local token = { isBot = true, name = name, character = model }
	Combatants.Register(model, token)
	return token, model, humanoid
end

local hits = {}
CombatService.OnDamage(function(_, victim, dealt, weaponId, headshot)
	table.insert(hits, { victim = victim, dealt = dealt, weaponId = weaponId, headshot = headshot, at = ProjectileService.Clock() })
end)

local def = WeaponData.Get("LarilaSniper")
local spec = Ballistics.Rounds[def.round or ""]
if not spec then
	problem("LarilaSniper has no flying round (WeaponData `round`)")
end

-- One shot from `shooter`'s head at `aim`, stepped at `dt` until nothing is in flight. Returns the hit
-- list and the positions sampled every `every` seconds.
local function shoot(shooterModel, aim, dt, every)
	table.clear(hits)
	ProjectileService.Clear()
	local head = shooterModel.Head.Position
	local started = ProjectileService.Clock()
	-- The same launch CombatService.Fire makes for a player (its LaunchProjectile hook is this function).
	local entry = ProjectileService.LaunchRound(Combatants.FromCharacter(shooterModel), def, head, aim - head)
	local samples, nextAt = {}, 0
	for _ = 1, math.ceil(2 / dt) do
		local rounds = ProjectileService.Counts()
		if rounds == 0 then
			break
		end
		ProjectileService.Step(dt)
		local t = ProjectileService.Clock() - started
		if every and t >= nextAt - 1e-6 then
			nextAt += every
			local live = entry and ProjectileService.Peek(entry.id)
			if live then
				table.insert(samples, string.format("%.2fs z%.0f y%+.2f", t, live.position.Z - head.Z, live.position.Y - head.Y))
			end
		end
	end
	for _, hit in ipairs(hits) do
		hit.after = hit.at - started
	end
	return hits, samples
end

local _, shooterModel = dummy(ORIGIN, "Shooter")
local target = dummy(ORIGIN + V(0, 0, -300), "Target")

if spec then
	-- FLIGHT: a body shot at 300 studs.
	local got, samples = shoot(shooterModel, ORIGIN + V(0, 0.2, -600), 1 / 60, 0.05)
	say("FLIGHT " .. table.concat(samples, " | "))
	local hit = got[1]
	if not hit or hit.victim ~= target then
		problem("FLIGHT: the target at 300 studs was not hit")
	else
		say(string.format("FLIGHT hit %s for %d after %.3f s (300 studs at %d studs/s is %.3f s), headshot %s",
			hit.victim.name, hit.dealt, hit.after, spec.speed, 300 / spec.speed, tostring(hit.headshot)))
		if hit.after < 0.3 then
			problem("FLIGHT: the hit landed after " .. hit.after .. " s: that is hitscan")
		end
	end

	-- HEAD: aimed at the head's centre at 300 studs.
	got = shoot(shooterModel, ORIGIN + V(0, 1.6, -300), 1 / 60)
	hit = got[1]
	say(string.format("HEAD %s", hit and string.format("dealt %d, headshot %s", hit.dealt, tostring(hit.headshot)) or "no hit"))
	if not hit or not hit.headshot then
		problem("HEAD: a head-centre shot at 300 studs was not a headshot")
	end

	-- WALL: a thin wall in the way, stepped coarsely.
	local wall = block("ThinWall", V(20, 12, 0.5), ORIGIN + V(0, 0, -200))
	got = shoot(shooterModel, ORIGIN + V(0, 0.2, -600), 0.1)
	say(string.format("WALL 0.5-stud wall at 200 studs, 0.1 s steps: %d hit(s) on the target behind it", #got))
	if #got > 0 then
		problem("WALL: the round passed a 0.5-stud wall")
	end
	wall:Destroy()
end

ProjectileService.Clear()
lane:Destroy()
bodies:Destroy()
if ownMap then
	map:Destroy()
end
ProjectileService.SetAutoStep(true)
CombatService.DamageVeto = savedVeto
say(string.format("veto set by the loaded mode: %s (cleared for this probe)", tostring(savedVeto ~= nil)))
say(string.format("SUMMARY %d problem(s)", problems))
