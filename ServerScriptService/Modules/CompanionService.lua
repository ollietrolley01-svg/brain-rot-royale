-- Brainrot companions: equip one from your collection and it follows you everywhere — around
-- the lobby, and into matches, where it fights for you.
--
-- Its move (BrainrotData.Attacks) fires when you press the companion hotkey, aimed at the enemy
-- nearest your crosshair within its range. Rarity sets the damage, cooldown and range. Damage
-- goes through CombatService.DealDamage with the owner as the attacker, so a companion kill
-- credits its owner exactly like a gun kill. Visuals are drawn by CompanionFxClient from one
-- broadcast per attack. Bots' companions use their move on their own whenever it's ready.
--
-- On top of its move, most brainrots have a style (BrainrotData.AbilityStyles, resolved into the
-- stats): a slow, a daze, a burn or poison, a heal for the owner, a wider splash, a quicker recharge,
-- longer reach or an extra fork. Styles land only on a hit that did damage (applyStyle).
--
-- Companions can be shot. One that runs out of health is downed for the rest of the match and
-- comes back when the match ends, ready for the next one.
--
-- Movement is physics: an AlignPosition pulls the creature toward a point beside its owner's
-- shoulder, and the owner's client simulates it, so it trails smoothly with no per-frame
-- server writes.
--
-- Every move has a short windup (CompanionAnimations.Windup) before it connects: the creature is
-- built as a rig, every client animates the strike (a leap, a spin, a stomp...), and the damage
-- here is delayed by the same windup so it lands as the animation does. Aimed moves lead a moving
-- target by the windup, so the extra beat costs no accuracy. Damage that lands is reported once
-- per attack (CompanionHit), for the impact effects.
--
-- Every broadcast goes out LAST, after the state it announces, through one pcall'd helper: a
-- remote fired at a player on their way out can throw, and a lethal hit whose confirm threw used
-- to leave a 0-HP companion fighting all match, unkillable (COORDINATION "Announce LAST", the
-- ProgressionService rank-up lesson). Splashes and a Chain's fork need line of sight; a move used
-- with nobody in reach still hurts whatever is where it lands; and every move lands on the lobby's
-- practice dummies.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local CompanionBoons = require(script.Parent:WaitForChild("CompanionBoons"))

local CompanionService = {}

local SCALE = 0.55
-- Left of, above and behind the owner. Characters face -Z, so +Z is behind. Was the character's
-- RIGHT (2.8, 2.6, 2.4) -- Oliver's #67, "move the companion to the characters left side so it
-- doesn't block the third person view": the right side is where the over-the-shoulder camera's own
-- pivot sits (CombatClient.client.lua's SHOULDER_HEIGHT=1.7 / SHOULDER_SIDE=1.9, guns-owned, read
-- only), so the companion was floating almost on top of the camera itself. Measured before/after in
-- tools/companion_offset_probe.lua and rendered in tools/companion_offset_gallery.lua (and the
-- merged tools/orphan3_render_gallery.lua): the fix moves it clear of the character's silhouette in
-- the real third-person camera and does not overlap the bottom-left HUD panels. The only use site
-- (grepped) is `anchor.Position` below and the `cframe` this function builds the model at; every
-- attack/ability origin elsewhere in this file reads the companion's LIVE position dynamically
-- (`entry.root.Position`), so nothing else needed to change for this.
local FOLLOW_OFFSET = Vector3.new(-2.8, 2.6, 2.4)
local THINK_INTERVAL = 0.2
-- Further than this from its anchor means the owner teleported; snap rather than fly across the map.
local TELEPORT_DISTANCE = 80
local SPIT_SPEED = 90
local LOB_TIME = 0.7
local BONK_TIME = 0.35
local CHAIN_RADIUS = 22
-- How far off the crosshair (degrees) an enemy can be and still be picked by the hotkey.
local AIM_ASSIST_ANGLE = 22
local WINDUP = CompanionAnimations.Windup
-- Hit positions sent per attack at most; a splash into a crowd reports the first few.
local MAX_HIT_MARKS = 4
-- Target speeds above this are a teleport or a launch, not something to lead.
local MAX_LEAD_SPEED = 60

-- The cooldown clock. os.clock() is process CPU time in Roblox, not wall time (COORDINATION
-- "Instruments that lie"), so on a mostly idle server a 3 s cooldown measured with it ran longer than
-- 3 s -- the HUD showed the move ready while the server still refused it. Server time is wall time,
-- and is the clock a client reads back if a cooldown is ever shown from it.
local function clockNow()
	return workspace:GetServerTimeNow()
end
-- A Lob leads its target through the windup AND its flight, but never by more than this: a runner
-- who turns around mid-flight shouldn't find the splash further off than they could have gone.
local LOB_MAX_LEAD = 14
local HEALTH_BAR_DISTANCE = 90
-- A Spit fired at a point (nobody in reach) hits anyone this close to where the glob lands; a Zap
-- or Chain fired at a point hits the first enemy whose root lies this close to the beam.
local SPIT_POINT_RADIUS = 2.5
local BEAM_HIT_RADIUS = 1.5

-- Set by Bootstrap: whether this combatant is alive in a live match. Companions only fight, and
-- can only be hurt, then.
CompanionService.IsFighting = function()
	return false
end

local companionAttack = Remotes.Event("CompanionAttack")
local companionDown = Remotes.Event("CompanionDown")
local companionHit = Remotes.Event("CompanionHit")

-- Every send in one place, in a pcall, and always AFTER the state it announces has been written.
-- A remote fired at a player on their way out can throw, and a throw here used to abort the rest
-- of the handler: a lethal hit whose ConfirmHit threw never reached down(), which left a 0-HP
-- companion fighting all match and unkillable (Damage returns 0 for a companion at 0 health).
-- COORDINATION "Announce LAST"; the same shape as the ProgressionService rank-up fix.
local function broadcast(remote, payload)
	local ok, err = pcall(remote.FireAllClients, remote, payload)
	if not ok then
		warn("[CompanionService] broadcast failed: " .. tostring(err))
	end
end

local function confirm(attackerToken, dealt, killed, position, hitShield)
	local ok, err = pcall(CombatService.ConfirmHit, attackerToken, dealt, killed, position, nil, hitShield)
	if not ok then
		warn("[CompanionService] hit confirm failed: " .. tostring(err))
	end
end

local folder = nil
local companions = {}
-- model -> owner token, for resolving a bullet that hit a companion.
local owners = {}
-- Owner tokens whose companion was downed this match.
local fallen = {}

-- owner token -> damage its companion has landed this match, for the results card.
local damageDealt = {}

local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = "Companions"
	folder.Parent = workspace
	return folder
end

-- The condition a companion was in when it last left the world: the fraction of its health it had,
-- and when it last used its ability. Kept per owner and OUTLIVES the creature, because unequipping
-- destroys the entry -- and off-then-on is precisely the shape of the exploit this exists to stop.
-- Cleared at the match's own boundaries (ResetStats, ReviveAll), which are allowed to heal, and when
-- the player leaves.
local lastCondition = {}

local function despawn(owner)
	-- Out of the tables FIRST, then everything that can throw. The boon's Clear reaches into the
	-- owner's humanoid and MatchService, and it used to run before the entry was removed: a Clear that
	-- threw inside down() left the companion in the table at 0 health, and a companion in the table
	-- can use its move -- the same 0-HP-fights-all-match bug by a second door.
	local entry = companions[owner]
	companions[owner] = nil
	if entry then
		owners[entry.model] = nil
	end
	if entry and entry.maxHealth and entry.maxHealth > 0 then
		lastCondition[owner] = { fraction = entry.health / entry.maxHealth, lastAttackAt = entry.lastAttackAt }
	end
	-- The boon goes with the companion, always, whatever took it away: unequipped, sold, downed,
	-- character gone, match over. Every one of those paths reaches here.
	local ok, err = pcall(CompanionBoons.Clear, owner)
	if not ok then
		warn("[CompanionService] boon clear failed: " .. tostring(err))
	end
	if entry then
		entry.model:Destroy()
		entry.anchor:Destroy()
	end
end

-- Whether a companion may use its move at all. A companion at 0 health is downed, and down() takes it
-- out of the table; this is the belt to that braces, checked at every door a move goes through (the
-- hotkey, the bots' loop, and a move whose windup is still running), so a 0-HP companion cannot fight
-- even if some future path leaves one behind.
local function canAct(entry)
	return entry ~= nil and type(entry.health) == "number" and entry.health > 0
end

local function setFallen(owner, value)
	fallen[owner] = value or nil
	if Combatants.IsPlayer(owner) then
		owner:SetAttribute("CompanionFallen", value == true)
	end
end

-- A small stud-sized bar over the creature, shown only while it can be hurt.
local function buildHealthBar(root, color)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromScale(2.6, 0.32)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
	gui.MaxDistance = HEALTH_BAR_DISTANCE
	gui.LightInfluence = 0
	gui.Enabled = false

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	back.BackgroundTransparency = 0.2
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = back

	for _, frame in ipairs({ back, fill }) do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame
	end

	gui.Parent = root
	return gui, fill
end

local function setHealth(entry, health)
	entry.health = math.clamp(health, 0, entry.maxHealth)
	entry.model:SetAttribute("Health", math.ceil(entry.health))
	entry.fill.Size = UDim2.fromScale(entry.health / entry.maxHealth, 1)
end

-- Level and merge stars from the owner's profile; 1 and 0 for a bot.
local function profileRank(owner, def)
	if typeof(owner) == "Instance" and owner:IsA("Player") then
		local ownerData = PlayerData.Get(owner)
		if ownerData then
			return BrainrotData.LevelForXp(ownerData.CompanionXp[def.name] or 0), BrainrotData.ClampStars(ownerData.Stars[def.name])
		end
	end
	return 1, 0
end

-- Builds the follower for any combatant — a player (whose client simulates it) or a bot
-- (the server does).
local function attachModel(owner, character, def, networkOwner)
	local ownerRoot = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not ownerRoot or not humanoid or humanoid.Health <= 0 then
		return
	end

	local anchor = Instance.new("Attachment")
	anchor.Name = "CompanionAnchor"
	anchor.Position = FOLLOW_OFFSET
	anchor.Parent = ownerRoot

	local glow = Rarity.IsAtLeast(def.rarity, "Epic") and Rarity.Color(def.rarity) or nil
	local model = BrainrotModels.Build(def, {
		scale = SCALE,
		anchored = false,
		rig = true,
		cframe = ownerRoot.CFrame * CFrame.new(FOLLOW_OFFSET),
		glow = glow,
	})
	-- Streamed in whole, so a client never animates a half-arrived rig.
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end)
	model.Name = Combatants.GetName(owner) .. "_Companion"
	if Combatants.IsPlayer(owner) then
		model:SetAttribute("OwnerUserId", owner.UserId)
	end
	local root = model.PrimaryPart

	-- BrainrotModels leaves its parts invisible to raycasts, which is right for statues and
	-- previews but meant bullets flew straight through companions. They have to be hittable.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = true
		end
	end

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Parent = root

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = rootAttachment
	alignPosition.Attachment1 = anchor
	alignPosition.MaxForce = 1e6
	alignPosition.Responsiveness = 14
	alignPosition.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.Attachment1 = anchor
	alignOrientation.MaxTorque = 1e6
	alignOrientation.Responsiveness = 12
	alignOrientation.Parent = root

	-- A player's companion fights at the level it has earned and the stars it has been merged
	-- to; bots' are level 1 and unmerged.
	local level, stars = profileRank(owner, def)
	local stats = BrainrotData.Stats(def, level, stars)
	local gui, fill = buildHealthBar(root, Rarity.Color(def.rarity))
	model:SetAttribute("MaxHealth", stats.health)
	model:SetAttribute("Level", level)
	model:SetAttribute("Stars", stars)

	-- A crown from level 5 — silver, then gold at the cap — so a levelled companion is
	-- recognisable at a glance. Welded to the root like the rest of the model.
	if level >= 5 then
		local metrics = BrainrotModels.Metrics(def)
		local modelScale = SCALE * (def.look and def.look.size or 1)
		local crownColor = level >= BrainrotData.MaxLevel and Color3.fromRGB(255, 200, 60) or Color3.fromRGB(214, 218, 230)
		local crownFrame = root.CFrame * CFrame.new(0, (metrics.top + 0.3) * modelScale, 0)
		-- Worn on the head, so it bobs and leaps with the rest of the creature.
		local crownAnchor = model:FindFirstChild("PivotHead") or model:FindFirstChild("PivotBody") or root
		local function crownPart(size, offset, shape)
			local piece = Instance.new("Part")
			if shape then
				piece.Shape = shape
			end
			piece.Name = "Crown"
			piece.Size = size * modelScale
			piece.CFrame = crownFrame * CFrame.new(offset.Position * modelScale) * offset.Rotation
			piece.Color = crownColor
			piece.Material = Enum.Material.Foil
			piece.Anchored = false
			piece.CanCollide = false
			piece.CanQuery = false
			piece.CanTouch = false
			piece.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = crownAnchor
			weld.Part1 = piece
			weld.Parent = piece
			piece.Parent = model
			return piece
		end
		crownPart(Vector3.new(0.16, 0.9, 0.9), CFrame.Angles(0, 0, math.pi / 2), Enum.PartType.Cylinder)
		for index = 0, 4 do
			local angle = index / 5 * math.pi * 2
			crownPart(Vector3.new(0.14, 0.32, 0.14), CFrame.new(math.cos(angle) * 0.38, 0.22, math.sin(angle) * 0.38))
		end
	end

	-- Not parented under the character: the first-person camera fades everything inside the
	-- character model, which would hide your own companion from you.
	model.Parent = ensureFolder()
	pcall(function()
		root:SetNetworkOwner(networkOwner)
	end)

	local entry = {
		model = model,
		root = root,
		anchor = anchor,
		def = def,
		stats = stats,
		-- Ready to use the moment it arrives.
		lastAttackAt = -math.huge,
		character = character,
		health = stats.health,
		maxHealth = stats.health,
		gui = gui,
		fill = fill,
	}
	companions[owner] = entry
	owners[model] = owner
	setHealth(entry, stats.health)

	humanoid.Died:Connect(function()
		local current = companions[owner]
		if current and current.character == character then
			despawn(owner)
		end
	end)
end

local function spawnFor(player, character)
	despawn(player)

	local data = PlayerData.Get(player)
	local name = data and data.Companion
	if not character or not name or fallen[player] then
		return
	end

	local def = BrainrotData.Get(name)
	if not def or not table.find(data.Brainrots, name) then
		-- Sold or traded away since it was equipped.
		data.Companion = nil
		return
	end

	attachModel(player, character, def, player)
	CompanionBoons.Apply(player, def)
end

-- Bots can bring a companion too. Cleaned up automatically when the bot's character goes:
-- the anchor lives on its root, and the think loop drops any entry whose anchor is gone.
function CompanionService.AttachBot(bot, def)
	despawn(bot)
	if bot.character and def and not fallen[bot] then
		attachModel(bot, bot.character, def, nil)
	end
end

--------------------------------------------------------------------------------
-- Taking damage
--------------------------------------------------------------------------------

local function down(owner, entry, killerToken)
	-- State first (fallen, then gone), the announcement last.
	local payload = {
		position = entry.root.Position,
		color = entry.stats.color,
		name = entry.def.name,
		owner = Combatants.IsPlayer(owner) and owner.UserId or nil,
		killer = killerToken and Combatants.GetName(killerToken) or nil,
		killerUserId = Combatants.IsPlayer(killerToken) and killerToken.UserId or nil,
	}
	setFallen(owner, true)
	despawn(owner)
	broadcast(companionDown, payload)
end

-- The companion model a part belongs to, if it's part of one.
function CompanionService.FromPart(part)
	if not folder or not part or not part:IsDescendantOf(folder) then
		return nil
	end
	local node = part
	while node and node.Parent ~= folder do
		node = node.Parent
	end
	return node
end

function CompanionService.OwnerOf(model)
	return owners[model]
end

function CompanionService.ModelOf(owner)
	local entry = companions[owner]
	return entry and entry.model or nil
end

-- Returns the damage actually dealt. Nobody can hurt their own companion, and companions are
-- untouchable outside a live match.
function CompanionService.Damage(attackerToken, model, amount)
	local owner = owners[model]
	local entry = owner and companions[owner]
	if not entry or type(amount) ~= "number" or amount <= 0 or entry.health <= 0 then
		return 0
	end
	if owner == attackerToken or not CombatService.IsEnabled() or not CompanionService.IsFighting(owner) then
		return 0
	end
	-- Team modes: a teammate's bullets, blasts and companion splash don't hurt your companion.
	if attackerToken ~= nil and CombatService.DamageVeto and CombatService.DamageVeto(attackerToken, owner) then
		return 0
	end

	local dealt = math.min(amount, entry.health)
	local at = entry.root.Position
	setHealth(entry, entry.health - amount)
	local killed = entry.health <= 0
	-- Downed BEFORE the hit is confirmed to the attacker: the confirm is a remote, and when it
	-- threw for an attacker on their way out, the companion below stayed at 0 health, alive.
	if killed then
		down(owner, entry, attackerToken)
	end
	confirm(attackerToken, dealt, killed, at)
	return dealt
end

-- Splash damage with linear falloff, for explosions and companion splash attacks.
function CompanionService.DamageInRadius(attackerToken, center, radius, amount)
	local hits = {}
	for owner, entry in pairs(companions) do
		if owner ~= attackerToken then
			local distance = (entry.root.Position - center).Magnitude
			if distance <= radius then
				table.insert(hits, { model = entry.model, amount = amount * (1 - distance / radius * 0.5) })
			end
		end
	end
	-- Applied after the scan: a downed companion is removed from the table mid-loop otherwise.
	for _, hit in ipairs(hits) do
		CompanionService.Damage(attackerToken, hit.model, hit.amount)
	end
end

--------------------------------------------------------------------------------
-- Fighting
--------------------------------------------------------------------------------

-- `alsoExclude` (optional) is a character the ray starts inside: the first target of a Chain,
-- whose own arms would otherwise stop every fork.
local function lineOfSight(from, targetCharacter, targetRoot, ownerCharacter, alsoExclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { ensureFolder(), ownerCharacter }
	if alsoExclude then
		table.insert(filter, alsoExclude)
	end
	local loot = workspace:FindFirstChild("Loot")
	if loot then
		table.insert(filter, loot)
	end
	params.FilterDescendantsInstances = filter
	-- Water is not cover: rays hit it by default, so a companion could not see a swimmer, or
	-- anyone from inside the shallows, because the ray stopped on the surface.
	params.IgnoreWater = true

	local result = workspace:Raycast(from, targetRoot.Position - from, params)
	return result == nil or result.Instance:IsDescendantOf(targetCharacter)
end

-- Team modes: a teammate is never a target (Oliver, 2026-09-23 14:49: team bots "hit eachother with
-- their buff companions"). ModeTeams is loaded on first use, not at the top, so no require cycle can form;
-- anything wrong with it fails open to today's behaviour.
local modeTeams
local function friendly(owner, token)
	if modeTeams == nil then
		local module = script.Parent:FindFirstChild("ModeTeams")
		local ok, result = false, nil
		if module then
			ok, result = pcall(require, module)
		end
		modeTeams = ok and type(result) == "table" and result or false
	end
	if not modeTeams or not modeTeams.IsHostile then
		return false
	end
	local ok, hostile = pcall(modeTeams.IsHostile, owner, token)
	return ok and hostile == false
end

-- The living enemy in range and in sight of the companion that sits nearest the owner's
-- crosshair, or, with no aim point (bots), simply the nearest one.
local function pickTarget(owner, entry, aimPoint)
	local from = entry.root.Position
	local ownerCharacter = Combatants.GetCharacter(owner)
	local head = ownerCharacter and ownerCharacter:FindFirstChild("Head")
	local eye = head and head.Position or from
	local aim = aimPoint and (aimPoint - eye).Magnitude > 0.5 and (aimPoint - eye).Unit or nil

	local bestToken, bestRoot, bestScore = nil, nil, math.huge
	for character, token in pairs(Combatants.All()) do
		if token ~= owner and character.Parent and not friendly(owner, token) then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local distance = (root.Position - from).Magnitude
				if distance <= entry.stats.range then
					local score = distance
					if aim then
						local toTarget = root.Position - eye
						local angle = toTarget.Magnitude > 0.1
							and math.deg(math.acos(math.clamp(aim:Dot(toTarget.Unit), -1, 1))) or 0
						score = angle <= AIM_ASSIST_ANGLE and angle + distance * 0.05 or math.huge
					end
					if score < bestScore and lineOfSight(from, character, root, entry.character) then
						bestToken, bestRoot, bestScore = token, root, score
					end
				end
			end
		end
	end

	return bestToken, bestRoot
end

-- `tag` ("Companion:<name>") is recorded as the weapon, so the kill feed can say which
-- brainrot landed the final hit.
-- Set by Bootstrap: (player, name, level, bonusPercent) when a companion levels up.
CompanionService.OnLevelUp = nil

-- Every point of damage a player's companion lands is a point of XP for that brainrot. A
-- level-up takes effect on the spot, not at the next spawn.
local function awardXp(player, dealt)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local entry = companions[player]
	local data = PlayerData.Get(player)
	if not entry or not data then
		return
	end
	local name = entry.def.name
	local before = BrainrotData.LevelForXp(data.CompanionXp[name] or 0)
	data.CompanionXp[name] = (data.CompanionXp[name] or 0) + dealt
	local after = BrainrotData.LevelForXp(data.CompanionXp[name])
	if after > before then
		entry.stats = BrainrotData.Stats(entry.def, after, data.Stars[name])
		entry.model:SetAttribute("Level", after)
		if CompanionService.OnLevelUp then
			-- A toast and a push: news, sent after the XP and stats are written, and never allowed
			-- to cost the rest of a splash its other victims.
			local ok, err = pcall(CompanionService.OnLevelUp, player, name, after, math.floor((BrainrotData.LevelBonus(after) - 1) * 100 + 0.5))
			if not ok then
				warn("[CompanionService] level-up notice failed: " .. tostring(err))
			end
		end
	end
end

-- MatchService owns walk speed (SetStatusSpeed), and requiring it at the top is a cycle (MatchService
-- requires BotService, which requires this). Resolved on first use, the way CompanionBoons reaches it.
local matchService
local function slowTarget(token, factor, duration)
	if matchService == nil then
		local ok, mod = pcall(require, script.Parent:WaitForChild("MatchService"))
		matchService = ok and type(mod) == "table" and mod or false
	end
	if matchService and matchService.SetStatusSpeed then
		local ok, err = pcall(matchService.SetStatusSpeed, token, "CompanionSlow", factor, duration)
		if not ok then
			warn("[CompanionService] slow failed: " .. tostring(err))
		end
	end
end

-- One use of a move takes at most BrainrotData.MaxUseDamage[rarity] off any one target, its hits and
-- the DoT it starts added together (Oliver: "make the companions other than Secret ones not one-shot").
-- The budget rides the use's `report`, which every hit of the use already shares. The cap is in
-- health as the victim loses it, so it is counted after CombatService.DealDamage's
-- CombatDamageScale: an amount handed to DealDamage (or to a DoT, which ticks through it) costs
-- `amount * scale` of the budget. A Secret has no cap and no budget.
local function useReport(entry)
	return { positions = {}, cap = BrainrotData.MaxUseDamage[entry.def.rarity], spent = {} }
end

-- The most of `amount` (a DealDamage amount, before the scale) the use may still put on `token`, and
-- books it against the budget. `amount` unchanged with no budget; 0 once the target's share is spent.
local function withinUse(report, token, amount)
	if not report or not report.cap then
		return amount
	end
	local scale = MatchConfig.CombatDamageScale or 1
	local left = math.max(0, report.cap - (report.spent[token] or 0))
	amount = math.min(amount, left / scale)
	report.spent[token] = (report.spent[token] or 0) + amount * scale
	return amount
end

-- What a move's style adds once a hit has landed `dealt` on `token` (BrainrotData.AbilityStyles):
-- a slow, a DoT, or a heal for the owner. Only ever after real damage, so a teammate the mode protects
-- (dealt 0) is never slowed or poisoned by a move that did not hurt them.
local function applyStyle(player, entry, token, dealt, tag, report)
	local stats = entry.stats
	if stats.slow and stats.slowTime and Combatants.IsAlive(token) then
		slowTarget(token, stats.slow, stats.slowTime)
	end
	-- Rides CompanionBoons' venom ticker: one slot per victim, refreshed rather than stacked, and a
	-- kill by the tick is credited to the owner as this brainrot. A venom-boon brainrot never carries a
	-- DoT style (the check refuses it), so the two never fight over the slot.
	-- The DoT is inside the use's cap: whatever of the budget the hit left is all it may add.
	if stats.dot and stats.dotTime and Combatants.IsAlive(token) then
		local damage = withinUse(report, token, dealt * stats.dot)
		if damage > 0 then
			CompanionBoons.StartVenom(player, token, { damage = damage, duration = stats.dotTime }, tag)
		end
	end
	if stats.leech then
		local character = Combatants.GetCharacter(player)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + dealt * stats.leech)
		end
	end
end

-- `report` (optional) collects where damage landed, for one CompanionHit broadcast per attack.
local function hit(player, token, amount, tag, report)
	if not Combatants.IsAlive(token) then
		return
	end
	amount = withinUse(report, token, amount)
	if amount <= 0 then
		return
	end
	local dealt = CombatService.DealDamage(player, token, amount, tag)
	if not dealt or dealt <= 0 then
		return
	end
	damageDealt[player] = (damageDealt[player] or 0) + dealt
	awardXp(player, dealt)
	if report then
		local root = Combatants.GetRoot(token)
		if root and #report.positions < MAX_HIT_MARKS then
			table.insert(report.positions, root.Position)
			-- Who it was, beside where: the client's style cue (a burn, a chill) clings to them for
			-- the status's length. `false`, never a hole, so the list survives the remote.
			report.victims = report.victims or {}
			report.victims[#report.positions] = Combatants.GetCharacter(token) or false
		end
		report.killed = report.killed or not Combatants.IsAlive(token)
	end
	local entry = companions[player]
	if not entry then
		return
	end
	-- Venom rides the hit rather than replacing it: the bite still does its damage, and the poison is
	-- what the boon adds. Refreshes on a second bite (CompanionBoons), it does not stack. Only on a hit
	-- that hurt: it used to start on a teammate the mode had just refused to damage.
	-- Inside the use's cap too, as the style's DoT is.
	local venom = CompanionBoons.VenomOf(entry.def)
	if venom then
		local damage = withinUse(report, token, venom.damage)
		if damage > 0 then
			CompanionBoons.StartVenom(player, token, { damage = damage, duration = venom.duration }, "Companion:" .. entry.def.name)
		end
	end
	applyStyle(player, entry, token, dealt, tag, report)
end

-- Where a splash is cast from: half a stud back toward where the move came from. A glob that
-- lands on a wall has its point ON the wall, and a ray never reports a part it starts inside
-- (COORDINATION "instruments that lie"), so a splash cast from the surface itself would reach
-- through the very wall it hit. A Shockwave has no "from" and casts from just above its body.
local function splashOrigin(center, from)
	if from and (from - center).Magnitude > 1 then
		return center + (from - center).Unit * 0.5
	end
	return center + Vector3.new(0, 0.5, 0)
end

-- How many splash victims a wall or floor has saved since the module loaded. Read by the probe so
-- a line-of-sight refusal is a number; nothing in the game reads or resets it.
CompanionService.SplashRefused = 0

-- Every enemy within `radius` of `center` that can be seen from there (except `except`, who took
-- the direct hit). Splashes used to reach through walls and floors -- 26-50 studs of it for a
-- Shockwave. Other companions in the radius take three quarters, as before.
local function splash(player, center, radius, amount, except, tag, report, from)
	local origin = splashOrigin(center, from)
	local ownerCharacter = Combatants.GetCharacter(player)
	for _, target in ipairs(CombatService.InRadius(center, radius, player)) do
		if target.token ~= except then
			local character = Combatants.GetCharacter(target.token)
			if character and lineOfSight(origin, character, target.root, ownerCharacter) then
				hit(player, target.token, amount, tag, report)
			else
				CompanionService.SplashRefused += 1
			end
		end
	end
	CompanionService.DamageInRadius(player, center, radius, amount * 0.75)
end

-- The enemy a Chain forks on to: the nearest other enemy within CHAIN_RADIUS of the first that
-- the first can see (the fork used to land through walls) and that the mode lets the owner hurt
-- (a beam drawn to a teammate who then took 0 was the tell).
local function chainTarget(player, token, targetRoot, tag, exclude)
	local at = targetRoot.Position
	local targetCharacter = Combatants.GetCharacter(token)
	local ownerCharacter = Combatants.GetCharacter(player)
	local best, bestDistance = nil, math.huge
	for _, target in ipairs(CombatService.InRadius(at, CHAIN_RADIUS, player)) do
		if target.token ~= token and not (exclude and exclude[target.token]) then
			local distance = (target.root.Position - at).Magnitude
			if distance < bestDistance then
				local vetoed = CombatService.DamageVeto ~= nil and CombatService.DamageVeto(player, target.token, tag) == true
				local character = Combatants.GetCharacter(target.token)
				if not vetoed and character and lineOfSight(at, character, target.root, ownerCharacter, targetCharacter) then
					best, bestDistance = target, distance
				end
			end
		end
	end
	return best
end

-- The enemies a beam jumps on to after `token`, `count` of them, each from the one before and never
-- back to one already struck: a Chain forks once, a Forking style adds one more (BrainrotData forks).
local function forkTargets(player, token, targetRoot, tag, count)
	local forks, struck = {}, { [token] = true }
	local fromToken, fromRoot = token, targetRoot
	for _ = 1, count or 0 do
		local nextTarget = chainTarget(player, fromToken, fromRoot, tag, struck)
		if not nextTarget then
			break
		end
		table.insert(forks, nextTarget)
		struck[nextTarget.token] = true
		fromToken, fromRoot = nextTarget.token, nextTarget.root
	end
	return forks
end

-- Each fork lands at 60% of the one before it, as a Chain's single fork always did.
local FORK_FALLOFF = 0.6
local function hitForks(player, forks, damage, tag, report)
	local amount = damage
	for _, fork in ipairs(forks) do
		amount *= FORK_FALLOFF
		hit(player, fork.token, amount, tag, report)
	end
end

-- The living enemy nearest along a beam from `from` to `to` whose root lies within
-- BEAM_HIT_RADIUS of it, in the companion's sight: what a Zap or Chain fired at a point hits.
local function onBeam(player, entry, from, to)
	local along = to - from
	local length2 = along:Dot(along)
	if length2 < 0.25 then
		return nil
	end
	local bestToken, bestRoot, bestAt = nil, nil, math.huge
	for character, token in pairs(Combatants.All()) do
		if token ~= player and character.Parent and not friendly(player, token) then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local at = math.clamp((root.Position - from):Dot(along) / length2, 0, 1)
				local off = (from + along * at - root.Position).Magnitude
				if off <= BEAM_HIT_RADIUS and at < bestAt and lineOfSight(from, character, root, entry.character) then
					bestToken, bestRoot, bestAt = token, root, at
				end
			end
		end
	end
	return bestToken, bestRoot
end

local function reportHits(entry, report)
	if #report.positions > 0 then
		local owner = owners[entry.model]
		local stats = entry.stats
		broadcast(companionHit, {
			companion = entry.model,
			positions = report.positions,
			killed = report.killed == true,
			color = stats.color,
			style = stats.style,
			-- For CompanionFxClient: the victims (parallel to `positions`), how long the style's slow
			-- or DoT really lasts (its cue lasts as long), the rarity that tints it, the owner (their
			-- own screen pulses) and the owner's root (a Leech's ribbon runs back to it).
			victims = report.victims,
			styleTime = stats.slowTime or stats.dotTime,
			rarity = entry.def.rarity,
			owner = owner and Combatants.IsPlayer(owner) and owner.UserId or nil,
			ownerRoot = owner and Combatants.GetRoot(owner) or nil,
		})
	end
end

-- Whether a companion is still out to finish a move it started: not downed, despawned or
-- replaced during the windup.
local function stillOut(player, entry)
	return companions[player] == entry and canAct(entry) and entry.model.Parent ~= nil
end

-- Where a target will be `seconds` from now (the windup, by default) at the speed it's moving
-- across the ground, leading it by at most `maxLead` studs.
local function lead(targetRoot, seconds, maxLead)
	local velocity = targetRoot.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	if speed ~= speed or speed > MAX_LEAD_SPEED then
		return targetRoot.Position
	end
	local offset = flat * (seconds or WINDUP)
	if maxLead and offset.Magnitude > maxLead then
		offset = offset.Unit * maxLead
	end
	return targetRoot.Position + offset
end

local function travelTime(kind, from, to)
	return (kind == "Lob" and LOB_TIME) or (kind == "Bonk" and BONK_TIME) or (to - from).Magnitude / SPIT_SPEED
end

-- The fork points for the client's beams: `to2` and `to3`, the same two fields a Chain always sent.
local function forkPoints(payload, forks)
	payload.to2 = forks[1] and lead(forks[1].root) or nil
	payload.to3 = forks[2] and lead(forks[2].root) or nil
end

local function basePayload(player, entry, to)
	local stats = entry.stats
	return {
		-- Lets the owner's HUD flash and start its cooldown when their own companion strikes.
		owner = Combatants.IsPlayer(player) and player.UserId or nil,
		cooldown = stats.cooldown,
		kind = stats.kind,
		from = entry.root.Position,
		to = to,
		color = stats.color,
		range = stats.range,
		splash = stats.splash,
		-- The move's style (BrainrotData.AbilityStyles), for the client's style cue. Nil for a plain move.
		style = stats.style,
		-- The model to animate, and how long its windup runs before the move connects.
		companion = entry.model,
		windup = WINDUP,
		-- When the damage lands, from the broadcast: the windup, plus the flight for a move that
		-- travels (set with `travel` below). CompanionFxClient draws the landing on exactly this
		-- beat, so the picture never runs ahead of or behind the hit.
		lands = WINDUP,
		-- Tints the effects (Rarity.Color) and sizes them up a little for rarer brainrots.
		rarity = entry.def.rarity,
	}
end

local function attack(player, entry, token, targetRoot)
	local stats = entry.stats
	local kind = stats.kind
	local tag = "Companion:" .. entry.def.name
	local from = entry.root.Position
	-- A Lob lands where it was aimed, so it leads through its flight as well; everything else homes in
	-- or strikes at once, and only needs the windup.
	local to = kind == "Lob" and lead(targetRoot, WINDUP + LOB_TIME, LOB_MAX_LEAD) or lead(targetRoot)
	local payload = basePayload(player, entry, to)
	local report = useReport(entry)

	-- The damage is scheduled first and the broadcast goes last in every branch, so a send that
	-- throws can never cost the hit (see broadcast).
	if kind == "Shockwave" then
		task.delay(WINDUP, function()
			if CombatService.IsEnabled() and stillOut(player, entry) then
				-- Centred where the creature is when it lands the stomp; its range is the radius.
				splash(player, entry.root.Position, stats.range, stats.damage, nil, tag, report)
				reportHits(entry, report)
			end
		end)
	elseif kind == "Zap" or kind == "Chain" then
		-- A plain Zap has no forks; a Chain has one; a Forking style adds one more to either.
		local forks = forkTargets(player, token, targetRoot, tag, stats.forks)
		forkPoints(payload, forks)
		task.delay(WINDUP, function()
			if CombatService.IsEnabled() and stillOut(player, entry) then
				hit(player, token, stats.damage, tag, report)
				hitForks(player, forks, stats.damage, tag, report)
				reportHits(entry, report)
			end
		end)
	else
		-- Spit, Bonk and Lob travel once the windup is over. Spit and Bonk home in on their target;
		-- a Lob lands where it was aimed, led by where the target was heading, so changing direction
		-- mid-flight still dodges it.
		local travel = travelTime(kind, from, to)
		payload.travel = travel
		payload.lands = WINDUP + travel

		task.delay(WINDUP, function()
			if not stillOut(player, entry) then
				return
			end
			task.delay(travel, function()
				if not CombatService.IsEnabled() then
					return
				end
				if kind == "Lob" then
					splash(player, to, stats.splash, stats.damage, nil, tag, report, from)
				else
					hit(player, token, stats.damage, tag, report)
					if stats.splash > 0 then
						local current = Combatants.GetRoot(token)
						splash(player, current and current.Position or to, stats.splash, stats.damage * 0.5, token, tag, report, from)
					end
				end
				reportHits(entry, report)
			end)
		end)
	end
	broadcast(companionAttack, payload)
end

-- Where a move with no target goes: toward the crosshair, no further than the move's range.
local function reachPoint(owner, entry, aimPoint)
	local from = entry.root.Position
	if not aimPoint then
		local root = Combatants.GetRoot(owner)
		local forward = root and root.CFrame.LookVector or Vector3.new(0, 0, -1)
		return from + forward * entry.stats.range * 0.6
	end
	local offset = aimPoint - from
	if offset.Magnitude > entry.stats.range then
		return from + offset.Unit * entry.stats.range
	end
	return aimPoint
end

-- Used with nobody in reach: every move still hurts whatever is where it lands. Shockwaves and
-- lobs always did; now a Bonk slams its splash down at the point, a Spit hits anyone within
-- SPIT_POINT_RADIUS of where the glob lands, and a Zap or Chain hits the first enemy the beam
-- passes within BEAM_HIT_RADIUS of (four of the six moves used to spend their whole cooldown for
-- nothing). Beam targets are picked at the broadcast, as a targeted Zap's is, so the fork can be
-- drawn; the hit still waits for the windup.
local function attackPoint(player, entry, to)
	local stats = entry.stats
	local kind = stats.kind
	local tag = "Companion:" .. entry.def.name
	local payload = basePayload(player, entry, to)
	local from = payload.from
	payload.travel = travelTime(kind, from, to)
	local report = useReport(entry)

	if kind == "Shockwave" then
		task.delay(WINDUP, function()
			if CombatService.IsEnabled() and stillOut(player, entry) then
				splash(player, entry.root.Position, stats.range, stats.damage, nil, tag, report)
				reportHits(entry, report)
			end
		end)
	elseif kind == "Zap" or kind == "Chain" then
		local token, root = onBeam(player, entry, from, to)
		local forks = token and forkTargets(player, token, root, tag, stats.forks) or {}
		forkPoints(payload, forks)
		task.delay(WINDUP, function()
			if token and CombatService.IsEnabled() and stillOut(player, entry) then
				hit(player, token, stats.damage, tag, report)
				hitForks(player, forks, stats.damage, tag, report)
				reportHits(entry, report)
			end
		end)
	else
		-- Spit, Bonk and Lob: a splash where they land, sized for the move.
		local radius = (kind == "Spit" and SPIT_POINT_RADIUS) or math.max(stats.splash, 1)
		payload.lands = WINDUP + payload.travel
		task.delay(WINDUP + payload.travel, function()
			if CombatService.IsEnabled() and stillOut(player, entry) then
				splash(player, to, radius, stats.damage, nil, tag, report, from)
				reportHits(entry, report)
			end
		end)
	end
	broadcast(companionAttack, payload)
end

-- The lobby's practice targets (tagged "PracticeDummy" by LobbyService) within `radius` of
-- `centre`, one part per dummy.
local function dummiesNear(PracticeDummy, centre, radius)
	local found, seen = {}, {}
	for _, part in ipairs(CollectionService:GetTagged("PracticeDummy")) do
		local body = PracticeDummy.BodyOf(part)
		if body and not seen[body] and part:IsDescendantOf(workspace) and (part.Position - centre).Magnitude <= radius then
			seen[body] = true
			table.insert(found, part)
		end
	end
	return found
end

-- Out of a match the move is a harmless demo on the practice targets: it goes for the nearest in
-- range, or wherever you're looking, and every kind lands -- the dummies have health to lose, so
-- what would drop in a match drops here: a Spit, Zap or Bonk takes its target, a Bonk's splash and
-- a Shockwave or Lob take every dummy in reach, and a Chain forks on to the nearest other dummy,
-- at the same fractions. (Only Shockwave and Lob used to land; the rest fizzed on a dummy that
-- never flinched.) Nothing else happens -- no hit report, no quest, no kill; a dummy is not a
-- combatant. PracticeDummy is required here rather than at the top so the practice range's module
-- loads with the lobby.
local function practice(player, entry, aimPoint)
	local stats = entry.stats
	local kind = stats.kind
	local from = entry.root.Position
	local PracticeDummy = require(script.Parent:WaitForChild("PracticeDummy"))
	local target, distance = nil, stats.range
	for _, dummy in ipairs(CollectionService:GetTagged("PracticeDummy")) do
		if dummy:IsA("BasePart") and dummy:IsDescendantOf(workspace) then
			local away = (dummy.Position - from).Magnitude
			if away < distance then
				target, distance = dummy, away
			end
		end
	end
	local to = target and target.Position or reachPoint(player, entry, aimPoint)
	local payload = basePayload(player, entry, to)
	payload.practice = true
	payload.travel = travelTime(kind, from, to)

	-- The forks: each the nearest dummy not yet struck to the one before, for the beams and the hits.
	local forks = {}
	if (kind == "Zap" or kind == "Chain") and target then
		local struck = { [PracticeDummy.BodyOf(target)] = true }
		local at = to
		for _ = 1, stats.forks or 0 do
			local nextPart, best = nil, CHAIN_RADIUS
			for _, part in ipairs(dummiesNear(PracticeDummy, at, CHAIN_RADIUS)) do
				local away = (part.Position - at).Magnitude
				if not struck[PracticeDummy.BodyOf(part)] and away < best then
					nextPart, best = part, away
				end
			end
			if not nextPart then
				break
			end
			table.insert(forks, nextPart)
			struck[PracticeDummy.BodyOf(nextPart)] = true
			at = nextPart.Position
		end
		payload.to2 = forks[1] and forks[1].Position or nil
		payload.to3 = forks[2] and forks[2].Position or nil
	end

	-- A Shockwave stomps on the windup here as it does in a match (it used to wait out a "flight"
	-- it doesn't have, so the lobby dummies dropped a beat after the stomp).
	local lands = WINDUP + ((kind == "Zap" or kind == "Chain" or kind == "Shockwave") and 0 or payload.travel)
	payload.lands = lands
	task.delay(lands, function()
		if not stillOut(player, entry) then
			return
		end
		local function strike(part, amount)
			if part:IsDescendantOf(workspace) and PracticeDummy.BodyOf(part) then
				local dealt, killed, hitShield = PracticeDummy.Hit(part, amount)
				confirm(player, dealt, killed, part.Position, hitShield)
			end
		end
		if kind == "Shockwave" then
			for _, part in ipairs(dummiesNear(PracticeDummy, entry.root.Position, stats.range)) do
				strike(part, stats.damage)
			end
		elseif kind == "Lob" then
			for _, part in ipairs(dummiesNear(PracticeDummy, to, stats.splash)) do
				strike(part, stats.damage)
			end
		elseif target then
			strike(target, stats.damage)
			local amount = stats.damage
			for _, part in ipairs(forks) do
				amount *= FORK_FALLOFF
				strike(part, amount)
			end
			if kind == "Bonk" then
				local targetBody = PracticeDummy.BodyOf(target)
				for _, part in ipairs(dummiesNear(PracticeDummy, to, stats.splash)) do
					if PracticeDummy.BodyOf(part) ~= targetBody then
						strike(part, stats.damage * 0.5)
					end
				end
			end
		end
	end)
	broadcast(companionAttack, payload)
end

-- The hotkey. Returns whether the move was used.

-- An explosive companion ability (`blast = true`, Legendary and rarer -- BrainrotData gates it).
--
-- Routed through ProjectileService.Explode rather than given its own blast maths, because that
-- function already does exposure raycasts, falloff, self-damage scaling and the client detonation
-- cue. A second blast implementation is how the explosive-ammo branch ended up cruder than the
-- rounds beside it. `kind = "grenade"` is a REGISTERED cue, so the client draws a real explosion
-- instead of nothing; a new kind would need client work this change does not do.
--
-- Lazy require: ProjectileService pulls in the combat path, and requiring it at the top of this file
-- makes a cycle. Resolved on first use, the way BotService reaches mode state.
local projectileService
local blastId = 0
local function blastFor(player, entry, position)
	if not entry.def.blast then
		return false
	end
	if not projectileService then
		local ok, mod = pcall(require, script.Parent:WaitForChild("ProjectileService"))
		if not ok then
			warn("[CompanionService] blast wanted ProjectileService: " .. tostring(mod))
			return false
		end
		projectileService = mod
	end
	local step = (BrainrotData.RarityIndex[entry.def.rarity] or 0) - (BrainrotData.RarityIndex[BrainrotData.BlastMinRarity] or 4)
	local radius = BrainrotData.BlastRadius + BrainrotData.BlastRadiusStep * math.max(0, step)
	blastId += 1
	projectileService.Explode({
		id = "companion" .. blastId,
		owner = player,
		position = position,
		normal = Vector3.yAxis,
		kind = "grenade",
		radius = radius,
		-- One DealDamage per victim, never more than this at the centre, so capping the amount caps the
		-- use (MaxUseDamage); "blast" stands for every victim. It also trims what the blast does to
		-- structures, vehicles and companions.
		damage = withinUse(useReport(entry), "blast", entry.stats.damage * BrainrotData.BlastPower),
		weaponId = "Companion:" .. entry.def.name,
	})
	return true
end

function CompanionService.UseAbility(owner, aimPoint)
	local entry = companions[owner]
	if not canAct(entry) then
		return false
	end
	local now = clockNow()
	if now - entry.lastAttackAt < entry.stats.cooldown then
		return false
	end
	-- NaN in Y or Z has a NaN magnitude, which compares false against 1e6, so a size check alone let
	-- it through; SafeValue tests every component. A bad aim just means "no aim".
	if not SafeValue.Vector3(aimPoint) then
		aimPoint = nil
	end

	entry.lastAttackAt = now
	if CompanionService.IsFighting(owner) and CombatService.IsEnabled() then
		local token, targetRoot = pickTarget(owner, entry, aimPoint)
		local to = token and targetRoot and targetRoot.Position or reachPoint(owner, entry, aimPoint)
		-- A blast brainrot explodes at the point instead of landing its single hit, so the two never
		-- both pay: the blast IS the ability, not a bonus on top of it.
		if blastFor(owner, entry, to) then
			-- The explosion is ProjectileService's; this tells clients the creature used its move,
			-- so it recoils (CompanionFxClient) and its owner's HUD starts the cooldown, as every
			-- other move's broadcast does. Sent after the blast, so a send that throws costs nothing.
			local payload = basePayload(owner, entry, to)
			payload.blast = true
			payload.windup = 0
			payload.lands = 0
			broadcast(companionAttack, payload)
		elseif token then
			attack(owner, entry, token, targetRoot)
		else
			attackPoint(owner, entry, to)
		end
	else
		practice(owner, entry, aimPoint)
	end
	return true
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Damage this owner's companion has landed since the last reset (the start of the match).
function CompanionService.DamageDealt(owner)
	return math.floor(damageDealt[owner] or 0)
end

-- Match start: clean stats, every companion back to full health.
function CompanionService.ResetStats()
	table.clear(damageDealt)
	table.clear(lastCondition)
	for owner in pairs(fallen) do
		setFallen(owner, false)
	end
	for _, entry in pairs(companions) do
		setHealth(entry, entry.maxHealth)
		entry.lastAttackAt = -math.huge
	end
end

-- Match end: downed companions come home for the next game.
function CompanionService.ReviveAll()
	table.clear(lastCondition)
	for owner in pairs(fallen) do
		setFallen(owner, false)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if not companions[player] then
			spawnFor(player, player.Character)
		end
	end
	for _, entry in pairs(companions) do
		setHealth(entry, entry.maxHealth)
	end
end

-- Re-spawns the companion the profile now names: after equipping a different one, and after selling
-- changes what is owned.
--
-- A respawn is a BRAND NEW creature -- full health, `lastAttackAt = -math.huge`, ability ready -- and
-- that turned the menu into a heal button and a cooldown reset. Equipping off and on is two Menu
-- tokens, and the Menu budget allows a burst of 15 then 5 a second, so a player could take a full
-- heal and a ready ability about twice a second against designed cooldowns of 1.35-2.6 s.
--
-- So the condition the old creature was in is carried across, exactly the way UpdateStats carries it
-- across a merge one function down: the same FRACTION of the new maximum (the new companion may have
-- a different maximum), and the same cooldown. Carrying the cooldown matters as much as the health --
-- without it, swapping companions is still a free ability every time.
--
-- Nothing here heals. The match's own boundaries do that: ResetStats at the start, ReviveAll at the
-- end. Outside a match this is the same fresh companion it always was, because there is nothing to
-- carry when none was out.
function CompanionService.Refresh(player)
	-- `spawnFor` despawns first, and `despawn` is what records the condition -- so the read happens
	-- AFTER, and one line covers both shapes of the exploit: re-equipping while the creature is still
	-- out, and unequipping (which destroys the entry) then equipping again a moment later.
	spawnFor(player, player.Character)

	local entry = companions[player]
	local last = lastCondition[player]
	if entry and last then
		setHealth(entry, entry.maxHealth * last.fraction)
		entry.lastAttackAt = last.lastAttackAt
	end
end

-- Re-reads level and stars for the companion already out, after a merge. Done in place rather
-- than through Refresh: a respawn would come back at full health, so merging mid-fight would
-- double as a heal. Health keeps its fraction of the new maximum instead.
function CompanionService.UpdateStats(player)
	local entry = companions[player]
	if not entry then
		return
	end
	local level, stars = profileRank(player, entry.def)
	local fraction = entry.maxHealth > 0 and entry.health / entry.maxHealth or 1
	entry.stats = BrainrotData.Stats(entry.def, level, stars)
	entry.maxHealth = entry.stats.health
	entry.model:SetAttribute("MaxHealth", entry.stats.health)
	entry.model:SetAttribute("Level", level)
	entry.model:SetAttribute("Stars", stars)
	setHealth(entry, entry.stats.health * fraction)
end

-- Every player's companion re-read, after a trade moved brainrots between collections. Through
-- Refresh, not spawnFor, so it carries health and cooldown for the same reason Refresh does: a trade
-- that completed mid-match would otherwise heal and re-arm every companion on the server at once.
function CompanionService.RefreshAll()
	for _, player in ipairs(Players:GetPlayers()) do
		CompanionService.Refresh(player)
	end
end

function CompanionService.Start()
	ensureFolder()

	CombatService.CompanionFromPart = CompanionService.FromPart
	CombatService.CompanionOf = CompanionService.ModelOf
	CombatService.CompanionOwner = CompanionService.OwnerOf
	CombatService.DamageCompanion = CompanionService.Damage
	CombatService.DamageCompanionsInRadius = CompanionService.DamageInRadius

	local function hook(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("HumanoidRootPart", 10)
			spawnFor(player, character)
		end)
		player.CharacterRemoving:Connect(function()
			despawn(player)
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
	Players.PlayerRemoving:Connect(function(player)
		despawn(player)
		fallen[player] = nil
		damageDealt[player] = nil
		-- After the despawn above, which is what writes it: a player who leaves must not leave their
		-- companion's condition behind in a table keyed by them.
		lastCondition[player] = nil
	end)

	-- The boons tick every THINK_INTERVAL as before; the companions themselves take turns in
	-- THINK_SLICES groups, one group a slice, so each still thinks once an interval but they no
	-- longer all think in the same frame. A bot's companion with nobody in sight casts a ray at
	-- every enemy in range (pickTarget), so with them all in one frame, 15 companions in a 50-bot
	-- crowd could cast ~700 rays in a single frame every 0.2 s (#126/#131; tools/perf_bot_cost.py).
	local THINK_SLICES = 4
	local accumulated, sliceAccumulated, slice, nextSlot = 0, 0, 0, 0
	RunService.Heartbeat:Connect(function(delta)
		accumulated += delta
		sliceAccumulated += delta
		if accumulated >= THINK_INTERVAL then
			accumulated = 0
			for owner in pairs(companions) do
				CompanionBoons.Tick(owner, THINK_INTERVAL)
			end
			CompanionBoons.TickVenom(THINK_INTERVAL)
		end
		if sliceAccumulated < THINK_INTERVAL / THINK_SLICES then
			return
		end
		sliceAccumulated = 0
		local current = slice
		slice = (slice + 1) % THINK_SLICES

		local now = clockNow()
		for owner, entry in pairs(companions) do
			if entry.slot == nil then
				entry.slot = nextSlot
				nextSlot = (nextSlot + 1) % THINK_SLICES
			end
			if entry.slot ~= current then
				-- Another slice's turn.
			elseif not entry.model.Parent or not entry.anchor.Parent then
				despawn(owner)
			else
				local anchorPosition = entry.anchor.WorldPosition
				if (entry.root.Position - anchorPosition).Magnitude > TELEPORT_DISTANCE then
					entry.model:PivotTo(CFrame.new(anchorPosition))
				end

				local fighting = CompanionService.IsFighting(owner) and CombatService.IsEnabled()
				entry.gui.Enabled = fighting

				-- Bots have no hotkey: theirs fight on their own whenever the move is ready.
				if fighting and Combatants.IsBot(owner) and canAct(entry) and now - entry.lastAttackAt >= entry.stats.cooldown then
					local token, targetRoot = pickTarget(owner, entry, nil)
					if token then
						entry.lastAttackAt = now
						attack(owner, entry, token, targetRoot)
					end
				end
			end
		end
	end)
end

return CompanionService
