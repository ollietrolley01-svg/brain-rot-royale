-- Objective Capture (the mode's id is still "KingOfTheHill", so the vote, the bots and the HUD keep
-- their wiring). Oliver, 2026-09-22 15:39: "make the king of the hill mode called objective capture
-- and make it two objectives that they have to capture and improve the visibility of the objectives".
--
-- TWO OBJECTIVES, A and B. Standing on one with no enemy on it captures it for your team, and it
-- STAYS yours after you leave until the other side captures it back. Every objective a team owns
-- scores that team a point a second. Both sides on it at once is CONTESTED: nothing changes hands.
--
-- Visibility: each objective is a ground ring, a tall beam of light in the owner's colour, and a
-- big A / B marker drawn through walls, so it can be found from anywhere in the arena.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local ModeTeams = require(script.Parent:WaitForChild("ModeTeams"))

local ModeKingOfTheHill = {}

local LETTERS = { "A", "B" }
local NEUTRAL = Color3.fromRGB(230, 230, 230)
local CONTESTED = Color3.fromRGB(255, 214, 80)
local BEAM_HEIGHT = 160
local STEP = 0.07
-- The two objectives are at least this far apart, so holding both means holding ground.
local SITE_GAP = 220

local mode = nil
local model = nil
local candidates = {}
-- objectives[i] = { position, owner, status, ring, beam, label, lastColour }
local objectives = {}

--------------------------------------------------------------------------------
-- Occupancy
--------------------------------------------------------------------------------

-- Which team is alone on it (nil if contested or empty), and a status word.
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

local function radius()
	return (mode and mode.hillRadius) or 28
end

local function height()
	return (mode and mode.hillHeight) or 22
end

-- Live combatants of each team on the objective at `point` (objective A when nil).
function ModeKingOfTheHill.Occupancy(point)
	local counts = { 0, 0 }
	point = point or (objectives[1] and objectives[1].position)
	if not point then
		return counts
	end
	for character, token in pairs(Combatants.All()) do
		local team = ModeTeams.TeamOf(token)
		if team and character.Parent and not ModeTeams.IsDowned(token) then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local offset = root.Position - point
				local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if flat <= radius() and offset.Y >= -6 and offset.Y <= height() then
					counts[team] = counts[team] + 1
				end
			end
		end
	end
	return counts
end

--------------------------------------------------------------------------------
-- The objectives in the world
--------------------------------------------------------------------------------

local function ensureModel()
	if model and model.Parent then
		return model
	end
	model = Instance.new("Model")
	model.Name = "Hill"
	model:SetAttribute("IntentionalFloat", true)
	model:SetAttribute("FootingSkip", true)
	model.Parent = workspace
	return model
end

local function part(name, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Parent = parent
	return p
end

local function buildObjective(index, position)
	local container = ensureModel()
	local folder = Instance.new("Model")
	folder.Name = "Objective" .. LETTERS[index]
	folder.Parent = container

	local ring = part("HillRing", folder)
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, radius() * 2, radius() * 2)
	ring.CFrame = CFrame.new(position + Vector3.new(0, STEP * 3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Transparency = 0.35
	ring.Color = NEUTRAL

	-- A tall beam: findable from anywhere in the arena, but never stops a bullet or a movement check.
	local beam = part("HillPillar", folder)
	beam.Shape = Enum.PartType.Cylinder
	beam.Size = Vector3.new(BEAM_HEIGHT, 7, 7)
	beam.CFrame = CFrame.new(position + Vector3.new(0, BEAM_HEIGHT / 2 + STEP * 6, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	beam.Transparency = 0.5
	beam.Color = NEUTRAL
	local light = Instance.new("PointLight")
	light.Range = 40
	light.Brightness = 2
	light.Color = NEUTRAL
	light.Parent = beam

	-- The letter, drawn through walls and at any distance.
	local anchor = part("HillMarker", folder)
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(position + Vector3.new(0, height() + 8, 0))
	local gui = Instance.new("BillboardGui")
	gui.Name = "ObjectiveMarker"
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(64, 64)
	gui.MaxDistance = 100000
	gui.LightInfluence = 0
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	label.BackgroundTransparency = 0.25
	label.Font = Enum.Font.FredokaOne
	label.Text = LETTERS[index]
	label.TextScaled = true
	label.TextColor3 = NEUTRAL
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = NEUTRAL
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = label

	folder:SetAttribute("HillX", position.X)
	folder:SetAttribute("HillZ", position.Z)
	folder:SetAttribute("HillRadius", radius())
	folder:SetAttribute("Objective", LETTERS[index])
	-- Objective A's position also sits on the container, where the HUD and minimap already look.
	if index == 1 then
		container:SetAttribute("HillX", position.X)
		container:SetAttribute("HillZ", position.Z)
		container:SetAttribute("HillRadius", radius())
	end

	return { position = position, owner = nil, status = "Open", ring = ring, beam = beam, light = light, label = label, stroke = stroke }
end

local function paint(objective)
	local colour
	if objective.status == "Contested" then
		colour = CONTESTED
	elseif objective.owner then
		colour = GameModes.TeamColor(objective.owner)
	else
		colour = NEUTRAL
	end
	if objective.lastColour == colour then
		return
	end
	objective.lastColour = colour
	objective.ring.Color = colour
	objective.beam.Color = colour
	objective.light.Color = colour
	objective.label.TextColor3 = colour
	objective.stroke.Color = colour
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function groundAt(site)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { workspace.Terrain }
	local found = workspace:Raycast(Vector3.new(site.X, 2000, site.Z), Vector3.new(0, -4000, 0), params)
	return Vector3.new(site.X, found and found.Position.Y or 0, site.Z)
end

function ModeKingOfTheHill.Start(currentMode, mapInfo)
	mode = currentMode
	ModeKingOfTheHill.Stop()
	mode = currentMode

	local centre, arena = ModeTeams.Arena()
	local function flat(v)
		return Vector3.new(v.X, 0, v.Z)
	end
	local function usable(point)
		if (flat(point) - centre).Magnitude > arena - 60 then
			return false
		end
		for _, existing in ipairs(candidates) do
			if (flat(point) - existing).Magnitude < SITE_GAP then
				return false
			end
		end
		return not ModeTeams.RefusePad(point.X, point.Z, mapInfo and mapInfo.river)
	end
	-- Landmarks and towns inside the arena first; the arena centre is the fallback for either slot.
	for _, entry in ipairs((mapInfo and mapInfo.landmarks) or {}) do
		local point = Vector3.new(entry.X or 0, 0, entry.Z or 0)
		if #candidates < 2 and usable(point) then
			table.insert(candidates, flat(point))
		end
	end
	for index, spot in ipairs((mapInfo and mapInfo.dropSpots) or {}) do
		if #candidates < 2 and usable(spot) then
			table.insert(candidates, flat(spot))
		end
	end
	if #candidates < 2 and usable(centre) then
		table.insert(candidates, flat(centre))
	end
	-- Still short: put them on either side of the centre, across the line between the two bases.
	local tries = 0
	while #candidates < 2 and tries < 24 do
		tries += 1
		local angle = math.random() * math.pi * 2
		local point = centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (arena * 0.35)
		if usable(point) or tries > 20 then
			table.insert(candidates, flat(point))
		end
	end

	for index, site in ipairs(candidates) do
		objectives[index] = buildObjective(index, groundAt(site))
	end
	return #objectives
end

-- Kept for the rotation hook: moves objective A to another site.
function ModeKingOfTheHill.MoveTo(index)
	return objectives[1] ~= nil and index == 1
end

-- The objective a team should head for: the nearest one it does not own; if it owns both, the one
-- under attack, else A. With no team, objective A.
function ModeKingOfTheHill.Position(team)
	if #objectives == 0 then
		return nil
	end
	if not team then
		return objectives[1].position
	end
	for _, objective in ipairs(objectives) do
		if objective.owner ~= team then
			return objective.position
		end
	end
	for _, objective in ipairs(objectives) do
		if objective.status == "Contested" then
			return objective.position
		end
	end
	return objectives[1].position
end

function ModeKingOfTheHill.Positions()
	local list = {}
	for index, objective in ipairs(objectives) do
		list[index] = objective.position
	end
	return list
end

function ModeKingOfTheHill.SiteCount()
	return #objectives
end

-- A spawn pad nearer an objective is worth a little more, so respawning is not a long walk back.
function ModeKingOfTheHill.PadBonus()
	if #objectives == 0 then
		return nil
	end
	return function(pad)
		local best = math.huge
		for _, objective in ipairs(objectives) do
			best = math.min(best, (pad - objective.position).Magnitude)
		end
		return math.max(0, 400 - best) * 0.25
	end
end

-- One tick: captures, recolours, and returns the list of scoring teams (one entry per objective
-- owned), a status string for the HUD, and the counts on objective A.
function ModeKingOfTheHill.Tick()
	local scoring = {}
	local owned = { 0, 0 }
	local firstCounts = nil
	for _, objective in ipairs(objectives) do
		local counts = ModeKingOfTheHill.Occupancy(objective.position)
		firstCounts = firstCounts or counts
		local alone, status = ModeKingOfTheHill.Holder(counts[1], counts[2])
		if alone then
			objective.owner = alone
		end
		objective.status = status
		paint(objective)
		if objective.owner then
			table.insert(scoring, objective.owner)
			owned[objective.owner] += 1
		end
	end
	local status = string.format("A %s · B %s",
		objectives[1] and (objectives[1].owner and GameModes.TeamName(objectives[1].owner) or "open") or "-",
		objectives[2] and (objectives[2].owner and GameModes.TeamName(objectives[2].owner) or "open") or "-")
	local leader = owned[1] > owned[2] and 1 or (owned[2] > owned[1] and 2 or nil)
	return leader, status, firstCounts or { 0, 0 }, scoring
end

function ModeKingOfTheHill.Stop()
	if model then
		model:Destroy()
		model = nil
	end
	table.clear(objectives)
	table.clear(candidates)
end

ModeKingOfTheHill.Step = STEP
ModeKingOfTheHill.FixTolerance = ZFight.FixTolerance

return ModeKingOfTheHill
