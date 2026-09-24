-- The body of tools/killanim_check.py (#24, death effects): run by it under lupa with the sources
-- handed in as strings and tools/deathfx_mocks.lua as `M`. Returns { fails = {...}, report = {...} }.
-- Every section runs the REAL file named, with only the engine's surroundings stood in for.

local M, src = ...
M.install()
-- Plain Lua's compiler (this file runs under lupa, not in Roblox, where there is no `load`).
local compile = _G["load"]

local fails, report = {}, {}
local function fail(fmt, ...)
	table.insert(fails, string.format(fmt, ...))
end
local function note(fmt, ...)
	table.insert(report, string.format(fmt, ...))
end
local V = M.vec

warn = function() end
script = nil

--------------------------------------------------------------------------------
-- Module plumbing: require(marker) -> MODULES[name]
--------------------------------------------------------------------------------

local MODULES = {}
local function marker(name)
	local m = { Name = name, __marker = true }
	m.WaitForChild = function(_, child) return marker(child) end
	m.FindFirstChild = function(_, child) return marker(child) end
	m.Parent = nil
	return m
end
local parentMarker = marker("Parent")
require = function(m)
	local found = MODULES[m.Name]
	if found == nil then
		error("unexpected require " .. tostring(m.Name))
	end
	return found
end
local function loadModule(source, name, env)
	local chunk, err = compile(source, "=" .. name, "t", env or _G)
	if not chunk then
		error("compile " .. name .. ": " .. tostring(err))
	end
	return chunk()
end

-- The world: a workspace instance with a camera and nothing to hit.
workspace = M.new("Workspace")
workspace.CurrentCamera = { CFrame = M.CFrame.new(0, 10, 0) }
rawset(workspace, "Raycast", function() return nil end)
rawset(workspace, "GetServerTimeNow", function() return 0 end)

local Players = { LocalPlayer = { Character = nil }, GetPlayers = function() return {} end, GetPlayerFromCharacter = function() return nil end }
local RunService = setmetatable({}, { __index = function(_, key)
	if key == "Heartbeat" then return M.Heartbeat end
	if key == "IsStudio" then return function() return false end end
end })
local tweens = {}
local TweenService = { Create = function(_, inst, info, goal)
	return { Play = function() table.insert(tweens, { inst = inst, goal = goal, at = M.now, time = info.Time }) end }
end }
local SERVICES = {
	Players = Players, RunService = RunService, TweenService = TweenService,
	Debris = { AddItem = function() end }, ReplicatedStorage = marker("ReplicatedStorage"),
}
game = { GetService = function(_, name) return SERVICES[name] or marker(name) end }
script = { Parent = parentMarker }

-- Fresh module tables per load, since several sections mutate them.
local function freshShared()
	MODULES.Rarity = loadModule(src.rarity, "Rarity")
	MODULES.CosmeticData = loadModule(src.cosmetic, "CosmeticData")
	MODULES.CrateData = loadModule(src.crate, "CrateData")
	MODULES.DeathEffectFx = loadModule(src.engine, "DeathEffectFx")
	MODULES.DeathEffectDesigns = loadModule(src.designs, "DeathEffectDesigns")
	MODULES.SafeValue = loadModule(src.safevalue, "SafeValue")
end
freshShared()
local CosmeticData = MODULES.CosmeticData
local CrateData = MODULES.CrateData
local Fx = MODULES.DeathEffectFx
local Designs = MODULES.DeathEffectDesigns
local SoundConfig = loadModule(src.soundconfig, "SoundConfig")

--------------------------------------------------------------------------------
-- 1. CosmeticData and the crate
--------------------------------------------------------------------------------

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }
local SOLD = { Common = true, Uncommon = true, Rare = true, Epic = true }
local bands = {}
for _, item in pairs(CosmeticData.Items) do
	if item.kind ~= "KillAnimation" and item.price and not item.crateOnly and not item.rankOnly and not item.bundleOnly then
		local band = bands[item.rarity] or { lo = math.huge, hi = 0 }
		band.lo, band.hi = math.min(band.lo, item.price), math.max(band.hi, item.price)
		bands[item.rarity] = band
	end
end
local killIds = CosmeticData.OfKind("KillAnimation")
if #killIds ~= 15 then fail("%d death effects in CosmeticData, want 15 (7 before, 8 new)", #killIds) end
local byRarity, names = {}, {}
for _, other in pairs(CosmeticData.Items) do
	names[other.name] = (names[other.name] or 0) + 1
end
-- Does any crate draw this kind?
local drawnBy = {}
for tier, crate in pairs(CrateData.Crates) do
	local kinds = crate.kinds or { crate.category }
	for _, kind in ipairs(kinds) do
		if kind == "KillAnimation" then table.insert(drawnBy, tier) end
	end
end
for _, id in ipairs(killIds) do
	local item = CosmeticData.Get(id)
	byRarity[item.rarity] = (byRarity[item.rarity] or 0) + 1
	if type(item.name) ~= "string" or item.name == "" then fail("%s has no name", id) end
	if names[item.name] and names[item.name] > 1 then fail("%s's name %q is shared with another cosmetic", id, item.name) end
	if type(item.description) ~= "string" or item.description == "" then fail("%s has no description", id) end
	if SOLD[item.rarity] then
		local band = bands[item.rarity]
		if item.crateOnly then fail("%s is %s but a crate exclusive; Common to Epic are sold", id, item.rarity) end
		if not band then
			fail("%s: rarity %s has no price band", id, tostring(item.rarity))
		elseif type(item.price) ~= "number" or item.price < band.lo or item.price > band.hi then
			fail("%s costs %s, outside the %s band %d-%d", id, tostring(item.price), item.rarity, band.lo, band.hi)
		end
	else
		if not item.crateOnly or item.price then fail("%s is %s but isn't a price-less crate exclusive", id, tostring(item.rarity)) end
		if #drawnBy == 0 then fail("%s is a crate exclusive, but no crate draws death effects", id) end
	end
end
for _, rarity in ipairs(RARITIES) do
	if not byRarity[rarity] then fail("no death effect of rarity %s", rarity) end
end
local crate = CrateData.Get("DeathEffect")
if not crate then
	fail("CrateData has no DeathEffect crate")
else
	local total = 0
	for _, weight in pairs(crate.odds) do total = total + weight end
	if math.abs(total - 100) > 1e-6 then fail("Death Effect Crate odds add to %s", tostring(total)) end
	for rarity, weight in pairs(crate.odds) do
		if weight > 0 and not byRarity[rarity] then fail("Death Effect Crate rolls %s, which has no death effect", rarity) end
	end
	for _, rarity in ipairs({ "Legendary", "Mythic", "Secret" }) do
		if not ((crate.odds[rarity] or 0) > 0) then fail("the Death Effect Crate can't roll %s, so those death effects can't be had", rarity) end
	end
	if crate.category ~= "KillAnimation" then fail("Death Effect Crate category %s", tostring(crate.category)) end
	if CrateData.Order[#CrateData.Order] ~= "DeathEffect" then fail("DeathEffect isn't last in CrateData.Order, so earlier crates' stock rolls move") end
	local shown = table.concat(CrateData.OddsLine(crate, 1, false), " ")
	for rarity, weight in pairs(crate.odds) do
		if weight > 0 and not shown:find(rarity, 1, true) then fail("the crate card's odds line leaves out %s", rarity) end
	end
end
local spread = {}
for _, rarity in ipairs(RARITIES) do
	table.insert(spread, rarity .. " " .. (byRarity[rarity] or 0))
end
note("death effects: %d (%s), crates drawing them: %s", #killIds, table.concat(spread, ", "), table.concat(drawnBy, ", "))

--------------------------------------------------------------------------------
-- 2. EquipCosmetic, 3. PlayerData reconcile, StateSync, Bootstrap
--------------------------------------------------------------------------------

local profile
local Reward = compile(src.equip, "=EquipCosmetic", "t", setmetatable({
	PlayerData = { Get = function() return profile end },
	CosmeticData = CosmeticData,
	StateSync = { Push = function() end },
}, { __index = _G }))()
local anim = killIds[1]
profile = { Cosmetics = { owned = { [anim] = true, GoldSahur = true }, gunSkin = "GoldSahur" } }
local ok = Reward.EquipCosmetic({}, anim)
if not ok or profile.Cosmetics.killAnimation ~= anim then fail("equipping owned %s didn't fill the killAnimation slot", anim) end
if profile.Cosmetics.gunSkin ~= "GoldSahur" then fail("equipping a death effect touched the gun skin") end
Reward.EquipCosmetic({}, anim)
if profile.Cosmetics.killAnimation ~= nil then fail("re-equipping %s didn't take it off", anim) end
ok = Reward.EquipCosmetic({}, killIds[2])
if ok or profile.Cosmetics.killAnimation ~= nil then fail("an unowned death effect was equipped") end
Reward.EquipCosmetic({}, anim)
Reward.EquipCosmetic({}, nil)
if profile.Cosmetics.killAnimation ~= nil then fail("EquipCosmetic(nil) left the death effect on") end

local env = setmetatable({ BrainrotData = { ClampStars = function(s) return s end, Get = function() return nil end, MaxStars = 5 },
	ProgressionData = { Default = function() return {} end, Reconcile = function() return {} end } }, { __index = _G })
MODULES.BrainrotData = env.BrainrotData
MODULES.ProgressionData = env.ProgressionData
local reconcile = compile(src.reconcile, "=reconcile", "t", env)()
local function oldSave()
	return { SahurCoins = 1234, Brainrots = { "Tung" },
		Cosmetics = { owned = { GoldSahur = true, SharkChute = true }, gunSkin = "GoldSahur", aura = "RotAura", parachute = "SharkChute" } }
end
local loaded = reconcile(oldSave())
if loaded.Cosmetics.killAnimation ~= nil then fail("an old save loaded with a death effect") end
-- Additive only: everything the working branch loads is loaded the same, and anything new is empty
-- (a 0 count, false, or an empty table) -- e.g. a new crate tier's `DeathEffect = 0`.
local function sameOrAdded(base, now, path)
	if type(base) ~= "table" or type(now) ~= "table" then
		if base ~= now then return path end
		return nil
	end
	for key, value in pairs(base) do
		local why = sameOrAdded(value, now[key], path .. "." .. tostring(key))
		if why then return why end
	end
	for key, value in pairs(now) do
		if base[key] == nil and not (value == 0 or value == false or (type(value) == "table" and next(value) == nil)) then
			return path .. "." .. tostring(key) .. " (new and not empty)"
		end
	end
	return nil
end
if src.baseReconcile then
	local baseReconcile = compile(src.baseReconcile, "=baseReconcile", "t", env)()
	local why = sameOrAdded(baseReconcile(oldSave()), loaded, "save")
	if why then fail("an old save loads differently from the working branch at %s", why) end
end
local withField = oldSave()
withField.Cosmetics.killAnimation = anim
withField.Cosmetics.owned[anim] = true
if reconcile(withField).Cosmetics.killAnimation ~= anim then fail("a saved death effect didn't load") end
if not src.statesync:find("killAnimation = data.Cosmetics.killAnimation", 1, true) then fail("StateSync doesn't send killAnimation") end
if not src.bootstrap:find('MatchService.OnKillCredited = require(Modules:WaitForChild("KillAnimService")).Chain(MatchService.OnKillCredited)', 1, true) then
	fail("Bootstrap doesn't chain KillAnimService onto OnKillCredited")
end

--------------------------------------------------------------------------------
-- 4. ShopRotation: 2000 rotations against the working branch's
--------------------------------------------------------------------------------

local ShopRotation = loadModule(src.rotation, "ShopRotation")
local BaseRotation, baseCrates
if src.baseRotation and src.baseCrate then
	local current = MODULES.CrateData
	MODULES.CrateData = loadModule(src.baseCrate, "BaseCrateData")
	baseCrates = MODULES.CrateData
	BaseRotation = loadModule(src.baseRotation, "BaseRotation")
	MODULES.CrateData = current
end
if (ShopRotation.KillAnimationSlots or 0) ~= 4 then fail("ShopRotation.KillAnimationSlots is %s, want 4", tostring(ShopRotation.KillAnimationSlots)) end
local seen, mismatches, crateMismatches, badCounts, crateOnlyOnSale, deathCrateSeen = {}, 0, 0, 0, 0, 0
for window = 1, 2000 do
	local at = window * ShopRotation.RotationSeconds + 1
	local onSale = 0
	for id, item in pairs(CosmeticData.Items) do
		local inStock = ShopRotation.IsCosmeticInStock(id, at)
		if item.kind == "KillAnimation" then
			if inStock then
				onSale = onSale + 1
				seen[id] = true
				if item.crateOnly then crateOnlyOnSale = crateOnlyOnSale + 1 end
			end
		elseif BaseRotation and inStock ~= BaseRotation.IsCosmeticInStock(id, at) then
			mismatches = mismatches + 1
		end
	end
	if BaseRotation then
		for _, tier in ipairs(baseCrates.Order) do
			if ShopRotation.IsCrateInStock(tier, at) ~= BaseRotation.IsCrateInStock(tier, at) then crateMismatches = crateMismatches + 1 end
		end
	end
	if ShopRotation.IsCrateInStock("DeathEffect", at) then deathCrateSeen = deathCrateSeen + 1 end
	if onSale ~= (ShopRotation.KillAnimationSlots or 0) or onSale == 0 then badCounts = badCounts + 1 end
end
if mismatches > 0 then fail("%d other-kind stock slots differ from the working branch's rotation", mismatches) end
if crateMismatches > 0 then fail("%d crate stock rolls differ from the working branch's for crates it already had", crateMismatches) end
if badCounts > 0 then fail("%d rotations didn't have exactly KillAnimationSlots death effects on sale", badCounts) end
if crateOnlyOnSale > 0 then fail("a crate-exclusive death effect was on sale %d times", crateOnlyOnSale) end
for _, id in ipairs(killIds) do
	if not CosmeticData.Get(id).crateOnly and not seen[id] then fail("%s never came up in 2000 rotations", id) end
end
if deathCrateSeen == 0 or deathCrateSeen == 2000 then fail("the Death Effect Crate was in stock %d of 2000 rotations", deathCrateSeen) end
note("rotation: 2000 windows, %d other-kind and %d crate mismatches vs the working branch, Death Effect Crate in stock %d", mismatches, crateMismatches, deathCrateSeen)

--------------------------------------------------------------------------------
-- 5. KillAnimService (with DeathFxService.Claim stood in), 6. DeathFxService.Claim (real)
--------------------------------------------------------------------------------

local fired = {}
local playersProfile = {}
local claims, claimAnswer = {}, true
local function player(name) return { __instance = true, Name = name, __type = "Instance" } end
MODULES.Remotes = { Event = function() return {
	FireAllClients = function(_, data) table.insert(fired, data) end,
	FireClient = function() end,
	OnClientEvent = { Connect = function() end },
} end }
MODULES.Combatants = {
	IsPlayer = function(t) return type(t) == "table" and rawget(t, "__instance") == true end,
	GetRoot = function(t) return t.root end,
	GetCharacter = function(t) return t.character end,
}
MODULES.PlayerData = { Get = function(p) return playersProfile[p] end }
MODULES.DeathFxService = { Claim = function(character, seconds)
	table.insert(claims, { character = character, seconds = seconds })
	return claimAnswer
end }
local Service = loadModule(src.service, "KillAnimService")
local killer = player("Killer")
local victimBody = M.new("Model")
local victim = { isBot = true, root = { Position = V(10, 5, 3) }, character = victimBody }
playersProfile[killer] = { Cosmetics = { owned = { [anim] = true }, killAnimation = anim } }
Service.Play(killer, victim)
if #fired ~= 1 or fired[1].id ~= anim or fired[1].position.Y ~= 5 then fail("an owned, equipped death effect wasn't sent to clients") end
if not (fired[1] and fired[1].body == victimBody) then fail("a claimed body wasn't sent with the effect") end
if not (claims[1] and claims[1].seconds > Designs.Get(anim).life) then fail("the body was claimed for %s s, not past the effect's %.1f s life", tostring(claims[1] and claims[1].seconds), Designs.Get(anim).life) end
fired, claimAnswer = {}, false
Service.Play(killer, victim)
if #fired ~= 1 or fired[1].body ~= nil then fail("a body DeathFxService refused was still sent to be moved") end
fired, claimAnswer = {}, true
playersProfile[killer].Cosmetics.owned[anim] = nil
Service.Play(killer, victim)
if #fired > 0 then fail("an unowned death effect played") end
playersProfile[killer].Cosmetics = { owned = { GoldSahur = true }, killAnimation = "GoldSahur" }
Service.Play(killer, victim)
if #fired > 0 then fail("a gun skin in the killAnimation slot played") end
Service.Play({ isBot = true }, victim)
if #fired > 0 then fail("a bot's kill played a death effect") end
local passed
local chained = Service.Chain(function(k, v, w) passed = { k, v, w } end)
playersProfile[killer] = { Cosmetics = { owned = { [anim] = true }, killAnimation = anim } }
chained(killer, { root = false, character = false }, "Pistol")
if not passed or passed[1] ~= killer or passed[3] ~= "Pistol" then fail("Chain didn't pass the kill on to the previous hook") end
passed = nil
MODULES.Combatants.GetRoot = function() error("boom") end
if not pcall(chained, killer, victim, "Pistol") or not passed then fail("an error in KillAnimService stopped the previous hook") end

-- The real DeathFxService.
local function ragdollBody(effect)
	local body = M.new("Model")
	body.Parent = workspace
	for _, name in ipairs({ "HumanoidRootPart", "UpperTorso", "LowerTorso", "Head", "LeftUpperArm" }) do
		local part = M.new("Part")
		part.Name = name
		part.CFrame = M.CFrame.new(0, 3, 0)
		part.Parent = body
	end
	local humanoid = M.new("Humanoid")
	humanoid.Parent = body
	if effect then body:SetAttribute("DeathFx", effect) end
	return body
end
fired = {}
MODULES.Combatants = { GetCharacter = function(t) return t end, GetRoot = function() return nil end }
local DeathFxService = loadModule(src.deathservice, "DeathFxService")
M.resetClock()
local claimed = ragdollBody("ragdoll")
if not DeathFxService.Claim(claimed, 2) then fail("Claim refused a plain ragdoll") end
local anchoredAll = true
for _, part in ipairs(claimed:GetDescendants()) do
	if part:IsA("BasePart") and not (part.Anchored and part.CanCollide == false and part.CanQuery == false) then anchoredAll = false end
end
if not anchoredAll then fail("a claimed body wasn't anchored and made untouchable") end
if DeathFxService.Claim(claimed, 2) then fail("a body was claimed twice") end
if DeathFxService.Claim(ragdollBody("burn"), 2) then fail("a body a gun's own effect has (burn) was claimed") end
local gone = ragdollBody("ragdoll")
gone.Parent = nil
if DeathFxService.Claim(gone, 2) then fail("a body no longer in the world was claimed") end
M.runTo(2.05)
local hidden = true
for _, part in ipairs(claimed:GetDescendants()) do
	if part:IsA("BasePart") and part.Transparency < 1 then hidden = false end
end
if not hidden then fail("a claimed body wasn't hidden once its time was up") end
M.resetClock()
local applied = ragdollBody(nil)
DeathFxService.Apply(applied, "ragdoll", V(0, 10, 0))
local payload = fired[#fired]
if not (payload and payload.kind == "ragdoll" and payload.body == applied and type(payload.linger) == "number") then
	fail("DeathFxService.Apply didn't send the body and its linger with a ragdoll")
end

--------------------------------------------------------------------------------
-- 7. The engine, every design, and KillAnimFxClient, on the stand-in clock
--------------------------------------------------------------------------------

local EPS = 1e-6
local FRAME = 1 / 60
local TEXTURES = {}
for _, path in pairs(Fx.Textures) do TEXTURES[path] = true end
for path in pairs(TEXTURES) do
	if not path:match("^rbxasset://textures/") then fail("texture %s isn't a built-in rbxasset", path) end
end
for name, ease in pairs(Fx.Ease) do
	if math.abs(ease(0)) > 1e-9 or math.abs(ease(1) - 1) > 1e-9 then fail("easing %s doesn't run 0 to 1 (%s, %s)", name, tostring(ease(0)), tostring(ease(1))) end
end
if Fx.MAX_LIFETIME > 3.2 + EPS or Fx.MAX_PARTS > 32 or Fx.MAX_PARTICLES > 64 or Fx.MAX_LIGHTS > 2 then
	fail("caps raised past the stated 32 parts / 64 particles / 2 lights / 3.2 s")
end

-- Every cosmetic has a design, every design a cosmetic.
for _, id in ipairs(killIds) do
	if not Designs.Get(id) then fail("%s has no design in DeathEffectDesigns", id) end
end
for _, id in ipairs(Designs.Ids()) do
	local item = CosmeticData.Get(id)
	if not item or item.kind ~= "KillAnimation" then fail("design %s has no death effect cosmetic", id) end
end

local function partsIn(model)
	local out = {}
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then table.insert(out, inst) end
	end
	return out
end
local function snapshot(parts)
	local out = {}
	for index, part in ipairs(parts) do
		local c = part.CFrame
		out[index] = { c.p.X, c.p.Y, c.p.Z, c.r[1], c.r[2], c.r[3], c.r[4], c.r[5], c.r[6], c.r[7], c.r[8], c.r[9],
			part.Size.X, part.Size.Y, part.Size.Z, part.Transparency, part.Color.R, part.Color.G, part.Color.B, part.Material.Name }
	end
	return out
end
local function differs(a, b, tolerance)
	if #a ~= #b then return "count " .. #a .. " vs " .. #b end
	for index = 1, #a do
		for field = 1, #a[index] do
			local x, y = a[index][field], b[index][field]
			if type(x) == "number" then
				if math.abs(x - y) > (tolerance or 1e-4) then return string.format("part %d field %d: %.5f vs %.5f", index, field, x, y) end
			elseif x ~= y then
				return string.format("part %d field %d: %s vs %s", index, field, tostring(x), tostring(y))
			end
		end
	end
	return nil
end
local function createdSince(mark, class)
	local out = {}
	for index = mark + 1, #M.log.created do
		local entry = M.log.created[index]
		if not class or entry.class == class then table.insert(out, entry.obj) end
	end
	return out
end

-- 7a. Preview mode through the engine, the way CosmeticPreview builds it: a dummy at the origin.
local function previewScene(id, seed)
	local dummy = Fx.Dummy()
	dummy.Parent = workspace
	local design = Designs.Get(id)
	local fx = Fx.new({ parent = workspace, origin = Fx.DummyRoot, ground = V(0, 0, 0), life = design.life, body = dummy,
		ownsBody = true, preview = true, seed = seed or 7 })
	design.build(fx)
	return fx, dummy, design
end

for _, id in ipairs(killIds) do
	local design = Designs.Get(id)
	if design then
		-- Shape of the design.
		if not (design.life > 0 and design.life <= Fx.MAX_LIFETIME + EPS) then fail("%s lives %s s, cap %.1f", id, tostring(design.life), Fx.MAX_LIFETIME) end
		if not (design.peak and design.peak > 0 and design.peak < design.life) then fail("%s's peak isn't inside its life", id) end
		local moments = design.moments or {}
		if #moments ~= 3 or not (moments[1] < moments[2] and moments[2] < moments[3] and moments[3] < design.life) then
			fail("%s needs three increasing moments inside its life", id)
		end
		if not (design.view and design.view.focus and design.view.radius) then fail("%s has no preview view", id) end

		-- Preview: stepped a frame at a time to the end.
		local mark = #M.log.created
		local fx, dummy = previewScene(id)
		local before = snapshot(partsIn(dummy))
		local t = 0
		while t < design.life - EPS do
			fx:step(t)
			t = t + FRAME
		end
		fx:step(design.life)
		for _, class in ipairs({ "ParticleEmitter", "PointLight", "Highlight" }) do
			if #createdSince(mark, class) > 0 then fail("%s's preview made a %s (a ViewportFrame draws none)", id, class) end
		end
		local made = #createdSince(mark, "Part") - #before
		if fx.sparkCount > Fx.MAX_SPARKS then fail("%s's preview made %d sparks, cap %d", id, fx.sparkCount, Fx.MAX_SPARKS) end
		if made ~= fx.parts + fx.sparkCount then fail("%s's preview made %d parts the budget didn't count (%d + %d sparks)", id, made, fx.parts, fx.sparkCount) end
		for _, track in ipairs(fx.tracks) do
			if track.t1 > design.life + EPS then fail("%s has a tween running to %.2f s, past its %.2f s life", id, track.t1, design.life); break end
		end
		for _, event in ipairs(fx.events) do
			if event.t > design.life + EPS then fail("%s has a moment at %.2f s, past its life", id, event.t); break end
		end
		local bodyAtEnd = partsIn(dummy)
		local visible = 0
		for _, part in ipairs(bodyAtEnd) do
			if part.Transparency < 0.99 then visible = visible + 1 end
		end
		if visible > 0 then fail("%s leaves %d body parts visible at its end", id, visible) end
		fx:destroy()
		local restored = differs(before, snapshot(partsIn(dummy)), 1e-9)
		if restored then fail("%s's preview didn't put the stand-in body back (%s)", id, restored) end
		dummy:Destroy()

		-- Stills are real frames: jumping straight to a moment gives what sixty frames a second gave.
		local checkAt = { moments[1], moments[2], moments[3], design.peak }
		for _, moment in ipairs(checkAt) do
			local fxA, dummyA = previewScene(id, 11)
			local tt = 0
			while tt < moment - EPS do
				fxA:step(tt)
				tt = tt + FRAME
			end
			fxA:step(moment)
			local a = snapshot(partsIn(dummyA))
			for _, part in ipairs(snapshot(partsIn(fxA.folder))) do table.insert(a, part) end
			local fxB, dummyB = previewScene(id, 11)
			fxB:step(moment)
			local b = snapshot(partsIn(dummyB))
			for _, part in ipairs(snapshot(partsIn(fxB.folder))) do table.insert(b, part) end
			local why = differs(a, b, 1e-4)
			if why then fail("%s: a still at %.2f s isn't the frame the game shows then (%s)", id, moment, why) end
			fxA:destroy(); fxB:destroy(); dummyA:Destroy(); dummyB:Destroy()
		end

		-- Geometry only ever goes to anchored body parts.
		local loose = Fx.Dummy()
		loose.Parent = workspace
		for _, part in ipairs(partsIn(loose)) do part.Anchored = false end
		local writeMark = #M.log.writes
		local fxL = Fx.new({ parent = workspace, origin = Fx.DummyRoot, ground = V(0, 0, 0), life = design.life, body = loose, ownsBody = true, seed = 3 })
		design.build(fxL)
		fxL:step(design.life)
		local looseParts = {}
		for _, part in ipairs(partsIn(loose)) do looseParts[part] = true end
		for index = writeMark + 1, #M.log.writes do
			local w = M.log.writes[index]
			if looseParts[w.obj] and (w.key == "CFrame" or w.key == "Size") then fail("%s moved an unanchored body part (%s)", id, w.key); break end
		end
		fxL:destroy()
		loose:Destroy()
	end
end

-- 7b. The world, through the real KillAnimFxClient.
local handler
local played = {}
MODULES.Remotes = { Event = function() return { OnClientEvent = { Connect = function(_, fn) handler = fn end } } end }
MODULES.Sfx = { PlayAt = function(cue, at, jitter) table.insert(played, { cue = cue, at = M.now }) end, Play = function() end }
local clientSrc = src.client
local clientCaps = {}
for name in ("MAX_LIVE CULL_DISTANCE"):gmatch("%S+") do
	clientCaps[name] = tonumber(clientSrc:match("local " .. name .. " = ([%d%.]+)"))
	if not clientCaps[name] then fail("KillAnimFxClient has no %s", name) end
end
-- A design that asks for far more than it may have. The caps have to stop it.
-- Its bursts and lights come first (each needs an anchor part), so every cap is reached on its own.
Designs.__Greedy = { life = 1, peak = 0.5, moments = { 0.1, 0.5, 0.9 }, view = {}, cues = {}, build = function(fx)
	fx:burst(0, fx.origin, { count = 500 })
	fx:burst(0.05, fx.origin, { count = 500 })
	for _ = 1, 6 do fx:light(0, 0.5, fx.origin, M.color(1, 1, 1), 10, 5) end
	fx:at(0.1, function()
		for _ = 1, 100 do fx:part(V(1, 1, 1), M.CFrame.new(fx.origin), nil) end
	end)
end }
M.resetClock()
loadModule(clientSrc, "KillAnimFxClient")
if not handler then fail("KillAnimFxClient never connected to KillAnimFx") end

local POSITION = V(5, 3.2, 5)
local function worldBody()
	local body = Fx.Dummy(M.CFrame.new(5, 0, 5))
	body.Parent = workspace
	return body
end
local function folders(mark)
	local out = {}
	for _, obj in ipairs(createdSince(mark, "Folder")) do
		if obj.Name == "KillAnimFx" then table.insert(out, obj) end
	end
	return out
end

for _, id in ipairs(killIds) do
	local design = Designs.Get(id)
	if design and handler then
		M.resetClock()
		played = {}
		local body = worldBody()
		local bodyParts = {}
		for _, part in ipairs(partsIn(body)) do bodyParts[part] = true end
		local mark, writeMark, emitMark = #M.log.created, #M.log.writes, #M.log.emits
		-- Sampled every frame, ahead of the client's own step: when the body first LOOKS different.
		local initial = snapshot(partsIn(body))
		local changedAt = math.huge
		local sampler = M.Heartbeat:Connect(function()
			if changedAt == math.huge and differs(initial, snapshot(partsIn(body)), 1e-3) then
				changedAt = M.now
			end
		end)
		handler({ id = id, position = POSITION, body = body })
		M.runTo(design.life + 0.5)
		sampler:Disconnect()
		local parts = #createdSince(mark, "Part")
		local lights = #createdSince(mark, "PointLight")
		local particles, lastParticle = 0, 0
		for index = emitMark + 1, #M.log.emits do
			local emit = M.log.emits[index]
			particles = particles + emit.count
			lastParticle = math.max(lastParticle, emit.at + emit.obj.Lifetime.Max)
			if not TEXTURES[emit.obj.Texture] then fail("%s uses texture %s, not one of the built-ins", id, tostring(emit.obj.Texture)) end
		end
		local firstTouch, lastWrite = changedAt, 0
		for index = writeMark + 1, #M.log.writes do
			local w = M.log.writes[index]
			lastWrite = math.max(lastWrite, w.at)
			if w.destroyed then fail("%s still wrote %s after its folder was destroyed", id, w.key); break end
		end
		note("%-19s %2d parts %2d particles %d lights %d sounds, body changes at %.2f s, done by %.2f s of %.1f", id, parts, particles, lights, #played,
			firstTouch, math.max(lastWrite, lastParticle), design.life)
		if parts > Fx.MAX_PARTS then fail("%s made %d parts, cap %d", id, parts, Fx.MAX_PARTS) end
		if particles > Fx.MAX_PARTICLES then fail("%s emitted %d particles, cap %d", id, particles, Fx.MAX_PARTICLES) end
		if lights > Fx.MAX_LIGHTS then fail("%s made %d lights, cap %d", id, lights, Fx.MAX_LIGHTS) end
		if lights < 1 then fail("%s has no light flash", id) end
		if particles < 1 then fail("%s emits no particles", id) end
		if lastParticle > design.life + EPS then fail("%s has particles alive at %.2f s, after its folder goes at %.2f", id, lastParticle, design.life) end
		if lastWrite > design.life + FRAME + EPS then fail("%s was still animating at %.2f s, after its %.2f s life", id, lastWrite, design.life) end
		if firstTouch > design.peak + 0.05 then fail("%s doesn't change the body until %.2f s, after its burst at %.2f", id, firstTouch, design.peak) end
		for _, part in ipairs(partsIn(body)) do
			if part.Transparency < 0.99 then fail("%s left the body visible at the end", id); break end
		end
		local made = folders(mark)
		if #made ~= 1 or not rawget(made[1], "__destroyed") then fail("%s's folder wasn't made once and destroyed", id) end
		if #played == 0 then fail("%s plays no sound", id) end
		local listed = {}
		for _, cue in ipairs(design.cues or {}) do
			listed[cue] = true
			if not SoundConfig.Sounds[cue] then fail("%s lists cue %s, which SoundConfig doesn't have", id, cue) end
		end
		local heard = {}
		for _, entry in ipairs(played) do
			heard[entry.cue] = true
			if not SoundConfig.Sounds[entry.cue] then fail("%s plays cue %s, which SoundConfig doesn't have", id, entry.cue) end
			if not listed[entry.cue] then fail("%s plays %s without listing it in cues", id, entry.cue) end
		end
		for cue in pairs(listed) do
			if not heard[cue] then fail("%s lists %s in cues but never plays it", id, cue) end
		end
		if M.heartbeatCount() ~= 0 then fail("%s left the Heartbeat connected with nothing running", id) end
		body:Destroy()

		-- With no body (a gun's own effect has it): it still plays, and touches nothing it wasn't given.
		M.resetClock()
		local markNo = #M.log.created
		handler({ id = id, position = POSITION })
		M.runTo(design.life + 0.2)
		if #createdSince(markNo, "Part") == 0 then fail("%s built nothing without a body", id) end
	end
end

-- Caps against a greedy design, MAX_LIVE, culling, junk.
M.resetClock()
local mark = #M.log.created
local emitMark = #M.log.emits
handler({ id = "__Greedy", position = POSITION })
M.runTo(1.5)
local greedyParticles = 0
for index = emitMark + 1, #M.log.emits do greedyParticles = greedyParticles + M.log.emits[index].count end
if #createdSince(mark, "Part") > Fx.MAX_PARTS then fail("a greedy design got %d parts past the cap of %d", #createdSince(mark, "Part"), Fx.MAX_PARTS) end
if greedyParticles > Fx.MAX_PARTICLES then fail("a greedy design got %d particles past the cap of %d", greedyParticles, Fx.MAX_PARTICLES) end
if #createdSince(mark, "PointLight") > Fx.MAX_LIGHTS then fail("a greedy design got %d lights past the cap", #createdSince(mark, "PointLight")) end

M.resetClock()
mark = #M.log.created
local bodies = {}
for index = 1, clientCaps.MAX_LIVE + 3 do
	bodies[index] = worldBody()
	handler({ id = killIds[1], position = POSITION, body = bodies[index] })
end
local builtFolders = 0
local partsBy = {}
for _, part in ipairs(createdSince(mark, "Part")) do
	if part.Parent and part.Parent.Name == "KillAnimFx" then partsBy[part.Parent] = true end
end
for _ in pairs(partsBy) do builtFolders = builtFolders + 1 end
if builtFolders ~= clientCaps.MAX_LIVE then fail("%d effects built at once, cap %d", builtFolders, clientCaps.MAX_LIVE) end
M.runTo(0.6)
for index = clientCaps.MAX_LIVE + 1, #bodies do
	for _, part in ipairs(partsIn(bodies[index])) do
		if part.Transparency < 0.99 then fail("a claimed body skipped over MAX_LIVE wasn't faded"); break end
	end
end
M.runTo(5)
mark = #M.log.created
handler({ id = killIds[1], position = POSITION })
if #createdSince(mark, "Part") == 0 then fail("the live count didn't come back down after the effects ended") end
M.runTo(10)
if M.heartbeatCount() ~= 0 then fail("the Heartbeat stayed connected after everything ended") end

M.resetClock()
local farBody = worldBody()
mark = #M.log.created
-- The camera is at (0, 10, 0): this one is well past CULL_DISTANCE.
handler({ id = killIds[1], position = V(clientCaps.CULL_DISTANCE + 100, 3, 0), body = farBody })
handler({ id = "NoSuchEffect", position = POSITION })
handler({ id = killIds[1], position = "nowhere" })
if #createdSince(mark, "Part") > 0 then fail("a far, unknown or malformed effect built %d parts", #createdSince(mark, "Part")) end
M.runTo(0.6)
for _, part in ipairs(partsIn(farBody)) do
	if part.Transparency < 0.99 then fail("a claimed body too far to build the effect for wasn't faded"); break end
end
M.runTo(2)

-- 7c. The plain death's dressing, through the real DeathFxClient.
local dressHandler
MODULES.Remotes = { Event = function() return { OnClientEvent = { Connect = function(_, fn) dressHandler = fn end } } end }
M.resetClock()
loadModule(src.deathclient, "DeathFxClient")
if not dressHandler then
	fail("DeathFxClient never connected to DeathFx")
else
	local ragdoll = worldBody()
	for _, part in ipairs(partsIn(ragdoll)) do part.Anchored = false end
	local ragdollParts = {}
	for _, part in ipairs(partsIn(ragdoll)) do ragdollParts[part] = true end
	mark = #M.log.created
	local writeMark = #M.log.writes
	dressHandler({ kind = "ragdoll", position = POSITION, body = ragdoll, linger = 4 })
	M.runTo(6.5)
	local highlights = createdSince(mark, "Highlight")
	if #highlights ~= 1 or highlights[1].Adornee ~= ragdoll then fail("the plain death's hit flash isn't one Highlight on the body") end
	local poofAt
	for index = mark + 1, #M.log.created do
		local entry = M.log.created[index]
		if entry.class == "Folder" and entry.obj.Name == "DeathFxDressing" and entry.at > 1 then poofAt = entry.at end
		if entry.class == "Folder" and entry.obj.Name == "DeathFxDressing" and not rawget(entry.obj, "__destroyed") then fail("a dressing folder was never destroyed") end
	end
	if not poofAt or math.abs(poofAt - 4) > 0.05 then fail("the fade puff didn't come when the ragdoll starts to fade (%s)", tostring(poofAt)) end
	for index = writeMark + 1, #M.log.writes do
		local w = M.log.writes[index]
		if ragdollParts[w.obj] then fail("the plain death's dressing wrote %s on the ragdoll (the server's physics owns it)", w.key); break end
	end
	if #createdSince(mark, "Part") > 2 * Fx.MAX_PARTS then fail("the dressing made too many parts") end
	if M.heartbeatCount() ~= 0 then fail("DeathFxClient left the Heartbeat connected") end
	-- Claimed a moment later by a death effect: no dressing at all.
	M.resetClock()
	local taken = worldBody()
	mark = #M.log.created
	dressHandler({ kind = "ragdoll", position = POSITION, body = taken, linger = 4 })
	taken:SetAttribute("DeathFxClaimed", true)
	M.runTo(6)
	if #createdSince(mark, "Part") > 0 or #createdSince(mark, "Highlight") > 0 then fail("a body a death effect claimed still got the plain death's dressing") end
	-- A grenade's worth: capped.
	M.resetClock()
	mark = #M.log.created
	for _ = 1, 10 do
		dressHandler({ kind = "ragdoll", position = POSITION, body = worldBody(), linger = 4 })
	end
	M.runTo(0.3)
	local dressed = 0
	for _, obj in ipairs(createdSince(mark, "Folder")) do
		if obj.Name == "DeathFxDressing" then dressed = dressed + 1 end
	end
	local cap = tonumber(src.deathclient:match("local MAX_DRESSED = (%d+)"))
	if not cap or dressed > cap then fail("%d dressings at once, cap %s", dressed, tostring(cap)) end
	M.runTo(8)
end

return { fails = fails, report = report }
