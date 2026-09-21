-- King of the Hill: one hill, held alone, scores a point a second.
--
-- ONE FIXED HILL (Oliver's decision). The rotation is written and tested but off — GameModes'
-- `hillRotation` is false, and turning it on is the whole change.
--
-- Occupancy is deliberately blunt: sole occupancy by one side scores, both sides present is
-- CONTESTED and nobody scores, empty scores nothing. No partial capture bar. Contested means
-- contested, which is the version someone can read at a glance from a rooftop across the square.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local ModeTeams = require(script.Parent:WaitForChild("ModeTeams"))

local ModeKingOfTheHill = {}

local mode = nil
local model = nil
local hill = nil
local hillIndex = 0
local candidates = {}
local ring, pillar = nil, nil

-- ZFight's pass runs over the map before this is built, so the hill is not swept by it. It still
-- has to be built to the same tolerance: nothing here sits within ZFight.FixTolerance of anything
-- else, so a future pass over the map folder would find nothing to move.
local STEP = 0.07

--------------------------------------------------------------------------------
-- Occupancy — the whole of the scoring rule, as a pure function so it can be fault-tested
--------------------------------------------------------------------------------

-- Given how many live combatants of each side are inside the zone, which team scores this tick.
-- Returns the team index, or nil for contested/empty, and a status string for the HUD.
function ModeKingOfTheHill.Holder(insideTeamOne, insideTeamTwo)
	if insideTeamOne > 0 and insideTeamTwo > 0 then
		return nil, "Contested"
	elseif insideTeamOne > 0 then
		return 1, "Held"
	elseif insideTeamTwo > 0 then
		return 2, "Held"
	end
	return nil, "Open"
end

-- Who is standing in the zone right now, by team. Counts live combatants only, and only within
-- the hill's own height — a zone that reached the sky would let someone hold it from a
-- third-floor window across the square.
function ModeKingOfTheHill.Occupancy()
	local counts = { 0, 0 }
	if not hill then
		return counts
	end
	local radius = (mode and mode.hillRadius or 28)
	local height = (mode and mode.hillHeight or 22)
	for character, token in pairs(Combatants.All()) do
		local team = ModeTeams.TeamOf(token)
		if team and character.Parent and not ModeTeams.IsDowned(token) then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local offset = root.Position - hill
				local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if flat <= radius and offset.Y >= -6 and offset.Y <= height then
					counts[team] = counts[team] + 1
				end
			end
		end
	end
	return counts
end

--------------------------------------------------------------------------------
-- The hill in the world
--------------------------------------------------------------------------------

local function ensureModel()
	if model and model.Parent then
		return model
	end
	model = Instance.new("Model")
	model.Name = "Hill"
	model.Parent = workspace
	return model
end

local function buildHill(position)
	local container = ensureModel()
	container:ClearAllChildren()

	local radius = (mode and mode.hillRadius or 28)

	-- The ground ring. Flat on the surface, so it is stepped clear of it rather than laid on it.
	ring = Instance.new("Part")
	ring.Name = "HillRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, radius * 2, radius * 2)
	ring.CFrame = CFrame.new(position + Vector3.new(0, STEP * 3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.55
	ring.Color = Color3.fromRGB(230, 230, 230)
	ring.Parent = container

	-- A pillar of light so it is findable from anywhere in the arena. No collision, no query: it
	-- must never stop a bullet or catch a movement check.
	pillar = Instance.new("Part")
	pillar.Name = "HillPillar"
	pillar.Shape = Enum.PartType.Cylinder
	pillar.Size = Vector3.new((mode and mode.hillHeight or 22), 6, 6)
	pillar.CFrame = CFrame.new(position + Vector3.new(0, (mode and mode.hillHeight or 22) / 2 + STEP * 6, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.Material = Enum.Material.Neon
	pillar.Transparency = 0.82
	pillar.Color = Color3.fromRGB(230, 230, 230)
	pillar.Parent = container

	container:SetAttribute("HillX", position.X)
	container:SetAttribute("HillZ", position.Z)
	container:SetAttribute("HillRadius", radius)
	-- Scatter props and the footing probe both skip things that are meant to float.
	container:SetAttribute("IntentionalFloat", true)
	container:SetAttribute("FootingSkip", true)
	return container
end

-- Tints the hill to whoever holds it. Called every tick; only writes when the colour changes, so
-- a held hill is not a property write ten times a second.
local lastTint = nil
local function tint(team)
	local colour = team and GameModes.TeamColor(team) or Color3.fromRGB(230, 230, 230)
	if lastTint and lastTint == colour then
		return
	end
	lastTint = colour
	if ring then
		ring.Color = colour
	end
	if pillar then
		pillar.Color = colour
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Hill sites: the arena centre first (town 1's square — streets, cover, and the ground the battle
-- royale's last circle already lands on), then landmarks and other towns inside the arena, at
-- least 160 studs apart. With rotation off only the first is ever used; the rest are built so the
-- rotation can be turned on without new work.
local SITE_GAP = 160

function ModeKingOfTheHill.Start(currentMode, mapInfo)
	mode = currentMode
	table.clear(candidates)
	hillIndex = 0
	lastTint = nil

	local centre, radius = ModeTeams.Arena()
	table.insert(candidates, centre)

	local function consider(point)
		if #candidates >= 3 or not point then
			return
		end
		local flat = Vector3.new(point.X, 0, point.Z)
		if (flat - centre).Magnitude > radius - 60 then
			return
		end
		for _, existing in ipairs(candidates) do
			if (flat - Vector3.new(existing.X, 0, existing.Z)).Magnitude < SITE_GAP then
				return
			end
		end
		if ModeTeams.RefusePad(flat.X, flat.Z, mapInfo and mapInfo.river) then
			return
		end
		table.insert(candidates, flat)
	end

	for _, entry in ipairs((mapInfo and mapInfo.landmarks) or {}) do
		consider(Vector3.new(entry.X or 0, 0, entry.Z or 0))
	end
	for index, spot in ipairs((mapInfo and mapInfo.dropSpots) or {}) do
		if index > 1 then
			consider(spot)
		end
	end

	ModeKingOfTheHill.MoveTo(1)
	return #candidates
end

function ModeKingOfTheHill.MoveTo(index)
	local site = candidates[index] or candidates[1]
	if not site then
		return false
	end
	hillIndex = index
	-- The ground under the site, found the same way pads are: from y = 2000, ignoring water.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { workspace.Terrain }
	local found = workspace:Raycast(Vector3.new(site.X, 2000, site.Z), Vector3.new(0, -4000, 0), params)
	hill = Vector3.new(site.X, found and found.Position.Y or 0, site.Z)
	buildHill(hill)
	return true
end

function ModeKingOfTheHill.Position()
	return hill
end

function ModeKingOfTheHill.SiteCount()
	return #candidates
end

-- How much a spawn pad is worth to a team beyond its distance from the nearest enemy: being
-- nearer the hill is worth something, so respawning does not mean a long walk back.
function ModeKingOfTheHill.PadBonus()
	if not hill then
		return nil
	end
	return function(pad)
		return math.max(0, 400 - (pad - hill).Magnitude) * 0.25
	end
end

-- One scoring tick. `seconds` is how long since the last one. Returns the holding team (or nil)
-- and the status, and tints the hill. The caller adds the points, so the arithmetic that decides a
-- match is not buried in a visual effect.
function ModeKingOfTheHill.Tick()
	local counts = ModeKingOfTheHill.Occupancy()
	local team, status = ModeKingOfTheHill.Holder(counts[1], counts[2])
	tint(team)
	return team, status, counts
end

function ModeKingOfTheHill.Stop()
	if model then
		model:Destroy()
		model = nil
	end
	ring, pillar, hill, lastTint = nil, nil, nil, nil
	hillIndex = 0
	table.clear(candidates)
end

-- Kept so a z-fight sweep over this model, if one is ever added, has the tolerance to hand.
ModeKingOfTheHill.Step = STEP
ModeKingOfTheHill.FixTolerance = ZFight.FixTolerance

return ModeKingOfTheHill
