-- The placement preview for portable defenses: while a Rot Barricade, Pop-up Bunker or Brainrot
-- Fortress is in your hand, a translucent ghost of exactly what DefenseService will build stands where
-- it will go up, green when the site is good and red when it isn't. No text: the ghost, the dotted lob,
-- the tint, a red outline on the structure a fourth throw would knock down, and a marker where you aimed
-- when the throw will not reach it say all of it in the world. A ModuleScript so
-- HudClient can drive it and tools/hud_ux_gallery.lua can render it without a match.
--
--   local preview = DefensePreview.new()
--   preview:Update(character, itemId)            -- each frame while a defense is held (aims for itself)
--   preview:Update(character, itemId, aimPoint)  -- or with an aim point (galleries, probes)
--   preview:Hide()
--   DefensePreview.Site(character, itemId, aimPoint)  -- the prediction alone, no drawing (probes)
--   DefensePreview.FlyKit(info)                  -- a thrown structure kit, flown on this client
--
-- It predicts rather than guesses:
--   * the aim is CombatClient's own crosshair point (AimState), the point the throw is sent with;
--   * the throw is the server's: the same start at the head, the same range clamp and facing
--     (DefensePlacement.ThrowTarget), the same lift where the kit lands;
--   * the site is the server's: DefensePlacement.FindSite, the function DefenseService itself calls,
--     with the same size, leaving out only what exists on this client alone (the camera's viewmodel
--     and this ghost, client-side effects);
--   * the ghost is the server's: a clone of the structure DefenseService builds with its own builders
--     into ReplicatedStorage.DefenseTemplates, set on the plan's origin (level, or tilted along a
--     barricade's length), with the plan's footings -- posts, sill, floats, ladder -- drawn from the
--     same DefensePlacement.Footings list DefenseService builds them from.
-- The kit does not arrive where you aimed: it is lobbed on an arc (DefensePlacement.ThrowArc) flat enough
-- to clip a rising hill, and measured on a real map the arc meets the ground a median 10 studs from the
-- aim point. So the preview walks that same arc (DefensePlacement.Landing, the function the server now
-- builds from) and puts the ghost where the throw will actually land, marks your aim when that is far
-- off, and stops the dotted lob there rather than drawing through the hillside. A structure's kit no
-- longer rolls (#128, 09-24: it deploys where the arc lands), so the ghost is a promise, not "about
-- here"; only the Rot Mine, still a physics throw, keeps the ring of how far it may roll.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local RunService = game:GetService("RunService")

local DefensePreview = {}
DefensePreview.__index = DefensePreview

-- The ring's radius: how far the kit rolls AFTER it lands, now that the arc above is traced rather than
-- assumed. Measured over 72 real throws on SahurSprings with physics (tools/hud_ux_gallery.lua "grip",
-- 2026-09-17): the roll from first contact to rest is mean 5.6, p50 2.7, p75 4.8, p90 11.9 studs, and no
-- kit friction, weight or bounce setting moved it. Five studs covers three throws in four. (The old
-- value of 16.2 was the distance from the AIM, which is a different and much larger thing: the same run
-- put the first contact a median 19.6 studs from the aim and 13 studs SHORT of it -- the flight, not the
-- roll, and the traced arc is what answers that.) Re-run `grip` if the throw or the kit models change.
DefensePreview.LandingSpread = 5
-- A structure lands exactly where the arc does: its ring is a marker, not a spread.
DefensePreview.StructureMark = 1
-- The site is worked out again when the landing moves this far, the facing turns, or this long passes
-- (the world changes under a ghost that is held still: someone walks into it).
DefensePreview.ReplanMove = 0.1
DefensePreview.ReplanAge = 0.25

DefensePreview.ValidColor = Color3.fromRGB(94, 214, 122)
DefensePreview.InvalidColor = Color3.fromRGB(232, 92, 92)

-- Workspace folders only a client has (effects drawn locally): never ground, never in the way. The
-- server has none of them, so leaving them out keeps the client's checks the same as the server's.
DefensePreview.ClientOnlyFolders = { "CompanionFx", "GlassFx", "LootFx", "StormWall", "BRR_GunFx", "BRR_Throwables", "BRR_DefensePreview",
	"BRR_DefenseKits" }

local REFRESH = 1 / 20
local ARC_DOTS = 36
local UP = Vector3.new(0, 1, 0)

--------------------------------------------------------------------------------
-- Prediction
--------------------------------------------------------------------------------

-- The point under the crosshair, the one a throw is sent with. CombatClient's own raycast when it's
-- running (AimState); the same raycast done here otherwise, so a gallery or a probe still works.
function DefensePreview.Aim(character)
	local okState, AimState = pcall(function()
		local module = script.Parent:FindFirstChild("AimState")
		return module and require(module)
	end)
	if okState and AimState and AimState.Get then
		local point = AimState.Get()
		if point then
			return point
		end
	end
	local camera = workspace.CurrentCamera
	if not camera or not character then
		return nil
	end
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	local filter = { character }
	for _, name in ipairs({ "Effects", "Loot" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	local companions = workspace:FindFirstChild("Companions")
	local player = Players.LocalPlayer
	if companions and player then
		for _, model in ipairs(companions:GetChildren()) do
			if model:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(filter, model)
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1500, params)
	return result and result.Position or ray.Origin + ray.Direction * 1500
end

local function clientOnly()
	local list = {}
	if workspace.CurrentCamera then
		table.insert(list, workspace.CurrentCamera)
	end
	for _, name in ipairs(DefensePreview.ClientOnlyFolders) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(list, instance)
		end
	end
	return list
end

-- Where a throw of `itemId` at `aimPoint` goes and whether it builds. Mirrors DefenseService.throwKit and
-- landKit step for step. Returns nil without a body to throw from, otherwise a table:
--   from, target, facing, offset, flightTime, velocity   the lob
--   centre                                            where the site checks start (target + LandLift)
--   size                                              the structure's box, or nil for a mine
--   origin                                            the build frame when the site is good
--   plan                                              and its plan, footings included
--   reason                                            why not, when it isn't
-- `cache` (optional, a table the caller keeps) reuses the last plan while the landing and facing hold
-- still, so a held ghost doesn't re-sample the ground twenty times a second.
function DefensePreview.Site(character, itemId, aimPoint, extraExclude, cache)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local head = character:FindFirstChild("Head") or root
	local look = root.CFrame.LookVector
	local exclude = extraExclude or clientOnly()
	-- The same wall clip the server throws from (DefensePlacement.ThrowOrigin): pressed against a
	-- building, a ghost drawn from an unclipped origin would show the throw starting inside the wall.
	local from = DefensePlacement.ThrowOrigin(character, head.Position, look, exclude)
	local velocity, flightTime, target, facing, offset = DefensePlacement.ThrowArc(from, look, aimPoint)
	-- Where the kit will really arrive, not where it was aimed. The server throws it on this arc and
	-- builds where it stops, and measured on a real map the arc meets the ground a median 10 studs from
	-- the aim point -- it is flat enough to clip a rising hill well short. Walking the same arc here is
	-- the difference between a ghost that lies and one that points at the hillside it will hit.
	-- The same filter the ground check uses, except that standing defenses are NOT left out: a kit
	-- thrown at your own bunker hits the bunker, and the arc should stop there like it will.
	local landing, struck, landTime = DefensePlacement.Landing(from, velocity, flightTime,
		DefensePlacement.GroundParams(character, nil, exclude))

	local result = {
		from = from,
		target = target,
		aimTarget = target,
		facing = facing,
		offset = offset,
		flightTime = flightTime,
		velocity = velocity,
		struck = struck,
		-- When on the arc it arrives, so the dotted lob stops where the kit does.
		landTime = landTime,
		-- How far short of the aim the arc lands, so the label can say so.
		short = (Vector3.new(target.X, 0, target.Z) - Vector3.new(landing.X, 0, landing.Z)).Magnitude,
		size = DefensePlacement.Sizes[itemId],
	}
	result.target = landing
	result.centre = landing + Vector3.new(0, DefensePlacement.LandLift, 0)
	if result.size then
		-- Game time: os.clock is CPU time, not the clock the world changes on.
		local now = time()
		if cache and cache.itemId == itemId and cache.centre and (cache.centre - result.centre).Magnitude < DefensePreview.ReplanMove
			and cache.facing:Dot(facing) > 0.9999 and now - cache.at < DefensePreview.ReplanAge then
			result.origin, result.reason, result.plan = cache.origin, cache.reason, cache.plan
		else
			result.origin, result.reason, result.plan = DefensePlacement.FindSite(character, result.size, result.centre, facing,
				workspace:FindFirstChild("Defenses"), exclude)
			if cache then
				cache.itemId, cache.centre, cache.facing, cache.at = itemId, result.centre, facing, now
				cache.origin, cache.reason, cache.plan = result.origin, result.reason, result.plan
			end
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function folder()
	local existing = workspace.CurrentCamera and workspace.CurrentCamera:FindFirstChild("BRR_DefensePreview")
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "BRR_DefensePreview"
	created.Parent = workspace.CurrentCamera
	return created
end

local function inert(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

function DefensePreview.new()
	local self = setmetatable({}, DefensePreview)
	self.itemId = nil
	self.ghost = nil
	self.ghostParts = {}
	self.lastRefresh = 0
	self.shown = false
	self.siteCache = {}
	-- The footings' ghosts: one pooled part per footing, remade when the footing's shape changes.
	self.footParts = {}

	local root = folder()
	self.root = root

	-- The lob, as dots.
	self.dots = {}
	for index = 1, ARC_DOTS do
		local dot = inert(Instance.new("Part"))
		dot.Name = "ArcDot"
		dot.Shape = Enum.PartType.Ball
		dot.Size = Vector3.new(0.26, 0.26, 0.26)
		dot.Material = Enum.Material.Neon
		dot.Transparency = 1
		dot.Parent = root
		self.dots[index] = dot
	end

	-- The landing ring, and the footprint the site is checked over, both on the ground.
	self.ring = Instance.new("CylinderHandleAdornment")
	self.ring.Name = "LandingRing"
	self.ring.Adornee = workspace.Terrain
	self.ring.Height = 0.2
	self.ring.Transparency = 0.35
	self.ring.Visible = false
	self.ring.Parent = root

	self.footprint = inert(Instance.new("Part"))
	self.footprint.Name = "Footprint"
	self.footprint.Material = Enum.Material.Neon
	self.footprint.Transparency = 1
	self.footprint.Parent = root
	self.frame = Instance.new("SelectionBox")
	self.frame.LineThickness = 0.08
	self.frame.SurfaceTransparency = 1
	self.frame.Transparency = 0.1
	self.frame.Adornee = self.footprint
	self.frame.Visible = false
	self.frame.Parent = root

	-- The front: a chevron on the ground ahead of the structure.
	self.front = {}
	for index = 1, 2 do
		local bar = inert(Instance.new("Part"))
		bar.Name = "Front"
		bar.Material = Enum.Material.Neon
		bar.Size = Vector3.new(0.35, 0.08, 2.4)
		bar.Transparency = 1
		bar.Parent = root
		self.front[index] = bar
	end

	-- No captions. The owner asked for the ghost and the lob without text over them, so what the words
	-- used to say is said in the world instead:
	--   * valid or refused -> the ghost's green or red tint, which always did that job;
	--   * "replaces your oldest" -> the structure that is about to come down is outlined in red;
	--   * "lands short of your aim" -> a marker sits where you aimed, and the dotted lob and the ghost
	--     stop visibly short of it, which is the same sentence drawn rather than written.
	self.oldestHighlight = Instance.new("Highlight")
	self.oldestHighlight.Name = "ReplacesOldest"
	self.oldestHighlight.FillColor = DefensePreview.InvalidColor
	self.oldestHighlight.FillTransparency = 0.72
	self.oldestHighlight.OutlineColor = DefensePreview.InvalidColor
	self.oldestHighlight.OutlineTransparency = 0
	self.oldestHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	self.oldestHighlight.Enabled = false
	self.oldestHighlight.Parent = root

	-- Where the throw was pointed, when that is not where it arrives.
	self.aimMark = inert(Instance.new("Part"))
	self.aimMark.Name = "AimMark"
	self.aimMark.Size = Vector3.new(0.2, 0.2, 0.2)
	self.aimMark.Transparency = 1
	self.aimMark.Parent = root
	self.aimRing = Instance.new("CylinderHandleAdornment")
	self.aimRing.Name = "AimRing"
	self.aimRing.Adornee = workspace.Terrain
	self.aimRing.Height = 0.2
	self.aimRing.Radius = 1.6
	self.aimRing.InnerRadius = 1.1
	self.aimRing.Transparency = 0.25
	self.aimRing.Visible = false
	self.aimRing.Parent = root
	self.aimCross = {}
	for index = 1, 2 do
		local bar = inert(Instance.new("Part"))
		bar.Name = "AimCross" .. index
		bar.Size = Vector3.new(index == 1 and 4.4 or 0.22, 0.06, index == 1 and 0.22 or 4.4)
		bar.Transparency = 1
		bar.Parent = root
		self.aimCross[index] = bar
	end
	return self
end

-- The ghost for an item: a clone of DefenseService's published template, see-through.
function DefensePreview:_ghostFor(itemId)
	if self.itemId == itemId and self.ghost and self.ghost.Parent then
		return self.ghost
	end
	if self.ghost then
		self.ghost:Destroy()
	end
	self.ghost, self.ghostParts, self.itemId = nil, {}, itemId
	local templates = ReplicatedStorage:FindFirstChild("DefenseTemplates")
	local template = templates and templates:FindFirstChild(itemId)
	if not template then
		return nil
	end
	local ghost = template:Clone()
	ghost.Name = "Ghost"
	for _, part in ipairs(ghost:GetDescendants()) do
		if part:IsA("BasePart") then
			inert(part)
			table.insert(self.ghostParts, { part = part, color = part.Color, offset = part.CFrame, neon = part.Material == Enum.Material.Neon })
			part.Material = Enum.Material.SmoothPlastic
		end
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "Outline"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.1
	highlight.Parent = ghost
	self.highlight = highlight
	ghost.Parent = self.root
	self.ghost = ghost
	return ghost
end

function DefensePreview:_paintGhost(origin, valid)
	local tint = valid and DefensePreview.ValidColor or DefensePreview.InvalidColor
	for _, entry in ipairs(self.ghostParts) do
		entry.part.CFrame = origin * entry.offset
		entry.part.Color = entry.neon and tint or entry.color:Lerp(tint, 0.5)
		entry.part.Transparency = entry.neon and 0.35 or 0.62
	end
	if self.highlight then
		self.highlight.FillColor = tint
		self.highlight.OutlineColor = tint:Lerp(Color3.new(1, 1, 1), 0.25)
	end
end

-- The plan's footings as ghosts: the same list, sizes and frames DefenseService builds them from.
function DefensePreview:_drawFootings(footings, valid)
	local tint = valid and DefensePreview.ValidColor or DefensePreview.InvalidColor
	for index, footing in ipairs(footings) do
		local part = self.footParts[index]
		local class = footing.class or "Part"
		-- Compare the effective shape (no `shape` means Block): a pooled float Cylinder must not be
		-- reused for a post or sill. TrussPart has no Shape, hence the class guard.
		if part and (part.ClassName ~= class or (class == "Part" and part.Shape ~= (footing.shape or Enum.PartType.Block))) then
			part:Destroy()
			part = nil
		end
		if not part then
			part = inert(Instance.new(class))
			part.Name = "GhostFooting"
			if footing.shape then
				part.Shape = footing.shape
			end
			part.Material = Enum.Material.SmoothPlastic
			part.Parent = self.root
			self.footParts[index] = part
		end
		part.Size = footing.size
		part.CFrame = footing.cframe
		part.Color = footing.color:Lerp(tint, 0.5)
		part.Transparency = 0.62
	end
	for index = #self.footParts, #footings + 1, -1 do
		self.footParts[index]:Destroy()
		self.footParts[index] = nil
	end
end

function DefensePreview:_drawArc(site, color)
	local g = workspace.Gravity
	local steps = 24
	local spacing = 1.6
	local used, carried = 0, 0
	local previous = site.from
	for step = 1, steps do
		local t = (site.landTime or site.flightTime) * step / steps
		local point = site.from + site.velocity * t - Vector3.new(0, 0.5 * g * t * t, 0)
		local length = (point - previous).Magnitude
		local at = spacing - carried
		while at <= length and used < ARC_DOTS do
			used += 1
			local dot = self.dots[used]
			dot.Position = previous + (point - previous) * (at / length)
			dot.Color = color
			-- Fade in from the hand so the first dots don't sit in your face.
			dot.Transparency = used <= 2 and 0.7 or 0.2
			at += spacing
		end
		carried = length - (at - spacing)
		previous = point
	end
	for index = used + 1, ARC_DOTS do
		self.dots[index].Transparency = 1
	end
end

-- Straight down from `position` onto whatever's there (for drawing a spot the site checks refused).
local function groundBelow(position, character)
	local params = DefensePlacement.GroundParams(character, workspace:FindFirstChild("Defenses"), clientOnly())
	local hit = workspace:Raycast(position + UP * 20, -UP * 60, params)
	return hit and hit.Position or position
end

function DefensePreview:Update(character, itemId, aimPoint, extraExclude)
	local item = ItemData.Get(itemId)
	if not item or item.kind ~= "defense" then
		self:Hide()
		return
	end
	local now = os.clock()
	if self.site and self.siteItem == itemId and now - self.lastRefresh < REFRESH and aimPoint == nil then
		return
	end
	self.lastRefresh = now
	local site = DefensePreview.Site(character, itemId, aimPoint or DefensePreview.Aim(character), extraExclude, self.siteCache)
	if not site then
		self:Hide()
		return
	end
	self.site, self.siteItem = site, itemId
	self.shown = true

	local valid = site.size == nil or site.origin ~= nil
	local tint = valid and DefensePreview.ValidColor or DefensePreview.InvalidColor
	self:_drawArc(site, site.size and tint or item.color)

	local landing = groundBelow(site.target, character)
	self.ring.CFrame = CFrame.new(landing + UP * 0.1) * CFrame.Angles(math.pi / 2, 0, 0)
	local spread = site.size and DefensePreview.StructureMark or DefensePreview.LandingSpread
	self.ring.Radius = spread
	self.ring.InnerRadius = math.max(0, spread - 0.5)
	self.ring.Color3 = site.size and tint or item.color
	self.ring.Visible = true

	if not site.size then
		-- A mine: where it arms. It doesn't count toward the structure cap, so drop any "replaces your
		-- oldest" outline a structure kit held just before left up.
		self:_hideStructure()
		self.oldestHighlight.Enabled = false
		self.oldestHighlight.Adornee = nil
		self:_showAim(site, groundBelow(site.aimTarget, character), item.color)
		return
	end

	-- Where to draw the structure: its build frame, or for a refused site the spot it was tried at.
	local origin = site.origin or (CFrame.new(Vector3.new(site.centre.X, groundBelow(site.centre, character).Y, site.centre.Z))
		* CFrame.lookAt(Vector3.zero, site.facing))
	local ghost = self:_ghostFor(itemId)
	if ghost then
		self:_paintGhost(origin, valid)
	end
	self:_drawFootings(site.plan and site.plan.footings or {}, valid)

	local size = site.size
	self.footprint.Size = Vector3.new(size.X, 0.05, size.Z)
	self.footprint.CFrame = origin * CFrame.new(0, 0.06, 0)
	self.frame.Color3 = tint
	self.frame.Visible = true
	for index, bar in ipairs(self.front) do
		local side = index == 1 and 1 or -1
		bar.Color = tint
		bar.Transparency = 0.15
		bar.CFrame = origin * CFrame.new(side * 0.8, 0.08, -size.Z / 2 - 1.6) * CFrame.Angles(0, side * math.rad(40), 0)
	end

	self:_showAim(site, groundBelow(site.aimTarget, character), tint)
	-- A fourth standing defense knocks this player's oldest down (DefenseService keeps three). The one
	-- that is about to go is outlined in red while the ghost is up, which says it where it happens
	-- instead of in a caption over the new one.
	local oldest = nil
	if valid then
		local defenses = workspace:FindFirstChild("Defenses")
		local player = Players.LocalPlayer
		local mine = {}
		for _, model in ipairs(defenses and defenses:GetChildren() or {}) do
			if player and model:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(mine, model)
			end
		end
		-- The folder holds them in the order they went up, so the first is the server's `mine[1]`.
		if #mine >= 3 then
			oldest = mine[1]
		end
	end
	self.oldestHighlight.Adornee = oldest
	self.oldestHighlight.Enabled = oldest ~= nil
end

-- The aim marker: a ring and a cross where the throw was pointed, drawn only when the kit is going to
-- arrive somewhere else. With the dotted lob stopping at the ghost, the gap between the two is the whole
-- message -- "you pointed there, it lands here" -- without a word of text. Measured median for that gap
-- is 19.6 studs, so it is not a rare case; under 6 studs it is noise and the marker stays down.
function DefensePreview:_showAim(site, aimGround, color)
	local far = site.short ~= nil and site.short > 6 and site.aimTarget ~= nil
	self.aimRing.Visible = far
	for _, bar in ipairs(self.aimCross) do
		bar.Transparency = far and 0.25 or 1
	end
	if not far then
		return
	end
	local aim = aimGround
	self.aimRing.CFrame = CFrame.new(aim + UP * 0.12) * CFrame.Angles(math.pi / 2, 0, 0)
	self.aimRing.Color3 = color
	for _, bar in ipairs(self.aimCross) do
		bar.Color = color
		bar.CFrame = CFrame.new(aim + UP * 0.1)
	end
end
function DefensePreview:_hideStructure()
	if self.ghost then
		self.ghost.Parent = nil
		self.ghost:Destroy()
		self.ghost, self.ghostParts, self.itemId = nil, {}, nil
	end
	self.frame.Visible = false
	for _, bar in ipairs(self.front) do
		bar.Transparency = 1
	end
	self:_drawFootings({}, false)
end

function DefensePreview:Hide()
	if not self.shown then
		return
	end
	self.shown = false
	self.site = nil
	self:_hideStructure()
	for _, dot in ipairs(self.dots) do
		dot.Transparency = 1
	end
	self.ring.Visible = false
	self.oldestHighlight.Enabled = false
	self.oldestHighlight.Adornee = nil
	self.aimRing.Visible = false
	for _, bar in ipairs(self.aimCross) do
		bar.Transparency = 1
	end
end

--------------------------------------------------------------------------------
-- Thrown kits, flown here
--------------------------------------------------------------------------------

-- The server decides where a structure kit lands and builds there when it arrives
-- (DefenseService.throwStructure); the kit in flight is only a picture, so each client flies its own
-- along the same arc (DefensePlacement.ArcPoint) every frame, instead of watching a server part step at
-- replication rate (critic C10). `info` is { itemId, from, velocity, landTime, spin }. Returns the kit
-- (probes), or nil for anything malformed.
function DefensePreview.FlyKit(info)
	if type(info) ~= "table" or typeof(info.from) ~= "Vector3" or typeof(info.velocity) ~= "Vector3"
		or type(info.landTime) ~= "number" or info.landTime ~= info.landTime or info.landTime < 0 or info.landTime > 10 then
		return nil
	end
	local kit = ItemModels.Build(info.itemId, { anchored = true, scale = 1.5, name = tostring(info.itemId) .. "Kit" })
	if not kit then
		return nil
	end
	for _, part in ipairs(kit:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	local spin = typeof(info.spin) == "CFrame" and info.spin or CFrame.new()
	local holder = workspace:FindFirstChild("BRR_DefenseKits")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "BRR_DefenseKits"
		holder.Parent = workspace
	end
	local function place(t)
		kit:PivotTo(CFrame.new(DefensePlacement.ArcPoint(info.from, info.velocity, t)) * spin * CFrame.Angles(t * 5, t * 3, 0))
	end
	place(0)
	kit.Parent = holder
	-- Game time, not os.clock (CPU time), for anything a player sees move.
	local started = time()
	local follow
	follow = RunService.RenderStepped:Connect(function()
		local t = time() - started
		if t >= info.landTime or not kit.Parent then
			follow:Disconnect()
			kit:Destroy()
			return
		end
		place(t)
	end)
	return kit
end

-- On a running client, every structure kit anyone throws is flown here. HudClient requires this module
-- at start, so this listens from the first frame; tools that require it outside a game don't listen.
if RunService:IsClient() and RunService:IsRunning() then
	task.spawn(function()
		local okRemotes, Remotes = pcall(require, Shared:WaitForChild("Remotes"))
		if okRemotes and Remotes then
			Remotes.Event("DefenseKitFlight").OnClientEvent:Connect(function(info)
				pcall(DefensePreview.FlyKit, info)
			end)
		end
	end)
end

function DefensePreview:Destroy()
	self:Hide()
	self.root:Destroy()
end

return DefensePreview
