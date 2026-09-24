-- Parking lots for the towns (Oliver's #31, "real parking lots for cars to spawn on"; landed
-- 2026-09-22 on "land the parking lots feature too").
--
-- Each town gets one painted car park near its square: flat asphalt (MapTerrain.FlattenPad, so it is
-- never on a slope or floating), white bay lines, and a "P" sign. The bays are published on the town as
-- the attributes VehicleService.ParkInTowns already reads (it was written ahead of this and did nothing
-- while no town had any):
--   ParkingBays      how many
--   ParkingBay_<i>   CFrame at the bay's centre on the asphalt, LookVector = the way the car's nose points
--   ParkingBaySize   Vector3 (width, 1, length), TownKinds.Bay
-- The bay count comes from the town's kind (TownKinds `bays.count`), clamped to 4..12.
--
--   ParkingLots.Build(town, center, spread, count, space, rectFree, streets) -> number of bays, or 0
--
-- The car park stands end-on to one of the town's streets (or carries on past the end of one) with its
-- aisle opening onto it, the kerb dropped across the way in (MapDecor.DropKerb) and the way in kept
-- clear. A site that is taken, reaches a road's corridor, or would need more than MAX_CUT / MAX_FILL
-- of earthworks is skipped for the next candidate; where none takes the kind's bay count, a smaller car
-- park is tried, down to four bays. If none fit, the town simply has no car park and its cars stay on
-- the verge, as before; nothing is ever built unpadded, and nothing is built that a car can't drive
-- out of.

local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Modules")
local MapTerrain = require(Modules:WaitForChild("MapTerrain"))
local TownKinds = require(Modules:WaitForChild("TownKinds"))
local MapDecor = require(Modules:WaitForChild("MapDecor"))

local ParkingLots = {}

local BAY = TownKinds.Bay or { width = 8.9, length = 16.6 }
local AISLE = 9 -- drive aisle between two rows, or in front of one
local EDGE = 2 -- asphalt round the bays
local MAX_CUT, MAX_FILL = 7, 7
local LINE = Color3.fromRGB(238, 238, 232)

local function part(parent, size, cframe, color, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function sign(parent, at, facing)
	local post = part(parent, Vector3.new(0.4, 6, 0.4), CFrame.new(at + Vector3.new(0, 3, 0)), Color3.fromRGB(90, 94, 100), Enum.Material.Metal)
	post.CanCollide = true
	post.CanQuery = true
	local board = part(parent, Vector3.new(2.6, 2.6, 0.25),
		CFrame.lookAt(at + Vector3.new(0, 6.4, 0), at + Vector3.new(0, 6.4, 0) + facing), Color3.fromRGB(40, 90, 200))
	board.CanQuery = true
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(100, 100)
		gui.LightInfluence = 0.3
		gui.Parent = board
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBlack
		label.Text = "P"
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Parent = gui
	end
end

-- A car park's shape for `count` bays: one row up to six, two beyond. The aisle runs the lot's length
-- (its X) between the rows, or in front of a single row, which backs onto the lot's -Z side; `aisleZ`
-- is the aisle's middle across the lot.
local function shapeFor(count)
	local rows = count > 6 and 2 or 1
	local perRow = math.ceil(count / rows)
	local width = perRow * BAY.width + EDGE * 2
	local depth = rows * BAY.length + AISLE + EDGE * 2
	return {
		count = count, rows = rows, perRow = perRow, width = width, depth = depth,
		halfX = width / 2 + 2, halfZ = depth / 2 + 2, aisleZ = rows == 1 and BAY.length / 2 or 0,
	}
end

-- Where a car park of `shape` could go on the town's `streets`, nearest the square first. A car park
-- is only a car park if you can drive into it (Oliver 09-24, "make sure all roads are connected";
-- tools/roads_check.py, access), so every site has its aisle opening onto a street, the lot's -X end
-- flush against the back of the pavement:
--   beside a street   end-on to it, anywhere along either side well clear of its ends (junctions,
--                     crossings, the square), so a car backs out of its bay and drives straight out
--   past its end      where a street stops past its last building (its kerb and pavement run across
--                     the end, MapDecor.Street's `closed`), carrying straight on from it
-- `kerb` is where the aisle's middle meets the edge of the street's asphalt, `out` the way into the lot.
local function sites(town, c, streets, shape)
	local list = {}
	local function add(street, kerb, out)
		local yaw = math.atan2(-out.Z, out.X)
		local zAxis = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
		local at = kerb + out * ((street.sidewalk or 0) + shape.width / 2) - zAxis * shape.aisleZ
		table.insert(list, { at = at, yaw = yaw, street = street, out = out, kerb = kerb, score = (at - c).Magnitude })
	end
	-- Which streets are closed off at their far end: a kerb across it, square to the street.
	local capped = {}
	for _, street in ipairs(streets) do
		local b = Vector3.new(street.b.X, 0, street.b.Z)
		for _, kerb in ipairs(town:GetChildren()) do
			if kerb.Name == "Kerb" and kerb:IsA("BasePart") and kerb.Size.X > kerb.Size.Z
				and (Vector3.new(kerb.Position.X, 0, kerb.Position.Z) - b).Magnitude < 1 then
				capped[street] = true
			end
		end
	end
	for _, street in ipairs(streets) do
		-- At the street's own height, which the car park is then laid at.
		local a = Vector3.new(street.a.X, street.a.Y, street.a.Z)
		local delta = Vector3.new(street.b.X - street.a.X, 0, street.b.Z - street.a.Z)
		local length = delta.Magnitude
		if length > 1 then
			local direction = delta / length
			local reach = 14 + shape.depth / 2
			for _, side in ipairs({ 1, -1 }) do
				local out = Vector3.new(-direction.Z, 0, direction.X) * side
				local along = reach
				while along <= length - reach do
					add(street, a + direction * along + out * (street.width / 2), out)
					along += 6
				end
			end
			if capped[street] then
				add(street, a + direction * length, direction)
			end
		end
	end
	table.sort(list, function(p, q)
		return p.score < q.score
	end)
	return list
end

-- `streets` are the town's drawn streets, { a, b, width, entry, sidewalk } each, as MapGenerator draws
-- them. The kind's bay count first; where no site takes that, the largest car park that fits, down
-- to MIN_BAYS, rather than none. Once the candidates are laid out nothing here rolls a random number,
-- so which one is taken changes nothing downstream.
local MIN_BAYS = 4
function ParkingLots.Build(town, center, spread, count, space, rectFree, streets)
	if not town or not center or not space or not rectFree then
		return 0
	end
	count = math.clamp(math.floor(count or 6), MIN_BAYS, 12)
	local c = Vector3.new(center.X, 0, center.Z)
	for bays = count, MIN_BAYS, -1 do
		local shape = shapeFor(bays)
		for _, site in ipairs(sites(town, c, streets or {}, shape)) do
			local at, yaw = site.at, site.yaw
			local frame = CFrame.new(at.X, 0, at.Z) * CFrame.Angles(0, yaw, 0)
			-- Flush against the pavement: the street's own claim is the one it may touch.
			if rectFree(space, at.X, at.Z, yaw, shape.halfX, shape.halfZ, site.street.entry) then
				-- At the street's own ground, not the ground's mean: a pad's flat runs 8 studs past its
				-- margin whatever stands there, which here is the pavement and the edge of the street.
				local ok, height = pcall(MapTerrain.FlattenPad, frame, Vector3.new(shape.width, 0, shape.depth), {
					height = site.kerb.Y, margin = 2, maxCut = MAX_CUT, maxFill = MAX_FILL,
					material = Enum.Material.Asphalt, space = space,
				})
				if ok and type(height) == "number" then
					return ParkingLots._lay(town, site, frame, height, shape, space)
				end
			end
		end
	end
	return 0
end

-- The car park itself, on its pad: claims, the way in, bays, lines, the sign, and the bays published.
function ParkingLots._lay(town, site, frame, height, shape, space)
	local count, rows, perRow, width, depth = shape.count, shape.rows, shape.perRow, shape.width, shape.depth
	space:AddRect(site.at.X, site.at.Z, shape.halfX, shape.halfZ, site.yaw)
	-- The way in: across the pavement and out into the near lane, kept clear of benches, lamps and
	-- kerbside cars the way a driveway's mouth is (MapDecor.Driveways), with the kerb dropped across it.
	local sidewalk = site.street.sidewalk or 0
	local lane = 9
	local entrance = site.kerb + site.out * ((sidewalk - lane) / 2)
	space:AddRect(entrance.X, entrance.Z, (sidewalk + lane) / 2, AISLE / 2 + 1, site.yaw)
	MapDecor.DropKerb(town, site.kerb, site.out, AISLE / 2 + 1, 2)

	local lot = Instance.new("Model")
	lot.Name = "ParkingLot"
	lot.Parent = town
	local base = frame + Vector3.new(0, height, 0)
	local bays = {}
	for row = 1, rows do
		-- Row 1 backs onto the lot's far edge (-Z) with noses pointing out that way; row 2
		-- backs onto the near edge (+Z). The aisle runs between them, or in front of row 1.
		local sign_ = row == 1 and -1 or 1
		local rowZ = sign_ * (depth / 2 - EDGE - BAY.length / 2)
		if rows == 1 then
			rowZ = -depth / 2 + EDGE + BAY.length / 2
		end
		local inRow = row == 1 and perRow or (count - perRow)
		for i = 1, inRow do
			local x = -width / 2 + EDGE + (i - 0.5) * BAY.width
			local centre = base * CFrame.new(x, 0, rowZ)
			local nose = base:VectorToWorldSpace(Vector3.new(0, 0, sign_))
			table.insert(bays, CFrame.lookAt(centre.Position, centre.Position + nose))
		end
		-- Bay lines: one at each side of every bay, running the bay's length.
		for i = 0, inRow do
			local x = -width / 2 + EDGE + i * BAY.width
			part(lot, Vector3.new(0.3, 0.06, BAY.length - 1), base * CFrame.new(x, 0.04, rowZ), LINE)
		end
		-- The line across the back of the row.
		part(lot, Vector3.new(inRow * BAY.width, 0.06, 0.3),
			base * CFrame.new(-width / 2 + EDGE + inRow * BAY.width / 2, 0.04, rowZ + sign_ * (BAY.length / 2 - 0.3)), LINE)
	end
	-- The sign at the street end, on the corner away from the aisle, facing the street.
	sign(lot, (base * CFrame.new(-width / 2 + 1, 0, -depth / 2 + 1)).Position, -site.out)

	town:SetAttribute("ParkingBays", #bays)
	town:SetAttribute("ParkingBaySize", Vector3.new(BAY.width, 1, BAY.length))
	for index, cf in ipairs(bays) do
		town:SetAttribute("ParkingBay_" .. index, cf)
	end
	return #bays
end

return ParkingLots
