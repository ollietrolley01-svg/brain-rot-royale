-- Server-authoritative shooting. The client sends only a direction; the server owns the
-- raycast, the fire-rate check, the ammo, and the damage.
--
-- Everything here works in combatant tokens (see Combatants), so a bot and a player take
-- and deal damage through exactly the same path.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local ItemData = require(Shared:WaitForChild("ItemData"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local LagCompensation = require(script.Parent:WaitForChild("LagCompensation"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local CombatService = {}

local ATTACKER_MEMORY = 12
local PIERCE_TARGETS = 2

local enabled = false
local lastAttacker = {}
local aiming = {}

-- Aiming tightens spread. The client only reports intent; the server decides what it's
-- worth, so a spoofed "always aiming" gains nothing a held right-click wouldn't.
local ADS_SPREAD_SCALE = 0.34

--------------------------------------------------------------------------------
-- Crouch steadiness
--
-- Crouched and barely moving, the gun sits still: spread x0.75 and recoil x0.85. It fades in over
-- Fade seconds and out over the same, so dropping into a crouch for the instant of a shot buys
-- nothing; and standing up drops it at once, with no trailing grace.
--
-- Crouch-walking runs at 45% of base speed (MovementConfig.Crouch.SpeedMultiplier), above the 40%
-- threshold here, so this is a reward for holding still rather than for holding the key.
--
-- Each scale is applied exactly once, to the spread ADS has already scaled — aiming and crouching
-- multiply, neither is counted twice.
--
-- The fade is stepped on Heartbeat rather than worked out at the shot, because it depends on how
-- long the crouch and the stillness have BOTH held and a shot can be the first look at a player in
-- seconds. The loop only walks characters that are crouching right now, which is nearly always
-- none of them.
--------------------------------------------------------------------------------
-- The numbers live in MovementConfig.Crouch, where the client reading them for the camera kick can
-- see them too. Copied once here so a probe can plant a fault without writing to shared config.
-- The fallbacks are what the config holds today: several tabs edit MovementConfig, and a missing
-- number here would be an error on every shot rather than a gun that's merely tuned wrong.
local STEADY = {
	SpreadScale = MovementConfig.Crouch.SteadySpread or 0.75,
	RecoilScale = MovementConfig.Crouch.SteadyRecoil or 0.85,
	Fade = MovementConfig.Crouch.SteadyFade or 0.2,
	MoveFraction = MovementConfig.Crouch.SteadyMoveFraction or 0.4,
}
-- Exposed so tools/crouch_accuracy_probe.lua can plant a fault (a fade of nothing, which would let
-- a crouch tapped for one shot pay out in full).
CombatService.Steady = STEADY
-- character -> how far the bonus has faded in, 0..1. Only crouching characters are in here, and the
-- crouch ending removes the entry: that is what makes it end without a grace period.
--
-- Strong tables emptied on Destroying, NOT weak-keyed ones. Roblox collects an Instance's Lua handle
-- as soon as nothing but a weak table holds it, even while the Instance is still in the world, so a
-- weak table here would drop a live crouching character's fade at a garbage collection and quietly
-- take the bonus away mid-crouch (and let WatchCrouch connect a second listener to the same
-- character). DestructibleService keeps its damage table the same way, for the same reason.
local steady = {}
local watchedCrouch = {}

-- Set by Bootstrap to MatchService.IsCrouching (MatchService requires this module, so this one
-- can't require it back). Unset, nothing is ever steady, which is how it behaved before.
CombatService.IsCrouching = nil

local function crouchChanged(character)
	if character:GetAttribute("Crouching") then
		steady[character] = steady[character] or 0
	else
		steady[character] = nil
	end
end

-- Watch a character's crouch state, once per character. Called on spawn and again from Fire, so a
-- character that was already crouching the first time we saw it is picked up too (it starts the
-- fade from zero then, which can only cost the shooter the fade, never hand it to them early).
function CombatService.WatchCrouch(character)
	if not character or watchedCrouch[character] then
		return
	end
	watchedCrouch[character] = true
	character:GetAttributeChangedSignal("Crouching"):Connect(function()
		crouchChanged(character)
	end)
	character.Destroying:Connect(function()
		steady[character] = nil
		watchedCrouch[character] = nil
	end)
	crouchChanged(character)
end

RunService.Heartbeat:Connect(function(delta)
	if next(steady) == nil then
		return
	end
	local threshold = MatchConfig.BaseWalkSpeed * STEADY.MoveFraction
	local step = delta / STEADY.Fade
	for character, value in pairs(steady) do
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = humanoid and humanoid.RootPart
		if not root or humanoid.Health <= 0 then
			steady[character] = nil
		else
			local velocity = root.AssemblyLinearVelocity
			if Vector3.new(velocity.X, 0, velocity.Z).Magnitude <= threshold then
				steady[character] = math.min(1, value + step)
			else
				steady[character] = math.max(0, value - step)
			end
		end
	end
end)

-- How far the crouch bonus has faded in for a token, 0..1. The crouch state is asked for as well
-- as the fade, so the bonus is gone the moment the crouch is, whatever the fade had reached.
function CombatService.SteadyFactor(token)
	if not CombatService.IsCrouching or not CombatService.IsCrouching(token) then
		return 0
	end
	local character = Combatants.GetCharacter(token)
	return character and steady[character] or 0
end

function CombatService.SteadySpread(token)
	return 1 - (1 - STEADY.SpreadScale) * CombatService.SteadyFactor(token)
end

-- The spread a shot from `token` goes out with: the weapon's own, tightened by aiming and then by a
-- steady crouch — each applied once, so the two multiply and neither is counted twice. Fire uses
-- this, and so does the probe, so what's measured is what's fired.
-- Bloom (Oliver, 2026-09-22: "the guns need a recoil and accuracy dropoff as they shoot like in other
-- similar games"). Every shot adds a point of heat and heat drains at BLOOM_RECOVER a second, so the
-- first shot is as accurate as the gun's `spread`, a held trigger gets steadily wider (up to
-- 1 + BLOOM_MAX times), and tapping or bursting keeps it tight. A slow gun (a sniper, a pump) drains
-- faster than it fires and never blooms; an SMG held down does. Aiming down sights halves the growth.
local BLOOM_PER_SHOT = 0.2
local BLOOM_MAX = 1.5
local BLOOM_RECOVER = 5
local bloom = setmetatable({}, { __mode = "k" })

local function bloomHeat(token)
	local entry = bloom[token]
	if not entry then
		return 0
	end
	return math.max(0, entry.heat - (os.clock() - entry.at) * BLOOM_RECOVER)
end

function CombatService.NoteShot(token)
	bloom[token] = { heat = bloomHeat(token) + 1, at = os.clock() }
end

function CombatService.SpreadFor(token, def)
	local spread = def and def.spread or 0
	local growth = BLOOM_PER_SHOT
	if aiming[token] then
		spread *= ADS_SPREAD_SCALE
		growth *= 0.5
	end
	spread *= 1 + math.min(bloomHeat(token) * growth, BLOOM_MAX)
	return spread * CombatService.SteadySpread(token)
end

-- For the shooter's own client: the camera kick lives there, so it scales the kick by this.
function CombatService.SteadyRecoil(token)
	return 1 - (1 - STEADY.RecoilScale) * CombatService.SteadyFactor(token)
end

-- A player's own Roblox accessories (hats, hair) stop no bullets. Their Handles are queryable by
-- Roblox default, and a Handle's parent is an Accessory, not a Model, so a shot that struck one walked
-- up to the CHARACTER and was paid as a body hit with the headshot lost, for everyone wearing a hat
-- or hair (HITREG_DESIGN.md, "Second cause"). This is the project's own pattern for everything hung on
-- a character (CosmeticBuild, the held gun): not queryable. Accessories arrive after CharacterAdded,
-- so the character is watched for them rather than swept once.
local function unqueryable(instance)
	if instance:IsA("BasePart") and instance:FindFirstAncestorWhichIsA("Accessory") then
		instance.CanQuery = false
	end
end

function CombatService.WatchAccessories(character)
	for _, instance in ipairs(character:GetDescendants()) do
		unqueryable(instance)
	end
	character.DescendantAdded:Connect(unqueryable)
end

local function characterAdded(character)
	CombatService.WatchCrouch(character)
	CombatService.WatchAccessories(character)
end

local function watchPlayer(player)
	player.CharacterAdded:Connect(characterAdded)
	if player.Character then
		characterAdded(player.Character)
	end
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
end

local shotFired = Remotes.Event("ShotFired")
local damageDealt = Remotes.Event("DamageDealt")
local damageTaken = Remotes.Event("DamageTaken")
local deathRecap = Remotes.Event("DeathRecap")

-- A Headhunter match doubles every headshot (MatchService sets it per match).
CombatService.HeadshotScale = 1

-- Per-player numbers for the results card, and the last few hits each player took for the
-- death recap. Reset when a match starts.
local stats = {}
local recent = {}
local RECAP_WINDOW = 12
local RECAP_HITS = 14

local function statsFor(token)
	local entry = stats[token]
	if not entry then
		entry = { shots = 0, hits = 0, headshots = 0, damageTaken = 0, longestKill = 0 }
		stats[token] = entry
	end
	return entry
end

function CombatService.ResetStats()
	table.clear(stats)
	table.clear(recent)
end

function CombatService.MatchStats(token)
	return stats[token]
end

-- What a weapon id reads as to a person: the gun's name, the companion brainrot, the barrel.
local function describeWeapon(weaponId)
	if type(weaponId) ~= "string" then
		return nil
	end
	local def = WeaponData.Get(weaponId)
	if def then
		return def.name
	end
	local companion = string.match(weaponId, "^Companion:(.+)$")
	if companion then
		return companion .. " (companion)"
	end
	if weaponId == "ExplosiveBarrel" then
		return "Explosive Barrel"
	elseif weaponId == "RotMine" then
		return "Rot Mine"
	end
	-- A thrown item: the Cooked Coconut, say.
	local item = ItemData.Get(weaponId)
	if item then
		return item.name
	end
	return weaponId
end
CombatService.DescribeWeapon = describeWeapon

-- Set by MatchService so this module doesn't need to know about match state.
CombatService.OnElimination = nil

-- Set by ProjectileService: fires a launcher's real round (WeaponData `projectile`).
CombatService.LaunchProjectile = nil

-- Set by ProjectileService to its blast, the one every launcher round and grenade goes off through:
-- fn(blast) with blast = { owner, weaponId, kind, position, normal, damage, radius, wallDamage }.
-- Explosive ammo goes off through it too, so every blast in the game falls off, respects cover and
-- holes walls the same way.
CombatService.Explode = nil

-- Told of every hit that lands: fn(attackerToken, victimToken, dealt, weaponId, headshot, shieldHit).
-- Register with CombatService.OnDamage. Each listener runs protected, so one that errors can't stop
-- damage or the listeners after it. (HitSplatService draws splats; status effects hang off it too.)
CombatService.DamageListeners = {}

function CombatService.OnDamage(fn)
	table.insert(CombatService.DamageListeners, fn)
end

-- Set by CompanionService (which requires this module, so it can't be required back): resolve a
-- hit part to a companion, find a combatant's own companion, and hurt companions.
CombatService.CompanionFromPart = nil
CombatService.CompanionOf = nil
CombatService.DamageCompanion = nil
CombatService.DamageCompanionsInRadius = nil

-- Set by DefenseService: players' barricades, bunkers and fortresses stop bullets and take damage.
CombatService.StructureFromPart = nil
CombatService.DamageStructure = nil
CombatService.DamageStructuresInRadius = nil

-- Set by DestructibleService: the map's own walls, floors, roofs and furniture, which take
-- damage per part rather than per model (a building is one Model, so a model-keyed lookup would
-- give a whole house one health pool instead of 250 a wall).
CombatService.DestructibleFromPart = nil
CombatService.DamageDestructible = nil
CombatService.DamageDestructiblesInRadius = nil
-- Also set by DestructibleService: true for window glass, which breaks and lets the shot through.
CombatService.DestructiblePassesThrough = nil

-- Set by HazardService: explosive barrels take bullets and splash, and go up.
CombatService.HazardFromPart = nil
CombatService.DamageHazard = nil
CombatService.DamageHazardsInRadius = nil

function CombatService.SetEnabled(value)
	enabled = value
end

function CombatService.IsEnabled()
	return enabled
end

function CombatService.SetAiming(player, value)
	aiming[player] = value == true
	if player.Character then player.Character:SetAttribute("Aiming", value == true or nil) end -- #13 third-person aim tilt
end

function CombatService.IsAiming(player)
	return aiming[player] == true
end

function CombatService.ClearAttacker(token)
	lastAttacker[token] = nil
end

-- Who last hurt `token` within ATTACKER_MEMORY seconds, with what, and when: the third value is the
-- os.clock() of that hit (compare with os.clock() on the server, never the client's clock).
function CombatService.GetLastAttacker(token)
	local record = lastAttacker[token]
	if not record then
		return nil
	end
	if os.clock() - record.at > ATTACKER_MEMORY then
		return nil
	end
	return record.token, record.weaponId, record.at
end

function CombatService.BroadcastShot(shooterToken, origin, endPoints, rarity)
	local shooterPlayer = Combatants.IsPlayer(shooterToken) and shooterToken or nil
	shotFired:FireAllClients(shooterPlayer, origin, endPoints, rarity)
end

-- Breaks the window panes on the line from `from` to `to`, stopping at the first thing on the map
-- that isn't glass. Bots don't trace their shots (they roll against accuracy), so this is what
-- makes a bot firing through a window take the pane with it, as a player's traced shot does.
function CombatService.BreakGlassAlong(shooterToken, from, to)
	if not (CombatService.DestructiblePassesThrough and CombatService.DamageDestructible) then
		return
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	local origin = from
	for _ = 1, 4 do
		local delta = to - origin
		if delta.Magnitude < 0.1 then
			return
		end
		local result = workspace:Raycast(origin, delta, params)
		if not result or not CombatService.DestructiblePassesThrough(result.Instance) then
			return
		end
		CombatService.DamageDestructible(shooterToken, result.Instance, 1, from)
		origin = result.Position + delta.Unit * 0.05
	end
end

--------------------------------------------------------------------------------
-- Damage
--------------------------------------------------------------------------------

-- `headshot` only marks the hit for the sound and hit marker; the multiplier is already in `amount`.
function CombatService.DealDamage(attackerToken, victimToken, amount, weaponId, headshot)
	local humanoid = Combatants.GetHumanoid(victimToken)
	if not humanoid or humanoid.Health <= 0 or amount <= 0 then
		return 0
	end

	-- A game mode can refuse a hit outright (friendly fire, spawn protection). nil by default, so
	-- the battle royale is untouched; 0 rather than nothing because callers add the result.
	if CombatService.DamageVeto and CombatService.DamageVeto(attackerToken, victimToken, weaponId) then
		return 0
	end

	-- Time-to-kill (Oliver, 2026-09-22 21:38, #111: "increase the ttk a bit"). Every hit one combatant
	-- lands on another is scaled here, guns, explosives and melee alike, for players and bots, so the
	-- guns keep their balance against each other and every fight lasts a little longer.
	-- Storm, fall and self-damage are left alone.
	if attackerToken ~= nil and attackerToken ~= victimToken then
		amount *= MatchConfig.CombatDamageScale or 1
	end

	-- A shield soaks damage before health does. Players keep theirs in the loadout; bots keep
	-- theirs on the humanoid, where BotService drinks potions into it.
	local absorbed = 0
	if Combatants.IsPlayer(victimToken) then
		amount, absorbed = WeaponService.AbsorbDamage(victimToken, amount)
	else
		local shield = humanoid:GetAttribute("Shield") or 0
		if shield > 0 then
			absorbed = math.min(shield, amount)
			humanoid:SetAttribute("Shield", shield - absorbed)
			amount -= absorbed
		end
	end

	local dealt = absorbed + math.min(amount, humanoid.Health)
	lastAttacker[victimToken] = { token = attackerToken, at = os.clock(), weaponId = weaponId }

	local victimRoot = Combatants.GetRoot(victimToken)
	local hitPosition = victimRoot and victimRoot.Position or nil
	local attackerRoot = attackerToken and Combatants.GetRoot(attackerToken) or nil

	if amount > 0 then
		humanoid:TakeDamage(amount)
	end

	if Combatants.IsPlayer(attackerToken) then
		-- Whether the hit landed on shield (blue hit marker) and whether it was a headshot (gold).
		damageDealt:FireClient(attackerToken, dealt, humanoid.Health <= 0, hitPosition, absorbed > 0, headshot == true)
		if attackerToken ~= victimToken then
			QuestService.Progress(attackerToken, "damage", dealt)
			local entry = statsFor(attackerToken)
			entry.hits += 1
			if headshot then
				entry.headshots += 1
			end
		end
	end

	-- Tell the victim which way the shot came from. Being hit from an unknown direction is
	-- the most disorienting thing that can happen in a battle royale.
	if Combatants.IsPlayer(victimToken) then
		damageTaken:FireClient(victimToken, dealt, attackerRoot and attackerRoot.Position or nil, headshot == true)
		statsFor(victimToken).damageTaken += dealt
		-- Remembered for the death recap: who, with what, from how far.
		local list = recent[victimToken]
		if not list then
			list = {}
			recent[victimToken] = list
		end
		table.insert(list, {
			at = os.clock(),
			name = attackerToken and Combatants.GetName(attackerToken) or nil,
			weaponId = weaponId,
			amount = dealt,
			headshot = headshot == true,
			distance = attackerRoot and victimRoot and (attackerRoot.Position - victimRoot.Position).Magnitude or nil,
		})
		if #list > RECAP_HITS then
			table.remove(list, 1)
		end
	end

	for _, listener in ipairs(CombatService.DamageListeners) do
		local ok, err = pcall(listener, attackerToken, victimToken, dealt, weaponId, headshot == true, absorbed > 0)
		if not ok then
			warn("[CombatService] damage listener failed: " .. tostring(err))
		end
	end

	return dealt
end

-- Hit marker and damage number for damage that didn't go through DealDamage (companions).
-- `kind` (optional) says what was hit when it wasn't a combatant: "structure" for a wall, a window,
-- a barricade or a barrel. The HUD marks those differently, so chipping cover never reads as a hit
-- on a person.
-- `hitShield` and `headshot` colour the marker (blue, gold) the way a hit on a player would; the
-- practice dummies pass them, everything else leaves them off.
function CombatService.ConfirmHit(attackerToken, dealt, killed, position, kind, hitShield, headshot)
	if Combatants.IsPlayer(attackerToken) and dealt > 0 then
		damageDealt:FireClient(attackerToken, dealt, killed, position, hitShield == true, headshot == true, kind)
	end
end

local function combatantsInRadius(position, radius, excludeToken)
	local found = {}
	for character, token in pairs(Combatants.All()) do
		if token ~= excludeToken and character.Parent then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 and (root.Position - position).Magnitude <= radius then
				table.insert(found, { token = token, humanoid = humanoid, root = root })
			end
		end
	end
	return found
end

CombatService.InRadius = combatantsInRadius

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

local function applySpread(direction, spreadDegrees)
	if spreadDegrees <= 0 then
		return direction
	end
	local spin = math.random() * math.pi * 2
	local tilt = math.random() * math.rad(spreadDegrees)
	local base = CFrame.lookAt(Vector3.zero, direction)
	return (base * CFrame.Angles(0, 0, spin) * CFrame.Angles(tilt, 0, 0)).LookVector
end

local function buildRaycastParams(character, shooterToken)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Terrain water doesn't stop a bullet. Left at its default, a raycast HITS water, so a shot
	-- across a river or over the sea on the sand maps died at the surface.
	--
	-- This comment used to say the client's own trace ignored water too. IT DID NOT:
	-- CombatClient.crosshairPoint left IgnoreWater at its default FALSE, so the crosshair stopped at
	-- the surface while the shot passed through it, and the two disagreed about where the player was
	-- aiming. Fixed 2026-09-21 (#97). verify.py now checks the two sites AGREE, because a comment
	-- asserting the opposite of the code is the reason nobody re-checked this for so long.
	params.IgnoreWater = true

	local filter = { character }
	-- Your own companion floats at your shoulder; shots pass straight through it.
	local ownCompanion = CombatService.CompanionOf and CombatService.CompanionOf(shooterToken)
	if ownCompanion then
		table.insert(filter, ownCompanion)
	end
	-- (The storm wall is client-only now, so it never needs excluding here.)
	for _, name in ipairs({ "Loot", "Effects" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter

	return params
end

-- `explosive` is not here: a hitscan gun's blast goes off where its bullet stops (bulletBlast), through
-- the same blast as the launchers, instead of the cruder splash this used to have (which had no
-- caller: the only explosive guns fire real rounds).
local function fireAbility(shooterToken, def, victimToken, hitPosition, baseDamage)
	if def.ability == "chain" and victimToken then
		local victimRoot = Combatants.GetRoot(victimToken)
		if victimRoot then
			for _, entry in ipairs(combatantsInRadius(victimRoot.Position, def.chainRadius or 20, shooterToken)) do
				if entry.token ~= victimToken then
					CombatService.DealDamage(shooterToken, entry.token, baseDamage * (def.chainRatio or 0.5), def.id)
					break
				end
			end
		end
	elseif def.ability == "lifesteal" then
		local humanoid = Combatants.GetHumanoid(shooterToken)
		if humanoid and humanoid.Health > 0 then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + baseDamage * (def.lifestealRatio or 0.2))
		end
	end
end

-- Explosive ammo (#122, WeaponData `explosiveAmmo = { damage, radius, wallDamage }`): a small blast
-- where a hitscan bullet stops. A hitscan gun with the old `ability = "explosive"` gets one too, sized
-- the way that ability always was (60% of the bullet over splashRadius), so no gun can fall back to a
-- second, different blast.
function CombatService.BulletBlast(def)
	if def.explosiveAmmo then
		return def.explosiveAmmo
	end
	if def.ability == "explosive" and not def.projectile then
		return { damage = def.damage * 0.6, radius = def.splashRadius or 12, wallDamage = 0 }
	end
	return nil
end

-- One bullet's blast, through ProjectileService's (CombatService.Explode). The victim the bullet struck
-- is inside it and takes their share like anyone else, exactly as a rocket's direct victim does; a
-- shooter standing too close takes the half every blast gives its owner.
local function bulletBlast(shooterToken, def, position, normal)
	local ammo = CombatService.BulletBlast(def)
	if not ammo or not CombatService.Explode then
		return nil
	end
	return CombatService.Explode({
		owner = shooterToken,
		weaponId = def.id,
		kind = "impact",
		position = position,
		normal = normal,
		damage = ammo.damage,
		radius = ammo.radius,
		innerRadius = 0,
		wallDamage = ammo.wallDamage or 0,
	})
end

-- `rewindTo`: the server time the victims are put back to (LagCompensation), or nil for the present.
local function firePellet(shooterToken, character, origin, direction, def, rewindTo)
	local params = buildRaycastParams(character, shooterToken)
	local remaining = def.ability == "pierce" and PIERCE_TARGETS or 1
	local currentOrigin = origin
	local travelled = 0
	local endPoint = origin + direction * def.range
	-- The last solid thing the bullet struck: where explosive ammo goes off. A pane it broke and flew
	-- on through doesn't count, and a bullet that ran out of range in the open blows up nothing.
	local stopped = nil

	while remaining > 0 and travelled < def.range do
		local result = LagCompensation.Raycast(currentOrigin, direction * (def.range - travelled), params, rewindTo)
		if not result then
			break
		end

		endPoint = result.Position
		stopped = result
		travelled += (result.Position - currentOrigin).Magnitude

		-- Someone else's companion soaks the bullet.
		local companionModel = CombatService.CompanionFromPart and CombatService.CompanionFromPart(result.Instance)
		if companionModel then
			CombatService.DamageCompanion(shooterToken, companionModel, def.damage)
			fireAbility(shooterToken, def, nil, result.Position, def.damage)
			break
		end

		-- A player's barricade, bunker or fortress takes the bullet.
		local structure = CombatService.StructureFromPart and CombatService.StructureFromPart(result.Instance)
		if structure then
			CombatService.DamageStructure(shooterToken, structure, def.damage)
			fireAbility(shooterToken, def, nil, result.Position, def.damage)
			break
		end

		-- The map itself: a wall, floor, roof or the furniture inside a building. Checked after
		-- the things that stand in front of it, and before the shot reaches anyone behind it.
		local destructible = CombatService.DestructibleFromPart and CombatService.DestructibleFromPart(result.Instance)
		if destructible then
			CombatService.DamageDestructible(shooterToken, destructible, def.damage, origin)
			-- A window pane breaks and the shot keeps going: rockets still burst on what's behind it.
			if CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(result.Instance) then
				local filter = params.FilterDescendantsInstances
				table.insert(filter, result.Instance)
				params.FilterDescendantsInstances = filter
				currentOrigin = result.Position + direction * 0.05
				stopped = nil
				continue
			end
			fireAbility(shooterToken, def, nil, result.Position, def.damage)
			break
		end

		-- An explosive barrel takes it, and may go up.
		local hazard = CombatService.HazardFromPart and CombatService.HazardFromPart(result.Instance)
		if hazard then
			CombatService.DamageHazard(shooterToken, hazard, def.damage)
			fireAbility(shooterToken, def, nil, result.Position, def.damage)
			break
		end

		local victimCharacter = result.Instance:FindFirstAncestorOfClass("Model")
		local victimToken = victimCharacter and Combatants.FromCharacter(victimCharacter) or nil
		if not victimToken or not Combatants.IsAlive(victimToken) then
			break
		end

		local damage = def.damage
		local headshot = result.Instance.Name == "Head"
		if headshot then
			damage *= (def.headshotMultiplier or 1) * CombatService.HeadshotScale
		end

		CombatService.DealDamage(shooterToken, victimToken, damage, def.id, headshot)
		fireAbility(shooterToken, def, victimToken, result.Position, def.damage)

		remaining -= 1
		if remaining > 0 then
			-- Keep going through the body for pierce weapons.
			local filter = params.FilterDescendantsInstances
			table.insert(filter, victimCharacter)
			params.FilterDescendantsInstances = filter
			currentOrigin = result.Position + direction * 0.5
		end
	end

	if stopped then
		bulletBlast(shooterToken, def, stopped.Position, stopped.Normal)
	end
	return endPoint
end

-- workspace:Raycast for a shot from `shooterToken`, with its victims rewound to where the shooter saw
-- them (LagCompensation: a player's own ping, capped; a bot, the present). For the hitscan path outside
-- this module (VehicleWeapons), so every bullet in the game is ruled on the same instant.
function CombatService.Raycast(shooterToken, origin, vector, params)
	local rewindTo = LagCompensation.RewindTime(shooterToken, LagCompensation.Now())
	return LagCompensation.Raycast(origin, vector, params, rewindTo)
end

-- True while `player` sits in a vehicle's driving seat. Drivers are VehicleSeats; passengers sit
-- on plain Seats and can shoot. Takes a Player or a probe's stand-in table with a Character.
function CombatService.IsDriving(player)
	local character = (typeof(player) == "table" or typeof(player) == "Instance" and player:IsA("Player")) and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	return seat ~= nil and seat ~= false and seat:IsA("VehicleSeat")
end

-- SHOTS ARE BUDGETED, NOT SPACED.
--
-- This gate used to be `now - lastShotAt < interval * 0.9`: a shot had to arrive at least 90% of an
-- interval after the last one or it was dropped, and dropped SILENTLY -- no BroadcastShot, so no
-- tracer, no muzzle flash, no report, and no ammo spent, while the shooter's own client had already
-- kicked the camera and the viewmodel. A shot that costs you your aim and does nothing is exactly
-- what "the hit registration feels bad" is made of (#97).
--
-- Two things legitimately compress the gap between two shots, and neither is cheating:
--   * the client sends on FRAME boundaries, so consecutive sends are one interval give or take a
--     frame -- at 30 fps that is 33 ms of honest earliness on the Glitch SMG's 71 ms interval;
--   * network jitter bunches packets in flight.
-- Measured against the old gate: once the client's fire rate was made accurate (CombatClient), the
-- Glitch SMG had 7.1 ms of tolerance left, which ordinary jitter clears without trying.
--
-- So: refill at exactly fireRate and allow FIRE_BURST shots of slack. Momentary compression is
-- absorbed, and the SUSTAINED rate -- the thing actually worth enforcing -- is still fireRate
-- exactly, because the bucket cannot refill faster than that. RateLimit's Fire budget still caps the
-- remote itself, so this is not the only thing between the server and a modified client.
local FIRE_BURST = 2

-- How many shots the shooter may take right now; >= 1 means fire. Deliberately does NOT spend
-- anything, so a shot refused for ammo immediately afterwards doesn't burn the budget.
function CombatService.ShotCredit(loadout, def, now)
	local interval = 1 / def.fireRate
	local since = now - (loadout.lastShotAt or 0)
	return math.min(FIRE_BURST, (loadout.fireCredit or FIRE_BURST) + since / interval)
end

-- Commits the shot ShotCredit approved.
function CombatService.SpendShot(loadout, credit, now)
	loadout.fireCredit = credit - 1
	loadout.lastShotAt = now
end

-- `aimPoint` is the world position under the client's crosshair. Direction is derived here
-- from the server's own view of the head, so the client never supplies the vector itself.
function CombatService.Fire(player, aimPoint)
	if not enabled then
		return
	end
	-- The driver has both hands on the wheel. CombatClient won't fire from the seat either; this
	-- holds against a client that ignores that.
	if CombatService.IsDriving(player) then
		return
	end
	-- Reject NaN/inf in ANY component, which would otherwise poison the raycast and reach every
	-- client's tracer through BroadcastShot. (Testing only X for NaN let it through in Y or Z:
	-- math.abs(NaN) > 1e6 is false.)
	if not SafeValue.Vector3(aimPoint) then
		return
	end

	local character = player.Character
	if not character or not Combatants.IsAlive(player) then
		return
	end

	local loadout = WeaponService.Get(player)
	local def = WeaponService.GetEquipped(player)
	if not loadout or not def or loadout.reloading then
		return
	end

	-- Weapon still being raised after a slot change.
	if not WeaponService.IsReady(player) then
		return
	end

	local now = os.clock()
	local credit = CombatService.ShotCredit(loadout, def, now)
	if credit < 1 then
		return
	end

	if not WeaponService.ConsumeAmmo(player) then
		return
	end
	CombatService.SpendShot(loadout, credit, now)
	-- The instant this shot is ruled on (#97): the victims as the shooter saw them, one ping ago on the
	-- server's clock. Worked out after the budget is settled and from nothing the client sent, so it
	-- can neither buy a shot nor be forged. A shot slower than the cap is ruled on the present.
	local rewindTo = LagCompensation.RewindTime(player, LagCompensation.Now())

	local head = character:FindFirstChild("Head")
	local origin = head and head.Position or character:GetPivot().Position

	local toTarget = aimPoint - origin
	if toTarget.Magnitude < 0.5 then
		return
	end
	local unit = toTarget.Unit

	CombatService.WatchCrouch(character)

	local spread = CombatService.SpreadFor(player, def)
	CombatService.NoteShot(player)

	-- Launchers fire real rounds that fly, drop and burst (ProjectileService); the shot still broadcasts
	-- with no end points so everyone gets the flash and report.
	if def.projectile and CombatService.LaunchProjectile then
		CombatService.LaunchProjectile(player, def, origin, applySpread(unit, spread))
		statsFor(player).shots += 1
		CombatService.BroadcastShot(player, origin, {}, def.rarity)
		return
	end

	local endPoints = {}
	for _ = 1, def.pellets or 1 do
		local pelletDirection = applySpread(unit, spread)
		table.insert(endPoints, firePellet(player, character, origin, pelletDirection, def, rewindTo))
	end
	statsFor(player).shots += def.pellets or 1

	CombatService.BroadcastShot(player, origin, endPoints, def.rarity)
end

-- Set by Bootstrap to DeathFxService.OnDeath: what the body does, by the gun that did it.
CombatService.OnDeathFx = nil

-- Damage with no attacker (the storm; StormService.OnDamage), kept for the death recap. It goes in the
-- same list as the hits, so the recap's sources name it, and it marks itself `environment` so that
-- when it was the LAST thing to hurt a player, the recap does not headline whoever shot them seconds
-- earlier. Kill credit is not touched: GetLastAttacker still names the shooter (#86).
function CombatService.RecordEnvironmentDamage(victimToken, amount, source)
	if not Combatants.IsPlayer(victimToken) or type(amount) ~= "number" or amount <= 0 then
		return
	end
	local list = recent[victimToken]
	if not list then
		list = {}
		recent[victimToken] = list
	end
	table.insert(list, { at = os.clock(), name = source, amount = amount, environment = true })
	if #list > RECAP_HITS then
		table.remove(list, 1)
	end
end

-- The death recap a player sees while their body hits the floor: who did it, with what, from how
-- far, what they had left, and where the last twelve seconds of damage came from.
local function sendRecap(victimToken, killerToken, weaponId)
	if not (Combatants.IsPlayer(victimToken) and victimToken.Parent) then
		return
	end
	local now = os.clock()
	local total, bySource, last = 0, {}, nil
	for _, hit in ipairs(recent[victimToken] or {}) do
		if now - hit.at <= RECAP_WINDOW then
			total += hit.amount
			local name = hit.name or "?"
			bySource[name] = (bySource[name] or 0) + hit.amount
			last = hit
		end
	end
	recent[victimToken] = nil

	local sources = {}
	for name, amount in pairs(bySource) do
		table.insert(sources, { name = name, amount = math.floor(amount + 0.5) })
	end
	table.sort(sources, function(a, b)
		return a.amount > b.amount
	end)
	while #sources > 3 do
		table.remove(sources)
	end

	-- Finished by the storm: no "ELIMINATED BY <shooter>  •  <gun>  •  <n> studs" headline. The
	-- shooter is still in `sources` with what they did.
	local environmentFinish = last ~= nil and last.environment == true
	local killerName, killerHealth, killerShield = nil, nil, nil
	if killerToken and killerToken ~= victimToken and not environmentFinish then
		killerName = Combatants.GetName(killerToken)
		local humanoid = Combatants.GetHumanoid(killerToken)
		if humanoid and humanoid.Health > 0 then
			killerHealth = math.ceil(humanoid.Health)
			local shield = Combatants.IsPlayer(killerToken) and WeaponService.GetShield(killerToken) or humanoid:GetAttribute("Shield") or 0
			killerShield = shield > 0 and math.ceil(shield) or nil
		end
	end

	deathRecap:FireClient(victimToken, {
		killer = killerName,
		weapon = not environmentFinish and describeWeapon(weaponId) or nil,
		distance = last and last.distance or nil,
		-- "Storm" when that was the final blow, for the HUD to title the recap by.
		finishedBy = environmentFinish and last.name or nil,
		headshot = last and last.headshot or false,
		killerHealth = killerHealth,
		killerShield = killerShield,
		taken = math.floor(total + 0.5),
		sources = sources,
	})
end

function CombatService.HandleDeath(victimToken)
	local killerToken, weaponId = CombatService.GetLastAttacker(victimToken)
	CombatService.ClearAttacker(victimToken)

	sendRecap(victimToken, killerToken, weaponId)

	-- The longest kill on the killer's card.
	if killerToken and killerToken ~= victimToken and Combatants.IsPlayer(killerToken) then
		local a, b = Combatants.GetRoot(killerToken), Combatants.GetRoot(victimToken)
		if a and b then
			local entry = statsFor(killerToken)
			entry.longestKill = math.max(entry.longestKill, (a.Position - b.Position).Magnitude)
		end
	end

	-- The raw id too: companion hits record "Companion:<name>", which isn't a weapon.
	local def = weaponId and WeaponData.Get(weaponId) or nil
	if CombatService.OnDeathFx then
		CombatService.OnDeathFx(victimToken, killerToken, def)
	end
	if CombatService.OnElimination then
		CombatService.OnElimination(victimToken, killerToken, def, weaponId)
	end
end

function CombatService.ForgetToken(token)
	lastAttacker[token] = nil
	aiming[token] = nil
	stats[token] = nil
	recent[token] = nil
	for victim, record in pairs(lastAttacker) do
		if record.token == token then
			lastAttacker[victim] = nil
		end
	end
end

Players.PlayerRemoving:Connect(CombatService.ForgetToken)

return CombatService
