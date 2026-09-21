-- The arena's target dummies: a body to shoot at, with exactly the health a player brings into a
-- match (MatchConfig.StartHealth) behind exactly the shield a full one carries (MatchConfig.MaxShield),
-- taken in the same order a player's is — shield first, then health. When the last of it goes the
-- dummy collapses in a ragdoll, and five seconds later a fresh one is standing on the same stand.
--
--   PracticeDummy.Build(parent, frame, group)   a stand and a dummy at `frame` (it faces the frame's LookVector)
--   PracticeDummy.Hit(part, amount)             damage through the part a shot landed on ->
--                                               dealt, killed, hitShield, headshot
--   PracticeDummy.BodyOf(part)                  the dummy a part belongs to, or nil
--   PracticeDummy.State(body)                   health and shield left
--   PracticeDummy.Pools()                       StartHealth, MaxShield — read from MatchConfig, never copied
--   PracticeDummy.Sites(parent)                 the stands under `parent` (for probes)
--   PracticeDummy.RespawnSeconds
--
-- Two things are structural rather than checked. Every body part carries the PracticeDummy tag and
-- RangeService's raycast filter INCLUDES only tagged parts, so the moment a dummy is destroyed its
-- pieces are untagged and unqueryable and can't be shot again; a rebuilt body is tagged by the same
-- Build path as the first, so nothing has to remember to tag it. And nothing here goes near
-- Combatants or DealDamage: a dummy is not a combatant, so destroying one cannot be a kill — no feed,
-- no rank, no quest, no stat — only the shooter's own hit marker, through CombatService.ConfirmHit.
--
-- Stands live in plain tables and are dropped when their parent is destroyed (a weak-keyed table
-- with Instance keys loses live entries in Roblox). A death schedules one task.delay, checked against
-- the stand's generation before it builds, so nothing accumulates however long the server runs.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

local PracticeDummy = {}

PracticeDummy.Tag = "PracticeDummy"
PracticeDummy.RespawnSeconds = 5
-- How long the collapsed body lies before it's cleared: just short of the respawn, so a corpse and a
-- live body never share a stand. A field so a probe can read it; nothing in the game changes it.
PracticeDummy.DebrisSeconds = 4.5

local BURLAP = Color3.fromRGB(196, 168, 118)
local BURLAP_DARK = Color3.fromRGB(172, 144, 98)
local BELT = Color3.fromRGB(92, 62, 40)
local WOOD = Color3.fromRGB(90, 70, 50)
local RED = Color3.fromRGB(214, 60, 60)
local WHITE = Color3.fromRGB(245, 245, 240)
local BUTTON = Color3.fromRGB(40, 30, 25)
local BAR_BACK = Color3.fromRGB(28, 28, 32)
local HEALTH_GREEN = Color3.fromRGB(96, 214, 96)
local SHIELD_BLUE = Color3.fromRGB(86, 168, 255)

local sites = {}      -- id -> stand
local byParent = {}   -- parent -> { ids, connection }
local nextId = 0

local function piece(parent, name, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function rounded(instance)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = instance
end

-- The bars over its head: shield above health, each full when the dummy is.
local function buildBars(body, head)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.new(4, 0, 1, 0)
	gui.StudsOffset = Vector3.new(0, 1.5, 0)
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	gui.Adornee = head
	gui.Parent = head
	local function bar(name, color, row)
		local back = Instance.new("Frame")
		back.Name = name .. "Back"
		back.Size = UDim2.new(1, 0, 0.36, 0)
		back.Position = UDim2.new(0, 0, row, 0)
		back.BackgroundColor3 = BAR_BACK
		back.BackgroundTransparency = 0.25
		back.BorderSizePixel = 0
		back.Parent = gui
		rounded(back)
		local fill = Instance.new("Frame")
		fill.Name = name
		fill.Size = UDim2.new(1, 0, 1, 0)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = back
		rounded(fill)
	end
	bar("Shield", SHIELD_BLUE, 0)
	bar("Health", HEALTH_GREEN, 0.5)
	local _ = body
end

local function paintBars(body, health, shield)
	local head = body:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("HealthBar")
	if not gui then
		return
	end
	local maxHealth = math.max(body:GetAttribute("DummyMaxHealth") or 1, 1)
	local maxShield = math.max(body:GetAttribute("DummyMaxShield") or 0, 0)
	local healthFill = gui:FindFirstChild("HealthBack") and gui.HealthBack:FindFirstChild("Health")
	local shieldFill = gui:FindFirstChild("ShieldBack") and gui.ShieldBack:FindFirstChild("Shield")
	if healthFill then
		healthFill.Size = UDim2.new(math.clamp(health / maxHealth, 0, 1), 0, 1, 0)
	end
	if shieldFill then
		shieldFill.Size = UDim2.new(maxShield > 0 and math.clamp(shield / maxShield, 0, 1) or 0, 0, 1, 0)
	end
end

-- The mannequin, laid out in the stand's own frame (x across, y up, -z the way it faces). Every face
-- that could lie flush with a neighbour is either a butt joint (the two faces point at each other) or
-- a clear 0.07 off, so the z-fight pass never has to move a part — it can't, on a body rebuilt at
-- runtime, so the body has to be clean as written.
local function buildBody(site)
	local frame = site.frame
	local body = Instance.new("Model")
	body.Name = "PracticeDummy"
	body:SetAttribute("DummySite", site.id)
	local upright = CFrame.Angles(0, 0, math.pi / 2)   -- a cylinder stood on end
	local facing = CFrame.Angles(0, math.pi / 2, 0)    -- a cylinder's axis along the way it faces
	local function limb(name, size, x, y, z, color, material, shape, rotation)
		local part = piece(body, name, size, frame * CFrame.new(x, y, z) * (rotation or CFrame.new()), color, material, shape)
		part:SetAttribute("Group", site.group)
		CollectionService:AddTag(part, PracticeDummy.Tag)
		return part
	end
	-- Legs stand on the plate (a butt joint), the belt sits on the legs, the chest on the belt: each
	-- piece a little wider than the one below so no two sides share a plane.
	limb("LeftLeg", Vector3.new(0.9, 1.8, 0.9), -0.55, 1.3, 0, BURLAP_DARK, Enum.Material.Fabric)
	limb("RightLeg", Vector3.new(0.9, 1.8, 0.9), 0.55, 1.3, 0, BURLAP_DARK, Enum.Material.Fabric)
	limb("LowerTorso", Vector3.new(2.2, 0.7, 1.06), 0, 2.55, 0, BELT, Enum.Material.Leather)
	local chest = limb("UpperTorso", Vector3.new(2.4, 1.8, 1.2), 0, 3.8, 0, BURLAP, Enum.Material.Fabric)
	-- Arms butt against the chest's sides; their tops share the chest's height but touch it only
	-- along an edge, which the pass rightly ignores.
	limb("LeftArm", Vector3.new(0.8, 1.8, 0.8), -1.6, 3.8, 0, BURLAP, Enum.Material.Fabric)
	limb("RightArm", Vector3.new(0.8, 1.8, 0.8), 1.6, 3.8, 0, BURLAP, Enum.Material.Fabric)
	limb("Neck", Vector3.new(0.3, 0.7, 0.7), 0, 4.85, 0, BELT, Enum.Material.Leather, Enum.PartType.Cylinder, upright)
	local head = limb("Head", Vector3.new(1.4, 1.4, 1.4), 0, 5.7, 0, BURLAP, Enum.Material.Fabric, Enum.PartType.Ball)
	-- The painted target on the chest: three discs each stepped 0.08 forward, the back of each
	-- butted to the front of the one behind it.
	limb("TargetRed", Vector3.new(0.08, 1.2, 1.2), 0, 3.85, -0.64, RED, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder, facing)
	limb("TargetWhite", Vector3.new(0.08, 0.7, 0.7), 0, 3.85, -0.72, WHITE, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder, facing)
	limb("TargetDot", Vector3.new(0.08, 0.3, 0.3), 0, 3.85, -0.8, RED, Enum.Material.Neon, Enum.PartType.Cylinder, facing)
	-- Button eyes and a stitched mouth, set into the head far enough to show.
	limb("LeftEye", Vector3.new(0.24, 0.24, 0.24), -0.24, 5.85, -0.6, BUTTON, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	limb("RightEye", Vector3.new(0.24, 0.24, 0.24), 0.24, 5.85, -0.6, BUTTON, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	limb("Mouth", Vector3.new(0.36, 0.06, 0.08), 0, 5.45, -0.7, BUTTON, Enum.Material.SmoothPlastic)
	body.PrimaryPart = chest

	local health, shield = PracticeDummy.Pools()
	body:SetAttribute("DummyHealth", health)
	body:SetAttribute("DummyShield", shield)
	body:SetAttribute("DummyMaxHealth", health)
	body:SetAttribute("DummyMaxShield", shield)
	buildBars(body, head)
	body.Parent = site.parent
	return body
end

-- The ragdoll's joints: child, parent, the joint's point in the stand's frame, the direction the
-- limb hangs at rest (the cone's axis), and the cone's half-angle. Small pieces that sit on a
-- bigger part (the neck on the chest, the painted target, the button eyes and the mouth) are
-- welded to it instead, and stop colliding so nothing they overlap can pop them apart.
local JOINTS = {
	{ "UpperTorso", "LowerTorso", Vector3.new(0, 2.9, 0), Vector3.new(0, 1, 0), 40 },
	{ "Head", "UpperTorso", Vector3.new(0, 5.0, 0), Vector3.new(0, 1, 0), 35 },
	{ "LeftArm", "UpperTorso", Vector3.new(-1.2, 4.55, 0), Vector3.new(-0.45, -1, 0), 85 },
	{ "RightArm", "UpperTorso", Vector3.new(1.2, 4.55, 0), Vector3.new(0.45, -1, 0), 85 },
	{ "LeftLeg", "LowerTorso", Vector3.new(-0.55, 2.2, 0), Vector3.new(0, -1, 0), 60 },
	{ "RightLeg", "LowerTorso", Vector3.new(0.55, 2.2, 0), Vector3.new(0, -1, 0), 60 },
}
local WELDED = {
	Neck = "UpperTorso", TargetRed = "UpperTorso", TargetWhite = "UpperTorso", TargetDot = "UpperTorso",
	LeftEye = "Head", RightEye = "Head", Mouth = "Head",
}

-- The dummy collapses in a ragdoll: every part loses its tag and its place in the raycast filter
-- (so nothing on the stand can be shot until the fresh body stands), the bars come off, the limbs
-- are hung from each other on limited ball sockets, everything is let go and the figure falls
-- under physics — with a nudge backward so it topples rather than stands on its own feet — and
-- lies there until it is cleared, just before the fresh body builds. The stand stays. Constraints
-- between anchored parts are inert, so the figure is assembled while it still stands and only
-- falls once everything is unanchored, all in one frame.
local function down(site, body)
	site.body = nil
	site.generation += 1
	local generation = site.generation
	body:SetAttribute("DummyDown", true)
	local head = body:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("HealthBar")
	if gui then
		gui:Destroy()
	end
	local frame = site.frame
	local parts = {}
	for _, part in ipairs(body:GetDescendants()) do
		if part:IsA("BasePart") then
			CollectionService:RemoveTag(part, PracticeDummy.Tag)
			part.CanQuery = false
			parts[part.Name] = part
		end
	end
	for childName, parentName in pairs(WELDED) do
		local child, parent = parts[childName], parts[parentName]
		if child and parent then
			child.CanCollide = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = parent
			weld.Part1 = child
			weld.Parent = child
		end
	end
	for _, joint in ipairs(JOINTS) do
		local child, parent = parts[joint[1]], parts[joint[2]]
		if child and parent then
			-- Both attachments at the joint, their X axis (the socket's cone axis) along the way the
			-- limb hangs, so the rest pose is the middle of the cone.
			local at = frame:PointToWorldSpace(joint[3])
			local axis = frame:VectorToWorldSpace(joint[4]).Unit
			local orientation = CFrame.lookAt(at, at + axis) * CFrame.Angles(0, math.pi / 2, 0)
			local a0 = Instance.new("Attachment")
			a0.Parent = parent
			a0.WorldCFrame = orientation
			local a1 = Instance.new("Attachment")
			a1.Parent = child
			a1.WorldCFrame = orientation
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = joint[5]
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -30
			socket.TwistUpperAngle = 30
			socket.Parent = child
		end
	end
	for _, part in pairs(parts) do
		part.Anchored = false
	end
	local chest = parts.UpperTorso
	if chest then
		chest.AssemblyLinearVelocity = -frame.LookVector * 5 + Vector3.new(0, 1, 0)
	end
	Debris:AddItem(body, PracticeDummy.DebrisSeconds)
	task.delay(PracticeDummy.RespawnSeconds, function()
		if site.dead or site.body or site.generation ~= generation or not site.parent.Parent then
			return
		end
		site.body = buildBody(site)
	end)
end

function PracticeDummy.Pools()
	return MatchConfig.StartHealth, MatchConfig.MaxShield
end

function PracticeDummy.Build(parent, frame, group)
	nextId += 1
	local site = { id = nextId, parent = parent, frame = frame, group = group, generation = 0, body = nil, dead = false }
	sites[site.id] = site
	local entry = byParent[parent]
	if not entry then
		entry = { ids = {} }
		byParent[parent] = entry
		entry.connection = parent.Destroying:Connect(function()
			for _, id in ipairs(entry.ids) do
				local stand = sites[id]
				if stand then
					stand.dead = true
					sites[id] = nil
				end
			end
			entry.connection:Disconnect()
			byParent[parent] = nil
		end)
	end
	table.insert(entry.ids, site.id)
	-- The stand: the plate the dummy is rebuilt on. Not tagged — it's a stand, not a target.
	local plate = piece(parent, "DummyStand", Vector3.new(0.4, 4.2, 4.2),
		frame * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.pi / 2), WOOD, Enum.Material.WoodPlanks, Enum.PartType.Cylinder)
	plate:SetAttribute("Group", group)
	plate:SetAttribute("DummyStand", site.id)
	site.stand = plate
	site.body = buildBody(site)
	return site.body
end

function PracticeDummy.BodyOf(part)
	local node = part
	while node and node ~= workspace do
		if node:IsA("Model") and node:GetAttribute("DummySite") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The head and what's on it; the painted target on the chest.
local HEAD_PARTS = { Head = true, LeftEye = true, RightEye = true, Mouth = true }
local BULLSEYE_PARTS = { TargetRed = true, TargetWhite = true, TargetDot = true }
PracticeDummy.BullseyeMultiplier = 1.5

-- Damage through the part a shot landed on. A head part pays `headshotMultiplier` (the gun's own,
-- as on a player; nil is 1) and the painted target pays the bullseye bonus. Returns what was dealt
-- (for the damage number), whether that finished it, whether the shield took any of it (a blue
-- marker) and whether it was the head (a gold one).
function PracticeDummy.Hit(part, amount, headshotMultiplier)
	local body = PracticeDummy.BodyOf(part)
	if not body or body:GetAttribute("DummyDown") or type(amount) ~= "number" or amount <= 0 then
		return 0, false, false, false
	end
	local site = sites[body:GetAttribute("DummySite")]
	if not site or site.body ~= body then
		return 0, false, false, false
	end
	local headshot = HEAD_PARTS[part.Name] == true
	if headshot then
		amount *= tonumber(headshotMultiplier) or 1
	elseif BULLSEYE_PARTS[part.Name] then
		amount *= PracticeDummy.BullseyeMultiplier
	end
	local health = body:GetAttribute("DummyHealth") or 0
	local shield = body:GetAttribute("DummyShield") or 0
	local absorbed = math.min(shield, amount)
	local through = math.min(health, amount - absorbed)
	shield -= absorbed
	health -= through
	body:SetAttribute("DummyHealth", health)
	body:SetAttribute("DummyShield", shield)
	paintBars(body, health, shield)
	local killed = health <= 0
	if killed then
		down(site, body)
	end
	return absorbed + through, killed, absorbed > 0, headshot
end

function PracticeDummy.State(body)
	return body:GetAttribute("DummyHealth") or 0, body:GetAttribute("DummyShield") or 0
end

function PracticeDummy.Sites(parent)
	local found = {}
	local entry = byParent[parent]
	if entry then
		for _, id in ipairs(entry.ids) do
			if sites[id] then
				table.insert(found, sites[id])
			end
		end
	end
	return found
end

return PracticeDummy
