-- Things on the map that blow up.
--
-- Explosive barrels: red drums in warehouses, back yards, loading docks and the container yard
-- that go up when shot. The blast hurts everyone near it (the shooter gets the kill), knocks
-- down defenses and companions in reach, and sets off any other barrel within range a beat
-- later, so a stack goes up in a chain. Bots don't aim for them, but a bot standing beside one
-- when you do is the whole point.
--
-- Rot Mines: the trap in the defense item pool. A thrown mine lands, takes a moment to arm (a
-- red light, then a slow green blink) and goes off under the next enemy who steps within reach.
-- Its owner can't set it off and isn't hurt by it. A mine can be shot to clear it (it still
-- blows, so stand back), and one that nobody steps on fizzles out after two minutes.
--
--   HazardService.Barrel(parent, cframe)          builds a barrel, its base on `cframe`
--   HazardService.Mine(parent, position, owner)   arms a mine on the ground under `position`
--   HazardService.FromPart(part)                  the hazard a hit part belongs to, or nil
--   HazardService.Damage(model, amount, by)       hurt one; it explodes at zero
--   HazardService.DamageInRadius(position, radius, amount, by)   splash from a blast or a rocket
--   HazardService.Count(kind)                     live barrels/mines (nil for both)
--
-- Registered with CombatService at load, the way defenses are, so bullets and splash find them.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))

local HazardService = {}

HazardService.WeaponId = "ExplosiveBarrel"
HazardService.MineWeaponId = "RotMine"

-- Set by whoever owns the match (Bootstrap -> MatchService): is a match actually being played? A mine
-- is a weapon, and a weapon that still kills during the fifteen-second results screen kills someone
-- who has already won or lost. True by default so this module still runs standalone in a probe, and
-- so a build without a match (the range, the lobby playground) behaves as it always did.
local DEFAULT_MATCH_IS_LIVE = function()
	return true
end
HazardService.MatchIsLive = DEFAULT_MATCH_IS_LIVE

-- Fail-open is deliberate, but never fail-open in SILENCE: if a live mine is polled while the DEFAULT
-- is still installed, Bootstrap's wiring has been dropped or has errored, mines are killing on the
-- results screen again, and nothing anywhere would say so. Warned once, the way StormService warns
-- when a tick begins with no eligibility predicate installed (StormService.lua:54-75).
local warnedUnwiredMatch = false
local warnedPredicateError = false
local function matchIsLive()
	local predicate = HazardService.MatchIsLive
	if predicate == DEFAULT_MATCH_IS_LIVE and not warnedUnwiredMatch then
		warnedUnwiredMatch = true
		warn("[HazardService] a mine was polled with NO match-state predicate installed (Bootstrap wires HazardService.MatchIsLive): mines will trigger during the results screen")
	end
	-- Through a pcall. The mine poll is a bare `while true` inside a task.spawn and there is no pcall
	-- anywhere else in this file, so a predicate that throws would kill that coroutine for the life of
	-- the server -- every mine AND every barrel dead, silently, with one stack trace at the top and
	-- nothing after it. That is far worse than the fifteen seconds of wrong triggering this guards
	-- against, so a throw is treated as LIVE (fail-open, like the default) and named once, with its own
	-- message so "nothing installed" and "it threw" are told apart in a log.
	local ok, live = pcall(predicate)
	if not ok then
		if not warnedPredicateError then
			warnedPredicateError = true
			warn("[HazardService] the match-state predicate threw, so mines keep triggering: " .. tostring(live))
		end
		return true
	end
	return live ~= false
end

local BARREL_HEALTH = 60
local BLAST_RADIUS = 15
local BLAST_DAMAGE = 78
local CHAIN_DELAY = 0.18
local SCORCH_TIME = 25

local MINE_HEALTH = 30
local MINE_SCALE = 3 -- the held item's model, this many times bigger
local MINE_ARM_TIME = 1.5
local MINE_TRIGGER_RADIUS = 5.5
local MINE_TRIGGER_HEIGHT = 6 -- someone on the floor above doesn't set it off
local MINE_BLAST_RADIUS = 10
local MINE_BLAST_DAMAGE = 95
local MINE_LIFETIME = 120
local MINE_POLL = 0.1

local RED = Color3.fromRGB(176, 40, 36)
local RED_DARK = Color3.fromRGB(120, 28, 26)
local YELLOW = Color3.fromRGB(255, 200, 40)
local IRON = Color3.fromRGB(58, 58, 64)
local LIGHT_ARMING = Color3.fromRGB(255, 80, 60)
local LIGHT_ARMED = Color3.fromRGB(90, 255, 120)
local LIGHT_OFF = Color3.fromRGB(40, 60, 44)

-- model -> { kind, health, exploded, base (centre height above the ground), owner, armsAt,
-- armed, expiresAt, position }. Strong keys, dropped when the hazard is destroyed (with its
-- map, or by going up): a weak-keyed table loses live Instances here, since Roblox collects an
-- instance's Lua handle whenever nothing but a weak table holds it.
local hazards = {}

local function part(parent, name, size, cframe, color, material, shape)
	local instance = Instance.new("Part")
	instance.Name = name
	if shape then
		instance.Shape = shape
	end
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Parent = parent
	return instance
end

local function decor(instance)
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	return instance
end

local function register(model, entry)
	hazards[model] = entry
	model.Destroying:Connect(function()
		hazards[model] = nil
	end)
end

--------------------------------------------------------------------------------
-- Barrels
--------------------------------------------------------------------------------

-- A drum standing on `cframe`: red body, a yellow warning band, dark rims, a filler cap and a
-- hazard plate on the front. The body is the part bullets and the pickup checks find.
function HazardService.Barrel(parent, cframe)
	local model = Instance.new("Model")
	model.Name = "ExplosiveBarrel"

	local body = part(model, "Barrel", Vector3.new(4.6, 3.4, 3.4), cframe * CFrame.new(0, 2.3, 0) * CFrame.Angles(0, 0, math.pi / 2), RED,
		Enum.Material.Metal, Enum.PartType.Cylinder)
	for _, y in ipairs({ 0.32, 4.28 }) do
		decor(part(model, "BarrelRim", Vector3.new(0.3, 3.52, 3.52), cframe * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2), IRON,
			Enum.Material.Metal, Enum.PartType.Cylinder))
	end
	decor(part(model, "BarrelBand", Vector3.new(0.5, 3.52, 3.52), cframe * CFrame.new(0, 2.3, 0) * CFrame.Angles(0, 0, math.pi / 2), YELLOW,
		Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	decor(part(model, "BarrelCap", Vector3.new(0.2, 0.8, 0.8), cframe * CFrame.new(0.9, 4.7, 0) * CFrame.Angles(0, 0, math.pi / 2), IRON,
		Enum.Material.Metal, Enum.PartType.Cylinder))
	local plate = decor(part(model, "BarrelPlate", Vector3.new(1.4, 1.4, 0.1), cframe * CFrame.new(0, 3.2, -1.76), RED_DARK, Enum.Material.SmoothPlastic))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.6
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = "!"
	label.TextColor3 = YELLOW
	label.TextScaled = true
	label.Parent = gui
	gui.Parent = plate

	model.PrimaryPart = body
	model:SetAttribute("Explosive", true)
	ZFight.Fix({ model }, { all = true })
	model.Parent = parent

	register(model, { kind = "barrel", health = BARREL_HEALTH, base = 2.3 })
	return model
end

--------------------------------------------------------------------------------
-- Mines
--------------------------------------------------------------------------------

-- The ground under a landing spot: the map or terrain, not loot, companions or another player's
-- barricade (a mine thrown onto one settles on the ground beneath it).
local function groundUnder(position)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local filter = {}
	for _, name in ipairs({ "Loot", "Companions", "Effects", "SupplyDrops", "Deployables", "Defenses" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter
	local hit = workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -30, 0), params)
	return hit and hit.Position or position
end

-- A mine's arming delay and lifetime are wall time: os.clock is CPU time in Roblox and drifts from the
-- wall under load, so a busy server armed mines late and left them out past their lifetime. Server time,
-- the clock CompanionService's cooldowns use.
local function clockNow()
	return workspace:GetServerTimeNow()
end

-- Arms a mine on the ground under `position`, owned by `ownerToken` (a player or a bot; nil for
-- one nobody owns, which anyone can set off). Returns the model, or nil if it couldn't be built.
function HazardService.Mine(parent, position, ownerToken)
	local model = ItemModels.Build("RotMine", { scale = MINE_SCALE, name = "RotMine" })
	if not model then
		return nil
	end
	local ground = groundUnder(position)
	-- The disc's centre sits half its height above the ground; the pivot is the design origin.
	model:PivotTo(CFrame.new(ground + Vector3.new(0, 0.1 * MINE_SCALE, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0))

	-- Shootable (bullets find the body) but not solid: you walk straight over it.
	local body = model:FindFirstChild("Body")
	if body then
		body.CanQuery = true
		model.PrimaryPart = body
	end
	model:SetAttribute("Explosive", true)
	model:SetAttribute("Armed", false)
	if Combatants.IsPlayer(ownerToken) then
		model:SetAttribute("OwnerUserId", ownerToken.UserId)
	end
	model.Parent = parent

	local now = clockNow()
	local entry = {
		kind = "mine",
		health = MINE_HEALTH,
		base = 0.1 * MINE_SCALE,
		owner = ownerToken,
		armsAt = now + MINE_ARM_TIME,
		expiresAt = now + MINE_LIFETIME,
		position = model:GetPivot().Position,
		lights = {},
	}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant.Name == "Glow" and descendant:IsA("BasePart") then
			table.insert(entry.lights, descendant)
			local light = Instance.new("PointLight")
			light.Color = LIGHT_ARMING
			light.Range = 6
			light.Brightness = 1.5
			light.Parent = descendant
		end
	end
	register(model, entry)
	return model
end

local function setLights(entry, color)
	for _, glow in ipairs(entry.lights) do
		if glow.Parent then
			glow.Color = color
			local light = glow:FindFirstChildOfClass("PointLight")
			if light then
				light.Color = color
				light.Enabled = color ~= LIGHT_OFF
			end
		end
	end
end

-- A mine nobody stepped on: a puff and it's gone, no damage.
local function fizzle(model, entry)
	entry.exploded = true
	local puff = Instance.new("Part")
	puff.Name = "Fizzle"
	puff.Shape = Enum.PartType.Ball
	puff.Size = Vector3.new(1.5, 1.5, 1.5)
	puff.CFrame = CFrame.new(entry.position)
	puff.Color = LIGHT_ARMED
	puff.Material = Enum.Material.Neon
	puff.Anchored = true
	puff.CanCollide = false
	puff.CanQuery = false
	puff.CanTouch = false
	puff.Parent = model.Parent or workspace
	TweenService:Create(puff, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(5, 5, 5), Transparency = 1 }):Play()
	Debris:AddItem(puff, 0.6)
	model:Destroy()
end

--------------------------------------------------------------------------------
-- Damage and the blast
--------------------------------------------------------------------------------

function HazardService.FromPart(instance)
	local model = instance and instance:FindFirstAncestorOfClass("Model")
	return model and hazards[model] and model or nil
end

local explode

-- Returns the damage actually taken.
function HazardService.Damage(model, amount, attackerToken)
	local entry = hazards[model]
	if not entry or entry.exploded or amount <= 0 then
		return 0
	end
	local dealt = math.min(entry.health, amount)
	entry.health -= dealt
	if entry.health <= 0 then
		explode(model, attackerToken)
	end
	return dealt
end

function HazardService.DamageInRadius(position, radius, amount, attackerToken)
	for model, entry in pairs(hazards) do
		if not entry.exploded and model.Parent and model.PrimaryPart and (model.PrimaryPart.Position - position).Magnitude <= radius then
			HazardService.Damage(model, amount, attackerToken)
		end
	end
end

-- The blast: a flash and fireball that everyone sees (an Explosion with no physics of its own,
-- so it can't fling anchored parts about), a scorch mark with smoke, a few fragments, then the
-- damage — and the chain to any barrel in reach.
explode = function(model, attackerToken)
	local entry = hazards[model]
	if not entry or entry.exploded then
		return
	end
	entry.exploded = true

	local mine = entry.kind == "mine"
	local radius = mine and MINE_BLAST_RADIUS or BLAST_RADIUS
	local baseDamage = mine and MINE_BLAST_DAMAGE or BLAST_DAMAGE
	local weaponId = mine and HazardService.MineWeaponId or HazardService.WeaponId

	local body = model.PrimaryPart
	local position = body and body.Position or model:GetPivot().Position
	local parent = model.Parent or workspace

	-- The look: every client draws it with ExplosiveFx, the same layered blast as a grenade or rocket
	-- (flash, fireballs, shock ring, sparks, smoke, debris, scorch), sized to this blast's radius, with
	-- its sound and screen kick (ProjectileClient's "detonate"). It used to be a bare Explosion and one
	-- tweened ball. Look only: the damage below is unchanged.
	Remotes.Event("ProjectileFx"):FireAllClients("detonate", {
		position = position,
		normal = Vector3.yAxis,
		kind = "grenade",
		radius = radius,
		weaponId = weaponId,
	})


	-- Fragments thrown out: drum plates from a barrel, a few shards from a mine.
	local fragments = mine and 4 or 6
	for index = 1, fragments do
		local fragment = Instance.new("Part")
		fragment.Name = "Fragment"
		fragment.Size = mine and Vector3.new(0.7, 0.2, 0.5) or Vector3.new(1.2, 0.3, 0.8)
		fragment.CFrame = CFrame.new(position) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		fragment.Color = index % 2 == 0 and (mine and IRON or RED) or IRON
		fragment.Material = Enum.Material.Metal
		fragment.CanCollide = true
		fragment.CanQuery = false
		fragment.CanTouch = false
		fragment.Parent = parent
		local angle = index / fragments * math.pi * 2
		fragment.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * 28, 32 + math.random() * 16, math.sin(angle) * 28)
		fragment.AssemblyAngularVelocity = Vector3.new(math.random() * 12, math.random() * 12, math.random() * 12)
		Debris:AddItem(fragment, 3)
	end

	model:Destroy()

	-- The damage. Whoever blew it up gets the credit; a barrel set off by another barrel keeps
	-- the same credit, so a chain still counts as one shooter's. A mine spares its owner.
	for _, victim in ipairs(CombatService.InRadius(position, radius, nil)) do
		if not (mine and entry.owner ~= nil and victim.token == entry.owner) then
			local falloff = 1 - (victim.root.Position - position).Magnitude / radius
			local damage = baseDamage * math.clamp(0.35 + falloff * 0.65, 0, 1)
			CombatService.DealDamage(attackerToken, victim.token, damage, weaponId)
		end
	end
	if CombatService.DamageCompanionsInRadius and attackerToken then
		CombatService.DamageCompanionsInRadius(attackerToken, position, radius, baseDamage * 0.6)
	end
	if CombatService.DamageStructuresInRadius then
		CombatService.DamageStructuresInRadius(position, radius, baseDamage * 1.5)
	end
	-- And the map itself: a barrel going up beside a wall takes a hole out of it.
	if CombatService.DamageDestructiblesInRadius then
		CombatService.DamageDestructiblesInRadius(position, radius, baseDamage * 1.2, attackerToken)
	end

	-- Quests: barrels you set off count; a mine is counted where it's thrown (DefenseService).
	if not mine and Combatants.IsPlayer(attackerToken) then
		QuestService.Progress(attackerToken, "barrels", 1)
	end

	-- The chain: barrels and mines alike go up when one blows beside them.
	for other, otherEntry in pairs(hazards) do
		if other ~= model and not otherEntry.exploded and other.Parent and other.PrimaryPart
			and (other.PrimaryPart.Position - position).Magnitude <= radius * 1.15 then
			task.delay(CHAIN_DELAY + math.random() * 0.12, function()
				HazardService.Damage(other, math.max(BARREL_HEALTH, MINE_HEALTH), attackerToken)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Mine watch: arming, the blink, the trigger, the fizzle
--------------------------------------------------------------------------------

local function stepMines(now)
	for model, entry in pairs(hazards) do
		if entry.kind == "mine" and not entry.exploded then
			if not model.Parent then
				hazards[model] = nil
			elseif now >= entry.expiresAt then
				fizzle(model, entry)
			elseif now < entry.armsAt then
				-- Arming: a fast red flicker.
				setLights(entry, math.floor(now * 8) % 2 == 0 and LIGHT_ARMING or LIGHT_OFF)
			else
				if not entry.armed then
					entry.armed = true
					model:SetAttribute("Armed", true)
				end
				setLights(entry, math.floor(now * 1.5) % 2 == 0 and LIGHT_ARMED or LIGHT_OFF)
				-- It still blinks and still times out, but it does not TRIGGER once the match is over:
				-- walking over a mine on the results screen is not a death anyone can answer.
				for _, victim in ipairs(matchIsLive() and CombatService.InRadius(entry.position, MINE_TRIGGER_RADIUS, entry.owner) or {}) do
					if math.abs(victim.root.Position.Y - entry.position.Y) <= MINE_TRIGGER_HEIGHT then
						explode(model, entry.owner)
						break
					end
				end
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(MINE_POLL)
		stepMines(clockNow())
	end
end)

-- How many live hazards there are (for the build check): "barrel", "mine", or nil for both.
function HazardService.Count(kind)
	local count = 0
	for model, entry in pairs(hazards) do
		if not entry.exploded and model.Parent and (kind == nil or entry.kind == kind) then
			count += 1
		end
	end
	return count
end

-- Everything this service is holding, gone: the mines a match left armed, and optionally the barrels
-- too. Called at both ends of a match, so nothing armed survives a results screen or greets the next
-- one. `kind` is "mine", "barrel", or nil for both. Returns how many it removed.
function HazardService.Clear(kind)
	local removed = 0
	for model, entry in pairs(hazards) do
		if kind == nil or entry.kind == kind then
			hazards[model] = nil
			if model.Parent then
				model:Destroy()
			end
			removed += 1
		end
	end
	return removed
end

-- Whether a mine has finished arming (for the build check).
function HazardService.IsArmed(model)
	local entry = hazards[model]
	return entry ~= nil and entry.armed == true and not entry.exploded
end

CombatService.HazardFromPart = HazardService.FromPart
CombatService.DamageHazard = function(shooterToken, model, amount)
	local body = model.PrimaryPart
	local at = body and body.Position or nil
	local dealt = HazardService.Damage(model, amount, shooterToken)
	CombatService.ConfirmHit(shooterToken, dealt, false, at, "structure")
	return dealt
end
CombatService.DamageHazardsInRadius = HazardService.DamageInRadius

-- A barrel standing on a building floor (MapBuildings puts them on every storey) or a mine a player
-- laid there: when that floor or roof breaks, it comes down onto whatever is under it rather than
-- hanging in the air (DestructibleService.OnPartBroken).
--
-- A mine keeps everything it had — owner, arming time, lifetime, blast — because only the model
-- moves; its entry's stored `position`, which the trigger and the blast read, is re-pointed to where
-- it landed. A barrel that would land in something (a player, a structure, another hazard) is left
-- where it is instead: better a barrel in the air than one inside somebody.
DestructibleService.OnPartBroken(function(cframe, size)
	local models = {}
	for model, entry in pairs(hazards) do
		if not entry.exploded and model.Parent then
			table.insert(models, model)
		end
	end
	local resting = DestructibleService.RestingOn(cframe, size, models)
	if #resting == 0 then
		return
	end
	task.defer(function()
		for _, model in ipairs(resting) do
			local entry = hazards[model]
			if entry and not entry.exploded and model.Parent then
				local wasAt = model:GetPivot()
				local clearance = OverlapParams.new()
				clearance.FilterType = Enum.RaycastFilterType.Exclude
				clearance.FilterDescendantsInstances = { model }
				if DestructibleService.SettleDown(model) then
					-- Landed: anything solid sharing that space means it went somewhere it shouldn't, so
					-- it goes back where it was.
					local landedBox, landedSize = model:GetBoundingBox()
					local blocked = false
					for _, other in ipairs(workspace:GetPartBoundsInBox(landedBox, landedSize * 0.9, clearance)) do
						if other.CanCollide and other:IsDescendantOf(workspace) and not other:IsDescendantOf(model) then
							local character = other:FindFirstAncestorOfClass("Model")
							if (character and character:FindFirstChildOfClass("Humanoid")) or hazards[character] then
								blocked = true
								break
							end
						end
					end
					if blocked then
						model:PivotTo(wasAt)
					elseif entry.position then
						entry.position = model:GetPivot().Position
					end
				end
			end
		end
	end)
end)

return HazardService
